import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { HOME } from "./config.ts";

const pexec = promisify(execFile);

export interface LineDiff {
  added: number;
  removed: number;
  /** Unified hunks (`@@`, ` `, `+`, `-` lines), clipped for the phone. */
  diff: string;
}

type Op = { k: " " | "+" | "-"; line: string };

/** Myers shortest edit script over lines; past `maxD` edits it falls back to replacing the whole middle. */
function editScript(a: string[], b: string[], maxD = 4000): Op[] {
  const n = a.length, m = b.length;
  const max = n + m;
  const v = new Int32Array(2 * max + 2);
  const trace: Int32Array[] = [];
  let found = -1;
  for (let d = 0; d <= Math.min(max, maxD); d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[max + k - 1] < v[max + k + 1]) ? v[max + k + 1] : v[max + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) x++, y++;
      v[max + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break;
      }
    }
    if (found >= 0) break;
  }
  if (found < 0) return [...a.map((line) => ({ k: "-" as const, line })), ...b.map((line) => ({ k: "+" as const, line }))];
  const ops: Op[] = [];
  let x = n, y = m;
  for (let d = found; d > 0; d--) {
    const vv = trace[d];
    const k = x - y;
    const prevK = k === -d || (k !== d && vv[max + k - 1] < vv[max + k + 1]) ? k + 1 : k - 1;
    const px = vv[max + prevK];
    const py = px - prevK;
    while (x > px && y > py) ops.push({ k: " ", line: a[--x] }), y--;
    if (x === px) ops.push({ k: "+", line: b[--y] });
    else ops.push({ k: "-", line: a[--x] });
  }
  while (x > 0 && y > 0) ops.push({ k: " ", line: a[--x] }), y--;
  return ops.reverse();
}

const split = (s: string) => (s === "" ? [] : s.replace(/\n$/, "").split("\n"));

/** Line diff of two texts: exact added/removed counts and unified hunks with `context` lines around changes. */
export function lineDiff(before: string, after: string, context = 3, maxChars = 6000): LineDiff {
  const a = split(before), b = split(after);
  let pre = 0;
  while (pre < a.length && pre < b.length && a[pre] === b[pre]) pre++;
  let suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] === b[b.length - 1 - suf]) suf++;
  const mid = editScript(a.slice(pre, a.length - suf), b.slice(pre, b.length - suf));
  const ops: Op[] = [...a.slice(0, pre).map((line) => ({ k: " " as const, line })), ...mid, ...a.slice(a.length - suf).map((line) => ({ k: " " as const, line }))];
  let added = 0, removed = 0;
  for (const o of ops) o.k === "+" ? added++ : o.k === "-" ? removed++ : 0;

  const out: string[] = [];
  let size = 0;
  let i = 0, aLine = 1, bLine = 1;
  while (i < ops.length && size < maxChars) {
    if (ops[i].k === " ") {
      i++, aLine++, bLine++;
      continue;
    }
    const start = Math.max(0, i - context);
    let end = i;
    let quiet = 0;
    while (end < ops.length && quiet <= context * 2) {
      quiet = ops[end].k === " " ? quiet + 1 : 0;
      end++;
    }
    end = Math.min(ops.length, end - Math.max(0, quiet - context));
    const back = i - start;
    const as = aLine - back, bs = bLine - back;
    const slice = ops.slice(start, end);
    const ac = slice.filter((o) => o.k !== "+").length, bc = slice.filter((o) => o.k !== "-").length;
    const hunk = [`@@ -${as},${ac} +${bs},${bc} @@`, ...slice.map((o) => o.k + o.line)];
    out.push(...hunk);
    size += hunk.reduce((n, l) => n + l.length + 1, 0);
    for (let j = i; j < end; j++) ops[j].k !== "+" && aLine++, ops[j].k !== "-" && bLine++;
    i = end;
  }
  let diff = out.join("\n");
  if (diff.length > maxChars) diff = diff.slice(0, maxChars) + "\n…";
  return { added, removed, diff };
}

// MARK: - Working tree changes

export interface FileChange {
  path: string;
  /** M modified, A added, D deleted, R renamed, U untracked. */
  status: "M" | "A" | "D" | "R" | "U";
  added: number;
  removed: number;
  binary?: boolean;
}

