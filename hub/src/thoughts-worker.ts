import { parentPort, workerData } from "node:worker_threads";
import { DatabaseSync } from "node:sqlite";

export interface Thought { text: string; durationMs?: number; beforeTool?: number; beforeText?: string }

const fingerprint = (t: string) => t.trimStart().slice(0, 400).replace(/\s+/g, " ").trim().slice(0, 40);

// Some chats hold hundreds of thousands of bubbles (gigabytes); reading them all takes seconds,
// so this runs off the hub's main thread.
const db = new DatabaseSync(workerData.dbPath, { readOnly: true });
const stmt = db.prepare(
  `SELECT json_extract(value,'$.createdAt') at, json_extract(value,'$.thinking.text') thought, json_extract(value,'$.thinkingDurationMs') ms,
          json_extract(value,'$.toolFormerData.toolCallId') tool, substr(json_extract(value,'$.text'),1,80) text
   FROM cursorDiskKV WHERE key >= ? AND key < ?`,
);

function thoughts(composerId: string): Thought[] {
  const rows = stmt.all(`bubbleId:${composerId}:`, `bubbleId:${composerId};`) as Array<{ at: string; thought: string | null; ms: number | null; tool: string | null; text: string | null }>;
  rows.sort((a, b) => String(a.at).localeCompare(String(b.at)));
  const out: Thought[] = [];
  let pending: Thought[] = [];
  let tools = 0;
  for (const r of rows) {
    if (r.thought && r.thought.trim()) pending.push({ text: r.thought.trim(), durationMs: r.ms ?? undefined });
    if (r.tool) {
      for (const t of pending) out.push({ ...t, beforeTool: tools });
      pending = [];
      tools++;
    } else if (r.text && r.text.trim() && pending.length) {
      for (const t of pending) out.push({ ...t, beforeText: fingerprint(r.text) });
      pending = [];
    }
  }
  out.push(...pending);
  return out;
}

parentPort!.on("message", (composerId: string) => {
  try {
    parentPort!.postMessage({ composerId, thoughts: thoughts(composerId) });
  } catch (e: any) {
    parentPort!.postMessage({ composerId, error: e.message });
  }
});
