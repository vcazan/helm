import type { Item } from "./store.ts";
import { cursorDb, LAST_USER_ROWIDS, userParts } from "./cursorui.ts";
import { log } from "./log.ts";
import { clipOutput, fromDatabase, mcpDiscover, rememberResults, resultText } from "./mcp.ts";
import { lineDiff, type LineDiff } from "./diff.ts";
import { saveResultImages } from "./images.ts";

/** Exact edit diffs by content pair, and by call id so they outlive the live window. */
const contentDiffs = new Map<string, LineDiff>();
const exactEdits = new Map<string, LineDiff>();

/** The edit's before/after file contents are in Cursor's database; diff them for exact counts. */
function editDiff(db: any, result: any): LineDiff | undefined {
  const b = result?.beforeContentId, a = result?.afterContentId;
  if (typeof a !== "string") return undefined;
  const key = `${b}|${a}`;
  const hit = contentDiffs.get(key);
  if (hit) return hit;
  try {
    const get = (k: unknown) => (typeof k === "string" ? (db.prepare(`SELECT value FROM cursorDiskKV WHERE key = ?`).get(k) as any)?.value : undefined);
    const after = get(a);
    if (typeof after !== "string") return undefined;
    const before = get(b);
    const d = lineDiff(typeof before === "string" ? before : "", after, 3);
    contentDiffs.set(key, d);
    if (contentDiffs.size > 2000) contentDiffs.delete(contentDiffs.keys().next().value!);
    return d;
  } catch {
    return undefined;
  }
}

/**
 * The turn a desktop chat is on, read from Cursor's database. Cursor writes each reply,
 * thought and tool call there the moment it happens; the transcript file catches up minutes
 * later, so this is what lets the phone show the agent working inline.
 */
export interface LiveTurn {
  userText: string;
  items: Item[];
}

/** How many recent turns come from the database, so a finished turn doesn't swap ids while it's on screen. */
const RECENT = 3;

const parse = (v: unknown): any => {
  if (typeof v !== "string" || !v) return {};
  try {
    return JSON.parse(v);
  } catch {
    return {};
  }
};
const tail = (s: string, n: number) => (s.length > n ? "…" + s.slice(-n) : s);

/** Cursor's internal tool names and argument shapes, mapped onto the ones transcripts use. */
function tool(name: string, params: any, raw: any, result: any): { name: string; args: Record<string, unknown>; meta: Record<string, unknown> } {
  const meta: Record<string, unknown> = {};
  switch (name) {
    case "run_terminal_command_v2": {
      if (typeof result.output === "string") meta.output = tail(result.output, 4000);
      if (typeof result.exitCode === "number") meta.exitCode = result.exitCode;
      if (result.backgroundShellId != null) meta.terminal = String(result.backgroundShellId);
      return { name: "shell", args: { command: params.command, description: params.commandDescription, isBackground: params.isBackground }, meta };
    }
    case "read_file_v2":
      if (typeof result.totalLinesInFile === "number" && result.totalLinesInFile > 0) meta.lines = result.totalLinesInFile;
      return { name: "read", args: { path: params.targetFile || raw.path }, meta };
    case "edit_file_v2":
      return { name: "edit", args: { path: params.relativeWorkspacePath || raw.path }, meta };
    case "ripgrep_raw_search":
      return { name: "grep", args: { pattern: params.pattern ?? raw.pattern, path: params.path ?? raw.path }, meta };
    case "glob_file_search":
      return { name: "glob", args: { glob_pattern: params.globPattern ?? raw.glob_pattern ?? raw.globPattern }, meta };
    case "delete_file":
      return { name: "delete", args: { path: params.targetFile ?? raw.path }, meta };
    case "task_v2":
      if (typeof result.agentId === "string") meta.subagentId = result.agentId;
      return { name: "task", args: { description: params.description, prompt: params.prompt, subagent_type: params.subagentType, resume: params.resume }, meta };
    case "web_search":
      return { name: "web_search", args: { search_term: params.searchTerm ?? raw.searchTerm }, meta };
    case "web_fetch":
      return { name: "fetch", args: { url: params.url ?? raw.url }, meta };
    case "todo_write":
      return { name: "todo", args: {}, meta };
    case "ask_question":
      return { name: "ask_user", args: { question: params.title || params.questions?.[0]?.prompt }, meta };
    case "await":
      return { name: "AwaitShell", args: { block_until_ms: raw.blockUntilMs, shell_id: raw.taskId || undefined }, meta };
    case "get_mcp_tools": {
      const d = mcpDiscover(params.server ?? raw.server, params.toolName ?? raw.toolName, params.pattern ?? raw.pattern);
      return { ...d, meta };
    }
  }
  if (name.startsWith("mcp-")) {
    const text = resultText(result.result ?? result);
    if (typeof text === "string") meta.output = clipOutput(text);
    const images = saveResultImages(result.result ?? result);
    if (images.length) meta.images = images;
    const t = fromDatabase(name, raw);
    return { ...t, meta };
  }
  return { name, args: { ...raw, ...params }, meta };
}

