import type { Item } from "./store.ts";
import { desktopLiveTool } from "./cursorui.ts";

export interface Wait {
  id: string;
  label: string;
  /** Epoch ms. */
  since: number;
  until: number;
}

const clip = (s: string, n: number) => {
  const t = s.replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n - 1).trimEnd() + "…" : t;
};

/**
 * How long a tool call deliberately blocks for, if it's a wait rather than real work.
 * Names cover Helm's transcripts (`shell`, `AwaitShell`) and Cursor's database (`run_terminal_command_v2`, …).
 */
function waitOf(name: string, a: Record<string, any>): { ms: number; label: string } | undefined {
  const block = Number(a.block_until_ms ?? a.blockUntilMs);
  if (/await/i.test(name) && block >= 3000) {
    const want = typeof a.pattern === "string" ? a.pattern.split("|").map((p: string) => p.trim()).find((p: string) => /\w{3}/.test(p)) : undefined;
    const shell = a.shell_id || a.shellId || a.taskId;
    return { ms: block, label: want ? `Waiting for “${clip(want.replace(/\\/g, ""), 32)}”` : shell ? "Waiting on a background command" : "Pausing before the next step" };
  }
  if (/shell|terminal/i.test(name) && typeof a.command === "string") {
    const m = a.command.match(/^\s*sleep\s+(\d+(?:\.\d+)?)([smh]?)\s*;?\s*$/);
    if (m) {
      const n = Number(m[1]) * (m[2] === "m" ? 60 : m[2] === "h" ? 3600 : 1);
      const desc = a.description ?? a.commandDescription;
      if (n >= 3) return { ms: n * 1000, label: desc ? clip(String(desc), 48) : `Sleeping ${m[1]}${m[2] || "s"}` };
    }
  }
  return undefined;
}

const fresh = (w: Wait) => (Date.now() <= w.until + 15_000 ? w : undefined);

/** A Helm agent sitting on a timer: its last item is a running wait. */
export function activeWait(items: Item[]): Wait | undefined {
  const last = items[items.length - 1];
  if (!last?.tool || last.tool.status !== "running") return undefined;
  const w = waitOf(last.tool.name, (last.tool.args || {}) as Record<string, any>);
  return w && fresh({ id: last.id, label: w.label, since: last.ts, until: last.ts + w.ms });
}

/** A desktop chat sitting on a timer, read live from Cursor's database. */
export function desktopWait(composerId: string): Wait | undefined {
  const t = desktopLiveTool(composerId);
  const w = t && waitOf(t.name, t.args);
  return w && fresh({ id: `lv-${t.id}`, label: w.label, since: t.startedAt, until: t.startedAt + w.ms });
}

/** Marks or appends the waiting step so the app draws it as a countdown. Cached items stay untouched. */
export function withWait(items: Item[], w: Wait | undefined): Item[] {
  if (!w) return items;
  const meta = { waitSince: w.since, waitUntil: w.until, waitLabel: w.label };
  if (items.some((it) => it.id === w.id)) {
    return items.map((it) => (it.id === w.id && it.tool ? { ...it, tool: { ...it.tool, status: "running" as const, meta: { ...it.tool.meta, ...meta } } } : it));
  }
  return [...items, { id: w.id, ts: w.since, kind: "tool", tool: { name: "wait", status: "running", args: {}, meta } }];
}
