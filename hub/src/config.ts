import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";

export const HOME = os.homedir();
export const DATA_DIR = process.env.HELM_DATA_DIR || path.join(HOME, ".helm");
export const TRANSCRIPTS_DIR = path.join(DATA_DIR, "transcripts");
export const WORKSPACE_FILES_DIR = path.join(DATA_DIR, "workspaces");
export const LOG_DIR = path.join(DATA_DIR, "logs");
export const CONFIG_PATH = path.join(DATA_DIR, "config.json");
export const HUB_DIR = path.resolve(import.meta.dirname, "..");
export const RUNNER_PATH = path.join(HUB_DIR, "runner", "runner.mjs");

export interface ApnsConfig {
  keyPath: string;
  keyId: string;
  teamId: string;
  bundleId: string;
}

export interface HubConfig {
  port: number;
  token: string;
  /** For Cursor chats calling Helm's MCP tools from this Mac; it can't reach the rest of the API. */
  mcpToken: string;
  hubName: string;
  defaultModel: string;
  settingSources: string[];
  notifyOnFinish: boolean;
  apns?: ApnsConfig;
  /** For push: your Apple Developer team ID and the iOS app's bundle ID (the ones in ios/Config/Local.xcconfig). */
  appleTeamId?: string;
  bundleId?: string;
}

for (const d of [DATA_DIR, TRANSCRIPTS_DIR, WORKSPACE_FILES_DIR, LOG_DIR]) fs.mkdirSync(d, { recursive: true, mode: 0o700 });

function detectApns(cfg: Partial<HubConfig>): ApnsConfig | undefined {
  const key = fs.readdirSync(DATA_DIR).find((f) => /^AuthKey_[A-Z0-9]+\.p8$/.test(f));
  const teamId = process.env.HELM_APPLE_TEAM_ID || cfg.appleTeamId;
  const bundleId = process.env.HELM_BUNDLE_ID || cfg.bundleId;
  if (!key || !teamId || !bundleId) return undefined;
  return {
    keyPath: path.join(DATA_DIR, key),
    keyId: key.slice("AuthKey_".length, -".p8".length),
    teamId,
    bundleId,
  };
}

export function loadConfig(): HubConfig {
  let cfg: Partial<HubConfig> = {};
  if (fs.existsSync(CONFIG_PATH)) cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  const full: HubConfig = {
    port: 7878,
    token: randomBytes(24).toString("base64url"),
    mcpToken: randomBytes(24).toString("base64url"),
    hubName: os.hostname().replace(/\.local$/, ""),
    defaultModel: "auto",
    settingSources: ["project", "user", "team", "plugins"],
    notifyOnFinish: true,
    ...cfg,
  };
  if (!full.apns) full.apns = detectApns(full);
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(full, null, 2), { mode: 0o600 });
  return full;
}

export function readCursorApiKey(): string | undefined {
  if (process.env.CURSOR_API_KEY) return process.env.CURSOR_API_KEY.trim();
  const p = path.join(HOME, ".cursor", "sdk", "auth.json");
  if (!fs.existsSync(p)) return undefined;
  try {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    if (j.apiKeyExpiresAtMs && j.apiKeyExpiresAtMs < Date.now()) return undefined;
    return j.apiKey;
  } catch {
    return undefined;
  }
}
