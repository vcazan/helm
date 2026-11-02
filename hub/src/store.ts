import fs from "node:fs";
import path from "node:path";
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { DATA_DIR, TRANSCRIPTS_DIR } from "./config.ts";

export interface Workspace {
  id: string;
  name: string;
  folders: string[];
  source: "cursor" | "hub";
  pinned: boolean;
  hidden: boolean;
  createdAt: number;
  lastActiveAt: number;
}

export type Runtime =
  | { kind: "local" }
  | { kind: "sprite"; sprite: string; repo: string; branch?: string; dir?: string };

export type AgentStatus = "idle" | "starting" | "running" | "waiting" | "error";

export interface Agent {
  id: string;
  workspaceId: string;
  name: string;
  model: string;
  runtime: Runtime;
  sdkAgentId?: string;
  status: AgentStatus;
  statusDetail?: string;
  lastText?: string;
  unread: number;
  queue: number;
  queued?: Array<{ id: string; text: string }>;
  /** Tucked away by the user; still kept, just out of the main list. */
  archived?: boolean;
  createdAt: number;
  updatedAt: number;
}

export interface Decision {
  id: string;
  agentId: string;
  question: string;
  options: string[];
  context?: string;
  createdAt: number;
  answeredAt?: number;
  answer?: string;
}

export interface Device {
  id: string;
  name: string;
  apnsToken?: string;
  apnsEnv: "sandbox" | "production";
  activityToken?: string;
  /** The APNs environment Live Activity tokens turned out to belong to, when it isn't `apnsEnv`. */
  activityEnv?: "sandbox" | "production";
  activityStartToken?: string;
  lastSeenAt: number;
}

export type ItemKind = "user" | "assistant" | "thinking" | "tool" | "agent_message" | "decision" | "system" | "error";

export interface Item {
  durationMs?: number;
  id: string;
  ts: number;
  kind: ItemKind;
  text?: string;
  tool?: { name: string; status: "running" | "completed" | "error"; args?: unknown; result?: string; callId?: string; meta?: Record<string, unknown> };
  from?: { agentId: string; name: string; workspace: string };
  decisionId?: string;
  streaming?: boolean;
  runId?: string;
}

interface State {
  workspaces: Workspace[];
  agents: Agent[];
  decisions: Decision[];
  devices: Device[];
}

const STATE_PATH = path.join(DATA_DIR, "state.json");

export const bus = new EventEmitter();
bus.setMaxListeners(100);

class Store {
  s: State;
  private saveTimer?: NodeJS.Timeout;
  private transcripts = new Map<string, Item[]>();

  constructor() {
    this.s = { workspaces: [], agents: [], decisions: [], devices: [] };
    if (fs.existsSync(STATE_PATH)) {
      this.s = { ...this.s, ...JSON.parse(fs.readFileSync(STATE_PATH, "utf8")) };
    }
    for (const a of this.s.agents) {
      if (a.status !== "idle" && a.status !== "error") {
        a.status = "idle";
        a.statusDetail = undefined;
      }
      a.queue = 0;
    }
  }

  save() {
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.flush(), 200);
  }

  flush() {
    const tmp = STATE_PATH + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(this.s, null, 1), { mode: 0o600 });
    fs.renameSync(tmp, STATE_PATH);
  }

  workspace(id: string) {
    return this.s.workspaces.find((w) => w.id === id);
  }

  agent(id: string) {
    return this.s.agents.find((a) => a.id === id);
  }

  upsertWorkspace(w: Workspace) {
    const i = this.s.workspaces.findIndex((x) => x.id === w.id);
    if (i >= 0) this.s.workspaces[i] = w;
    else this.s.workspaces.push(w);
    this.save();
    bus.emit("event", { type: "workspace", workspace: w });
  }

  removeWorkspace(id: string) {
    this.s.workspaces = this.s.workspaces.filter((w) => w.id !== id);
    this.save();
    bus.emit("event", { type: "removed", kind: "workspace", id });
  }

  updateAgent(id: string, patch: Partial<Agent>) {
    const a = this.agent(id);
    if (!a) return;
    Object.assign(a, patch, { updatedAt: Date.now() });
    const w = this.workspace(a.workspaceId);
    if (w) w.lastActiveAt = Date.now();
    this.save();
    bus.emit("event", { type: "agent", agent: a });
    return a;
  }

  addAgent(a: Agent) {
    this.s.agents.push(a);
    this.save();
    bus.emit("event", { type: "agent", agent: a });
  }

  removeAgent(id: string) {
    this.s.agents = this.s.agents.filter((a) => a.id !== id);
    this.transcripts.delete(id);
    fs.rmSync(path.join(TRANSCRIPTS_DIR, `${id}.json`), { force: true });
    this.save();
    bus.emit("event", { type: "removed", kind: "agent", id });
  }

  transcript(agentId: string): Item[] {
    let t = this.transcripts.get(agentId);
    if (!t) {
      const p = path.join(TRANSCRIPTS_DIR, `${agentId}.json`);
      t = fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, "utf8")) : [];
      for (const it of t!) it.streaming = false;
      this.transcripts.set(agentId, t!);
    }
    return t!;
  }

  private transcriptTimers = new Map<string, NodeJS.Timeout>();
  private saveTranscript(agentId: string) {
    clearTimeout(this.transcriptTimers.get(agentId));
    this.transcriptTimers.set(
      agentId,
      setTimeout(() => {
        const t = this.transcripts.get(agentId);
        if (t) fs.writeFileSync(path.join(TRANSCRIPTS_DIR, `${agentId}.json`), JSON.stringify(t));
      }, 500),
    );
  }

  addItem(agentId: string, item: Omit<Item, "id" | "ts"> & { id?: string }): Item {
    const full: Item = { id: randomUUID(), ts: Date.now(), ...item } as Item;
    this.transcript(agentId).push(full);
    this.saveTranscript(agentId);
    bus.emit("event", { type: "item", agentId, item: full });
    return full;
  }

  patchItem(agentId: string, itemId: string, patch: Partial<Item>, appendText?: string) {
    const it = this.transcript(agentId).find((i) => i.id === itemId);
    if (!it) return;
    Object.assign(it, patch);
    if (appendText) it.text = (it.text || "") + appendText;
    this.saveTranscript(agentId);
    if (appendText && Object.keys(patch).length === 0) {
      bus.emit("event", { type: "append", agentId, itemId, text: appendText });
    } else {
      bus.emit("event", { type: "item", agentId, item: it });
    }
  }

  addDecision(d: Omit<Decision, "id" | "createdAt">): Decision {
    const full = { id: randomUUID(), createdAt: Date.now(), ...d };
    this.s.decisions.push(full);
    this.s.decisions = this.s.decisions.filter((x) => !x.answeredAt || Date.now() - x.answeredAt < 7 * 864e5);
    this.save();
    bus.emit("event", { type: "decision", decision: full });
    return full;
  }

  answerDecision(id: string, answer: string) {
    const d = this.s.decisions.find((x) => x.id === id);
    if (!d || d.answeredAt) return undefined;
    d.answer = answer;
    d.answeredAt = Date.now();
    this.save();
    bus.emit("event", { type: "decision", decision: d });
    return d;
  }

  upsertDevice(dev: Device) {
    const i = this.s.devices.findIndex((x) => x.id === dev.id);
    if (i >= 0) this.s.devices[i] = dev;
    else this.s.devices.push(dev);
    this.save();
  }
}

export const store = new Store();
process.on("exit", () => store.flush());
