import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { randomUUID } from "node:crypto";
import { RUNNER_PATH, DATA_DIR, readCursorApiKey, type HubConfig } from "./config.ts";
import { RunnerConnection } from "./runner.ts";
import { store, type Agent, type Runtime } from "./store.ts";
import { push } from "./push.ts";
import { bootstrapSprite, runnerCommand, uploadRunner } from "./sprites.ts";
import { log } from "./log.ts";
import { clipOutput, fromSdk, resultText } from "./mcp.ts";
import { saveResultImages, toolImages } from "./images.ts";
import type { CursorUI } from "./cursorui.ts";
import { desktopLiveTurns } from "./liveturn.ts";

const TOOLS = {
  ask_user: {
    description:
      "Ask the user (who is usually away from the laptop, on their phone) to make a decision or answer a question. Sends them a push notification and blocks until they answer. Use this instead of asking in plain text whenever you need the user's input to continue. Offer short options when the answer is a choice.",
    inputSchema: {
      type: "object",
      properties: {
        question: { type: "string", description: "The question, phrased so it can be answered from a lock-screen notification." },
        options: { type: "array", items: { type: "string" }, description: "Optional short answer choices (2-5)." },
        context: { type: "string", description: "Optional extra detail shown when the user opens the question." },
      },
      required: ["question"],
    },
  },
  notify_user: {
    description: "Send the user a push notification without waiting for an answer, e.g. to report a milestone.",
    inputSchema: {
      type: "object",
      properties: { title: { type: "string" }, message: { type: "string" } },
      required: ["message"],
    },
  },
  list_agents: {
    description:
      "List everyone you can message: the user's Helm agents and their Cursor desktop chats, across all workspaces, with id, name, kind, workspace, status, and what each was last doing.",
    inputSchema: { type: "object", properties: {} },
  },
  message_agent: {
    description:
      "Send a message to another Helm agent or Cursor chat (by id or name), possibly in another workspace or on a remote sprite. By default waits for its reply: the target's final response to your message is returned to you. Set wait_for_reply to false to just hand something off.",
    inputSchema: {
      type: "object",
      properties: {
        agent: { type: "string", description: "Target id or name, from list_agents. Cursor chats have ids like chat:<id>." },
        message: { type: "string" },
        wait_for_reply: { type: "boolean", description: "Default true." },
      },
      required: ["agent", "message"],
    },
  },
  spawn_agent: {
    description: "Start a new helper agent in a workspace (default: your own) and give it a first task. Returns its id so you can message it.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string" },
        prompt: { type: "string" },
        workspace: { type: "string", description: "Workspace id or name. Defaults to your workspace." },
      },
      required: ["name", "prompt"],
    },
  },
};

/** A Cursor desktop chat, as other agents see it. */
export interface ChatPeer {
  kind: "chat";
  id: string;
  composerId: string;
  windowId: string;
  title: string;
  workspace: string;
  status: string;
  updatedAt?: number;
}

/** Who a message is from: a Helm agent, a Cursor chat, or someone Helm couldn't identify. */
export type Sender = { kind: "agent"; agent: Agent } | ChatPeer | undefined;

const senderId = (f: Sender) => (!f ? undefined : f.kind === "agent" ? f.agent.id : f.id);
const senderName = (f: Sender) => (!f ? "another agent" : f.kind === "agent" ? f.agent.name : f.title);

interface QueueEntry {
  id?: string;
  /** Shown in the transcript once the message actually starts; until then it sits in the queue. */
  userText?: string;
  text: string;
  images?: any[];
  onDone?: (result: { status: string; text: string }) => void;
}

interface Live {
  runId?: string;
  assistantItemId?: string;
  thinkingItemId?: string;
  tools: Map<string, string>;
  texts: string[];
  entry?: QueueEntry;
}

function clip(s: unknown, n = 4000) {
  const str = typeof s === "string" ? s : JSON.stringify(s, null, 1) ?? "";
  return str.length > n ? str.slice(0, n) + `\n… (${str.length - n} more chars)` : str;
}

function toolMeta(result: any): Record<string, unknown> | undefined {
  let r = result;
  if (typeof r === "string") {
    try {
      r = JSON.parse(r);
    } catch {
      return undefined;
    }
  }
  const v = r?.value;
  if (!v || typeof v !== "object") return r?.status === "error" ? { error: clip(r.error ?? r.message ?? "", 400) } : undefined;
  const meta: Record<string, unknown> = {};
  if (typeof v.linesAdded === "number") meta.added = v.linesAdded;
  if (typeof v.linesRemoved === "number") meta.removed = v.linesRemoved;
  if (typeof v.diffString === "string") meta.diff = clip(v.diffString, 3000);
  if (typeof v.totalLines === "number") meta.lines = v.totalLines;
  if (typeof v.exitCode === "number") meta.exitCode = v.exitCode;
  if (typeof v.stdout === "string" || typeof v.stderr === "string") {
    const out = `${v.stdout ?? ""}${v.stderr ? `\n${v.stderr}` : ""}`.trimEnd();
    meta.output = out.length > 2000 ? out.slice(-2000) : out;
  }
  const ws = v.workspaceResults && Object.values(v.workspaceResults)[0];
  const matches = (ws as any)?.output?.matches;
  if (Array.isArray(matches)) meta.files = matches.length;
  return Object.keys(meta).length ? meta : undefined;
}

