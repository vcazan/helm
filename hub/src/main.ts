import os from "node:os";
import fs from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createRequire } from "node:module";
import { loadConfig, readCursorApiKey, DATA_DIR } from "./config.ts";

const pexec = promisify(execFile);
const require = createRequire(import.meta.url);
const TS_CLI = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"].find((p) => fs.existsSync(p));

async function tailscaleAddress(): Promise<{ ip?: string; dns?: string }> {
  let ip: string | undefined;
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs || []) {
      const m = a.family === "IPv4" && a.address.match(/^100\.(\d+)\./);
      if (m && +m[1] >= 64 && +m[1] <= 127) ip = a.address;
    }
  }
  let dns: string | undefined;
  if (TS_CLI) {
    try {
      const { stdout } = await pexec(TS_CLI, ["status", "--json"], { timeout: 5000 });
      const j = JSON.parse(stdout);
      dns = j.Self?.DNSName?.replace(/\.$/, "") || undefined;
      ip = ip || j.Self?.TailscaleIPs?.find((x: string) => x.includes("."));
    } catch {}
  }
  return { ip, dns };
}

async function loginFromCursorApp(): Promise<string> {
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(`${os.homedir()}/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, { readOnly: true });
  const get = (k: string) => (db.prepare("select value from ItemTable where key = ?").get(k) as any)?.value as string | undefined;
  const accessToken = get("cursorAuth/accessToken");
  const email = get("cursorAuth/cachedEmail");
  const backendUrl = (get("cursorAuth/storedServerBackendUrl") || "https://api2.cursor.sh").replace(/\/+$/, "");
  db.close();
  if (!accessToken) throw new Error("the Cursor app is not signed in");
  const { DEFAULT_LOGIN_API_KEY_TTL_MS } = await import("@cursor/sdk");
  const expiresAtMs = Date.now() + DEFAULT_LOGIN_API_KEY_TTL_MS;
  const res = await fetch(`${backendUrl}/aiserver.v1.DashboardService/CreateUserApiKey`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json", "connect-protocol-version": "1" },
    body: JSON.stringify({ name: "helm-hub", expiresAt: String(expiresAtMs) }),
  });
  const body: any = await res.json().catch(() => ({}));
  if (!res.ok || !body.apiKey) throw new Error(body.message || `HTTP ${res.status}`);
  const dir = `${os.homedir()}/.cursor/sdk`;
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const creds = { version: 1, backendUrl, apiKey: body.apiKey, apiKeyExpiresAtMs: expiresAtMs, email, createdAtMs: Date.now() };
  fs.writeFileSync(`${dir}/auth.json`, JSON.stringify(creds, null, 2), { mode: 0o600 });
  return email || "your account";
}

function cursorEmail(): string | undefined {
  try {
    return JSON.parse(fs.readFileSync(`${os.homedir()}/.cursor/sdk/auth.json`, "utf8")).email || undefined;
  } catch {
    return undefined;
  }
}

async function pairing(cfg: ReturnType<typeof loadConfig>) {
  const ts = await tailscaleAddress();
  const host = ts.ip || "127.0.0.1";
  const url = `http://${host}:${cfg.port}`;
  const link = `helm://pair?url=${encodeURIComponent(url)}&token=${encodeURIComponent(cfg.token)}&name=${encodeURIComponent(cfg.hubName)}${ts.dns ? `&alt=${encodeURIComponent(`http://${ts.dns}:${cfg.port}`)}` : ""}`;
  return { url, link, ts };
}

async function printPairing(cfg: ReturnType<typeof loadConfig>) {
  const { url, link, ts } = await pairing(cfg);
  const qr = require("qrcode-terminal");
  console.log("\n  Helm — pair your iPhone");
  console.log("  Open Helm on the phone and scan this code:\n");
  qr.generate(link, { small: true }, (s: string) => console.log(s.replace(/^/gm, "  ")));
  console.log(`  Hub:   ${url}${ts.dns ? `  (${ts.dns})` : ""}`);
  console.log(`  Token: ${cfg.token}`);
  if (!ts.ip) console.log("\n  ⚠ Tailscale isn't connected on this Mac. Open the Tailscale app and connect, then run `npm run pair` again.");
  console.log(`  Link:  ${link}\n`);
  fs.writeFileSync(`${DATA_DIR}/pairing.txt`, link + "\n", { mode: 0o600 });
}

async function main() {
  const cmd = process.argv[2] || "start";
  const cfg = loadConfig();

  if (cmd === "pair") return printPairing(cfg);

  if (cmd === "login") {
    if (!process.argv.includes("--browser")) {
      try {
        const email = await loginFromCursorApp();
        console.log(`Created a Helm API key from the Cursor app's sign-in (${email}). Restart the hub if it is running.`);
        return;
      } catch (e: any) {
        console.log(`Couldn't reuse the Cursor app's sign-in (${e.message}); falling back to the browser.`);
      }
    }
    const { Cursor } = await import("@cursor/sdk");
    const r = await Cursor.auth.login({ apiKeyName: "helm-hub", onLoginUrl: (u: string) => console.log(`Opening ${u}`) });
    console.log(`Logged in to Cursor as ${r.email}. Restart the hub if it is running.`);
    return;
  }

  if (cmd === "status") {
    const { url, link, ts } = await pairing(cfg);
    console.log(JSON.stringify({ cursorLoggedIn: !!readCursorApiKey(), cursorEmail: cursorEmail(), tailscale: ts, tailscaleInstalled: !!TS_CLI, push: !!cfg.apns, hubName: cfg.hubName, dataDir: DATA_DIR, port: cfg.port, pairing: { url, link } }, null, 2));
    return;
  }

  if (cmd !== "start") {
    console.log("usage: helm [start|pair|login|status]");
    process.exit(1);
  }

  const { log } = await import("./log.ts");
  const { AgentManager } = await import("./agents.ts");
  const { startServer } = await import("./server.ts");
  const { store } = await import("./store.ts");
  if (!readCursorApiKey()) log.warn("Not logged in to Cursor: run `npm run login` in hub/ so agents can start.");
  if (!cfg.apns) log.warn(`Push is off: put your APNs AuthKey_XXXXXXXXXX.p8 in ${DATA_DIR} and restart.`);
  const agents = new AgentManager(cfg);
  startServer(cfg, agents);
  await printPairing(cfg);
  const stop = () => {
    store.flush();
    agents.shutdown();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  // Started by the Mac app: stop with it, even when it's killed rather than quit.
  const parent = Number(process.env.HELM_PARENT_PID);
  if (parent) setInterval(() => process.ppid !== parent && stop(), 2000).unref();
  process.on("uncaughtException", (e) => log.error(`uncaught: ${e.stack || e.message}`));
  process.on("unhandledRejection", (e: any) => log.error(`unhandled: ${e?.stack || e}`));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
