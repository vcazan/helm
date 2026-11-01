import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { DatabaseSync } from "node:sqlite";
import { HOME, WORKSPACE_FILES_DIR } from "./config.ts";
import type { Workspace } from "./store.ts";

const pexec = promisify(execFile);
const CURSOR_USER = path.join(HOME, "Library/Application Support/Cursor/User/globalStorage");
const CURSOR_CLI = ["/usr/local/bin/cursor", "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"].find((p) => fs.existsSync(p)) || "cursor";

function uriToPath(uri: string) {
  return uri.startsWith("file://") ? decodeURIComponent(new URL(uri).pathname) : undefined;
}

export interface RecentEntry {
  name: string;
  folders: string[];
}

function readWorkspaceFile(p: string): string[] {
  try {
    const raw = fs.readFileSync(p, "utf8").replace(/^\s*\/\/.*$/gm, "").replace(/,(\s*[}\]])/g, "$1");
    const j = JSON.parse(raw);
    return (j.folders || []).map((f: any) => path.resolve(path.dirname(p), f.path || uriToPath(f.uri) || "")).filter(Boolean);
  } catch {
    return [];
  }
}

export function cursorRecents(limit = 40): RecentEntry[] {
  const db = path.join(CURSOR_USER, "state.vscdb");
  if (!fs.existsSync(db)) return [];
  let entries: any[] = [];
  try {
    const conn = new DatabaseSync(db, { readOnly: true });
    const row = conn.prepare("select value from ItemTable where key = 'history.recentlyOpenedPathsList'").get() as any;
    conn.close();
    entries = row ? JSON.parse(row.value).entries : [];
  } catch {
    return [];
  }
  const out: RecentEntry[] = [];
  for (const e of entries) {
    if (e.folderUri) {
      const p = uriToPath(e.folderUri);
      if (p && fs.existsSync(p)) out.push({ name: path.basename(p), folders: [p] });
    } else if (e.workspace?.configPath) {
      const p = uriToPath(e.workspace.configPath);
      if (p && fs.existsSync(p) && !p.startsWith(WORKSPACE_FILES_DIR)) {
        const folders = readWorkspaceFile(p);
        if (folders.length) out.push({ name: path.basename(p, ".code-workspace"), folders });
      }
    }
    if (out.length >= limit) break;
  }
  return out;
}

export function openCursorWindows(): string[][] {
  try {
    const j = JSON.parse(fs.readFileSync(path.join(CURSOR_USER, "storage.json"), "utf8"));
    const wins = [j.windowsState?.lastActiveWindow, ...(j.windowsState?.openedWindows || [])].filter(Boolean);
    return wins
      .map((w: any) => {
        if (w.folder) return [uriToPath(w.folder)].filter(Boolean) as string[];
        if (w.workspaceIdentifier?.configURIPath) return readWorkspaceFile(uriToPath(w.workspaceIdentifier.configURIPath) || "");
        return [];
      })
      .filter((f: string[]) => f.length);
  } catch {
    return [];
  }
}

export async function cursorRunning() {
  try {
    const { stdout } = await pexec("ps", ["-axo", "comm"]);
    return stdout.split("\n").some((l) => l.trim() === "/Applications/Cursor.app/Contents/MacOS/Cursor");
  } catch {
    return false;
  }
}

export async function openInCursor(w: Workspace, newWindow = true) {
  let target: string;
  if (w.folders.length === 1) target = w.folders[0];
  else {
    target = path.join(WORKSPACE_FILES_DIR, `${w.name.replace(/[^\w.-]+/g, "-")}.code-workspace`);
    fs.writeFileSync(target, JSON.stringify({ folders: w.folders.map((p) => ({ path: p })) }, null, 2));
  }
  await pexec(CURSOR_CLI, [newWindow ? "--new-window" : "--reuse-window", target], { timeout: 30_000 });
}

export interface DirEntry {
  name: string;
  path: string;
  git: boolean;
  hasChildren: boolean;
}

export function listDir(p: string, showHidden = false): { path: string; parent?: string; entries: DirEntry[] } {
  const abs = path.resolve(p.replace(/^~(?=$|\/)/, HOME));
  const entries: DirEntry[] = [];
  for (const d of fs.readdirSync(abs, { withFileTypes: true })) {
    if (!showHidden && d.name.startsWith(".")) continue;
    let isDir = d.isDirectory();
    const full = path.join(abs, d.name);
    if (d.isSymbolicLink()) {
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch {
        isDir = false;
      }
    }
    if (!isDir || d.name === "node_modules") continue;
    let hasChildren = false;
    try {
      hasChildren = fs.readdirSync(full, { withFileTypes: true }).some((c) => c.isDirectory() && !c.name.startsWith("."));
    } catch {}
    entries.push({ name: d.name, path: full, git: fs.existsSync(path.join(full, ".git")), hasChildren });
  }
  entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
  return { path: abs, parent: abs === "/" ? undefined : path.dirname(abs), entries };
}

export async function repoInfo(folder: string): Promise<{ repo?: string; branch?: string }> {
  const git = async (...args: string[]) => (await pexec("git", ["-C", folder, ...args], { timeout: 10_000 })).stdout.trim();
  try {
    const url = await git("remote", "get-url", "origin");
    const m = url.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
    const branch = await git("rev-parse", "--abbrev-ref", "HEAD").catch(() => undefined);
    return { repo: m?.[1], branch: branch === "HEAD" ? undefined : branch };
  } catch {
    return {};
  }
}