/** SDK MCP calls become Helm's shared shape; Helm's own tools keep their names. */
function normalizeTool(name: string, args: any): { name: string; args: any } {
  if (name === "mcp" || name === "callMcpTool" || /mcp/i.test(name)) {
    const t = fromSdk(args);
    if (t) return t;
  }
  return { name, args };
}

/** MCP output the agent got back, so the phone can show it. */
function mcpMeta(result: any): Record<string, unknown> | undefined {
  const r = typeof result === "string" ? (() => { try { return JSON.parse(result); } catch { return result; } })() : result;
  if (r?.status === "error") return { error: clip(r.error ?? r.message ?? resultText(r) ?? "", 600) };
  const text = resultText(r?.value ?? r);
  const images = saveResultImages(r?.value ?? r);
  if (!text && !images.length) return undefined;
  return { ...(text ? { output: clipOutput(text) } : {}), ...(images.length ? { images } : {}) };
}

export class AgentManager {
  cfg: HubConfig;
  local: RunnerConnection;
  sprites = new Map<string, RunnerConnection>();
  private live = new Map<string, Live>();
  private queues = new Map<string, QueueEntry[]>();
  private waitingOn = new Map<string, string>();
  private decisionResolvers = new Map<string, (answer: string) => void>();
  private toolRunner = new Map<string, RunnerConnection>();
  private modelsCache?: { at: number; list: any[] };
  private ui?: CursorUI;
  /** Replies that arrived after the sender stopped waiting, by message ref, for get_reply. */
  private lateReplies = new Map<string, { from: string; text: string; at: number }>();

  attachDesktop(ui: CursorUI) {
    this.ui = ui;
  }

  constructor(cfg: HubConfig) {
    this.cfg = cfg;
    this.local = this.makeRunner({ key: "local", label: "laptop", command: process.execPath, args: [RUNNER_PATH], cwd: path.dirname(RUNNER_PATH) });
  }

  private initMsg = () => ({ t: "init", apiKey: readCursorApiKey(), tools: TOOLS, settingSources: this.cfg.settingSources });

  private makeRunner(spec: ConstructorParameters<typeof RunnerConnection>[0]) {
    const r = new RunnerConnection(spec, this.initMsg);
    r.on("message", (m) => this.onRunnerMessage(r, m));
    r.on("exit", () => {
      for (const a of store.s.agents) {
        if (this.runnerFor(a, false) === r && this.live.has(a.id)) this.finishRun(a.id, "error", "The agent host disconnected. Send again to continue.");
      }
    });
    return r;
  }

  private runnerFor(a: Agent, create = true): RunnerConnection | undefined {
    if (a.runtime.kind === "local") return this.local;
    const name = a.runtime.sprite;
    let r = this.sprites.get(name);
    if (!r && create) {
      const cmd = { command: "sprite", args: [] as string[] };
      r = this.makeRunner({
        key: `sprite:${name}`,
        label: `sprite ${name}`,
        ...cmd,
        prepare: async () => {
          await uploadRunner(name);
          const rc = await runnerCommand(name);
          r!.spec.command = rc.command;
          r!.spec.args = rc.args;
        },
      });
      this.sprites.set(name, r);
    }
    return r;
  }

  private agentCwd(a: Agent): { cwd: string; dirs: string[] } {
    if (a.runtime.kind === "sprite") return { cwd: a.runtime.dir!, dirs: [] };
    const w = store.workspace(a.workspaceId);
    const folders = (w?.folders || []).filter((f) => fs.existsSync(f));
    if (folders.length) return { cwd: folders[0], dirs: folders.slice(1) };
    const scratch = path.join(DATA_DIR, "scratch", a.workspaceId);
    fs.mkdirSync(scratch, { recursive: true });
    return { cwd: scratch, dirs: [] };
  }

  async models() {
    if (this.modelsCache && Date.now() - this.modelsCache.at < 10 * 60_000) return this.modelsCache.list;
    const list = await this.local.request({ t: "models" });
    this.modelsCache = { at: Date.now(), list };
    return list;
  }