function repoRoot(dir: string) {
  const abs = path.resolve(dir.replace(/^~(?=$|\/)/, HOME));
  const rel = path.relative(HOME, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) throw Object.assign(new Error("Only folders in your home folder"), { status: 403 });
  return abs;
}

const git = async (cwd: string, ...args: string[]) => (await pexec("git", ["-C", cwd, ...args], { timeout: 15_000, maxBuffer: 32 * 1024 * 1024 })).stdout;

/** Everything changed in a folder's git checkout since the last commit, untracked files included. */
export async function workingChanges(dir: string) {
  const cwd = repoRoot(dir);
  let top: string;
  try {
    top = (await git(cwd, "rev-parse", "--show-toplevel")).trim();
  } catch {
    return { git: false, files: [] as FileChange[], added: 0, removed: 0 };
  }
  const branch = (await git(top, "rev-parse", "--abbrev-ref", "HEAD").catch(() => "")).trim();
  const hasHead = await git(top, "rev-parse", "--verify", "HEAD").then(() => true, () => false);
  const files = new Map<string, FileChange>();
  if (hasHead) {
    for (const line of (await git(top, "diff", "HEAD", "--numstat", "-M")).split("\n")) {
      const m = line.match(/^(-|\d+)\t(-|\d+)\t(.+)$/);
      if (!m) continue;
      let p = m[3];
      const renamed = p.includes(" => ");
      if (renamed) p = p.replace(/\{([^{}]*) => ([^{}]*)\}/, "$2").replace(/^.* => /, "");
      files.set(p, { path: p, status: renamed ? "R" : "M", added: m[1] === "-" ? 0 : +m[1], removed: m[2] === "-" ? 0 : +m[2], binary: m[1] === "-" || undefined });
    }
    for (const line of (await git(top, "diff", "HEAD", "--name-status", "-M")).split("\n")) {
      const m = line.match(/^([ADMR])\d*\t(?:[^\t]+\t)?([^\t]+)$/);
      const f = m && files.get(m[2]);
      if (f && (m[1] === "A" || m[1] === "D")) f.status = m[1];
    }
  }
  const untracked = (await git(top, "ls-files", "--others", "--exclude-standard", "-z")).split("\0").filter(Boolean).slice(0, 400);
  for (const p of untracked) {
    let added = 0, binary: boolean | undefined;
    try {
      const st = fs.statSync(path.join(top, p));
      if (st.size > 2_000_000) binary = true;
      else {
        const buf = fs.readFileSync(path.join(top, p));
        if (buf.includes(0)) binary = true;
        else added = split(buf.toString("utf8")).length;
      }
    } catch {}
    files.set(p, { path: p, status: "U", added, removed: 0, binary });
  }
  const list = [...files.values()].sort((x, y) => y.added + y.removed - (x.added + x.removed) || x.path.localeCompare(y.path));
  return {
    git: true,
    root: top,
    branch: branch === "HEAD" ? undefined : branch,
    files: list.slice(0, 300),
    more: Math.max(0, list.length - 300),
    added: list.reduce((n, f) => n + f.added, 0),
    removed: list.reduce((n, f) => n + f.removed, 0),
  };
}

/** One file's change since the last commit, as unified hunks. */
export async function fileChange(dir: string, file: string) {
  const cwd = repoRoot(dir);
  const top = (await git(cwd, "rev-parse", "--show-toplevel")).trim();
  const abs = path.resolve(top, file);
  if (path.relative(top, abs).startsWith("..")) throw Object.assign(new Error("That file isn't in this repo"), { status: 403 });
  const rel = path.relative(top, abs);
  const read = (p: string) => (fs.existsSync(p) && fs.statSync(p).size < 4_000_000 ? fs.readFileSync(p, "utf8") : "");
  const before = await git(top, "show", `HEAD:${rel}`).catch(() => "");
  const after = read(abs);
  if (before.includes("\0") || after.includes("\0")) return { path: rel, binary: true, added: 0, removed: 0, diff: "" };
  return { path: rel, ...lineDiff(before, after, 3, 200_000) };
}
