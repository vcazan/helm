import path from "node:path";
import { mcpLine, serverName } from "./mcp.ts";
import type { ApnsConfig } from "./config.ts";
import { type CursorUI, desktopTranscript, desktopSubagents } from "./cursorui.ts";
import { store, bus, type Device, type Item } from "./store.ts";
import { sendRaw } from "./push.ts";
import { log } from "./log.ts";
import { activeWait, desktopWait, type Wait } from "./wait.ts";

/** Mirrors `HelmActivityAttributes.ContentState` in the iOS widget. Keep keys in sync. */
export interface ActivityRow {
  id: string;
  name: string;
  place: string;
  state: "working" | "waiting";
  since: number;
  /** What it's doing right now, or what it's asking. */
  detail?: string;
  /** How you can answer from the lock screen. */
  ask?: "approve" | "choose";
  options?: string[];
  approve?: string;
  reject?: string;
  /** Helm decision id, when the ask is an agent's question. */
  decision?: string;
  subagents?: number;
  /** Epoch seconds of a timer the agent is sitting on, so the widget can count it down. */
  waitFrom?: number;
  waitUntil?: number;
}
export interface ActivityState {
  working: number;
  waiting: number;
  rows: ActivityRow[];
}

const since = new Map<string, number>();
const clip = (s: string, n: number) => {
  const t = s.replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n - 1).trimEnd() + "…" : t;
};

function timer(row: ActivityRow, w: Wait | undefined) {
  if (!w || w.until <= Date.now()) return;
  row.detail = w.label;
  row.waitFrom = Math.floor(w.since / 1000);
  row.waitUntil = Math.ceil(w.until / 1000);
}

/** One short line for the latest thing in a transcript. */
export function describe(items: Item[]): string | undefined {
  for (let i = items.length - 1; i >= Math.max(0, items.length - 6); i--) {
    const it = items[i];
    if (it.kind === "tool" && it.tool) {
      const a: any = it.tool.args || {};
      const file = (p: unknown) => (typeof p === "string" ? path.basename(p) : "");
      switch (it.tool.name) {
        case "shell":
          return a.description ? clip(String(a.description), 60) : `$ ${clip(String(a.command || ""), 56)}`;
        case "read":
          return `Reading ${file(a.path)}`;
        case "edit":
        case "write":
          return `Editing ${file(a.path)}`;
        case "delete":
          return `Deleting ${file(a.path)}`;
        case "grep":
        case "glob":
          return `Searching ${clip(String(a.pattern || a.glob_pattern || ""), 40)}`;
        case "task":
          return `Subagent: ${clip(String(a.description || "working"), 48)}`;
        case "web_search":
        case "fetch":
          return "Looking things up online";
        case "todo":
          return "Planning next steps";
        case "mcp":
          return clip(mcpLine(a), 70);
        case "mcp_discover":
          return `Looking up ${serverName(String(a.server || ""))} tools`;
        default:
          return `Using ${it.tool.name}`;
      }
    }
    if (it.kind === "thinking") return "Thinking";
    if (it.kind === "assistant" && it.text) return clip(it.text.split("\n").find((l) => l.trim()) || it.text, 70);
    if (it.kind === "user") return "Reading your message";
  }
  return undefined;
}

export function activityState(ui: CursorUI): ActivityState {
  const rows: ActivityRow[] = [];
  for (const a of store.s.agents) {
    const state = a.status === "waiting" ? "waiting" : a.status === "running" || a.status === "starting" ? "working" : undefined;
    if (!state) continue;
    const row: ActivityRow = { id: a.id, name: a.name, place: store.workspace(a.workspaceId)?.name || "Helm", state, since: 0 };
    const d = store.s.decisions.find((x) => x.agentId === a.id && !x.answeredAt);
    if (state === "waiting" && d) {
      row.detail = clip(d.question, 110);
      row.decision = d.id;
      if (d.options.length) {
        row.ask = "choose";
        row.options = d.options.slice(0, 3).map((o) => clip(o, 60));
      }
    } else {
      const items = store.transcript(a.id);
      row.detail = describe(items) || (a.statusDetail ? clip(a.statusDetail, 70) : undefined);
      timer(row, activeWait(items));
    }
    rows.push(row);
  }
  for (const w of ui.state().windows) {
    for (const c of w.chats) {
      const q = w.question?.chat === c.title ? w.question : undefined;
      const p = w.pending?.chat === c.title ? w.pending : undefined;
      const state = q || p || c.status === "attention" ? "waiting" : c.status === "working" ? "working" : undefined;
      if (!state) continue;
      const row: ActivityRow = { id: `${w.id}:${c.title}`, name: c.title, place: w.workspace, state, since: 0 };
      if (p) {
        row.detail = clip(p.label, 110);
        row.ask = "approve";
        row.approve = clip(p.approve || "Run", 14);
        row.reject = clip(p.reject || "Skip", 14);
      } else if (q) {
        const cur = q.questions.find((x) => x.active) || q.questions[0];
        if (cur) {
          row.detail = clip(cur.prompt, 110);
          if (q.questions.length === 1 && cur.options.length && cur.options.length <= 3) {
            row.ask = "choose";
            row.options = cur.options.map((o) => o.trim().slice(0, 60));
          }
        }
      } else if (c.composerId) {
        try {
          const t = desktopTranscript(c.composerId);
          row.detail = describe(t?.items || []);
          if (state === "working") timer(row, desktopWait(c.composerId));
          const subs = desktopSubagents(c.composerId).filter((s) => s.status === "running").length;
          if (subs) row.subagents = subs;
        } catch {}
      }
      if (state === "waiting" && !row.detail) row.detail = "Waiting for you";
      rows.push(row);
    }
  }
  const now = Math.floor(Date.now() / 1000);
  const live = new Set(rows.map((r) => `${r.id}:${r.state}`));
  for (const k of since.keys()) if (!live.has(k)) since.delete(k);
  for (const r of rows) {
    const k = `${r.id}:${r.state}`;
    if (!since.has(k)) since.set(k, now);
    r.since = since.get(k)!;
  }
  rows.sort((a, b) => (a.state === b.state ? a.since - b.since : a.state === "waiting" ? -1 : 1));
  return {
    working: rows.filter((r) => r.state === "working").length,
    waiting: rows.filter((r) => r.state === "waiting").length,
    rows: rows.slice(0, 4),
  };
}