  async createAgent(input: { workspaceId: string; name?: string; model?: string; runtime?: Runtime; prompt?: string; images?: any[] }) {
    const w = store.workspace(input.workspaceId);
    if (!w) throw new Error("workspace not found");
    const count = store.s.agents.filter((a) => a.workspaceId === w.id).length;
    const runtime: Runtime = input.runtime || { kind: "local" };
    const a: Agent = {
      id: randomUUID().slice(0, 8),
      workspaceId: w.id,
      name: input.name?.trim() || (runtime.kind === "sprite" ? `Remote ${count + 1}` : `Agent ${count + 1}`),
      model: input.model || this.cfg.defaultModel,
      runtime,
      status: runtime.kind === "sprite" ? "starting" : "idle",
      statusDetail: runtime.kind === "sprite" ? "Preparing sprite" : undefined,
      unread: 0,
      queue: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    store.addAgent(a);
    if (runtime.kind === "sprite") {
      store.addItem(a.id, { kind: "system", text: `Setting up sprite **${runtime.sprite}** with \`${runtime.repo}\`${runtime.branch ? ` on \`${runtime.branch}\`` : ""}…` });
      this.prepareSprite(a, input.prompt, input.images);
    } else if (input.prompt) {
      this.sendUser(a.id, input.prompt, input.images);
    }
    return a;
  }

  private async prepareSprite(a: Agent, prompt?: string, images?: any[]) {
    const rt = a.runtime as Extract<Runtime, { kind: "sprite" }>;
    try {
      const dir = await bootstrapSprite(rt.sprite, rt.repo, rt.branch);
      store.updateAgent(a.id, { runtime: { ...rt, dir }, status: "idle", statusDetail: undefined });
      store.addItem(a.id, { kind: "system", text: `Sprite ready. Working in \`${dir}\`.` });
      if (prompt) this.sendUser(a.id, prompt, images);
      else this.pump(a.id);
    } catch (e: any) {
      log.error(`sprite prepare ${rt.sprite}: ${e.message}`);
      store.updateAgent(a.id, { status: "error", statusDetail: "Sprite setup failed" });
      store.addItem(a.id, { kind: "error", text: `Sprite setup failed: ${e.message}` });
    }
  }

  private preamble(a: Agent) {
    const w = store.workspace(a.workspaceId);
    const lines = [
      `You are "${a.name}", one of several Cursor agents the user runs through Helm, a remote control they use from their iPhone, often away from the laptop.`,
      `When you need the user to choose, approve, or clarify something, call the ask_user tool on MCP server "custom-user-tools" rather than asking in plain text; it pushes a notification to their phone and returns their answer.`,
      `You can see the other agents with list_agents, talk to them with message_agent, and start helpers with spawn_agent (same server). Workspace: "${w?.name}".`,
    ];
    if (a.runtime.kind === "sprite") {
      lines.push(
        `You run inside a Fly Sprite (a remote Linux VM), on a clone of github.com/${a.runtime.repo} at ${a.runtime.dir}. The user's laptop cannot see your files: commit and push your work to a branch${a.runtime.branch ? ` (current: ${a.runtime.branch})` : ""} when you finish, and say which branch.`,
      );
    }
    return `<helm_context>\n${lines.join("\n")}\n</helm_context>\n\n`;
  }

  sendUser(agentId: string, text: string, images?: any[]) {
    const a = store.agent(agentId);
    if (!a) throw new Error("agent not found");
    this.enqueue(a, { text, images, userText: text });
  }

  private enqueue(a: Agent, entry: QueueEntry) {
    const q = this.queues.get(a.id) || [];
    q.push({ ...entry, id: entry.id || randomUUID() });
    this.queues.set(a.id, q);
    this.pump(a.id);
    this.syncQueue(a.id);
  }

  private syncQueue(agentId: string) {
    const q = this.queues.get(agentId) || [];
    store.updateAgent(agentId, { queue: q.length, queued: q.filter((e) => e.userText).map((e) => ({ id: e.id!, text: e.userText! })) });
  }

  removeQueued(agentId: string, id: string) {
    const q = this.queues.get(agentId) || [];
    const i = q.findIndex((e) => e.id === id);
    if (i < 0) throw Object.assign(new Error("That message already started"), { status: 409 });
    q.splice(i, 1);
    this.syncQueue(agentId);
    return { ok: true };
  }

  /** Moves a queued message to position `to` among the messages the user can see in the queue. */
  reorderQueued(agentId: string, id: string, to: number) {
    const q = this.queues.get(agentId) || [];
    const i = q.findIndex((e) => e.id === id);
    if (i < 0) throw Object.assign(new Error("That message already started"), { status: 409 });
    const [entry] = q.splice(i, 1);
    const visible = q.filter((e) => e.userText);
    const before = visible[Math.max(0, to)];
    q.splice(before ? q.indexOf(before) : q.length, 0, entry);
    this.syncQueue(agentId);
    return { ok: true, order: q.filter((e) => e.userText).map((e) => e.id) };
  }

