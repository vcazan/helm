import http from "node:http";
import fs from "node:fs";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { WebSocketServer, type WebSocket } from "ws";
import type { HubConfig } from "./config.ts";
import { readCursorApiKey } from "./config.ts";
import { store, bus, type Workspace } from "./store.ts";
import type { AgentManager } from "./agents.ts";
import { cursorRecents, openCursorWindows, openInCursor, listDir, readDocument, repoInfo, cursorRunning } from "./desktop.ts";
import { listSprites, createSprite, destroySprite, spriteAuthState } from "./sprites.ts";
import { pushEnabled, push } from "./push.ts";
import { startLiveActivities } from "./liveactivity.ts";
import { CursorUI, chatFiles, desktopTranscript, desktopQueue, desktopSubagents, desktopSubagent, linkSubagents, orphanSubagents } from "./cursorui.ts";
import { withRememberedResults } from "./mcp.ts";
import { asAgentMessages, handleMcp, registerWithCursor } from "./mcpserver.ts";
import { fileChange, workingChanges } from "./diff.ts";
import { imageFile, withImages } from "./images.ts";
import { makeDir, searchDirs, githubRepos, startClone } from "./github.ts";
import { log } from "./log.ts";
import { activeWait, desktopWait, withWait } from "./wait.ts";
import { desktopLiveTurns, withLiveTurns } from "./liveturn.ts";

const folderKey = (folders: string[]) => [...folders].sort().join("\n");

export function syncCursorWorkspaces() {
  const known = new Set(store.s.workspaces.map((w) => folderKey(w.folders)));
  const recents = cursorRecents();
  const now = Date.now();
  recents.forEach((r, i) => {
    if (known.has(folderKey(r.folders))) return;
    known.add(folderKey(r.folders));
    store.upsertWorkspace({ id: randomUUID().slice(0, 8), name: r.name, folders: r.folders, source: "cursor", pinned: false, hidden: false, createdAt: now, lastActiveAt: now - (i + 1) * 60_000 });
  });
  // Open in Cursor but not in its recents list yet.
  for (const folders of openCursorWindows()) {
    if (folders.length !== 1 || known.has(folderKey(folders))) continue;
    known.add(folderKey(folders));
    store.upsertWorkspace({ id: randomUUID().slice(0, 8), name: folders[0].split("/").pop() || folders[0], folders, source: "cursor", pinned: false, hidden: false, createdAt: now, lastActiveAt: now });
  }
}

function isLoopback(addr = "") {
  const a = addr.replace(/^::ffff:/, "");
  return a === "127.0.0.1" || a === "::1";
}

function isAllowedAddress(addr = "") {
  const a = addr.replace(/^::ffff:/, "");
  if (isLoopback(a)) return true;
  const m = a.match(/^100\.(\d+)\./);
  if (m && +m[1] >= 64 && +m[1] <= 127) return true;
  if (a.toLowerCase().startsWith("fd7a:115c:a1e0")) return true;
  if (process.env.HELM_ALLOW_LAN && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a)) return true;
  return false;
}

class HttpError extends Error {
  status: number;
  constructor(status: number, msg: string) {
    super(msg);
    this.status = status;
  }
}

async function readBody(req: http.IncomingMessage): Promise<any> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > 40 * 1024 * 1024) throw new HttpError(413, "body too large");
    chunks.push(c);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "invalid json");
  }
}

