#!/usr/bin/env node
// Hosts Cursor SDK agents for the Helm hub. The same file runs on the laptop (as a child
// process of the hub) and inside Fly Sprites (through `sprite exec`). It speaks JSON lines:
// requests arrive on stdin, and every protocol line it writes to stdout starts with MARK so
// stray output from dependencies can never corrupt the stream.

import readline from "node:readline";
import { randomUUID } from "node:crypto";

const MARK = "\u001eHELM ";
const out = (msg) => process.stdout.write(MARK + JSON.stringify(msg) + "\n");
console.log = (...a) => process.stderr.write(a.join(" ") + "\n");
console.info = console.log;

let sdk;
let apiKey;
let toolDefs = {};
let settingSources = ["project", "user", "team", "plugins"];
const agents = new Map();
const pendingTools = new Map();

function errMsg(e) {
  if (!e) return "unknown error";
  return e.message || String(e);
}

function customTools(id) {
  const tools = {};
  for (const [name, def] of Object.entries(toolDefs)) {
    tools[name] = {
      description: def.description,
      inputSchema: def.inputSchema,
      execute: (args) =>
        new Promise((resolve) => {
          const callId = randomUUID();
          pendingTools.set(callId, resolve);
          out({ t: "tool_call", id, callId, name, args });
        }),
    };
  }
  return tools;
}

function agentOptions(id, o) {
  return {
    apiKey,
    name: o.name,
    model: o.model ? { id: o.model } : { id: "auto" },
    disallowedTools: ["askQuestion"],
    local: {
      cwd: o.cwd,
      dirs: o.dirs && o.dirs.length ? o.dirs : undefined,
      settingSources,
      customTools: customTools(id),
    },
  };
}

async function ensureAgent(id) {
  const a = agents.get(id);
  if (!a) throw new Error(`agent ${id} is not registered with this runner`);
  if (a.agent) return a;
  const opts = agentOptions(id, a.opts);
  try {
    a.agent = a.opts.sdkAgentId
      ? await sdk.Agent.resume(a.opts.sdkAgentId, opts)
      : await sdk.Agent.create(opts);
  } catch (e) {
    if (!a.opts.sdkAgentId) throw e;
    out({ t: "log", level: "warn", msg: `resume failed for ${id}, starting fresh: ${errMsg(e)}` });
    a.agent = await sdk.Agent.create(opts);
  }
  if (a.agent.agentId !== a.opts.sdkAgentId) {
    a.opts.sdkAgentId = a.agent.agentId;
    out({ t: "sdk_agent", id, sdkAgentId: a.agent.agentId });
  }
  return a;
}

async function runSend(id, text, images, model, mode) {
  const a = await ensureAgent(id);
  if (a.run) throw new Error("agent is busy");
  const message = images && images.length ? { text, images } : text;
  const run = await a.agent.send(message, {
    model: model ? { id: model } : undefined,
    mode,
    onDelta: ({ update }) => {
      if (update.type === "text-delta" || update.type === "thinking-delta") {
        out({ t: "delta", id, kind: update.type, text: update.text });
      } else if (update.type === "thinking-completed") {
        out({ t: "delta", id, kind: "thinking-completed" });
      } else if (update.type === "shell-output-delta") {
        out({ t: "delta", id, kind: "shell", callId: update.callId, text: update.text ?? update.data });
      }
    },
  });
  a.run = run;
  out({ t: "run_start", id, runId: run.id });
  try {
    for await (const ev of run.stream()) out({ t: "event", id, ev });
    const r = await run.wait();
    out({ t: "run_end", id, runId: run.id, status: r.status, result: r.result, error: r.error?.message, usage: r.usage, durationMs: r.durationMs });
  } finally {
    a.run = undefined;
  }
}

async function handle(msg) {
  switch (msg.t) {
    case "init": {
      apiKey = msg.apiKey;
      if (apiKey) process.env.CURSOR_API_KEY = apiKey;
      toolDefs = msg.tools || {};
      if (msg.settingSources) settingSources = msg.settingSources;
      sdk = await import("@cursor/sdk");
      out({ t: "ready", node: process.version, platform: `${process.platform}-${process.arch}` });
      return;
    }
    case "register": {
      const existing = agents.get(msg.id);
      if (existing) existing.opts = { ...existing.opts, ...msg.opts, sdkAgentId: existing.opts.sdkAgentId || msg.opts.sdkAgentId };
      else agents.set(msg.id, { opts: { ...msg.opts } });
      return;
    }
    case "send": {
      runSend(msg.id, msg.text, msg.images, msg.model, msg.mode).catch((e) => {
        out({ t: "run_end", id: msg.id, status: "error", error: errMsg(e) });
      });
      return;
    }
    case "cancel": {
      const a = agents.get(msg.id);
      if (a?.run) await a.run.cancel().catch(() => {});
      return;
    }
    case "unregister": {
      const a = agents.get(msg.id);
      if (a?.run) await a.run.cancel().catch(() => {});
      a?.agent?.close?.();
      agents.delete(msg.id);
      return;
    }
    case "tool_result": {
      const resolve = pendingTools.get(msg.callId);
      pendingTools.delete(msg.callId);
      resolve?.(msg.result);
      return;
    }
    case "models": {
      const list = await sdk.Cursor.models.list({ apiKey });
      out({ t: "reply", rid: msg.rid, ok: true, data: list });
      return;
    }
    case "ping":
      out({ t: "pong", rid: msg.rid });
      return;
  }
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  handle(msg).catch((e) => {
    if (msg.rid) out({ t: "reply", rid: msg.rid, ok: false, error: errMsg(e) });
    else out({ t: "log", level: "error", msg: `${msg.t}: ${errMsg(e)}` });
  });
});
rl.on("close", () => process.exit(0));
process.on("unhandledRejection", (e) => out({ t: "log", level: "error", msg: `unhandled: ${errMsg(e)}` }));