  private async pump(agentId: string) {
    const a = store.agent(agentId);
    if (!a || this.live.has(agentId) || a.status === "starting") return;
    const q = this.queues.get(agentId) || [];
    const entry = q.shift();
    if (!entry) return;
    const live: Live = { tools: new Map(), texts: [], entry };
    this.live.set(agentId, live);
    if (entry.userText) store.addItem(agentId, { kind: "user", text: entry.userText });
    store.updateAgent(agentId, { status: "running", statusDetail: undefined });
    this.syncQueue(agentId);
    try {
      const r = this.runnerFor(a)!;
      const { cwd, dirs } = this.agentCwd(a);
      const first = !a.sdkAgentId && !store.transcript(a.id).some((i) => i.kind === "assistant");
      await r.register(a.id, { cwd, dirs, model: a.model, name: a.name, sdkAgentId: a.sdkAgentId });
      this.toolRunner.set(a.id, r);
      await r.send({ t: "send", id: a.id, text: (first ? this.preamble(a) : "") + entry.text, images: entry.images, model: a.model });
    } catch (e: any) {
      this.finishRun(agentId, "error", e.message);
    }
  }

  private finishRun(agentId: string, status: string, error?: string, result?: string) {
    const live = this.live.get(agentId);
    this.live.delete(agentId);
    const a = store.agent(agentId);
    if (!a) return;
    if (live?.assistantItemId) store.patchItem(agentId, live.assistantItemId, { streaming: false });
    if (live?.thinkingItemId) store.patchItem(agentId, live.thinkingItemId, { streaming: false });
    for (const itemId of live?.tools.values() || []) {
      const it = store.transcript(agentId).find((i) => i.id === itemId);
      if (it?.tool?.status === "running") store.patchItem(agentId, itemId, { tool: { ...it.tool, status: status === "finished" ? "completed" : "error" } });
    }
    let finalText = live?.texts.join("").trim() || "";
    if (!finalText && result) {
      finalText = result;
      store.addItem(agentId, { kind: "assistant", text: result });
    }
    if (status === "error") store.addItem(agentId, { kind: "error", text: error || "The run failed." });
    if (status === "cancelled") store.addItem(agentId, { kind: "system", text: "Stopped." });
    for (const [decId, resolve] of this.decisionResolvers) {
      const d = store.s.decisions.find((x) => x.id === decId);
      if (d?.agentId === agentId && !d.answeredAt) {
        store.answerDecision(decId, "(cancelled)");
        this.decisionResolvers.delete(decId);
        resolve("The run ended before the user answered.");
      }
    }
    const lastAssistant = [...store.transcript(agentId)].reverse().find((i) => i.kind === "assistant");
    const q = this.queues.get(agentId) || [];
    store.updateAgent(agentId, {
      status: status === "error" ? "error" : "idle",
      statusDetail: status === "error" ? (error || "").slice(0, 120) : undefined,
      lastText: (lastAssistant?.text || a.lastText || "").slice(0, 300),
      unread: a.unread + 1,
    });
    this.syncQueue(agentId);
    live?.entry?.onDone?.({ status, text: finalText || error || "(no reply)" });
    if (this.cfg.notifyOnFinish && status !== "cancelled" && q.length === 0 && !live?.entry?.onDone) {
      const w = store.workspace(a.workspaceId);
      push(this.cfg.apns, {
        title: status === "error" ? `${a.name} hit an error` : `${a.name} finished`,
        subtitle: w?.name,
        body: (status === "error" ? error : finalText)?.replace(/\s+/g, " ").slice(0, 220) || "Done.",
        category: "AGENT",
        threadId: a.id,
        collapseId: `done-${a.id}`,
        data: { agentId: a.id },
      });
    }
    this.pump(agentId);
  }

  private onRunnerMessage(r: RunnerConnection, m: any) {
    const id = m.id as string;
    if (m.t === "sdk_agent") {
      store.updateAgent(id, { sdkAgentId: m.sdkAgentId });
      return;
    }
    if (m.t === "tool_call") {
      this.handleTool(r, id, m.callId, m.name, m.args || {});
      return;
    }
    const live = this.live.get(id);
    if (!live) return;
    switch (m.t) {
      case "run_start":
        live.runId = m.runId;
        return;
      case "delta":
        return this.onDelta(id, live, m);
      case "event":
        return this.onEvent(id, live, m.ev);
      case "run_end":
        return this.finishRun(id, m.status, m.error, m.result);
    }
  }

  private onDelta(id: string, live: Live, m: any) {
    if (m.kind === "text-delta" && m.text) {
      if (live.thinkingItemId) {
        store.patchItem(id, live.thinkingItemId, { streaming: false });
        live.thinkingItemId = undefined;
      }
      live.texts.push(m.text);
      if (!live.assistantItemId) live.assistantItemId = store.addItem(id, { kind: "assistant", text: m.text, streaming: true, runId: live.runId }).id;
      else store.patchItem(id, live.assistantItemId, {}, m.text);
    } else if (m.kind === "thinking-delta" && m.text) {
      if (!live.thinkingItemId) live.thinkingItemId = store.addItem(id, { kind: "thinking", text: m.text, streaming: true }).id;
      else store.patchItem(id, live.thinkingItemId, {}, m.text);
    } else if (m.kind === "thinking-completed" && live.thinkingItemId) {
      store.patchItem(id, live.thinkingItemId, { streaming: false });
      live.thinkingItemId = undefined;
    }
  }

