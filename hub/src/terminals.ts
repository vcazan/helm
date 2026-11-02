import fs from "node:fs";
import path from "node:path";
import type { Item } from "./store.ts";
import { PROJECTS, transcriptPath } from "./cursorui.ts";

/**
 * Terminals Cursor's agents start. Each one is a file at `~/.cursor/projects/<project>/terminals/<id>.txt`:
 * a `---` header (pid, cwd, command, title, status, started_at), the output as it streams, and once the
 * command exits a `---` footer with exit_code, elapsed_ms and ended_at. The header is rewritten in place.
 */
export interface TerminalInfo {
  id: string;
  title?: string;
  command?: string;
  cwd?: string;
  status: string;
  exitCode?: number;
  startedAt?: number;
  endedAt?: number;
  elapsedMs?: number;
}

const HEAD_BYTES = 8192;
const TAIL_BYTES = 256 * 1024;

function unquote(v: string): string {
  const s = v.trim();
  if (s.startsWith('"')) {
    try {
      return JSON.parse(s);
    } catch {}
  }
  return s;
}

function fields(block: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of block.split("\n")) {
    const m = line.match(/^([a-z_]+):\s?(.*)$/);
    if (m) out[m[1]] = unquote(m[2]);
  }
  return out;
}

/** Splits the raw head of a terminal file into its header fields and the byte offset the output starts at. */
function header(head: Buffer): { f: Record<string, string>; bodyStart: number } | undefined {
  const text = head.toString("utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) return undefined;
  return { f: fields(m[1]), bodyStart: Buffer.byteLength(m[0]) };
}

const FOOTER = /\n?---\n((?:[a-z_]+:.*\n)+)---\n?$/;

function info(id: string, f: Record<string, string>, footer?: Record<string, string>): TerminalInfo {
  const num = (v?: string) => (v !== undefined && v !== "" && Number.isFinite(Number(v)) ? Number(v) : undefined);
  const time = (v?: string) => (v ? Date.parse(v) || undefined : undefined);
  const exitCode = num(footer?.exit_code);
  let status = (f.status || "").trim() || (footer ? "finished" : "running");
  if (footer && status === "running") status = exitCode === 0 ? "succeeded" : "failed";
  return {
    id,
    title: f.title || undefined,
    command: f.command || undefined,
    cwd: f.cwd || undefined,
    status,
    exitCode,
    startedAt: time(f.started_at),
    endedAt: time(footer?.ended_at),
    elapsedMs: num(footer?.elapsed_ms) ?? num(f.running_for_ms),
  };
}

/** Escape sequences shells and progress bars emit; carriage returns keep only the last redraw of a line. */
export function plain(s: string): string {
  return s
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
    .replace(/\x1b[()][A-Za-z0-9]/g, "")
    .replace(/[^\n]*\r(?!\n)/g, "")
    .replace(/\r\n/g, "\n")
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
}

function projectOf(composerId?: string): string | undefined {
  const t = composerId ? transcriptPath(composerId) : undefined;
  if (!t) return undefined;
  const rel = path.relative(PROJECTS, t).split(path.sep)[0];
  return rel ? path.join(PROJECTS, rel) : undefined;
}

function fileFor(id: string, composerId?: string): string | undefined {
  if (!/^\d{1,12}$/.test(id)) return undefined;
  const own = projectOf(composerId);
  if (own) {
    const f = path.join(own, "terminals", `${id}.txt`);
    if (fs.existsSync(f)) return f;
  }
  let best: { f: string; m: number } | undefined;
  for (const p of fs.readdirSync(PROJECTS)) {
    const f = path.join(PROJECTS, p, "terminals", `${id}.txt`);
    try {
      const m = fs.statSync(f).mtimeMs;
      if (!best || m > best.m) best = { f, m };
    } catch {}
  }
  return best?.f;
}

function readRange(fd: number, start: number, end: number): Buffer {
  const buf = Buffer.alloc(Math.max(0, end - start));
  if (buf.length) fs.readSync(fd, buf, 0, buf.length, start);
  return buf;
}

/**
 * A terminal's details and output. `from` is the `next` offset of an earlier read: only what was
 * written since comes back. While it runs, output stops at the last complete line so a read never
 * splits a line or a character.
 */
export function readTerminal(id: string, composerId?: string, from = 0) {
  const file = fileFor(id, composerId);
  if (!file) return undefined;
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const h = header(readRange(fd, 0, Math.min(size, HEAD_BYTES)));
    if (!h) return undefined;
    const tailStart = Math.max(h.bodyStart, size - 512);
    const end = readRange(fd, tailStart, size).toString("utf8");
    const fm = end.match(FOOTER);
    const footer = fm ? fields(fm[1]) : undefined;
    const bodyEnd = fm ? size - Buffer.byteLength(fm[0]) : size;
    const t = info(id, h.f, footer);

    const resume = from >= h.bodyStart && from <= bodyEnd;
    let start = resume ? from : Math.max(h.bodyStart, bodyEnd - TAIL_BYTES);
    let chunk = readRange(fd, start, bodyEnd);
    if (!resume && start > h.bodyStart) {
      const nl = chunk.indexOf(10);
      if (nl >= 0) {
        chunk = chunk.subarray(nl + 1);
        start += nl + 1;
      }
    }
    if (t.status === "running") {
      const nl = chunk.lastIndexOf(10);
      chunk = chunk.subarray(0, nl + 1);
    }
    return {
      ...t,
      output: plain(chunk.toString("utf8")),
      append: resume,
      truncated: !resume && start > h.bodyStart,
      next: start + chunk.length,
    };
  } finally {
    fs.closeSync(fd);
  }
}