export function startServer(cfg: HubConfig, agents: AgentManager) {
  const tokenBuf = Buffer.from(cfg.token);
  const authed = (t?: string | null) => !!t && t.length === cfg.token.length && timingSafeEqual(Buffer.from(t), tokenBuf);
  let openCache: { at: number; keys: Set<string> } = { at: 0, keys: new Set() };

  async function hubInfo() {
    let sdkEmail: string | undefined;
    try {
      const p = `${process.env.HOME}/.cursor/sdk/auth.json`;
      if (fs.existsSync(p)) sdkEmail = JSON.parse(fs.readFileSync(p, "utf8")).email;
    } catch {}
    return {
      name: cfg.hubName,
      version: "1.0.0",
      push: pushEnabled(cfg.apns),
      cursorLoggedIn: !!readCursorApiKey(),
      cursorEmail: sdkEmail,
      cursorRunning: await cursorRunning(),
      defaultModel: cfg.defaultModel,
    };
  }

  function openKeys() {
    if (Date.now() - openCache.at > 5000) openCache = { at: Date.now(), keys: new Set(openCursorWindows().map(folderKey)) };
    return openCache.keys;
  }

  function wsView(w: Workspace) {
    return { ...w, openOnLaptop: openKeys().has(folderKey(w.folders)) };
  }

  const ui = new CursorUI();
  agents.attachDesktop(ui);
  try {
    registerWithCursor(cfg.port, cfg.mcpToken);
  } catch (e: any) {
    log.warn(`couldn't add Helm to Cursor's MCP servers: ${e.message}`);
  }
  ui.onAttention = (w, chat, why) => {
    log.info(`desktop ${why}: ${w.workspace} / ${chat}`);
    if (why === "done" && !cfg.notifyOnFinish) return;
    const body = why === "question" ? (w.question?.questions[0]?.prompt || "Has a question for you").slice(0, 160) : why === "approval" ? `Wants to run: ${(w.pending?.label || "").split("\n")[0].slice(0, 120)}` : why === "attention" ? "Needs your input" : "Finished";
    push(cfg.apns, { title: chat || w.workspace, subtitle: `${w.workspace} · Cursor`, body, category: why === "done" ? "AGENT" : "DECISION", data: { desktopWindow: w.id, chat } }).catch(() => {});
  };
  ui.start();
  const activities = startLiveActivities(() => cfg.apns, ui);

  async function snapshot() {
    syncCursorWorkspaces();
    return {
      desktop: ui.state(),
      hub: await hubInfo(),
      // Removed projects still open in Cursor show up there anyway, so keep them pinnable.
      workspaces: store.s.workspaces.filter((w) => !w.hidden || openKeys().has(folderKey(w.folders))).map(wsView),
      agents: store.s.agents,
      decisions: store.s.decisions,
    };
  }

  type Handler = (p: { body: any; params: Record<string, string>; query: URLSearchParams }) => Promise<any> | any;
  const routes: Array<{ method: string; re: RegExp; keys: string[]; h: Handler }> = [];
  const route = (method: string, pattern: string, h: Handler) => {
    const keys: string[] = [];
    const re = new RegExp("^" + pattern.replace(/:(\w+)/g, (_, k) => (keys.push(k), "([^/]+)")) + "$");
    routes.push({ method, re, keys, h });
  };

  route("GET", "/api/state", () => snapshot());

  route("POST", "/api/workspaces", ({ body }) => {
    const folders: string[] = (body.folders || []).filter((f: string) => fs.existsSync(f));
    const w: Workspace = {
      id: randomUUID().slice(0, 8),
      name: String(body.name || "").trim() || (folders[0] ? folders[0].split("/").pop()! : "New workspace"),
      folders,
      source: "hub",
      pinned: false,
      hidden: false,
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    };
    store.upsertWorkspace(w);
    if (body.openOnLaptop && folders.length) openInCursor(w).catch((e) => log.warn(`open in cursor: ${e.message}`));
    return wsView(w);
  });

  route("PATCH", "/api/workspaces/:id", ({ params, body }) => {
    const w = store.workspace(params.id);
    if (!w) throw new HttpError(404, "workspace not found");
    if (typeof body.name === "string" && body.name.trim()) w.name = body.name.trim();
    if (Array.isArray(body.folders)) w.folders = body.folders.filter((f: string) => fs.existsSync(f));
    if (typeof body.pinned === "boolean") w.pinned = body.pinned;
    if (w.pinned) w.hidden = false;
    store.upsertWorkspace(w);
    return wsView(w);
  });

  route("DELETE", "/api/workspaces/:id", async ({ params }) => {
    const w = store.workspace(params.id);
    if (!w) return { ok: true };
    for (const a of store.s.agents.filter((x) => x.workspaceId === w.id)) await agents.remove(a.id);
    if (w.source === "cursor") {
      w.hidden = true;
      store.upsertWorkspace(w);
      bus.emit("event", { type: "removed", kind: "workspace", id: w.id });
    } else store.removeWorkspace(w.id);
    return { ok: true };
  });

  route("POST", "/api/workspaces/:id/open", async ({ params }) => {
    const w = store.workspace(params.id);
    if (!w) throw new HttpError(404, "workspace not found");
    if (!w.folders.length) throw new HttpError(400, "workspace has no folders");
    await openInCursor(w);
    openCache.at = 0;
    return { ok: true };
  });

  route("GET", "/api/fs", ({ query }) => {
    try {
      return listDir(query.get("path") || "~", query.get("hidden") === "1");
    } catch (e: any) {
      throw new HttpError(400, e.message);
    }
  });

  /** Files a chat (`<composerId>` or `agent:<id>`) has touched, so loose document names can be resolved. */
  const known = new Map<string, { at: number; files: string[] }>();
  const knownFiles = (chat: string): string[] => {
    if (!chat) return [];
    const hit = known.get(chat);
    if (hit && Date.now() - hit.at < 20_000) return hit.files;
    let files: string[] = [];
    if (chat.startsWith("agent:")) {
      const id = chat.slice(6);
      const ws = store.workspace(store.agent(id)?.workspaceId || "");
      for (const it of store.transcript(id)) {
        const a: any = it.tool?.args;
        const p = a?.path ?? a?.file_path ?? a?.target_file;
        if (typeof p === "string" && p.startsWith("/")) files.push(p);
      }
      files.push(...(ws?.folders || []).map((f) => f.replace(/\/?$/, "/.")));
    } else {
      files = chatFiles(chat);
    }
    known.set(chat, { at: Date.now(), files });
    if (known.size > 50) known.delete(known.keys().next().value!);
    return files;
  };

  route("GET", "/api/file", ({ query }) => {
    try {
      return readDocument(query.get("path") || "", query.get("root") || undefined, knownFiles(query.get("chat") || ""));
    } catch (e: any) {
      if (e.code === "ENOENT") throw new HttpError(404, "This file isn't on your Mac anymore");
      throw new HttpError(e.status || 400, e.message);
    }
  });
  route("GET", "/api/changes", ({ query }) => workingChanges(query.get("root") || ""));
  route("GET", "/api/changes/file", ({ query }) => fileChange(query.get("root") || "", query.get("path") || ""));
  route("GET", "/api/fs/search", ({ query }) => searchDirs(query.get("q") || "", query.get("root") || "~"));
  route("POST", "/api/fs/mkdir", ({ body }) => makeDir(String(body.parent || "~"), String(body.name || "")));
  route("GET", "/api/github/repos", ({ query }) => githubRepos(query.get("q") || ""));
  route("POST", "/api/github/clone", ({ body }) => startClone(String(body.repo || ""), String(body.parent || "~/Projects"), body.name ? String(body.name) : undefined));

  route("GET", "/api/repo-info", ({ query }) => repoInfo(query.get("path") || ""));

  route("GET", "/api/models", async () => {
    const list = await agents.models();
    return list.map((m: any) => ({ id: m.id, name: m.displayName, description: m.description }));
  });

  route("POST", "/api/agents", async ({ body }) => {
    const runtime = body.runtime?.kind === "sprite" ? { kind: "sprite" as const, sprite: String(body.runtime.sprite), repo: String(body.runtime.repo), branch: body.runtime.branch || undefined } : { kind: "local" as const };
    if (runtime.kind === "sprite" && (!runtime.sprite || !/^[\w.-]+\/[\w.-]+$/.test(runtime.repo))) throw new HttpError(400, "sprite agents need a sprite name and a GitHub repo like owner/name");
    if (runtime.kind === "sprite" && body.createSprite) await createSprite(runtime.sprite);
    return agents.createAgent({ workspaceId: body.workspaceId, name: body.name, model: body.model, runtime, prompt: body.prompt, images: body.images });
  });

  route("GET", "/api/agents/:id/transcript", ({ params }) => {
    if (!store.agent(params.id)) throw new HttpError(404, "agent not found");
    const items = store.transcript(params.id);
    return withImages(withWait(items, activeWait(items)));
  });

  route("POST", "/api/agents/:id/messages", ({ params, body }) => {
    if (!String(body.text || "").trim() && !body.images?.length) throw new HttpError(400, "empty message");
    agents.sendUser(params.id, String(body.text || ""), body.images);
    return { ok: true };
  });

  route("POST", "/api/agents/:id/cancel", async ({ params }) => {
    await agents.cancel(params.id);
    return { ok: true };
  });

  route("POST", "/api/agents/:id/read", ({ params }) => {
    store.updateAgent(params.id, { unread: 0 });
    return { ok: true };
  });

  route("POST", "/api/agents/:id/relay", ({ params, body }) => {
    agents.relay(params.id, String(body.targetId), String(body.instruction || ""));
    return { ok: true };
  });

  route("PATCH", "/api/agents/:id", ({ params, body }) => agents.update(params.id, body));

  route("DELETE", "/api/agents/:id", async ({ params }) => {
    await agents.remove(params.id);
    return { ok: true };
  });

  route("POST", "/api/decisions/:id", ({ params, body }) => agents.answerDecision(params.id, String(body.answer || "")));

  route("GET", "/api/desktop", () => ui.state());

  route("GET", "/api/desktop/:win/transcript", async ({ params, query }) => {
    const chat = query.get("chat") || "";
    let composerId = query.get("composerId") || undefined;
    if (!composerId) composerId = await ui.locked(params.win, () => ui.select(params.win, chat));
    if (!composerId) throw new HttpError(404, "Couldn't find that chat's history");
    const t = desktopTranscript(composerId);
    const live = await ui.liveRows(params.win, composerId).catch(() => []);
    const subagents = desktopSubagents(composerId);
    const working = ui.state().windows.some((w) => w.chats.some((c) => c.composerId === composerId && c.status === "working"));
    const turns = desktopLiveTurns(composerId, working);
    const base = withWait(withLiveTurns(t?.items || [], turns, composerId), desktopWait(composerId));
    linkSubagents(base, subagents);
    const all = withImages(asAgentMessages(withRememberedResults([...base, ...orphanSubagents(composerId, base, subagents)])));
    const items = tailOf(all, Number(query.get("tail")) || 0);
    return { composerId, items, total: all.length, updatedAt: t?.updatedAt, live, liveTurn: turns.some((x) => x.items.length > 0), queued: desktopQueue(composerId), subagents };
  });

  route("GET", "/api/desktop/subagents/:id", ({ params }) => {
    const s = desktopSubagent(params.id);
    if (!s) throw new HttpError(404, "Couldn't find that subagent");
    return s;
  });

  route("POST", "/api/agents/:id/queue/edit", ({ params, body }) => agents.editQueued(params.id, String(body.id || ""), String(body.text || "").trim()));
  route("POST", "/api/agents/:id/queue/send", ({ params, body }) => agents.sendQueuedNow(params.id, String(body.id || "")));
  route("POST", "/api/agents/:id/queue/remove", ({ params, body }) => agents.removeQueued(params.id, String(body.id || "")));
  route("POST", "/api/desktop/:win/queue/edit", ({ params, body }) => {
    const text = String(body.text || "").trim();
    if (!text) throw new HttpError(400, "text required");
    return ui.locked(params.win, () => ui.editQueued(params.win, String(body.chat || ""), String(body.id || ""), text));
  });
  route("POST", "/api/desktop/:win/queue/send", ({ params, body }) => ui.locked(params.win, () => ui.sendQueuedNow(params.win, String(body.chat || ""), String(body.id || ""))));
  route("POST", "/api/agents/:id/queue/move", ({ params, body }) => agents.reorderQueued(params.id, String(body.id || ""), Number(body.to) || 0));
  route("POST", "/api/desktop/:win/queue/move", ({ params, body }) =>
    ui.locked(params.win, () => ui.reorderQueued(params.win, String(body.chat || ""), String(body.id || ""), Number(body.to) || 0)),
  );
  route("POST", "/api/desktop/:win/queue/remove", ({ params, body }) => ui.locked(params.win, () => ui.removeQueued(params.win, String(body.chat || ""), String(body.id || ""))));
  route("POST", "/api/desktop/:win/select", async ({ params, body }) => ({ composerId: await ui.select(params.win, String(body.chat || "")) }));
  route("POST", "/api/desktop/:win/send", ({ params, body }) => {
    const text = String(body.text || "").trim();
    const images = Array.isArray(body.images) ? body.images.filter((i: any) => typeof i?.data === "string").slice(0, 8) : [];
    if (!text && !images.length) throw new HttpError(400, "text or images required");
    return ui.locked(params.win, () => ui.send(params.win, body.chat ? String(body.chat) : undefined, text, images));
  });
  route("POST", "/api/desktop/:win/respond", ({ params, body }) => ui.locked(params.win, () => ui.respond(params.win, String(body.chat || ""), body.approve !== false)));
  route("POST", "/api/desktop/:win/answer", ({ params, body }) => ui.locked(params.win, () => ui.answer(params.win, String(body.chat || ""), Array.isArray(body.answers) ? body.answers : [])));
  route("POST", "/api/desktop/:win/chats/:id/rename", ({ params, body }) => {
    const name = String(body.name || "").replace(/\s+/g, " ").trim().slice(0, 120);
    if (!name) throw new HttpError(400, "name required");
    return ui.locked(params.win, () => ui.manage(params.win, params.id, "rename", name));
  });
  route("POST", "/api/desktop/:win/chats/:id/archive", ({ params, body }) =>
    ui.locked(params.win, () => ui.manage(params.win, params.id, body.archived === false ? "restore" : "archive")),
  );
  route("POST", "/api/desktop/:win/chats/:id/delete", ({ params }) => ui.locked(params.win, () => ui.manage(params.win, params.id, "delete")));
  route("POST", "/api/desktop/:win/stop", ({ params, body }) => ui.locked(params.win, () => ui.stopChat(params.win, String(body.chat || ""))));

  route("GET", "/api/sprites", async () => {
    const auth = await spriteAuthState();
    if (!auth.ok) return { loggedIn: false, error: auth.error, sprites: [] };
    return { loggedIn: true, sprites: await listSprites() };
  });

  route("POST", "/api/sprites", async ({ body }) => {
    const name = String(body.name || "").trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9-]{1,40}$/.test(name)) throw new HttpError(400, "sprite names use lowercase letters, numbers and dashes");
    await createSprite(name);
    return { ok: true, name };
  });

  route("DELETE", "/api/sprites/:name", async ({ params }) => {
    for (const a of store.s.agents.filter((x) => x.runtime.kind === "sprite" && x.runtime.sprite === params.name)) await agents.remove(a.id);
    agents.sprites.get(params.name)?.stop();
    agents.sprites.delete(params.name);
    await destroySprite(params.name);
    return { ok: true };
  });

  route("POST", "/api/devices", ({ body }) => {
    const id = String(body.id || randomUUID());
    const prev = store.s.devices.find((d) => d.id === id);
    if (body.notif) log.info(`device ${id.slice(0, 8)} notif settings ${JSON.stringify(body.notif)} token ${String(body.apnsToken || "none").slice(0, 8)}`);
    store.upsertDevice({ ...prev, id, name: String(body.name || "iPhone"), apnsToken: body.apnsToken || undefined, apnsEnv: body.apnsEnv === "production" ? "production" : "sandbox", lastSeenAt: Date.now() });
    return { ok: true, id };
  });

  route("POST", "/api/devices/:id/activity", ({ params, body }) => {
    const dev = store.s.devices.find((d) => d.id === params.id);
    if (!dev) throw Object.assign(new Error("Unknown device"), { status: 404 });
    // A new push-to-start token means the app was reinstalled or relaunched, which ends its activity.
    if ("startToken" in body && body.startToken !== dev.activityStartToken && !("token" in body)) dev.activityToken = undefined;
    if ("token" in body) dev.activityToken = body.token || undefined;
    if ("startToken" in body) dev.activityStartToken = body.startToken || undefined;
    log.info(`live activity tokens for ${dev.name}: ${dev.activityToken ? "running" : "none"}, ${dev.activityStartToken ? "can start" : "can't start"}`);
    store.upsertDevice(dev);
    activities.refresh();
    return { ok: true };
  });
  route("GET", "/api/activity", () => activities.state());

  route("POST", "/api/push-ack", ({ body }) => {
    log.info(`push received on phone (${body.how}): ${body.id}`);
    return { ok: true };
  });

  route("POST", "/api/test-push", async () => {
    await push(cfg.apns, { title: "Helm", body: "Push notifications are working.", category: "AGENT" });
    return { ok: true, enabled: pushEnabled(cfg.apns), devices: store.s.devices.filter((d) => d.apnsToken).length };
  });

  const server = http.createServer(async (req, res) => {
    const send = (status: number, data: any) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(data));
    };
    if (!isAllowedAddress(req.socket.remoteAddress)) return send(403, { error: "only Tailscale and local connections are allowed" });
    const url = new URL(req.url || "/", "http://x");
    if (url.pathname === "/health") return send(200, { ok: true, name: cfg.hubName });
    if (url.pathname === "/hub" && isLoopback(req.socket.remoteAddress) && authed(req.headers.authorization?.replace(/^Bearer\s+/i, ""))) {
      return send(200, {
        name: cfg.hubName,
        phonesConnected: clients.size,
        devices: store.s.devices.map((d) => ({ name: d.name, lastSeenAt: d.lastSeenAt, push: !!d.apnsToken })),
        push: pushEnabled(cfg.apns),
      });
    }
    if (url.pathname === "/mcp") {
      const local = isLoopback(req.socket.remoteAddress);
      const t = req.headers.authorization?.replace(/^Bearer\s+/i, "") || "";
      if (!local || t.length !== cfg.mcpToken.length || !timingSafeEqual(Buffer.from(t), Buffer.from(cfg.mcpToken))) return send(401, { error: "unauthorized" });
      try {
        return await handleMcp(req, res, req.method === "POST" ? await readBody(req) : {}, agents);
      } catch (e: any) {
        log.error(`mcp: ${e.stack || e.message}`);
        return send(500, { error: e.message });
      }
    }
    const auth = req.headers.authorization?.replace(/^Bearer\s+/i, "");
    if (!authed(auth)) return send(401, { error: "unauthorized" });
    if (url.pathname === "/api/image" && req.method === "GET") {
      try {
        const w = Number(url.searchParams.get("w")) || undefined;
        const img = await imageFile(url.searchParams.get("path") || "", url.searchParams.get("root") || undefined, w);
        res.writeHead(200, { "content-type": img.mime, "cache-control": "private, max-age=3600" });
        return fs.createReadStream(img.file).pipe(res);
      } catch (e: any) {
        return send(e.code === "ENOENT" ? 404 : e.status || 400, { error: e.code === "ENOENT" ? "This image isn't on your Mac anymore" : e.message });
      }
    }
    const r = routes.find((x) => x.method === req.method && x.re.test(url.pathname));
    if (!r) return send(404, { error: "not found" });
    const m = url.pathname.match(r.re)!;
    const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
    try {
      const body = req.method === "GET" ? {} : await readBody(req);
      send(200, (await r.h({ body, params, query: url.searchParams })) ?? { ok: true });
    } catch (e: any) {
      const status = typeof e.status === "number" ? e.status : 500;
      if (status >= 500) log.error(`${req.method} ${url.pathname}: ${e.stack || e.message}`);
      // CDP internals ("Runtime.evaluate timed out") mean nothing on a phone.
      const msg = /^(Runtime|Input|Page|DOM)\.\w+ timed out$/.test(String(e.message)) ? "Cursor didn't respond in time. It may be busy; try again in a moment." : e.message;
      send(status, { error: msg });
    }
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url || "/", "http://x");
    if (!isAllowedAddress(req.socket.remoteAddress) || url.pathname !== "/ws" || !authed(url.searchParams.get("token"))) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      return socket.destroy();
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws));
  });

  const clients = new Set<WebSocket>();
  wss.on("connection", async (ws: WebSocket & { alive?: boolean }) => {
    clients.add(ws);
    ws.alive = true;
    ws.on("pong", () => (ws.alive = true));
    ws.on("close", () => clients.delete(ws));
    ws.on("error", () => clients.delete(ws));
    ws.send(JSON.stringify({ type: "snapshot", ...(await snapshot()) }));
  });

  setInterval(() => {
    for (const ws of clients as Set<WebSocket & { alive?: boolean }>) {
      if (!ws.alive) {
        ws.terminate();
        clients.delete(ws);
        continue;
      }
      ws.alive = false;
      ws.ping();
    }
  }, 20_000);

  bus.on("event", (ev) => {
    const payload = JSON.stringify(ev.type === "workspace" ? { ...ev, workspace: wsView(ev.workspace) } : ev);
    for (const ws of clients) if (ws.readyState === 1) ws.send(payload);
  });

  server.listen(cfg.port, "0.0.0.0", () => log.info(`hub listening on :${cfg.port}`));
  return server;
}

/** The newest `n` items, widened back to the user message that starts that turn so a page never opens mid-run. */
function tailOf<T extends { kind: string }>(items: T[], n: number): T[] {
  if (!n || n >= items.length) return items;
  let start = items.length - n;
  for (let i = start; i >= Math.max(0, start - 200); i--) {
    if (items[i].kind === "user") {
      start = i;
      break;
    }
  }
  return items.slice(start);
}