  private onEvent(id: string, live: Live, ev: any) {
    if (ev.type !== "tool_call") return;
    const existing = live.tools.get(ev.call_id);
    const norm = normalizeTool(ev.name, ev.args);
    const name = norm.name;
    const args = norm.args;
    const meta = (r: any) => (name === "mcp" ? mcpMeta(r) : toolMeta(r));
    if (!existing) {
      if (live.assistantItemId) {
        store.patchItem(id, live.assistantItemId, { streaming: false });
        live.assistantItemId = undefined;
        live.texts.push("\n\n");
      }
      if (live.thinkingItemId) {
        store.patchItem(id, live.thinkingItemId, { streaming: false });
        live.thinkingItemId = undefined;
      }
      const item = store.addItem(id, {
        kind: "tool",
        tool: { name, status: ev.status, args, callId: ev.call_id, result: ev.result !== undefined ? clip(ev.result) : undefined, meta: ev.result !== undefined ? meta(ev.result) : undefined },
      });
      live.tools.set(ev.call_id, item.id);
    } else {
      const it = store.transcript(id).find((i) => i.id === existing);
      const tool = {
        ...(it?.tool as any),
        name,
        status: ev.status,
        args: ev.args ? args : it?.tool?.args,
        result: ev.result !== undefined ? clip(ev.result) : it?.tool?.result,
        meta: ev.result !== undefined ? meta(ev.result) : it?.tool?.meta,
      };
      if (ev.status !== "running") {
        const images = toolImages(tool);
        if (images.length) tool.meta = { ...(tool.meta || {}), images };
      }
      store.patchItem(id, existing, { tool });
    }
  }

  // ---- custom tools -------------------------------------------------------

  private resolveAgent(ref: string, near?: Agent): Agent | undefined {
    const s = String(ref || "").trim().replace(/^@/, "");
    const byId = store.agent(s);
    if (byId) return byId;
    const matches = store.s.agents.filter((a) => a.name.toLowerCase() === s.toLowerCase());
    return matches.find((a) => a.workspaceId === near?.workspaceId) || matches[0];
  }

  private resolveWorkspace(ref: string) {
    const s = String(ref || "").trim().toLowerCase();
    return store.workspace(ref) || store.s.workspaces.find((w) => w.name.toLowerCase() === s);
  }

  private async handleTool(r: RunnerConnection, agentId: string, callId: string, name: string, args: any) {
    const reply = (result: any) => {
      try {
        r.write({ t: "tool_result", callId, result });
      } catch (e: any) {
        log.warn(`tool_result for ${name} dropped: ${e.message}`);
      }
    };
    const a = store.agent(agentId);
    if (!a) return reply({ content: [{ type: "text", text: "Unknown agent." }], isError: true });
    try {
      switch (name) {
        case "ask_user":
          return reply(await this.askUser(a, args));
        case "notify_user": {
          await push(this.cfg.apns, { title: args.title || a.name, subtitle: args.title ? a.name : undefined, body: String(args.message), category: "AGENT", threadId: a.id, data: { agentId: a.id } });
          store.addItem(a.id, { kind: "system", text: `🔔 ${args.title ? `**${args.title}** ` : ""}${args.message}` });
          return reply("Notification sent.");
        }
        case "list_agents":
          return reply(this.directory({ kind: "agent", agent: a }));
        case "message_agent":
          return reply(await this.messageAgent({ kind: "agent", agent: a }, args));
        case "spawn_agent": {
          const w = args.workspace ? this.resolveWorkspace(args.workspace) : store.workspace(a.workspaceId);
          if (!w) return reply({ content: [{ type: "text", text: `No workspace named ${args.workspace}.` }], isError: true });
          const child = await this.createAgent({ workspaceId: w.id, name: args.name, model: a.model });
          this.deliver(child, { kind: "agent", agent: a }, String(args.prompt), false);
          return reply(`Started agent "${child.name}" (id ${child.id}) in workspace "${w.name}". It has your task; message it with message_agent.`);
        }
        default:
          return reply({ content: [{ type: "text", text: `Unknown tool ${name}` }], isError: true });
      }
    } catch (e: any) {
      reply({ content: [{ type: "text", text: e.message }], isError: true });
    }
  }

  private askUser(a: Agent, args: any): Promise<string> {
    const options = Array.isArray(args.options) ? args.options.map(String).filter(Boolean).slice(0, 6) : [];
    const d = store.addDecision({ agentId: a.id, question: String(args.question), options, context: args.context ? String(args.context) : undefined });
    store.addItem(a.id, { kind: "decision", decisionId: d.id, text: d.question });
    store.updateAgent(a.id, { status: "waiting", statusDetail: "Needs your decision" });
    const w = store.workspace(a.workspaceId);
    push(this.cfg.apns, {
      title: `${a.name} needs you`,
      subtitle: w?.name,
      body: d.question + (options.length ? `\n${options.map((o, i) => `${i + 1}. ${o}`).join("   ")}` : ""),
      category: "DECISION",
      threadId: a.id,
      collapseId: d.id,
      data: { agentId: a.id, decisionId: d.id, options },
    });
    return new Promise((resolve) => {
      this.decisionResolvers.set(d.id, (answer) => {
        if (this.live.has(a.id)) store.updateAgent(a.id, { status: "running", statusDetail: undefined });
        resolve(`The user answered: ${answer}`);
      });
    });
  }