function payload(event: "start" | "update" | "end", state: ActivityState, alert?: { title: string; body: string }) {
  const now = Math.floor(Date.now() / 1000);
  return {
    aps: {
      timestamp: now,
      event,
      "content-state": state,
      ...(event === "start" ? { "attributes-type": "HelmActivityAttributes", attributes: { hub: "Helm" } } : {}),
      ...(event === "end" ? { "dismissal-date": now + 4 * 60 } : {}),
      ...(alert ? { alert, sound: "default" } : {}),
      // Ranks Helm above other activities on the lock screen and Watch while something waits on you.
      "relevance-score": state.waiting > 0 ? 100 : 50,
      "stale-date": now + 30 * 60,
    },
  };
}

/** Keeps each paired phone's lock-screen activity current, and starts one remotely when work begins. */
export function startLiveActivities(cfg: () => ApnsConfig | undefined, ui: CursorUI) {
  let last = "";
  let lastShape = "";
  let lastWaiting = 0;
  let timer: NodeJS.Timeout | undefined;
  let lastSent = 0;

  const send = async () => {
    timer = undefined;
    const apns = cfg();
    if (!apns) return;
    const state = activityState(ui);
    const key = JSON.stringify({ ...state, rows: state.rows.map(({ since: _s, ...r }) => r) });
    if (key === last) return;
    // Step-by-step progress changes often; only who's working or waiting is urgent.
    const shape = JSON.stringify(state.rows.map((r) => [r.id, r.state, r.detail && r.state === "waiting" ? r.detail : "", r.waitUntil ?? 0]));
    if (shape === lastShape && Date.now() - lastSent < 8000) {
      schedule(8000 - (Date.now() - lastSent));
      return;
    }
    const active = state.rows.length > 0;
    const becameWaiting = state.waiting > lastWaiting;
    last = key;
    lastShape = shape;
    lastWaiting = state.waiting;
    lastSent = Date.now();
    const topic = `${apns.bundleId}.push-type.liveactivity`;
    const priority = becameWaiting || !active ? "10" : "5";
    const devices = store.s.devices.filter((d) => d.activityToken || d.activityStartToken);
    const body = JSON.stringify(payload(active ? "update" : "end", state));
    if (body.length > 3800) log.warn(`live activity payload ${body.length} bytes`);
    await Promise.all(
      devices.map(async (d: Device) => {
        if (d.activityToken) {
          const ask = state.rows.find((r) => r.state === "waiting");
          const alert = becameWaiting && ask ? { title: `${ask.name} needs you`, body: ask.detail || "Waiting for you" } : undefined;
          const ok = await sendRaw(apns, d, d.activityToken, topic, "liveactivity", priority, payload(active ? "update" : "end", state, alert));
          if (!ok || !active) {
            d.activityToken = undefined;
            store.upsertDevice(d);
          }
        } else if (active && d.activityStartToken) {
          const first = state.rows[0];
          const ok = await sendRaw(apns, d, d.activityStartToken, topic, "liveactivity", "10", payload("start", state, { title: first.name, body: first.detail || (first.state === "waiting" ? "Needs you" : "Working") }));
          if (ok) log.info(`live activity started on ${d.name}`);
        }
      }),
    );
  };

  const schedule = (delay?: number) => {
    if (timer) return;
    const wait = delay ?? Math.max(400, 2500 - (Date.now() - lastSent));
    timer = setTimeout(() => send().catch((e) => log.warn(`live activity: ${e.message}`)), wait);
  };
  bus.on("event", (ev: { type: string }) => {
    if (ev.type === "agent" || ev.type === "desktop" || ev.type === "removed" || ev.type === "decision" || ev.type === "item") schedule();
  });
  // Desktop transcripts change without bus events; look again while anything is working.
  setInterval(() => {
    if (last && last !== JSON.stringify({ working: 0, waiting: 0, rows: [] })) schedule();
  }, 5000).unref();
  return { refresh: () => { last = ""; lastShape = ""; schedule(); }, state: () => activityState(ui) };
}