const listCache = new Map<string, { m: number; t: TerminalInfo }>();

/** Every agent terminal in a project, newest first. Terminals the person opened themselves have no command and are left out. */
export function projectTerminals(composerId: string): TerminalInfo[] {
  const dir = projectOf(composerId);
  if (!dir) return [];
  const tdir = path.join(dir, "terminals");
  let names: string[] = [];
  try {
    names = fs.readdirSync(tdir).filter((n) => /^\d+\.txt$/.test(n));
  } catch {
    return [];
  }
  const out: TerminalInfo[] = [];
  for (const n of names) {
    const f = path.join(tdir, n);
    try {
      const st = fs.statSync(f);
      const hit = listCache.get(f);
      if (hit && hit.m === st.mtimeMs) {
        out.push(hit.t);
        continue;
      }
      const fd = fs.openSync(f, "r");
      try {
        const h = header(readRange(fd, 0, Math.min(st.size, HEAD_BYTES)));
        if (!h?.f.command) continue;
        const fm = readRange(fd, Math.max(h.bodyStart, st.size - 512), st.size).toString("utf8").match(FOOTER);
        const t = info(n.replace(/\.txt$/, ""), h.f, fm ? fields(fm[1]) : undefined);
        listCache.set(f, { m: st.mtimeMs, t });
        out.push(t);
      } finally {
        fs.closeSync(fd);
      }
    } catch {}
  }
  if (listCache.size > 2000) for (const k of [...listCache.keys()].slice(0, listCache.size - 2000)) listCache.delete(k);
  return out.sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0));
}

const norm = (s: unknown) => (typeof s === "string" ? s.replace(/…$/, "").trim().slice(0, 500) : "");

/**
 * Links shell calls to the terminal they left running. Live turns know the terminal id; older turns
 * come from the transcript file, which doesn't, so those match on the command, newest call to newest terminal.
 */
export function withTerminals(items: Item[], composerId: string): Item[] {
  const shells = items.filter((it) => it.tool?.name === "shell");
  if (!shells.length) return items;
  const terms = projectTerminals(composerId);
  if (!terms.length) return items;
  const byId = new Map(terms.map((t) => [t.id, t]));
  const taken = new Set(shells.map((s) => s.tool?.meta?.terminal).filter(Boolean) as string[]);
  const pick = new Map<Item, TerminalInfo>();
  for (let i = shells.length - 1; i >= 0; i--) {
    const s = shells[i];
    const known = s.tool?.meta?.terminal as string | undefined;
    if (known) {
      const t = byId.get(known);
      if (t) pick.set(s, t);
      continue;
    }
    const cmd = norm((s.tool?.args as any)?.command);
    if (!cmd) continue;
    const t = terms.find((t) => !taken.has(t.id) && norm(t.command).startsWith(cmd));
    if (!t) continue;
    taken.add(t.id);
    pick.set(s, t);
  }
  if (!pick.size) return items;
  return items.map((it) => {
    const t = pick.get(it);
    if (!t || !it.tool) return it;
    return { ...it, tool: { ...it.tool, meta: { ...it.tool.meta, terminal: t.id, terminalStatus: t.status, terminalTitle: t.title } } };
  });
}