  answerDecision(id: string, raw: string) {
    const d = store.s.decisions.find((x) => x.id === id);
    if (!d) throw new Error("decision not found");
    if (d.answeredAt) return d;
    const n = Number(raw.trim());
    const answer = Number.isInteger(n) && n >= 1 && n <= d.options.length ? d.options[n - 1] : raw.trim();
    store.answerDecision(id, answer);
    const resolve = this.decisionResolvers.get(id);
    this.decisionResolvers.delete(id);
    if (resolve) resolve(answer);
    else {
      const a = store.agent(d.agentId);
      if (a) this.sendUser(a.id, `(Answer to your earlier question "${d.question}"): ${answer}`);
    }
    return d;
  }

  private senderWorkspace(f: Sender) {
    return !f ? "" : f.kind === "agent" ? store.workspace(f.agent.workspaceId)?.name || "" : f.workspace;
  }

  private header(from: Sender, ref?: string) {
    const tag = ref ? ` · ref ${ref}` : "";
    if (!from) return `[Message from another agent${tag}]`;
    const what = from.kind === "agent" ? "agent" : "Cursor chat";
    return `[Message from ${what} "${senderName(from)}" (id ${senderId(from)}) in workspace "${this.senderWorkspace(from)}"${tag}]`;
  }

  private deliver(target: Agent, from: Sender | null, text: string, wait: boolean, onDone?: QueueEntry["onDone"]) {
    store.addItem(target.id, {
      kind: "agent_message",
      text,
      from: from ? { agentId: senderId(from)!, name: senderName(from), workspace: this.senderWorkspace(from) } : undefined,
    });
    const header = from === null ? "[Message relayed by the user]" : this.header(from);
    const footer = wait
      ? "They are waiting: your final response this turn is sent back to them automatically."
      : from
        ? "They are not waiting for a reply; use message_agent if you need to answer."
        : "";
    this.enqueue(target, { text: `${header}\n${text}\n\n${footer}`.trim(), onDone });
  }

  /** Cursor's desktop chats that can be messaged. */
  chats(): ChatPeer[] {
    if (!this.ui) return [];
    const out: ChatPeer[] = [];
    for (const w of this.ui.state().windows) {
      for (const c of w.chats) {
        if (!c.composerId) continue;
        out.push({ kind: "chat", id: `chat:${c.composerId}`, composerId: c.composerId, windowId: w.id, title: c.title, workspace: w.workspace, status: c.status, updatedAt: c.updatedAt });
      }
    }
    return out;
  }

  directory(self: Sender) {
    const me = senderId(self);
    return [
      ...store.s.agents
        .filter((x) => !x.archived)
        .map((x) => ({
          id: x.id,
          name: x.name,
          kind: "Helm agent",
          workspace: store.workspace(x.workspaceId)?.name,
          runtime: x.runtime.kind === "sprite" ? `sprite:${x.runtime.sprite} (${x.runtime.repo})` : "laptop",
          status: x.status,
          you: x.id === me || undefined,
          last: x.lastText?.slice(0, 160),
        })),
      ...this.chats().map((c) => ({ id: c.id, name: c.title, kind: "Cursor chat", workspace: c.workspace, status: c.status, you: c.id === me || undefined })),
    ];
  }

  private resolvePeer(ref: string, near: Sender): { kind: "agent"; agent: Agent } | ChatPeer | undefined {
    const s = String(ref || "").trim().replace(/^@/, "");
    const chats = this.chats();
    const chat = chats.find((c) => c.id === s || c.composerId === s);
    if (chat) return chat;
    const agent = store.agent(s);
    if (agent) return { kind: "agent", agent };
    const ws = this.senderWorkspace(near);
    const lc = s.toLowerCase();
    const agents = store.s.agents.filter((a) => !a.archived && a.name.toLowerCase() === lc);
    const named = chats.filter((c) => c.title.toLowerCase() === lc);
    const sameWs = agents.find((a) => store.workspace(a.workspaceId)?.name === ws);
    if (sameWs) return { kind: "agent", agent: sameWs };
    const chatWs = named.find((c) => c.workspace === ws);
    if (chatWs) return chatWs;
    if (agents[0]) return { kind: "agent", agent: agents[0] };
    if (named[0]) return named[0];
    const loose = chats.filter((c) => c.title.toLowerCase().includes(lc));
    return loose.length === 1 ? loose[0] : undefined;
  }