export function desktopLiveTurns(composerId: string, working: boolean): LiveTurn[] {
  if (!composerId) return [];
  try {
    const users: any[] = cursorDb()
      .prepare(
        `SELECT rowid, key, json_extract(value,'$.text') text, json_extract(value,'$.createdAt') at FROM cursorDiskKV
         WHERE rowid IN (${LAST_USER_ROWIDS(RECENT)}) ORDER BY json_extract(value,'$.createdAt') DESC`,
      )
      .all(`bubbleId:${composerId}:`, `bubbleId:${composerId};`, `bubbleId:${composerId}:`.length + 1);
    return users
      .reverse()
      .filter((u) => u.key && typeof u.text === "string")
      .map((u, i, all) => turn(composerId, u, all[i + 1]?.at, working && i === all.length - 1))
      .filter((t): t is LiveTurn => !!t);
  } catch (e: any) {
    log.warn(`cursor live turns: ${e.message}`);
    return [];
  }
}

function turn(composerId: string, user: { rowid: number; key: string; text: string; at?: string }, nextAt: string | undefined, working: boolean): LiveTurn | undefined {
  try {
    const db = cursorDb();
    const lo = `bubbleId:${composerId}:`;
    // A turn's bubbles usually share its user bubble's key as a prefix: `<turn>`, `<turn>/s:N`, `<turn>/t:<call>`.
    // Chats that keep one agent run going across messages file every reply under that run's key
    // instead, so anything written after this message and before the next one belongs to it too.
    const from = Date.parse(user.at || "") || 0;
    const until = Date.parse(nextAt || "") || Infinity;
    const rows: any[] = db
      .prepare(
        `SELECT key, json_extract(value,'$.createdAt') at, json_extract(value,'$.type') type, json_extract(value,'$.text') text,
                json_extract(value,'$.thinking.text') thought, json_extract(value,'$.thinkingDurationMs') ms,
                json_extract(value,'$.toolFormerData.name') name, json_extract(value,'$.toolFormerData.status') status,
                json_extract(value,'$.toolFormerData.toolCallId') call, json_extract(value,'$.toolFormerData.params') params,
                json_extract(value,'$.toolFormerData.rawArgs') raw, substr(json_extract(value,'$.toolFormerData.result'), 1, 20000) result
         FROM cursorDiskKV WHERE key >= ? AND key < ? AND (key >= ? AND key < ? OR rowid > ?)`,
      )
      .all(lo, `bubbleId:${composerId};`, user.key, `${user.key}0`, user.rowid)
      .filter((r: any) => {
        if (r.key === user.key || String(r.key).startsWith(`${user.key}/`)) return true;
        if (r.type === 1) return false;
        const at = Date.parse(r.at) || 0;
        return at >= from && at < until;
      });
    rows.sort((a, b) => String(a.at).localeCompare(String(b.at)));
    const items: Item[] = [];
    for (const r of rows) {
      const ts = Date.parse(r.at) || Date.now();
      const id = `lv-${String(r.key).slice(lo.length)}`;
      if (r.type === 1) {
        const u = userParts(r.text);
        u.notices.forEach((n, k) => items.push({ id: `${id}.n${k}`, ts, kind: "system", text: n }));
        if (u.text) items.push({ id, ts, kind: "user", text: u.text });
      } else if (r.name) {
        const t = tool(r.name, parse(r.params), parse(r.raw), parse(r.result));
        if (t.name === "edit") {
          const d = editDiff(db, parse(r.result));
          if (d) {
            Object.assign(t.meta, { added: d.added, removed: d.removed, diff: d.diff });
            if (r.call) exactEdits.set(r.call, d);
            if (exactEdits.size > 5000) exactEdits.delete(exactEdits.keys().next().value!);
          }
        }
        let status: "running" | "completed" | "error" = r.status === "loading" ? "running" : r.status === "error" || r.status === "cancelled" ? "error" : "completed";
        if (status === "running" && !working) status = "completed";
        if (r.status === "cancelled") t.meta.error = "Cancelled";
        else if (status === "error" && t.name === "mcp" && typeof t.meta.output === "string") t.meta.error = String(t.meta.output).slice(0, 600);
        items.push({
          id: r.call ? `lv-${r.call}` : id,
          ts,
          kind: "tool",
          tool: { name: t.name, status, args: t.args, callId: r.call || undefined, meta: Object.keys(t.meta).length ? t.meta : undefined },
        });
      } else if (typeof r.thought === "string" && r.thought.trim()) {
        items.push({ id, ts, kind: "thinking", text: r.thought.trim(), durationMs: typeof r.ms === "number" ? r.ms : undefined });
      } else if (typeof r.text === "string" && r.text.trim()) {
        items.push({ id, ts, kind: "assistant", text: r.text.trim() });
      }
    }
    // Cursor leaves finished calls "loading" until it flushes; only the latest batch can really be running.
    let batchStart = items.length;
    while (batchStart > 0 && items[batchStart - 1].kind === "tool") batchStart--;
    const lastTs = items[items.length - 1]?.ts ?? 0;
    items.forEach((it, i) => {
      if (it.tool?.status === "running" && (i < batchStart || it.ts < lastTs - 3000)) it.tool.status = "completed";
    });
    rememberResults(items);
    const last = items[items.length - 1];
    if (working && last?.kind === "thinking" && last.durationMs === undefined) last.streaming = true;
    return { userText: items[0]?.text || "", items };
  } catch (e: any) {
    log.warn(`cursor live turn: ${e.message}`);
    return undefined;
  }
}

