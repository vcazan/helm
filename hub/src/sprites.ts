import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import { promisify } from "node:util";
import { RUNNER_PATH } from "./config.ts";
import { log } from "./log.ts";

const pexec = promisify(execFile);
export const SPRITE_BIN = process.env.SPRITE_BIN || "sprite";

export interface SpriteInfo {
  name: string;
  status?: string;
  url?: string;
}

async function sprite(args: string[], opts: { timeoutMs?: number; input?: string } = {}) {
  if (opts.input !== undefined) {
    return new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
      const p = spawn(SPRITE_BIN, args, { stdio: ["pipe", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      p.stdout.on("data", (d) => (stdout += d));
      p.stderr.on("data", (d) => (stderr += d));
      const t = setTimeout(() => p.kill(), opts.timeoutMs ?? 120_000);
      p.on("exit", (code) => {
        clearTimeout(t);
        if (code === 0) resolve({ stdout, stderr });
        else reject(new Error((stderr || stdout).trim() || `sprite ${args[0]} failed (${code})`));
      });
      p.stdin.end(opts.input);
    });
  }
  try {
    return await pexec(SPRITE_BIN, args, { timeout: opts.timeoutMs ?? 120_000, maxBuffer: 20 * 1024 * 1024 });
  } catch (e: any) {
    throw new Error((e.stderr || e.stdout || e.message || "").toString().trim());
  }
}

export async function spriteAuthState(): Promise<{ ok: boolean; error?: string }> {
  try {
    await sprite(["ls"], { timeoutMs: 20_000 });
    return { ok: true };
  } catch (e: any) {
    return { ok: false, error: e.message };
  }
}

export async function listSprites(): Promise<SpriteInfo[]> {
  try {
    const { stdout } = await sprite(["api", "/v1/sprites"], { timeoutMs: 30_000 });
    const j = JSON.parse(stdout);
    const arr = Array.isArray(j) ? j : j.sprites || j.data || [];
    return arr.map((s: any) => ({ name: s.name, status: s.status, url: s.url }));
  } catch (e) {
    log.debug(`sprite api list failed, falling back to ls: ${(e as Error).message}`);
  }
  const { stdout } = await sprite(["ls"], { timeoutMs: 30_000 });
  return stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !/^name\b/i.test(l) && !/^no sprites/i.test(l) && !/^[-=\s]+$/.test(l))
    .map((l) => ({ name: l.split(/\s+/)[0] }));
}

export async function createSprite(name: string) {
  await sprite(["create", "--skip-console", "--label", "helm", name], { timeoutMs: 300_000, input: "" });
}

export async function destroySprite(name: string) {
  await sprite(["destroy", "--force", name], { timeoutMs: 120_000, input: "" });
}

async function localGitIdentity() {
  const get = async (k: string) => {
    try {
      return (await pexec("git", ["config", "--global", k])).stdout.trim();
    } catch {
      return "";
    }
  };
  return { name: (await get("user.name")) || "Helm Agent", email: (await get("user.email")) || "helm@localhost" };
}

export async function githubToken(): Promise<string | undefined> {
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN;
  try {
    return (await pexec("gh", ["auth", "token"])).stdout.trim() || undefined;
  } catch {
    return undefined;
  }
}

const BOOTSTRAP = `
set -e
command -v node >/dev/null || { echo "node is not installed in this sprite" >&2; exit 3; }
mkdir -p "$HOME/.helm" "$HOME/work"
cd "$HOME/.helm"
if [ ! -f node_modules/@cursor/sdk/package.json ]; then
  [ -f package.json ] || echo '{"name":"helm-runner","private":true,"type":"module"}' > package.json
  if ! npm install --no-audit --no-fund @cursor/sdk zod > npm-install.log 2>&1; then
    tail -20 npm-install.log >&2
    exit 4
  fi
fi
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
if [ -n "$GH_TOKEN" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\\n' "$GH_TOKEN" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
fi
if [ -n "$REPO" ]; then
  D="$HOME/work/$REPO_NAME"
  if [ ! -d "$D/.git" ]; then git clone -q "https://github.com/$REPO.git" "$D"; fi
  cd "$D"
  git fetch -q --all || true
  if [ -n "$BRANCH" ]; then
    git checkout -q "$BRANCH" 2>/dev/null || git checkout -q -b "$BRANCH"
    git pull -q --ff-only 2>/dev/null || true
  fi
  echo "HELM_DIR=$D"
else
  echo "HELM_DIR=$HOME/work"
fi
`;

export async function bootstrapSprite(name: string, repo?: string, branch?: string): Promise<string> {
  const id = await localGitIdentity();
  const gh = await githubToken();
  const env = [`GIT_NAME=${id.name}`, `GIT_EMAIL=${id.email}`, `REPO=${repo || ""}`, `REPO_NAME=${repo ? repo.split("/").pop() : ""}`, `BRANCH=${branch || ""}`];
  if (gh) env.push(`GH_TOKEN=${gh}`);
  log.info(`sprite ${name}: bootstrapping ${repo || "(no repo)"}${branch ? `@${branch}` : ""}`);
  const { stdout } = await sprite(["exec", "-s", name, "--no-port-forward", "--env", env.join(","), "--", "bash", "-c", BOOTSTRAP], {
    timeoutMs: 600_000,
    input: "",
  });
  await uploadRunner(name);
  const m = stdout.match(/HELM_DIR=(.+)/);
  if (!m) throw new Error(`sprite bootstrap gave no directory: ${stdout.slice(-400)}`);
  return m[1].trim();
}

export async function uploadRunner(name: string) {
  await sprite(["exec", "-s", name, "--no-port-forward", "--", "sh", "-c", 'mkdir -p "$HOME/.helm" && cat > "$HOME/.helm/runner.mjs"'], {
    input: fs.readFileSync(RUNNER_PATH, "utf8"),
    timeoutMs: 120_000,
  });
}

export async function runnerCommand(name: string) {
  const gh = await githubToken();
  const args = ["exec", "-s", name, "--no-port-forward"];
  if (gh) args.push("--env", `GH_TOKEN=${gh}`);
  args.push("--", "sh", "-c", 'cd "$HOME/.helm" && exec node runner.mjs');
  return { command: SPRITE_BIN, args };
}