  /**
   * Sends a message from an agent or a chat. `maxWaitMs` is how long the sender can hold the call:
   * Helm agents can wait 20 minutes, MCP callers (Cursor chats) only about a minute before their
   * client gives up, so their late replies are posted into the chat instead.
   */
  async messageAgent(from: Sender, args: any, maxWaitMs = 20 * 60_000): Promise<string> {
    const target = this.resolvePeer(args.agent, from);
    if (!target) return `No agent or chat called "${args.agent}". Call list_agents to see who is available.`;
    const targetId = target.kind === "agent" ? target.agent.id : target.id;
    const targetName = target.kind === "agent" ? target.agent.name : target.title;
    const me = senderId(from);
    if (targetId === me) return "That's you.";
    const wait = args.wait_for_reply !== false;
    if (wait && me) {
      for (let cur: string | undefined = targetId, hops = 0; cur && hops < 20; cur = this.waitingOn.get(cur), hops++) {
        if (cur === me)
          return `"${targetName}" is itself waiting on you, so waiting for its reply would deadlock. Resend with wait_for_reply=false, or finish your turn so your answer reaches it.`;
      }
    }
    const text = String(args.message || "");
    if (!text.trim()) return "The message is empty.";
    const ref = `m-${randomUUID().slice(0, 6)}`;
    log.info(`message ${senderName(from)} → ${targetName}${wait ? " (waiting)" : ""}`);

    let reply: Promise<{ status: string; text: string } | undefined>;
    if (target.kind === "agent") {
      if (!wait) {
        this.deliver(target.agent, from, text, false);
        return `Delivered to "${targetName}".`;
      }
      reply = new Promise((resolve) => this.deliver(target.agent, from, text, true, resolve));
    } else {
      if (!this.ui) return "Cursor isn't connected to Helm right now.";
      const footer = wait
        ? "They are waiting: your final response this turn is sent back to them automatically."
        : "They are not waiting for a reply; use the helm message_agent tool if you need to answer.";
      try {
        await this.ui.locked(target.windowId, () => this.ui!.send(target.windowId, target.title, `${this.header(from, ref)}\n${text}\n\n${footer}`));
      } catch (e: any) {
        return `Couldn't reach Cursor chat "${targetName}": ${e.message}`;
      }
      if (!wait) return `Delivered to Cursor chat "${targetName}".`;
      reply = this.chatReply(target, ref, 20 * 60_000);
    }

    if (from?.kind === "agent") store.updateAgent(from.agent.id, { status: "waiting", statusDetail: `Waiting on ${targetName}` });
    if (me) this.waitingOn.set(me, targetId);
    const release = () => {
      if (me && this.waitingOn.get(me) === targetId) this.waitingOn.delete(me);
      if (from?.kind === "agent" && this.live.has(from.agent.id)) store.updateAgent(from.agent.id, { status: "running", statusDetail: undefined });
    };
    const timeout = new Promise<"timeout">((r) => setTimeout(() => r("timeout"), maxWaitMs));
    const first = await Promise.race([reply, timeout]);
    if (first !== "timeout") {
      release();
      return first ? `Reply from "${targetName}" (${first.status}):\n${first.text}` : `"${targetName}" finished without replying.`;
    }
    // Still working: hand the reply over whenever it comes.
    reply.then((r) => {
      release();
      if (!r) return;
      this.lateReplies.set(ref, { from: targetName, text: r.text, at: Date.now() });
      if (this.lateReplies.size > 200) this.lateReplies.delete(this.lateReplies.keys().next().value!);
      const note = `[Reply from ${target.kind === "agent" ? "agent" : "Cursor chat"} "${targetName}" (id ${targetId}) to your message · ref ${ref}]\n${r.text}`;
      if (from?.kind === "chat" && this.ui) {
        this.ui.locked(from.windowId, () => this.ui!.send(from.windowId, from.title, note)).catch((e) => log.warn(`late reply to ${from.title}: ${e.message}`));
      } else if (from?.kind === "agent") {
        this.enqueue(from.agent, { text: note });
      }
    });
    return from?.kind === "chat"
      ? `Sent (ref ${ref}). "${targetName}" is still working on it; its reply will arrive in this chat as a new message. You can also call get_reply with ref ${ref}.`
      : `No reply from "${targetName}" yet (ref ${ref}). It is still working; its reply will reach you as a message when it's done.`;
  }

  getReply(ref: string) {
    const r = this.lateReplies.get(String(ref || "").trim());
    return r ? `Reply from "${r.from}":\n${r.text}` : `No reply for ${ref} yet.`;
  }

  /** Waits for a Cursor chat to finish the turn our message started, and returns what it said. */
  private async chatReply(chat: ChatPeer, ref: string, ms: number): Promise<{ status: string; text: string } | undefined> {
    const end = Date.now() + ms;
    let idlePolls = 0;
    while (Date.now() < end) {
      await new Promise((r) => setTimeout(r, 2000));
      const c = this.chats().find((x) => x.composerId === chat.composerId);
      const busy = c?.status === "working" || c?.status === "attention";
      const turn = desktopLiveTurns(chat.composerId, busy).find((t) => t.items.some((i) => i.kind === "user" && i.text?.includes(ref)));
      if (!turn || busy) {
        idlePolls = 0;
        continue;
      }
      const last = [...turn.items].reverse().find((i) => i.kind === "assistant" && i.text?.trim());
      if (!last) continue;
      if (++idlePolls < 2) continue;
      return { status: "finished", text: clip(last.text, 8000) };
    }
    return undefined;
  }