const fp = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 60);

/**
 * Swaps the transcript file's copy of the recent turns (often missing or partial) for the live
 * ones, keeping the file's richer details (edit diffs) for tool calls it already has.
 */
/**
 * File item id -> the live id it had while its turn was served from the database. Once a turn
 * ages out of the live window its file copy keeps those ids, so the phone doesn't rebuild its rows.
 */
const liveIds = new Map<string, Map<string, string>>();

function rememberIds(composerId: string, file: Item[], live: Item[]) {
  const m = liveIds.get(composerId) || new Map<string, string>();
  liveIds.set(composerId, m);
  const used = new Set<string>();
  for (const f of file) {
    const hit = live.find((l) => {
      if (used.has(l.id) || l.kind !== f.kind) return false;
      if (f.tool?.callId) return l.tool?.callId === f.tool.callId;
      if (f.kind === "tool") return !!f.tool && l.tool?.name === f.tool.name;
      // The file sometimes joins text the database keeps as separate segments.
      const a = fp(l.text || ""), b = fp(f.text || "");
      return Math.min(a.length, b.length) >= 20 ? a.startsWith(b) || b.startsWith(a) : !!a && a === b;
    });
    if (!hit) continue;
    used.add(hit.id);
    m.set(f.id, hit.id);
  }
  if (m.size > 5000) for (const k of [...m.keys()].slice(0, m.size - 5000)) m.delete(k);
}

export function withLiveTurns(items: Item[], turns: LiveTurn[], composerId = ""): Item[] {
  const known = liveIds.get(composerId);
  const stable = (list: Item[]) => (known ? list.map((it) => (known.has(it.id) ? { ...it, id: known.get(it.id)! } : it)) : list);
  if (!turns.length) return withExactEdits(stable(items));
  // Line the oldest live turn up with its user message in the file; anything from there on is replaced.
  // Messages repeat ("Testing", "More"), so a match only counts if the file's later messages agree with
  // the live turns' later messages too. The file lags, so it may hold just the first part of them.
  const anchor = (it: Item) => it.kind === "user" || it.kind === "system";
  const users = items.map((it, i) => (anchor(it) ? i : -1)).filter((i) => i >= 0).slice(-(RECENT * 3 + 3));
  const liveAnchors = turns.map((t) => t.items.filter(anchor).map((it) => fp(it.text || "")));
  let cut = items.length;
  let from = 0;
  outer: for (let k = 0; k < turns.length; k++) {
    const key = fp(turns[k].userText);
    if (!key) continue;
    const later = liveAnchors.slice(k).flat();
    for (let u = users.length - 1; u >= 0; u--) {
      const i = users[u];
      if (fp(items[i].text || "") !== key) continue;
      const fileLater = users.slice(u).map((j) => fp(items[j].text || ""));
      const start = later.indexOf(key);
      if (start < 0 || fileLater.length > later.length - start) continue;
      if (fileLater.every((f, n) => f === later[start + n])) {
        cut = i;
        from = k;
        break outer;
      }
    }
  }
  const fileTools = new Map<string, Item>();
  for (const it of items.slice(cut)) if (it.tool?.callId) fileTools.set(it.tool.callId, it);
  const live = turns.slice(from).flatMap((t) => t.items).map((it) => {
    const f = it.tool?.callId ? fileTools.get(it.tool.callId) : undefined;
    if (!f?.tool?.meta || !it.tool) return it;
    const { diff, added, removed, lines } = f.tool.meta as any;
    const exact = !!it.tool.meta?.diff;
    return { ...it, tool: { ...it.tool, meta: { ...it.tool.meta, ...(diff && !exact ? { diff, added, removed } : {}), ...(lines && !it.tool.meta?.lines ? { lines } : {}) } } };
  });
  if (composerId) rememberIds(composerId, items.slice(cut), live);
  return [...withExactEdits(stable(items.slice(0, cut))), ...live];
}

/** Edits seen live keep their exact diff once the transcript file's copy takes over. */
function withExactEdits(items: Item[]): Item[] {
  if (!exactEdits.size) return items;
  return items.map((it) => {
    const d = it.tool?.callId ? exactEdits.get(it.tool.callId) : undefined;
    return d && it.tool ? { ...it, tool: { ...it.tool, meta: { ...it.tool.meta, added: d.added, removed: d.removed, diff: d.diff } } } : it;
  });
}
