import http2 from "node:http2";
import crypto from "node:crypto";
import fs from "node:fs";
import type { ApnsConfig } from "./config.ts";
import { store, type Device } from "./store.ts";
import { log } from "./log.ts";

export interface PushMessage {
  title: string;
  subtitle?: string;
  body: string;
  category?: "DECISION" | "AGENT";
  threadId?: string;
  collapseId?: string;
  data?: Record<string, unknown>;
}

let jwt: { token: string; at: number } | undefined;

function apnsJwt(cfg: ApnsConfig) {
  if (jwt && Date.now() - jwt.at < 40 * 60_000) return jwt.token;
  const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = b64({ alg: "ES256", kid: cfg.keyId });
  const claims = b64({ iss: cfg.teamId, iat: Math.floor(Date.now() / 1000) });
  const sig = crypto.sign("sha256", Buffer.from(`${head}.${claims}`), {
    key: fs.readFileSync(cfg.keyPath, "utf8"),
    dsaEncoding: "ieee-p1363",
  });
  jwt = { token: `${head}.${claims}.${sig.toString("base64url")}`, at: Date.now() };
  return jwt.token;
}

const clients = new Map<string, http2.ClientHttp2Session>();
function client(host: string) {
  let c = clients.get(host);
  if (!c || c.closed || c.destroyed) {
    c = http2.connect(`https://${host}`);
    c.on("error", (e) => log.warn(`apns ${host}: ${e.message}`));
    c.on("close", () => clients.delete(host));
    clients.set(host, c);
  }
  return c;
}

function sendOne(cfg: ApnsConfig, dev: Device, msg: PushMessage): Promise<void> {
  const host = dev.apnsEnv === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const payload = JSON.stringify({
    aps: {
      alert: { title: msg.title, subtitle: msg.subtitle, body: msg.body },
      sound: "default",
      category: msg.category,
      "thread-id": msg.threadId,
      "mutable-content": 1,
      "content-available": 1,
    },
    pushId: msg.collapseId || `${Date.now().toString(36)}`,
    ...msg.data,
  });
  return new Promise((resolve) => {
    let req: http2.ClientHttp2Stream;
    try {
      req = client(host).request({
        ":method": "POST",
        ":path": `/3/device/${dev.apnsToken}`,
        authorization: `bearer ${apnsJwt(cfg)}`,
        "apns-topic": cfg.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        ...(msg.collapseId ? { "apns-collapse-id": msg.collapseId.slice(0, 64) } : {}),
      });
    } catch (e: any) {
      log.warn(`apns request failed: ${e.message}`);
      return resolve();
    }
    let status = 0;
    let body = "";
    req.on("response", (h) => (status = Number(h[":status"])));
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      if (status === 200) log.info(`push → ${dev.name}: ${msg.title} — ${msg.body.slice(0, 60)}`);
      if (status !== 200) {
        log.warn(`apns ${status} for ${dev.name}: ${body}`);
        if (status === 410 || /BadDeviceToken|Unregistered/.test(body)) {
          dev.apnsToken = undefined;
          store.upsertDevice(dev);
        }
      }
      resolve();
    });
    req.on("error", (e) => {
      log.warn(`apns stream error: ${e.message}`);
      resolve();
    });
    req.setTimeout(15_000, () => req.close());
    req.end(payload);
  });
}

/**
 * Sends any APNs payload (e.g. Live Activity updates) to a specific token. Resolves "ok" on 200 and "bad"
 * when Apple rejects the token itself. Live Activity tokens don't always come from the same APNs
 * environment as the app's alert token, so a rejected token gets one try on the other environment.
 */
export async function sendRaw(cfg: ApnsConfig, dev: Device, token: string, topic: string, pushType: string, priority: string, body: object): Promise<"ok" | "bad" | "failed"> {
  if (!pushEnabled(cfg)) return "failed";
  const env = dev.activityEnv || dev.apnsEnv;
  const first = await sendTo(cfg, dev, env, token, topic, pushType, priority, body);
  if (first.status === 200) return "ok";
  if (!/BadDeviceToken/.test(first.text)) {
    log.warn(`apns ${pushType} ${first.status} for ${dev.name}: ${first.text}`);
    return "failed";
  }
  const other = env === "production" ? "sandbox" : "production";
  const second = await sendTo(cfg, dev, other, token, topic, pushType, priority, body);
  if (second.status === 200) {
    log.info(`apns ${pushType}: ${dev.name}'s token is for ${other}, using that from now on`);
    dev.activityEnv = other;
    store.upsertDevice(dev);
    return "ok";
  }
  log.warn(`apns ${pushType} token for ${dev.name} rejected by both environments: ${first.text}`);
  return "bad";
}

function sendTo(cfg: ApnsConfig, dev: Device, env: Device["apnsEnv"], token: string, topic: string, pushType: string, priority: string, body: object): Promise<{ status: number; text: string }> {
  const host = env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  return new Promise((resolve) => {
    let req: http2.ClientHttp2Stream;
    try {
      req = client(host).request({
        ":method": "POST",
        ":path": `/3/device/${token}`,
        authorization: `bearer ${apnsJwt(cfg)}`,
        "apns-topic": topic,
        "apns-push-type": pushType,
        "apns-priority": priority,
      });
    } catch (e: any) {
      log.warn(`apns request failed for ${dev.name}: ${e.message}`);
      return resolve({ status: 0, text: e.message });
    }
    let status = 0;
    let text = "";
    req.on("response", (h) => (status = Number(h[":status"])));
    req.on("data", (d) => (text += d));
    req.on("end", () => resolve({ status, text }));
    req.on("error", (e) => resolve({ status: 0, text: e.message }));
    req.setTimeout(15_000, () => req.close());
    req.end(JSON.stringify(body));
  });
}

export function pushEnabled(cfg?: ApnsConfig) {
  return !!cfg && fs.existsSync(cfg.keyPath);
}

export async function push(cfg: ApnsConfig | undefined, msg: PushMessage) {
  if (!pushEnabled(cfg)) return;
  const devices = store.s.devices.filter((d) => d.apnsToken);
  await Promise.all(devices.map((d) => sendOne(cfg!, d, msg)));
}