  /**
   * Which Cursor chat is making an MCP call right now. Cursor doesn't say who's calling, and while a
   * call runs its database row only has the call id (name "mcp--", no arguments), so the caller is
   * the chat with an MCP call in flight. Two chats calling MCP tools at the same moment can't be told apart.
   */
  async callingChat(tool: string): Promise<ChatPeer | undefined> {
    for (let attempt = 0; attempt < 5; attempt++) {
      const pending: ChatPeer[] = [];
      for (const c of this.chats().filter((c) => c.status === "working")) {
        const turns = desktopLiveTurns(c.composerId, true);
        const items = turns[turns.length - 1]?.items || [];
        const inFlight = items.some((it) => {
          const a: any = it.tool?.args;
          return it.tool?.name === "mcp" && it.tool.status === "running" && (!a?.tool || a.tool === "tool" || a.tool === tool);
        });
        if (inFlight) pending.push(c);
      }
      if (pending.length === 1) return pending[0];
      if (pending.length > 1) {
        log.warn(`helm mcp: ${pending.length} chats are calling tools at once; can't tell which sent ${tool}`);
        return undefined;
      }
      await new Promise((r) => setTimeout(r, 300));
    }
    return undefined;
  }

  relay(fromId: string, toId: string, instruction: string) {
    const from = store.agent(fromId);
    if (!from) throw new Error("agent not found");
    let label: string;
    let text: string;
    if (toId.startsWith("chat:")) {
      const chat = this.chats().find((c) => c.id === toId);
      if (!chat) throw new Error("That Cursor chat isn't open on the Mac");
      label = chat.title;
      text = `Coordinate with the Cursor chat "${chat.title}" (id ${chat.id}, workspace "${chat.workspace}") using message_agent. ${instruction}`.trim();
    } else {
      const to = store.agent(toId);
      if (!to) throw new Error("agent not found");
      label = to.name;
      text = `Coordinate with agent "${to.name}" (id ${to.id}, workspace "${store.workspace(to.workspaceId)?.name}") using message_agent. ${instruction}`.trim();
    }
    store.addItem(from.id, { kind: "user", text: `→ **${label}**: ${instruction}` });
    this.enqueue(from, { text });
  }

  editQueued(agentId: string, id: string, text: string) {
    const e = (this.queues.get(agentId) || []).find((x) => x.id === id);
    if (!e || !e.userText) throw Object.assign(new Error("That message already started"), { status: 409 });
    if (!text) throw Object.assign(new Error("text required"), { status: 400 });
    e.text = text;
    e.userText = text;
    this.syncQueue(agentId);
    return { ok: true };
  }

  /** Jumps a queued message to the front and stops the current run so it starts now. */
  async sendQueuedNow(agentId: string, id: string) {
    const a = store.agent(agentId);
    const q = this.queues.get(agentId) || [];
    const i = q.findIndex((e) => e.id === id);
    if (!a || i < 0) throw Object.assign(new Error("That message already started"), { status: 409 });
    q.unshift(...q.splice(i, 1));
    this.syncQueue(agentId);
    if (!this.live.has(agentId)) {
      this.pump(agentId);
      return { ok: true };
    }
    const r = this.toolRunner.get(agentId) || this.runnerFor(a);
    try {
      await r?.send({ t: "cancel", id: agentId });
    } catch {}
    setTimeout(() => this.live.has(agentId) && this.finishRun(agentId, "cancelled"), 8000);
    return { ok: true };
  }

  async cancel(agentId: string) {
    const a = store.agent(agentId);
    if (!a) return;
    this.queues.set(agentId, []);
    this.syncQueue(agentId);
    if (!this.live.has(agentId)) {
      store.updateAgent(agentId, { status: a.status === "error" ? "error" : "idle" });
      return;
    }
    const r = this.toolRunner.get(agentId) || this.runnerFor(a);
    try {
      await r?.send({ t: "cancel", id: agentId });
    } catch {}
    setTimeout(() => this.live.has(agentId) && this.finishRun(agentId, "cancelled"), 8000);
  }

  async remove(agentId: string) {
    const a = store.agent(agentId);
    if (!a) return;
    await this.cancel(agentId);
    this.runnerFor(a, false)?.unregister(agentId);
    this.live.delete(agentId);
    store.removeAgent(agentId);
  }

  update(agentId: string, patch: { name?: string; model?: string; archived?: boolean }) {
    const clean: any = {};
    if (patch.name?.trim()) clean.name = patch.name.trim();
    if (patch.model) clean.model = patch.model;
    if (typeof patch.archived === "boolean") clean.archived = patch.archived;
    return store.updateAgent(agentId, clean);
  }

  shutdown() {
    this.local.stop();
    for (const r of this.sprites.values()) r.stop();
  }
}

export const hostname = os.hostname();
