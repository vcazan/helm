import fs from "node:fs";
import path from "node:path";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { HOME } from "./config.ts";
import { bus } from "./store.ts";
import { log } from "./log.ts";

const pexec = promisify(execFile);
const expand = (p: string) => path.resolve(p.replace(/^~(?=$|\/)/, HOME));

// ---- folders ------------------------------------------------------------------------------

export function makeDir(parent: string, name: string) {
  const clean = name.trim();
  if (!clean || clean.includes("/") || clean === "." || clean === "..") throw Object.assign(new Error("Pick a folder name without slashes"), { status: 400 });
  const full = path.join(expand(parent), clean);
  if (fs.existsSync(full)) throw Object.assign(new Error(`${clean} already exists here`), { status: 409 });
  fs.mkdirSync(full);
  return { path: full, name: clean };
}

const SKIP = new Set(["node_modules", "Library", "build", "dist", "DerivedData", "Pods", "venv", "target", "vendor", "Applications", "Movies", "Music", "Pictures"]);

/** Folders whose name contains `q` under `root`: breadth-first, shallow matches first, bounded in depth and time. */
export async function searchDirs(q: string, root = "~") {
  const needle = q.trim().toLowerCase();
  if (needle.length < 2) return [];
  const started = Date.now();
  const out: Array<{ name: string; path: string; git: boolean; hasChildren: boolean }> = [];
  let level = [expand(root)];
  for (let depth = 0; depth < 6 && level.length && out.length < 40 && Date.now() - started < 2500; depth++) {
    const next: string[] = [];
    for (const dir of level) {
      let entries: fs.Dirent[];
      try {
        entries = await fs.promises.readdir(dir, { withFileTypes: true });
      } catch {
        continue;
      }
      for (const d of entries) {
        if (!d.isDirectory() || d.name.startsWith(".") || SKIP.has(d.name)) continue;
        const full = path.join(dir, d.name);
        if (d.name.toLowerCase().includes(needle)) {
          let hasChildren = false;
          try {
            hasChildren = fs.readdirSync(full, { withFileTypes: true }).some((c) => c.isDirectory() && !c.name.startsWith("."));
          } catch {}
          out.push({ name: d.name, path: full, git: fs.existsSync(path.join(full, ".git")), hasChildren });
          if (out.length >= 40) break;
        }
        if (!fs.existsSync(path.join(full, ".git"))) next.push(full);
      }
      if (out.length >= 40 || Date.now() - started > 2500) break;
    }
    level = next;
  }
  return out.sort((a, b) => Number(b.name.toLowerCase() === needle) - Number(a.name.toLowerCase() === needle));
}

// ---- GitHub -------------------------------------------------------------------------------

export interface Repo {
  name: string;
  description?: string;
  private: boolean;
  pushedAt?: string;
}

let repoCache: { at: number; repos: Repo[] } | undefined;

async function allRepos(): Promise<Repo[]> {
  if (repoCache && Date.now() - repoCache.at < 5 * 60_000) return repoCache.repos;
  const { stdout } = await pexec(
    "gh",
    ["api", "--paginate", "user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member", "--jq", ".[] | {name: .full_name, description: .description, private: .private, pushedAt: .pushed_at}"],
    { timeout: 30_000, maxBuffer: 32 * 1024 * 1024 },
  );
  const repos = stdout.split("\n").filter(Boolean).map((l) => JSON.parse(l) as Repo);
  repos.sort((a, b) => (b.pushedAt || "").localeCompare(a.pushedAt || ""));
  repoCache = { at: Date.now(), repos };
  return repos;
}

export async function githubRepos(q = "") {
  let repos: Repo[];
  try {
    repos = await allRepos();
  } catch (e: any) {
    throw Object.assign(new Error("GitHub CLI isn't signed in on the Mac. Run `gh auth login`."), { status: 503, cause: e });
  }
  const terms = q.toLowerCase().split(/\s+/).filter(Boolean);
  const hits = terms.length ? repos.filter((r) => terms.every((t) => r.name.toLowerCase().includes(t) || (r.description || "").toLowerCase().includes(t))) : repos;
  return hits.slice(0, 60);
}

export interface CloneJob {
  id: string;
  repo: string;
  path: string;
  state: "running" | "done" | "error";
  phase: string;
  percent?: number;
  error?: string;
}

const jobs = new Map<string, CloneJob>();

function emit(job: CloneJob) {
  bus.emit("event", { type: "clone", job });
}

/** Clone with the Mac's own credentials: `gh` for owner/name (keyring token), plain git (SSH keys) for URLs. */
export function startClone(repo: string, parent: string, name?: string): CloneJob {
  const spec = repo.trim().replace(/^https:\/\/github\.com\//, "").replace(/\.git$/, "");
  const isShorthand = /^[\w.-]+\/[\w.-]+$/.test(spec);
  if (!isShorthand && !/^(git@|ssh:\/\/|https?:\/\/)/.test(repo.trim())) throw Object.assign(new Error("Use owner/name or a git URL"), { status: 400 });
  const folder = (name || "").trim() || (isShorthand ? spec.split("/")[1] : path.basename(repo.trim()).replace(/\.git$/, ""));
  const dest = path.join(expand(parent), folder);
  if (fs.existsSync(dest)) throw Object.assign(new Error(`${folder} already exists in ${path.basename(expand(parent))}`), { status: 409 });

  const job: CloneJob = { id: randomUUID().slice(0, 8), repo: isShorthand ? spec : repo.trim(), path: dest, state: "running", phase: "Connecting" };
  jobs.set(job.id, job);
  emit(job);

  const [cmd, args] = isShorthand ? ["gh", ["repo", "clone", spec, dest, "--", "--progress"]] : ["git", ["clone", "--progress", repo.trim(), dest]];
  const child = spawn(cmd, args, { env: { ...process.env, GIT_TERMINAL_PROMPT: "0" }, stdio: ["ignore", "pipe", "pipe"] });
  let tail = "";
  let lastEmit = 0;
  const onData = (d: Buffer) => {
    const text = d.toString();
    tail = (tail + text).slice(-4000);
    const m = [...text.matchAll(/(Counting|Compressing|Receiving|Resolving) (objects|deltas):\s+(\d+)%/g)].pop();
    if (!m) return;
    const weights: Record<string, [number, number]> = { Counting: [0, 5], Compressing: [5, 10], Receiving: [10, 85], Resolving: [85, 100] };
    const [lo, hi] = weights[m[1]];
    job.phase = m[1] === "Receiving" ? "Downloading" : m[1] === "Resolving" ? "Unpacking" : "Preparing";
    job.percent = Math.round(lo + ((hi - lo) * Number(m[3])) / 100);
    if (Date.now() - lastEmit > 150) {
      lastEmit = Date.now();
      emit(job);
    }
  };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData);
  child.on("error", (e) => {
    job.state = "error";
    job.error = e.message;
    emit(job);
  });
  child.on("close", (code) => {
    if (job.state === "error") return;
    if (code === 0) {
      job.state = "done";
      job.phase = "Cloned";
      job.percent = 100;
    } else {
      job.state = "error";
      const line = tail.split("\n").map((l) => l.trim()).filter((l) => /fatal|error|denied|not found|could not/i.test(l)).pop();
      job.error = line?.replace(/^(fatal|error):\s*/i, "") || `Clone failed (exit ${code})`;
      fs.rmSync(dest, { recursive: true, force: true });
    }
    emit(job);
    log.info(`clone ${job.repo} → ${dest}: ${job.state}${job.error ? ` (${job.error})` : ""}`);
  });
  return job;
}