/** Files the phone can open to read: documents agents write, never config or secrets. */
const READABLE = new Set([".md", ".markdown", ".mdx", ".txt"]);
const PRIVATE_DIRS = [".ssh", ".helm", ".aws", ".gnupg", ".config", ".kube", ".docker", "Library"];
const READ_LIMIT = 1_000_000;

const ALLOWED_IN_PRIVATE = [path.join("Library", "Application Support", "Cursor", "AgentStores") + path.sep];
const TEMP_ROOTS = ["/private/tmp", "/private/var/folders"];

function readableDoc(abs: string) {
  if (TEMP_ROOTS.some((r) => abs.startsWith(r + path.sep))) return;
  const rel = path.relative(HOME, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) throw Object.assign(new Error("Only files in your home folder can be opened"), { status: 403 });
  if (PRIVATE_DIRS.includes(rel.split(path.sep)[0]) && !ALLOWED_IN_PRIVATE.some((a) => rel.startsWith(a))) throw Object.assign(new Error("That folder is private"), { status: 403 });
}

function repoTop(file: string): string | undefined {
  let dir = path.dirname(file);
  while (dir.startsWith(HOME + path.sep)) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    dir = path.dirname(dir);
  }
  return undefined;
}

/** Looks for `rel` (a bare name or a partial path) under `root`, skipping dependency and build folders. */
function findUnder(root: string, rel: string, budget = { left: 20_000 }): string | undefined {
  const want = rel.split("/").filter(Boolean);
  const name = want[want.length - 1];
  const skip = new Set(["node_modules", ".git", "dist", "build", ".next", "DerivedData", "Pods", ".venv", "venv", "target"]);
  const walk = (dir: string, depth: number): string | undefined => {
    if (depth > 8 || budget.left <= 0) return undefined;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return undefined;
    }
    budget.left -= entries.length;
    for (const e of entries) {
      if (e.isFile() && e.name === name) {
        const full = path.join(dir, e.name);
        if (full.endsWith(path.sep + want.join(path.sep))) return full;
      }
    }
    for (const e of entries) {
      if (e.isDirectory() && !skip.has(e.name) && !e.name.startsWith(".")) {
        const hit = walk(path.join(dir, e.name), depth + 1);
        if (hit) return hit;
      }
    }
    return undefined;
  };
  return walk(root, 0);
}

/**
 * Finds the file a chat means by `p`. Agents name documents loosely ("decisions.md", "docs/x.md"), so a relative
 * path is tried against the chat's folder and the folders above it, then matched against files the chat touched,
 * then looked for inside the projects those files are in.
 */
function locateDocument(p: string, root: string | undefined, known: string[]): string | undefined {
  const local = p.startsWith("file://") ? decodeURIComponent(p.slice(7)) : p;
  const expanded = local.replace(/^~(?=$|\/)/, HOME).replace(/:\d+(?::\d+)?$/, "");
  if (path.isAbsolute(expanded)) return fs.existsSync(expanded) ? expanded : undefined;
  const rel = expanded.replace(/^\.\//, "");
  const base = root ? root.replace(/^~(?=$|\/)/, HOME) : undefined;
  for (let dir = base; dir && dir.startsWith(HOME + path.sep); dir = path.dirname(dir)) {
    const f = path.resolve(dir, rel);
    if (fs.existsSync(f)) return f;
  }
  const suffix = path.sep + rel.split("/").join(path.sep);
  const touched = [...known].reverse().find((k) => k.endsWith(suffix) && fs.existsSync(k));
  if (touched) return touched;
  const roots = [...new Set([base, ...known.map(repoTop)].filter((r): r is string => !!r && fs.existsSync(r)))];
  for (const r of roots) {
    const f = path.resolve(r, rel);
    if (fs.existsSync(f)) return f;
  }
  const budget = { left: 40_000 };
  for (const r of roots.slice(0, 6)) {
    const hit = findUnder(r, rel, budget);
    if (hit) return hit;
  }
  return undefined;
}

export function readDocument(p: string, root?: string, known: string[] = []): { path: string; name: string; size: number; modifiedAt: number; text: string; truncated: boolean } {
  const found = locateDocument(p, root, known);
  if (!found) throw Object.assign(new Error(path.isAbsolute(p.replace(/^~/, "/")) ? "This file isn't on your Mac anymore" : `Couldn't find ${p} in this chat's projects`), { status: 404 });
  const abs = fs.realpathSync(found);
  readableDoc(abs);
  if (!READABLE.has(path.extname(abs).toLowerCase())) throw Object.assign(new Error("Only Markdown and text files can be opened"), { status: 415 });
  const st = fs.statSync(abs);
  if (!st.isFile()) throw Object.assign(new Error("Not a file"), { status: 400 });
  const fd = fs.openSync(abs, "r");
  try {
    const buf = Buffer.alloc(Math.min(st.size, READ_LIMIT));
    fs.readSync(fd, buf, 0, buf.length, 0);
    return { path: abs, name: path.basename(abs), size: st.size, modifiedAt: st.mtimeMs, text: buf.toString("utf8"), truncated: st.size > READ_LIMIT };
  } finally {
    fs.closeSync(fd);
  }
}
