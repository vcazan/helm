import { Worker } from "node:worker_threads";
import fs from "node:fs";
import path from "node:path";
import { HOME } from "./config.ts";
import type { Item } from "./store.ts";
import { bus } from "./store.ts";
import { log } from "./log.ts";
import { fromTranscript } from "./mcp.ts";
import { lineDiff } from "./diff.ts";

// Drives the Cursor desktop app over the Chrome DevTools Protocol. Cursor has to be started with
// --remote-debugging-port (see `cursor-cdp`); everything here degrades to "unavailable" otherwise.

const CDP = `http://127.0.0.1:${process.env.CURSOR_CDP_PORT || 9222}`;
export const PROJECTS = path.join(HOME, ".cursor/projects");

export type ChatStatus = "working" | "attention" | "done" | "idle";

export interface DesktopChat {
  title: string;
  age: string;
  status: ChatStatus;
  selected: boolean;
  composerId?: string;
  updatedAt?: number;
}

export interface ArchivedChat {
  title: string;
  composerId: string;
  age: string;
}

export interface PendingApproval {
  chat: string;
  label: string;
  approve: string;
  reject?: string;
}

export interface PendingQuestion {
  chat: string;
  questions: Array<{ index: number; prompt: string; options: string[]; freeform: boolean; active: boolean }>;
}

export interface DesktopWindow {
  id: string;
  title: string;
  workspace: string;
  chats: DesktopChat[];
  archived?: ArchivedChat[];
  /** Cursor's services are reachable, so chats can be renamed, archived and deleted. */
  manageable?: boolean;
  activeComposerId?: string;
  working: boolean;
  pending?: PendingApproval;
  question?: PendingQuestion;
}

class Page {
  private ws?: WebSocket;
  private seq = 0;
  private waiting = new Map<number, (m: any) => void>();
  readonly id: string;
  title: string;
  private url: string;
  constructor(id: string, title: string, url: string) {
    this.id = id;
    this.title = title;
    this.url = url;
  }

  private async open() {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return this.ws;
    const ws = new WebSocket(this.url);
    await new Promise<void>((res, rej) => {
      ws.onopen = () => res();
      ws.onerror = () => rej(new Error("CDP connection failed"));
    });
    ws.onmessage = (e) => {
      const m = JSON.parse(String(e.data));
      const cb = this.waiting.get(m.id);
      if (cb) {
        this.waiting.delete(m.id);
        cb(m);
      }
    };
    ws.onclose = () => {
      this.ws = undefined;
      for (const cb of this.waiting.values()) cb({ error: { message: "closed" } });
      this.waiting.clear();
    };
    this.ws = ws;
    return ws;
  }

  async call(method: string, params: Record<string, unknown> = {}, timeout = 8000): Promise<any> {
    const ws = await this.open();
    const id = ++this.seq;
    return new Promise((res, rej) => {
      const t = setTimeout(() => {
        this.waiting.delete(id);
        rej(new Error(`${method} timed out`));
      }, timeout);
      this.waiting.set(id, (m) => {
        clearTimeout(t);
        m.error ? rej(new Error(m.error.message)) : res(m.result);
      });
      ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async eval<T = any>(fn: string, ...args: unknown[]): Promise<T> {
    return this.evalFor<T>(8000, fn, ...args);
  }

  async evalFor<T = any>(timeout: number, fn: string, ...args: unknown[]): Promise<T> {
    const expression = `(${fn})(...${JSON.stringify(args)})`;
    const r = await this.call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, timeout);
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result?.value as T;
  }

  /**
   * Click the element `finder` returns. Synthetic CDP mouse input is ignored by background
   * windows, so the pointer sequence is fired from inside the page instead.
   */
  async clickWhere(finder: string, ...args: unknown[]): Promise<boolean> {
    return this.eval<boolean>(
      `(...a) => {
        const el = (${finder})(...a);
        if (!el) return false;
        if (el.already) return true;
        el.scrollIntoView({ block: "nearest" });
        const r = el.getBoundingClientRect();
        const o = { bubbles: true, cancelable: true, composed: true, clientX: r.x + Math.min(r.width / 2, 40), clientY: r.y + r.height / 2, button: 0, pointerId: 1, pointerType: "mouse", isPrimary: true };
        for (const [T, t] of [[PointerEvent, "pointerdown"], [MouseEvent, "mousedown"], [PointerEvent, "pointerup"], [MouseEvent, "mouseup"], [MouseEvent, "click"]]) el.dispatchEvent(new T(t, o));
        return true;
      }`,
      ...args,
    );
  }

  private capturing?: Promise<boolean>;
  private captureFailedAt = 0;

  /**
   * Finds Cursor's workbench services (the same object its sidebar uses to rename, archive and delete
   * chats) and parks it on `window.__helmSvc`. It lives in a module-level WeakMap, reachable from any
   * of the bundle's event listeners through their closure scopes. Takes about a second, once per window load.
   */
  captureServices(): Promise<boolean> {
    if (this.capturing) return this.capturing;
    if (Date.now() - this.captureFailedAt < 60_000) return Promise.resolve(false);
    this.capturing = (async () => {
      const group = "helm-capture";
      try {
        const props = async (objectId: string) => this.call("Runtime.getProperties", { objectId, ownProperties: true });
        const fns = await this.call("Runtime.evaluate", {
          expression: `(() => { const out = []; for (const el of [window, document, document.body]) for (const ls of Object.values(getEventListeners(el))) for (const l of ls) out.push(l.listener); return out })()`,
          includeCommandLineAPI: true,
          objectGroup: group,
        });
        if (!fns.result?.objectId) throw new Error("no listeners");
        const list = (await props(fns.result.objectId)).result.filter((p: any) => /^\d+$/.test(p.name));
        for (const f of list) {
          const scopes = (await props(f.value.objectId)).internalProperties?.find((p: any) => p.name === "[[Scopes]]");
          if (!scopes) continue;
          for (const s of (await props(scopes.value.objectId)).result) {
            if (!/^\d+$/.test(s.name) || s.value.description !== "Module") continue;
            const vars = (await props(s.value.objectId)).result as any[];
            for (const v of vars) {
              if (v.value?.className !== "WeakMap") continue;
              const entries = (await props(v.value.objectId)).internalProperties?.find((p: any) => p.name === "[[Entries]]");
              if (!entries) continue;
              const r = await this.call("Runtime.callFunctionOn", {
                objectId: entries.value.objectId,
                returnByValue: true,
                functionDeclaration: `function () {
                  for (let i = 0; i < this.length; i++) {
                    const s = this[i]?.value;
                    try {
                      if (typeof s?.composerService?.renameComposer === "function" && typeof s?.composerDataService?.setAllComposersData === "function" && s.agentLayoutService) {
                        window.__helmSvc = s;
                        return true;
                      }
                    } catch {}
                  }
                  return false;
                }`,
              });
              if (r.result?.value) {
                log.info(`cursor services captured for "${this.title}"`);
                return true;
              }
            }
            break;
          }
        }
        throw new Error("services not found");
      } catch (e: any) {
        this.captureFailedAt = Date.now();
        log.warn(`cursor services capture (${this.title}): ${e.message}`);
        return false;
      } finally {
        this.call("Runtime.releaseObjectGroup", { objectGroup: group }).catch(() => {});
        this.capturing = undefined;
      }
    })();
    return this.capturing;
  }

  close() {
    this.ws?.close();
  }
}

// Runs inside the Cursor window. Keep it self-contained: it is serialised into Runtime.evaluate.
const READ_STATE = `() => {
  const cells = [...document.querySelectorAll(".agent-sidebar-cell[data-has-hover-actions]")];
  const chats = [];
  for (const c of cells) {
    const title = c.querySelector(".agent-sidebar-cell-text")?.textContent?.trim() || "";
    const caption = c.querySelector(".agent-sidebar-cell-caption")?.textContent?.trim();
    if (!caption) continue;
    const label = [...c.querySelectorAll("[aria-label]")].map(e => e.getAttribute("aria-label")).join(" ");
    const status = /progress|running|generating/i.test(label) ? "working" : /attention|waiting|review/i.test(label) ? "attention" : /complete/i.test(label) ? "done" : "idle";
    chats.push({ title, age: caption, status, selected: c.dataset.selected === "true" });
  }
  const aux = document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar") || document;
  const visible = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const approveSel = "button.ui-shell-tool-call__run-btn, button.ui-shell-tool-call__allowlist-button";
  const rejectSel = "button.ui-shell-tool-call__skip-btn";
  let approve = [...aux.querySelectorAll(approveSel)].find(visible);
  if (!approve) approve = [...aux.querySelectorAll("button")].find(b => visible(b) && /^(Run|Accept|Accept All|Allow|Approve)\\b/.test(b.innerText.trim()) && b.closest("[data-message-kind=tool], [data-tool-call-id]"));
  let pending;
  if (approve) {
    const row = approve.closest("[data-tool-call-id], [data-message-kind=tool], .agent-transcript-row");
    const reject = row && ([...row.querySelectorAll(rejectSel)].find(visible) || [...row.querySelectorAll("button")].find(b => visible(b) && /^(Skip|Reject|Deny|Cancel)\\b/.test(b.innerText.trim())));
    const sel = chats.find(c => c.selected);
    pending = { chat: sel?.title || "", label: (row?.innerText || "").replace(/\\s+\\n/g, "\\n").trim().slice(0, 600), approve: approve.innerText.trim() || "Run", reject: reject?.innerText.trim() };
  }
  const stop = [...aux.querySelectorAll(".composer-button-area .codicon-debug-stop")].find(visible);
  const qEls = [...aux.querySelectorAll(".composer-questionnaire-toolbar-question")];
  let question;
  if (qEls.length) {
    const sel = chats.find(c => c.selected);
    question = {
      chat: sel?.title || "",
      questions: qEls.map((q, index) => ({
        index,
        prompt: (q.querySelector(".composer-questionnaire-toolbar-question-label")?.innerText || "").replace(/^\\s*\\d+\\.\\s*/, "").trim(),
        options: [...q.querySelectorAll(".composer-questionnaire-toolbar-option:not(.composer-questionnaire-toolbar-option-freeform)")].map(o => (o.querySelector(".composer-questionnaire-toolbar-option-label")?.innerText || "").trim()).filter(Boolean),
        freeform: !!q.querySelector(".composer-questionnaire-toolbar-option-freeform, .composer-questionnaire-toolbar-freeform-input, textarea"),
        active: q.classList.contains("composer-questionnaire-toolbar-question-active"),
      })),
    };
  }
  const activeComposerId = aux.querySelector("[data-composer-id]")?.getAttribute("data-composer-id") || undefined;
  // The sidebar only renders some chats; Cursor's own records have all of them.
  let heads;
  try { heads = window.__helmSvc?.composerDataService?.allComposersData?.allComposers; } catch {}
  let list = chats, archived;
  if (Array.isArray(heads)) {
    const now = Date.now();
    const age = (t) => { const s = (now - t) / 1000; return !t ? "" : s < 60 ? "now" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : s < 604800 ? Math.floor(s / 86400) + "d" : Math.floor(s / 604800) + "w"; };
    const dom = new Map(chats.map(c => [c.title, c]));
    const real = heads
      .filter(h => h && h.type === "head" && !h.isBestOfNSubcomposer && !h.subagentInfo && (h.name || "").trim())
      .sort((a, b) => (b.lastUpdatedAt || b.createdAt || 0) - (a.lastUpdatedAt || a.createdAt || 0));
    const seen = new Set();
    list = [];
    for (const h of real) {
      const title = h.name.trim();
      if (h.isArchived || seen.has(title) || list.length >= 80) continue;
      seen.add(title);
      const at = h.lastUpdatedAt || h.createdAt || 0;
      const d = dom.get(title);
      const status = h.hasBlockingPendingActions ? "attention" : h.unfinishedRunAt && now - at < 15 * 60000 ? "working" : h.hasUnreadMessages && now - at < 86400000 ? "done" : "idle";
      list.push(d ? { ...d, composerId: h.composerId, updatedAt: at } : { title, age: age(at), status, selected: h.composerId === activeComposerId, composerId: h.composerId, updatedAt: at });
    }
    for (const c of chats) if (!seen.has(c.title)) { seen.add(c.title); list.push(c); }
    archived = real.filter(h => h.isArchived).slice(0, 40).map(h => ({ title: h.name.trim(), composerId: h.composerId, age: age(h.lastUpdatedAt || h.createdAt || 0) }));
  }
  return {
    question,
    chats: list,
    archived,
    manageable: Array.isArray(heads),
    activeComposerId,
    working: !!stop,
    pending,
  };
}`;

function workspaceOf(title: string) {
  const name = title.includes(" — ") ? title.split(" — ").pop()! : title;
  return name.replace(/\s*\(Workspace\)\s*$/, "").trim();
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class CursorUI {
  private pages = new Map<string, Page>();
  private windows: DesktopWindow[] = [];
  private lastJson = "";
  private available = false;
  private composerIds = new Map<string, string>();
  private timer?: NodeJS.Timeout;
  onAttention?: (w: DesktopWindow, chat: string, why: "approval" | "question" | "attention" | "done") => void;

  start() {
    const tick = async () => {
      await this.pollOnce();
      this.timer = setTimeout(tick, 1500);
    };
    tick();
  }

  private polling = false;
  private async pollOnce() {
    if (this.polling) return;
    this.polling = true;
    try {
      await this.poll();
    } catch (e: any) {
      log.debug(`cursor ui poll: ${e.message}`);
    } finally {
      this.polling = false;
    }
  }

  /** Look again right away, so a change we just caused (a send, an answer) reaches the phone fast. */
  nudge() {
    for (const ms of [150, 600, 1200]) setTimeout(() => this.pollOnce(), ms);
  }

  stop() {
    if (this.timer) clearTimeout(this.timer);
    for (const p of this.pages.values()) p.close();
  }

  state() {
    return { available: this.available, windows: this.windows };
  }

  private async targets() {
    try {
      const r = await fetch(`${CDP}/json`, { signal: AbortSignal.timeout(1500) });
      const list = (await r.json()) as any[];
      return list.filter((t) => t.type === "page" && t.webSocketDebuggerUrl && !t.url.startsWith("devtools://"));
    } catch {
      return undefined;
    }
  }

  private async poll() {
    const targets = await this.targets();
    if (!targets) {
      this.available = false;
      this.windows = [];
      this.emit();
      return;
    }
    this.available = true;
    const seen = new Set<string>();
    const next: DesktopWindow[] = [];
    for (const t of targets) {
      seen.add(t.id);
      let page = this.pages.get(t.id);
      if (!page) this.pages.set(t.id, (page = new Page(t.id, t.title, t.webSocketDebuggerUrl)));
      page.title = t.title;
      try {
        const s = await page.eval(READ_STATE);
        if (!s?.chats) continue;
        if (!s.manageable) page.captureServices().then((ok) => ok && this.nudge());
        const key = (title: string) => `${t.id}\n${title}`;
        const sel = s.chats.find((c: DesktopChat) => c.selected);
        if (sel && s.activeComposerId) this.composerIds.set(key(sel.title), s.activeComposerId);
        for (const c of s.chats) {
          if (c.composerId) this.composerIds.set(key(c.title), c.composerId);
          else c.composerId = this.composerIds.get(key(c.title));
        }
        next.push({ id: t.id, title: t.title, workspace: workspaceOf(t.title), ...s });
      } catch {}
    }
    for (const [id, p] of this.pages) {
      if (!seen.has(id)) {
        p.close();
        this.pages.delete(id);
      }
    }
    this.notifyChanges(this.windows, next);
    this.windows = next;
    this.emit();
  }

  private notifyChanges(prev: DesktopWindow[], next: DesktopWindow[]) {
    if (!this.onAttention || !prev.length) return;
    for (const w of next) {
      const before = prev.find((p) => p.id === w.id);
      if (!before) continue;
      if (w.pending && (!before.pending || before.pending.label !== w.pending.label)) this.onAttention(w, w.pending.chat, "approval");
      const qKey = (x?: PendingQuestion) => x?.questions.map((q) => q.prompt).join("|");
      if (w.question && qKey(w.question) !== qKey(before.question)) this.onAttention(w, w.question.chat, "question");
      for (const c of w.chats) {
        const old = before.chats.find((o) => o.title === c.title);
        if (!old) continue;
        if (c.status === "attention" && old.status !== "attention") this.onAttention(w, c.title, "attention");
        else if (c.status === "done" && old.status === "working") this.onAttention(w, c.title, "done");
      }
    }
  }

  private emit() {
    const json = JSON.stringify(this.state());
    if (json === this.lastJson) return;
    this.lastJson = json;
    bus.emit("event", { type: "desktop", ...this.state() });
  }

  private page(windowId: string) {
    const p = this.pages.get(windowId);
    if (!p) throw Object.assign(new Error("That Cursor window is no longer open"), { status: 404 });
    return p;
  }

  /** Make `title` the visible chat in its window. Returns its composer id once Cursor has switched. */
  async select(windowId: string, title: string): Promise<string | undefined> {
    const page = this.page(windowId);
    const cell = `(title) => [...document.querySelectorAll(".agent-sidebar-cell[data-has-hover-actions]")].find(c => c.querySelector(".agent-sidebar-cell-text")?.textContent?.trim() === title)`;
    const state = await page.eval<"missing" | "selected" | "other">(`(title) => { const c = (${cell})(title); return !c ? "missing" : c.dataset.selected === "true" ? "selected" : "other"; }`, title);
    if (state === "missing") {
      const want = this.composerIds.get(`${windowId}\n${title}`);
      if (!want || !(await this.openById(page, want))) throw Object.assign(new Error(`No chat called "${title}" in that window`), { status: 404 });
      return want;
    }
    if (state === "other") {
      await page.clickWhere(cell, title);
      for (let i = 0; i < 20; i++) {
        await sleep(100);
        if ((await page.eval<string>(`(title) => (${cell})(title)?.dataset.selected`, title)) === "true") break;
      }
      await sleep(250);
    }
    const id = await page.eval<string | undefined>(`() => document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar [data-composer-id]")?.getAttribute("data-composer-id") || undefined`);
    if (id) this.composerIds.set(`${windowId}\n${title}`, id);
    return id;
  }

  private activeId(page: Page) {
    return page.eval<string | undefined>(`() => document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar [data-composer-id]")?.getAttribute("data-composer-id") || undefined`);
  }

  /** Opens a chat the sidebar isn't rendering (it only shows recent ones) through Cursor's services. */
  private async openById(page: Page, id: string) {
    if ((await this.activeId(page)) === id) return true;
    const ok = await page.eval<boolean>(`(id) => { const s = window.__helmSvc; if (!s) return false; s.agentLayoutService.openComposer({ type: "local", id }); return true; }`, id);
    if (!ok) return false;
    for (let i = 0; i < 30; i++) {
      await sleep(100);
      if ((await this.activeId(page)) === id) {
        await sleep(250);
        return true;
      }
    }
    return false;
  }

  /** Renames, archives, restores or deletes a chat the way Cursor's sidebar does. */
  async manage(windowId: string, composerId: string, op: "rename" | "archive" | "restore" | "delete", name?: string) {
    const page = this.page(windowId);
    if (!(await page.eval<boolean>(`() => !!window.__helmSvc`)) && !(await page.captureServices())) {
      throw Object.assign(new Error("Helm can't reach Cursor's chat controls in that window yet. Try again in a moment."), { status: 409 });
    }
    const t0 = Date.now();
    const r = await page.evalFor<string>(
      20000,
      `async (op, id, name) => {
        const s = window.__helmSvc;
        const d = s.composerDataService;
        const all = () => d.allComposersData.allComposers;
        const head = () => all().find(c => c.composerId === id);
        if (!head()) return "missing";
        const active = document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar [data-composer-id]")?.getAttribute("data-composer-id");
        // Like the sidebar: leaving the open chat lands on the next most recent one, or a new agent.
        const leave = async () => {
          if (active !== id) return false;
          const next = all().filter(c => c.composerId !== id && c.type === "head" && !c.isArchived && !c.isBestOfNSubcomposer && !c.subagentInfo && (c.name || "").trim())
            .sort((a, b) => (b.lastUpdatedAt || 0) - (a.lastUpdatedAt || 0))[0];
          try { await (next ? s.agentLayoutService.openComposer({ type: "local", id: next.composerId }) : s.agentLayoutService.createNewComposer({ source: "sidebar" })); } catch {}
          return true;
        };
        if (op === "rename") {
          await s.composerService.renameComposer(id, name);
          return (head()?.name || "").trim() === name.trim() ? "ok" : "unchanged";
        }
        if (op === "restore") {
          d.setAllComposersData("allComposers", c => c.composerId === id, { isArchived: false, lastUpdatedAt: Date.now() });
          return head()?.isArchived ? "unchanged" : "ok";
        }
        if (op === "archive") {
          try { s.composerService.cancelChat(id); } catch {}
          d.setAllComposersData("allComposers", c => c.composerId === id, { isArchived: true, lastUpdatedAt: Date.now() });
          if (await leave()) try { s.composerService.closeComposer(id, { skipOpenComposer: false }); } catch {}
          return head()?.isArchived ? "ok" : "unchanged";
        }
        if (op === "delete") {
          try { s.composerService.cancelChat(id); } catch {}
          await leave();
          if (all().length > 1) await s.composerService.deleteComposer(id);
          else await s.composerService.resetComposer(id);
          return "deleting";
        }
        return "bad op";
      }`,
      op,
      composerId,
      name ?? "",
    );
    if (r === "missing") throw Object.assign(new Error("That chat isn't in this window anymore"), { status: 404 });
    // Timers are throttled in background windows, so wait here rather than in the page. Cursor erases
    // the chat but leaves a nameless header behind, which its sidebar skips.
    let ok = r === "ok";
    for (let i = 0; r === "deleting" && !ok && i < 20; i++) {
      ok = await page.eval<boolean>(`(id) => !(window.__helmSvc.composerDataService.allComposersData.allComposers.find(c => c.composerId === id)?.name || "").trim()`, composerId);
      if (!ok) await sleep(100);
    }
    if (!ok) throw new Error(`Cursor didn't ${op} that chat`);
    log.info(`desktop chat ${op} ${composerId}${name ? ` → "${name}"` : ""} in ${Date.now() - t0}ms`);
    this.nudge();
    return { ok: true };
  }

  /** The last rows Cursor is rendering for the open chat — newer than the transcript file, which lags. */
  async liveRows(windowId: string, composerId: string) {
    const page = this.page(windowId);
    return page.eval<Array<{ role: string; kind: string; text: string }>>(
      `(id) => {
        const aux = document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar");
        if (!aux || aux.querySelector("[data-composer-id]")?.getAttribute("data-composer-id") !== id) return [];
        return [...aux.querySelectorAll("[data-message-role]")].slice(-10).map(e => ({
          role: e.getAttribute("data-message-role"),
          kind: e.getAttribute("data-message-kind") || "",
          text: (e.innerText || "").trim().slice(0, 1200),
        })).filter(r => r.text);
      }`,
      composerId,
    );
  }

  async newChat(windowId: string) {
    const page = this.page(windowId);
    const before = await page.eval<string | undefined>(`() => document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar [data-composer-id]")?.getAttribute("data-composer-id") || undefined`);
    const ok = await page.clickWhere(`() => [...document.querySelectorAll(".agent-sidebar-cell")].find(c => /^New Agent/.test(c.innerText.trim()))`);
    if (!ok) throw new Error("Couldn't find New Agent in that window");
    for (let i = 0; i < 20; i++) {
      await sleep(100);
      const now = await page.eval<string | undefined>(`() => document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar [data-composer-id]")?.getAttribute("data-composer-id") || undefined`);
      if (now !== before) break;
    }
    await sleep(500);
  }

  async send(windowId: string, chat: string | undefined, text: string, images: Array<{ data: string; mimeType?: string }> = []) {
    const started = Date.now();
    const page = this.page(windowId);
    let cid: string | undefined;
    if (chat) cid = await this.select(windowId, chat);
    else await this.newChat(windowId);
    // Sending while the agent runs puts the message in Cursor's queue; report which entry it became
    // so the phone can track it by id instead of guessing from the text.
    const busy = await page.eval<boolean>(`() => [...document.querySelectorAll("#workbench\\\\.parts\\\\.auxiliarybar .composer-button-area .codicon-debug-stop")].some(e => e.getBoundingClientRect().width > 0)`);
    const queuedBefore = new Set(cid ? desktopQueue(cid).map((q) => q.id) : []);
    const input = `() => [...document.querySelectorAll("#workbench\\\\.parts\\\\.auxiliarybar .aislash-editor-input")].find(e => e.getBoundingClientRect().width > 0)`;
    if (!(await page.clickWhere(input))) throw new Error("The chat panel is closed in that window. Open it in Cursor (⌘L) and try again.");
    await page.eval(`() => (${input})()?.focus()`);
    const before = await page.eval<string>(`() => document.activeElement?.innerText || ""`);
    if (before.trim()) {
      await page.call("Input.dispatchKeyEvent", { type: "keyDown", key: "a", code: "KeyA", modifiers: 4, windowsVirtualKeyCode: 65 });
      await page.call("Input.dispatchKeyEvent", { type: "keyUp", key: "a", code: "KeyA", modifiers: 4, windowsVirtualKeyCode: 65 });
      await page.call("Input.dispatchKeyEvent", { type: "keyDown", key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 });
      await page.call("Input.dispatchKeyEvent", { type: "keyUp", key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 });
    }
    for (const [i, img] of images.entries()) {
      const attached = await page.eval<boolean>(
        `async (b64, type, name) => {
          const aux = document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar");
          const input = [...aux.querySelectorAll(".aislash-editor-input")].find(e => e.getBoundingClientRect().width > 0);
          if (!input) return false;
          const count = () => aux.querySelectorAll(".context-pill-image").length;
          const before = count();
          const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
          const dt = new DataTransfer();
          dt.items.add(new File([bytes], name, { type }));
          input.focus();
          input.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
          for (let t = 0; t < 40 && count() <= before; t++) await new Promise((r) => setTimeout(r, 100));
          return count() > before;
        }`,
        img.data,
        img.mimeType || "image/jpeg",
        `phone-${Date.now()}-${i + 1}.${(img.mimeType || "image/jpeg").split("/")[1] || "jpg"}`,
      );
      if (!attached) throw new Error("Cursor didn't take the picture. Is the chat input visible?");
    }
    await page.eval(`() => (${input})()?.focus()`);
    if (text) {
      await page.call("Input.insertText", { text });
      await sleep(120);
      const typed = await page.eval<string>(`() => document.activeElement?.innerText || ""`);
      if (!typed.includes(text.slice(0, 20).trim())) throw new Error("Cursor didn't accept the text. Is the chat input visible?");
    }
    await page.call("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" });
    await page.call("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
    this.nudge();
    let queued: string | undefined;
    for (let t = 0; cid && t < (busy ? 12 : 1) && !queued; t++) {
      await sleep(100);
      queued = desktopQueue(cid).find((q) => !queuedBefore.has(q.id))?.id;
    }
    log.info(`desktop send took ${Date.now() - started}ms${queued ? " (queued)" : ""}`);
    if (!cid) await sleep(150);
    return { ok: true, queued, composerId: cid ?? (await this.select(windowId, chat || (await this.selectedTitle(page)) || "").catch(() => undefined)) };
  }

  private async selectedTitle(page: Page) {
    return page.eval<string | undefined>(`() => document.querySelector(".agent-sidebar-cell[data-selected=true] .agent-sidebar-cell-text")?.textContent?.trim()`);
  }

  async respond(windowId: string, chat: string, approve: boolean) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const ok = await page.clickWhere(
      `(approve) => {
        const aux = document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar") || document;
        const visible = (e) => e.getBoundingClientRect().width > 0;
        const sel = approve ? "button.ui-shell-tool-call__run-btn, button.ui-shell-tool-call__allowlist-button" : "button.ui-shell-tool-call__skip-btn";
        const re = approve ? /^(Run|Accept|Accept All|Allow|Approve)\\b/ : /^(Skip|Reject|Deny|Cancel)\\b/;
        return [...aux.querySelectorAll(sel)].find(visible) || [...aux.querySelectorAll("button")].find(b => visible(b) && re.test(b.innerText.trim()) && b.closest("[data-message-kind=tool], [data-tool-call-id]"));
      }`,
      approve,
    );
    if (!ok) throw Object.assign(new Error("Nothing is waiting for approval in that chat anymore"), { status: 409 });
    return { ok: true };
  }

  /** Answer Cursor's questionnaire (AskQuestion) the way a click on the desktop would. */
  async answer(windowId: string, chat: string, answers: Array<{ index: number; option?: string; text?: string }>) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const Q = `(i) => [...document.querySelectorAll("#workbench\\\\.parts\\\\.auxiliarybar .composer-questionnaire-toolbar-question")][i]`;
    if (!(await page.eval<boolean>(`() => !!(${Q})(0)`))) throw Object.assign(new Error("That question was already answered"), { status: 409 });
    for (const a of answers) {
      if (a.option) {
        const ok = await page.clickWhere(
          `(i, label) => {
            const q = (${Q})(i);
            if (!q) return null;
            const opts = [...q.querySelectorAll(".composer-questionnaire-toolbar-option")];
            const o = opts.find(o => (o.querySelector(".composer-questionnaire-toolbar-option-label")?.innerText || "").trim() === label);
            const anySelected = opts.some(x => x.className.includes("unselected-with-selections"));
            const selected = o && anySelected && !o.className.includes("unselected-with-selections");
            return selected ? { already: true } : o;
          }`,
          a.index,
          a.option,
        );
        if (!ok) throw Object.assign(new Error(`"${a.option}" isn't an option anymore`), { status: 409 });
      } else if (a.text) {
        await page.clickWhere(`(i) => { const q = (${Q})(i); return q && (q.querySelector(".composer-questionnaire-toolbar-option-freeform") || q.querySelector("textarea")); }`, a.index);
        await sleep(150);
        const focused = await page.eval<boolean>(`(i) => { const t = (${Q})(i)?.querySelector("textarea, .composer-questionnaire-toolbar-freeform-input"); if (!t) return false; t.focus(); return true; }`, a.index);
        if (!focused) throw new Error("Couldn't find the text box for that question");
        await page.call("Input.insertText", { text: a.text });
      }
      await sleep(250);
    }
    for (let attempt = 0; attempt < answers.length + 3; attempt++) {
      await sleep(350);
      if (!(await page.eval<boolean>(`() => !!(${Q})(0)`))) return { ok: true };
      const clicked = await page.clickWhere(`() => {
        const q = (${Q})(0);
        const root = q?.closest(".has-pending-questionnaire") || document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar");
        const hits = [...root.querySelectorAll("button, [role=button], div, span")].filter((e) => {
          if (e.closest(".composer-questionnaire-toolbar-questions") || !e.getBoundingClientRect().width) return false;
          return /^(Continue|Submit|Done|Send|Answer|Confirm)\\b/i.test((e.innerText || e.getAttribute("aria-label") || "").trim());
        });
        return hits[0];
      }`);
      if (!clicked) {
        await page.eval(`() => (${Q})(0)?.querySelector(".composer-questionnaire-toolbar-option")?.focus()`);
        await page.call("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" });
        await page.call("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
      }
    }
    const still = await page.eval<boolean>(`() => !!(${Q})(0)`);
    return { ok: !still, submitted: !still };
  }

  private locks = new Map<string, Promise<unknown>>();

  /** Runs UI actions for one window one at a time, so two phone actions never interleave keystrokes. */
  locked<T>(windowId: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(windowId) || Promise.resolve();
    const next = prev.catch(() => {}).then(fn);
    this.locks.set(windowId, next.catch(() => {}));
    return next;
  }

  /** Edits a queued message in place: Cursor loads it into the chat box, we replace the text and save. */
  async editQueued(windowId: string, chat: string, id: string, text: string) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const L = `document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar .composer-toolbar-queue-item-list")`;
    const I = `[...document.querySelectorAll("#workbench\\\\.parts\\\\.auxiliarybar .aislash-editor-input")].find(e => e.getBoundingClientRect().width > 0)`;
    const item = `${L}?.querySelector('[data-queue-item-id="' + id + '"]')`;
    const key = async (k: string, code: string, vk: number, modifiers = 0) => {
      await page.call("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, windowsVirtualKeyCode: vk, modifiers });
      await page.call("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: vk, modifiers });
    };
    const original = await page.eval<string | null>(`(id) => ${item}?.dataset.queueItemQuery ?? null`, id);
    if (original === null) throw Object.assign(new Error("That message isn't queued anymore"), { status: 409 });
    if ((await page.eval<string>(`() => ${I}?.innerText || ""`)).trim()) {
      throw Object.assign(new Error("There's a draft in that chat's box on the Mac. Clear it first so it isn't lost."), { status: 409 });
    }
    const focused = () => page.eval<string | null>(`() => ${L}?.querySelector(".composer-toolbar-queue-item[data-focused=true]")?.dataset.queueItemId || null`);
    const count = await page.eval<number>(`() => ${L}?.querySelectorAll(".composer-toolbar-queue-item").length || 0`);
    await page.eval(`() => ${L}?.focus()`);
    await sleep(80);
    const firstId = () => page.eval<string | null>(`() => ${L}?.querySelector(".composer-toolbar-queue-item")?.dataset.queueItemId || null`);
    for (let i = 0; i <= count && (await focused()) !== id; i++) {
      if (!(await focused()) && (await firstId()) === id) break;
      await key("ArrowDown", "ArrowDown", 40);
      await sleep(60);
    }
    const f = await focused();
    if (f !== id && !(f === null && (await firstId()) === id)) throw new Error("Couldn't select that queued message in Cursor");
    await key("ArrowRight", "ArrowRight", 39);
    let loaded = false;
    for (let t = 0; t < 20 && !loaded; t++) {
      await sleep(100);
      loaded = await page.eval<boolean>(`(id, orig) => !!${item}?.className.includes("editing") && (${I}?.innerText || "").trim() === orig.trim()`, id, original);
    }
    if (!loaded) {
      await key("Escape", "Escape", 27);
      throw new Error("Cursor didn't open that message for editing");
    }
    await page.eval(`() => ${I}?.focus()`);
    await key("a", "KeyA", 65, 4);
    await page.call("Input.insertText", { text });
    await sleep(120);
    if ((await page.eval<string>(`() => ${I}?.innerText || ""`)).trim() !== text.trim()) {
      await key("Escape", "Escape", 27);
      throw new Error("Cursor didn't take the new text");
    }
    await key("Enter", "Enter", 13);
    for (let t = 0; t < 15; t++) {
      await sleep(120);
      const now = await page.eval<string | null>(`(id) => ${item}?.dataset.queueItemQuery ?? null`, id);
      if (now !== null && now.trim() === text.trim()) return { ok: true };
    }
    throw new Error("Cursor didn't save the edit");
  }

  /** Sends a queued message right away (Cursor steers it into the running turn, or interrupts). */
  async sendQueuedNow(windowId: string, chat: string, id: string) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const L = `document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar .composer-toolbar-queue-item-list")`;
    const has = () => page.eval<boolean>(`(id) => !!${L}?.querySelector('[data-queue-item-id="' + id + '"]')`, id);
    if (!(await has())) throw Object.assign(new Error("That message isn't queued anymore"), { status: 409 });
    const key = async (k: string, code: string, vk: number) => {
      await page.call("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, windowsVirtualKeyCode: vk });
      await page.call("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: vk });
    };
    const focused = () => page.eval<string | null>(`() => ${L}?.querySelector(".composer-toolbar-queue-item[data-focused=true]")?.dataset.queueItemId || null`);
    const count = await page.eval<number>(`() => ${L}?.querySelectorAll(".composer-toolbar-queue-item").length || 0`);
    await page.eval(`() => ${L}?.focus()`);
    await sleep(80);
    for (let i = 0; i <= count && (await focused()) !== id; i++) {
      if (!(await focused())) {
        const first = await page.eval<string | null>(`() => ${L}?.querySelector(".composer-toolbar-queue-item")?.dataset.queueItemId || null`);
        if (first === id) break;
      }
      await key("ArrowDown", "ArrowDown", 40);
      await sleep(60);
    }
    const f = await focused();
    const first = await page.eval<string | null>(`() => ${L}?.querySelector(".composer-toolbar-queue-item")?.dataset.queueItemId || null`);
    if (f !== id && !(f === null && first === id)) throw new Error("Couldn't select that queued message in Cursor");
    await key("Enter", "Enter", 13);
    for (let t = 0; t < 15; t++) {
      await sleep(150);
      if (!(await has())) return { ok: true };
    }
    throw new Error("Cursor didn't send it. Try again, or send it on the Mac.");
  }

  /**
   * Moves a queued message to position `to` by replaying the drag Cursor's queue list listens for:
   * dragstart on the message, dragover past the midpoint of the one it should follow (or above the first), drop.
   */
  async reorderQueued(windowId: string, chat: string, id: string, to: number) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const order = await page.eval<string[] | string>(
      `async (id, to) => {
        const L = document.querySelector("#workbench\\\\.parts\\\\.auxiliarybar .composer-toolbar-queue-item-list");
        const items = () => [...(L?.querySelectorAll(".composer-toolbar-queue-item[data-queue-item-id]") || [])];
        const src = items().find((e) => e.dataset.queueItemId === id);
        if (!src) return "missing";
        const rest = items().filter((e) => e !== src);
        to = Math.max(0, Math.min(rest.length, to));
        if (items().indexOf(src) === to) return items().map((e) => e.dataset.queueItemId);
        const target = to === 0 ? rest[0] : rest[to - 1];
        const r = target.getBoundingClientRect();
        const y = to === 0 ? r.top + 2 : r.bottom - 2;
        const dt = new DataTransfer();
        const fire = (el, type, clientY) => el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt, clientX: r.left + 20, clientY }));
        const s = src.getBoundingClientRect();
        fire(src, "dragstart", s.top + s.height / 2);
        await new Promise((res) => setTimeout(res, 30));
        fire(target, "dragenter", y);
        fire(target, "dragover", y);
        await new Promise((res) => setTimeout(res, 30));
        fire(target, "drop", y);
        fire(src, "dragend", y);
        await new Promise((res) => setTimeout(res, 250));
        return items().map((e) => e.dataset.queueItemId);
      }`,
      id,
      to,
    );
    if (order === "missing") throw Object.assign(new Error("That message isn't queued anymore"), { status: 409 });
    if (!Array.isArray(order) || order.indexOf(id) !== Math.min(to, order.length - 1)) throw Object.assign(new Error("Cursor didn't move that message"), { status: 409 });
    return { ok: true, order };
  }

  /** Removes a queued message by clicking its trash button (it only renders on hover). */
  async removeQueued(windowId: string, chat: string, id: string) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const ok = await page.eval<boolean>(
      `async (id) => {
        const it = document.querySelector('#workbench\\\\.parts\\\\.auxiliarybar .composer-toolbar-queue-item[data-queue-item-id="' + id + '"]');
        if (!it) return false;
        for (const t of ["pointerover", "pointerenter", "mouseover", "mouseenter", "mousemove"]) it.dispatchEvent(new (t.startsWith("pointer") ? PointerEvent : MouseEvent)(t, { bubbles: t.endsWith("over") || t === "mousemove" }));
        await new Promise((r) => setTimeout(r, 200));
        const icon = it.querySelector(".codicon-trashcan");
        const btn = icon && (icon.closest(".anysphere-icon-button, button, [role=button]") || icon.parentElement);
        if (!btn) return false;
        const o = { bubbles: true, cancelable: true, view: window, button: 0 };
        for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) btn.dispatchEvent(new (t.startsWith("pointer") ? PointerEvent : MouseEvent)(t, o));
        await new Promise((r) => setTimeout(r, 300));
        return !document.querySelector('#workbench\\\\.parts\\\\.auxiliarybar .composer-toolbar-queue-item[data-queue-item-id="' + id + '"]');
      }`,
      id,
    );
    if (!ok) throw Object.assign(new Error("Couldn't remove that queued message"), { status: 409 });
    return { ok: true };
  }

  async stopChat(windowId: string, chat: string) {
    const page = this.page(windowId);
    await this.select(windowId, chat);
    const click = () =>
      page.clickWhere(`() => {
      const s = [...document.querySelectorAll("#workbench\\\\.parts\\\\.auxiliarybar .composer-button-area .codicon-debug-stop")].find(e => e.getBoundingClientRect().width > 0);
      return s?.closest("button, .anysphere-icon-button") || s;
    }`);
    // Cursor's window can stall for a moment while it streams; one retry covers it.
    const ok = await click().catch(async (e) => {
      log.warn(`stop click: ${e.message}; retrying`);
      return click();
    });
    this.nudge();
    if (!ok) return { ok: true, idle: true };
    return { ok: true };
  }
}

// ---- transcripts -------------------------------------------------------------------------

const fileIndex = new Map<string, string>();

export function transcriptPath(composerId: string): string | undefined {
  const cached = fileIndex.get(composerId);
  if (cached && fs.existsSync(cached)) return cached;
  for (const proj of fs.readdirSync(PROJECTS)) {
    const p = path.join(PROJECTS, proj, "agent-transcripts", composerId, `${composerId}.jsonl`);
    if (fs.existsSync(p)) {
      fileIndex.set(composerId, p);
      return p;
    }
    const flat = path.join(PROJECTS, proj, "agent-transcripts", `${composerId}.jsonl`);
    if (fs.existsSync(flat)) {
      fileIndex.set(composerId, flat);
      return flat;
    }
  }
}

const TOOL_NAMES: Record<string, string> = {
  Shell: "shell",
  Read: "read",
  StrReplace: "edit",
  Write: "write",
  Grep: "grep",
  Glob: "glob",
  Delete: "delete",
  WebSearch: "web_search",
  WebFetch: "fetch",
  TodoWrite: "todo",
  AskQuestion: "ask_user",
  Task: "task",
};

function toolItem(id: string, ts: number, u: any): Item {
  if (u.name === "CallDynamicTool" && u.input?.namespace === "cursor" && typeof u.input.toolName === "string") {
    u = { ...u, name: u.input.toolName, input: u.input.arguments || {} };
  }
  const mcp = fromTranscript(u.name, u.input || {});
  if (mcp) return { id, ts, kind: "tool", tool: { name: mcp.name, status: "completed", args: mcp.args, callId: typeof u.id === "string" ? u.id : undefined } };
  const input = u.input || {};
  const name = TOOL_NAMES[u.name] || u.name;
  const meta: Record<string, unknown> = {};
  if (u.name === "StrReplace" && typeof input.old_string === "string" && typeof input.new_string === "string") {
    // Only the replaced snippet is known here, so hunk line numbers would be wrong; keep the separators.
    const d = lineDiff(input.old_string, input.new_string, 2);
    meta.removed = d.removed;
    meta.added = d.added;
    meta.diff = d.diff.replace(/^@@ .* @@$/gm, "@@");
  } else if (u.name === "Write" && typeof input.contents === "string") {
    meta.added = input.contents.split("\n").length;
    meta.lines = meta.added;
  }
  const args: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (k === "contents" || k === "old_string" || k === "new_string") continue;
    args[k === "working_directory" ? "workingDirectory" : k] = typeof v === "string" && v.length > 600 ? v.slice(0, 600) + "…" : v;
  }
  return { id, ts, kind: "tool", tool: { name, status: "completed", args, callId: typeof u.id === "string" ? u.id : undefined, meta: Object.keys(meta).length ? meta : undefined } };
}

function userText(raw: string): string | undefined {
  return userParts(raw).text;
}

/** Cursor's follow-up prompts it sends on its own when a background job or subagent finishes. */
const AUTO_PROMPT = /^(Briefly inform the user about the task result|Perform any necessary follow-up actions)/;

/**
 * What a user-role message really holds: what the person typed, plus one line per notice Cursor
 * folded into it (background jobs and subagents finishing). Context blocks are dropped.
 */
export function userParts(raw: string): { text?: string; notices: string[] } {
  const notices: string[] = [];
  for (const m of raw.matchAll(/<system_notification>([\s\S]*?)<\/system_notification>/g)) {
    for (const t of m[1].matchAll(/<task>([\s\S]*?)<\/task>/g)) {
      const field = (k: string) => t[1].match(new RegExp(`^\\s*${k}:\\s*(.+)$`, "m"))?.[1].trim();
      const kind = field("kind") === "subagent" ? "Subagent" : "Background command";
      const status = field("status");
      const verb = status === "success" ? "finished" : status === "aborted" ? "stopped" : status === "error" || status === "failed" ? "failed" : status || "finished";
      const title = field("title");
      notices.push(`${kind} ${verb}${title ? ` · ${title}` : ""}`);
    }
  }
  const parts: string[] = [];
  const q = raw.match(/<user_query>\s*([\s\S]*?)\s*<\/user_query>/);
  if (q && !AUTO_PROMPT.test(q[1].trim())) parts.push(q[1].trim());
  else if (q && !notices.length) notices.push("Background task finished");
  const outside = raw
    .replace(/<user_query>[\s\S]*?<\/user_query>/g, "")
    .replace(/<([a-z_]+)(?:\s[^>]*)?>[\s\S]*?<\/\1>/g, "")
    .replace(/^\s*timestamp>[^\n]*$/gm, "")
    .trim();
  if (outside && !outside.startsWith("<") && !AUTO_PROMPT.test(outside)) parts.push(outside);
  const text = parts.join("\n\n").trim();
  return { text: text || undefined, notices };
}

const parsed = new Map<string, { mtime: number; size: number; items: Item[] }>();

export function desktopTranscript(composerId: string): { items: Item[]; updatedAt: number } | undefined {
  const file = transcriptPath(composerId);
  if (!file) return undefined;
  const st = fs.statSync(file);
  const hit = parsed.get(file);
  if (hit && hit.mtime === st.mtimeMs && hit.size === st.size) return { items: hit.items, updatedAt: st.mtimeMs };
  const items: Item[] = [];
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const base = st.birthtimeMs || st.mtimeMs - lines.length * 1000;
  lines.forEach((line, i) => {
    if (!line.trim()) return;
    let o: any;
    try {
      o = JSON.parse(line);
    } catch {
      return;
    }
    const ts = Math.round(base + i * 1000);
    const content = o.message?.content;
    if (!Array.isArray(content)) {
      if (o.error || o.type === "error") items.push({ id: `${i}`, ts, kind: "error", text: String(o.error?.message || o.error || "Error") });
      return;
    }
    const hasTool = content.some((c: any) => c.type === "tool_use");
    content.forEach((c: any, j: number) => {
      const id = `${i}.${j}`;
      if (c.type === "text" && typeof c.text === "string") {
        if (o.role === "user") {
          const u = userParts(c.text);
          u.notices.forEach((n, k) => items.push({ id: `${id}.n${k}`, ts, kind: "system", text: n }));
          if (u.text) items.push({ id, ts, kind: "user", text: u.text });
        } else if (c.text.trim()) {
          items.push({ id, ts, kind: "assistant", text: c.text.trim() });
        }
      } else if (c.type === "tool_use") {
        items.push(toolItem(id, ts, c));
      }
    });
  });
  const merged = withThoughts(composerId, items);
  parsed.set(file, { mtime: st.mtimeMs, size: st.size, items: merged });
  return { items: merged, updatedAt: st.mtimeMs };
}

const CURSOR_DB = path.join(HOME, "Library/Application Support/Cursor/User/globalStorage/state.vscdb");
let db: any;

type Thought = import("./thoughts-worker.ts").Thought;

const thoughtCache = new Map<string, { thoughts: Thought[]; at: number; took: number }>();
const thoughtsPending = new Map<string, number>();
let thoughtWorker: Worker | undefined;

function worker(): Worker {
  if (thoughtWorker) return thoughtWorker;
  const w = new Worker(new URL("./thoughts-worker.ts", import.meta.url), { workerData: { dbPath: CURSOR_DB } });
  w.unref();
  w.on("message", (m: { composerId: string; thoughts?: Thought[]; error?: string }) => {
    const began = thoughtsPending.get(m.composerId) ?? Date.now();
    thoughtsPending.delete(m.composerId);
    if (m.error) return log.warn(`cursor thoughts: ${m.error}`);
    const prev = thoughtCache.get(m.composerId);
    const next = m.thoughts || [];
    thoughtCache.set(m.composerId, { thoughts: next, at: Date.now(), took: Date.now() - began });
    const changed = !prev || prev.thoughts.length !== next.length || prev.thoughts.at(-1)?.text !== next.at(-1)?.text;
    if (changed) {
      const file = transcriptPath(m.composerId);
      if (file) parsed.delete(file);
    }
  });
  w.on("error", (e) => {
    log.warn(`thoughts worker: ${e.message}`);
    thoughtWorker = undefined;
    thoughtsPending.clear();
  });
  return (thoughtWorker = w);
}

/** Cursor keeps reasoning only in its own database, not in the transcript file. Answers from cache; a worker refreshes it. */
function thoughts(composerId: string): Thought[] {
  if (!composerId) return [];
  const hit = thoughtCache.get(composerId);
  const stale = !hit || Date.now() - hit.at > Math.max(3000, hit.took * 4);
  if (stale && !thoughtsPending.has(composerId)) {
    thoughtsPending.set(composerId, Date.now());
    worker().postMessage(composerId);
  }
  return hit?.thoughts || [];
}

/**
 * The tool call a desktop chat is running this second. Cursor records it in its database the
 * moment it starts; the transcript file only catches up later.
 */
export function desktopLiveTool(composerId: string): { id: string; name: string; args: Record<string, any>; startedAt: number } | undefined {
  // An empty id would turn the key range into every bubble Cursor has ever stored.
  if (!composerId) return undefined;
  try {
    const r: any = cursorDb()
      .prepare(
        `SELECT json_extract(value,'$.createdAt') at, json_extract(value,'$.toolFormerData.name') name, json_extract(value,'$.toolFormerData.status') status,
                json_extract(value,'$.toolFormerData.toolCallId') id, json_extract(value,'$.toolFormerData.params') params,
                json_extract(value,'$.toolFormerData.rawArgs') raw, json_extract(value,'$.toolFormerData.additionalData.startedAtMs') started
         FROM cursorDiskKV WHERE rowid = (SELECT rowid FROM cursorDiskKV WHERE key >= ? AND key < ? ORDER BY rowid DESC LIMIT 1)`,
      )
      .get(`bubbleId:${composerId}:`, `bubbleId:${composerId};`);
    if (!r || r.status !== "loading" || !r.name) return undefined;
    const parse = (v: unknown) => {
      if (typeof v !== "string" || !v) return {};
      try {
        return JSON.parse(v);
      } catch {
        return {};
      }
    };
    return { id: String(r.id || r.at), name: r.name, args: { ...parse(r.raw), ...parse(r.params) }, startedAt: Number(r.started) || Date.parse(r.at) || Date.now() };
  } catch (e: any) {
    log.warn(`cursor live tool: ${e.message}`);
    return undefined;
  }
}

/**
 * Rowids of a chat's newest user bubbles, looked for among its newest top-level keys (no `/s:` or `/t:`
 * suffix; older chats keep assistant bubbles there too). Rowid order follows
 * write order, and unlike `json_extract(createdAt)` it doesn't parse every bubble; some chats have
 * hundreds of thousands. Params: range low, range high, prefix length + 1.
 */
export const LAST_USER_ROWIDS = (n: number) =>
  `SELECT rowid FROM cursorDiskKV WHERE rowid IN (
     SELECT rowid FROM cursorDiskKV WHERE key >= ? AND key < ? AND instr(substr(key, ?), '/') = 0 ORDER BY rowid DESC LIMIT 200
   ) AND json_extract(value,'$.type') = 1 ORDER BY rowid DESC LIMIT ${n}`;

/** Absolute paths of files a Cursor chat read, wrote or edited, oldest first. */
export function chatFiles(composerId: string): string[] {
  const out: string[] = [];
  try {
    const row = cursorDb()
      .prepare(`SELECT json_extract(value,'$.originalFileStates') f FROM cursorDiskKV WHERE key = ?`)
      .get(`composerData:${composerId}`) as { f?: string } | undefined;
    for (const k of Object.keys(row?.f ? JSON.parse(row.f) : {})) if (k.startsWith("file://")) out.push(decodeURIComponent(k.slice(7)));
  } catch {}
  for (const it of desktopTranscript(composerId)?.items || []) {
    const a: any = it.tool?.args;
    const p = a?.path ?? a?.file_path ?? a?.target_file;
    if (typeof p === "string" && p.startsWith("/")) out.push(p);
  }
  return out;
}

export function cursorDb() {
  if (!db) {
    const { DatabaseSync } = process.getBuiltinModule("node:sqlite") as any;
    const raw = new DatabaseSync(CURSOR_DB, { readOnly: true });
    // Queries here are synchronous and block the whole hub; flag any that get slow.
    db = {
      prepare(sql: string) {
        const st = raw.prepare(sql);
        const timed = (fn: "get" | "all") => (...args: unknown[]) => {
          const t = performance.now();
          const r = st[fn](...args);
          const ms = performance.now() - t;
          if (ms > 300) log.warn(`slow cursor db ${fn} ${Math.round(ms)}ms: ${sql.replace(/\s+/g, " ").slice(0, 140)} ${JSON.stringify(args).slice(0, 160)}`);
          return r;
        };
        return { get: timed("get"), all: timed("all") };
      },
    };
  }
  return db;
}

/** Messages waiting in a desktop chat's queue (sent while the agent was busy). */
export function desktopQueue(composerId: string): Array<{ id: string; text: string }> {
  try {
    const row = cursorDb()
      .prepare(`SELECT json_extract(value,'$.queueItems') q FROM cursorDiskKV WHERE key = ?`)
      .get(`composerData:${composerId}`) as { q?: string } | undefined;
    const items = row?.q ? JSON.parse(row.q) : [];
    return Array.isArray(items) ? items.filter((i: any) => i?.id).map((i: any) => ({ id: String(i.id), text: String(i.query || "").trim() })) : [];
  } catch (e: any) {
    log.warn(`cursor queue: ${e.message}`);
    return [];
  }
}

export interface Subagent {
  id: string;
  name: string;
  type?: string;
  status: "running" | "done" | "stopped" | "failed";
  activity?: string;
  startedAt?: number;
  updatedAt?: number;
  brief?: string;
  steps?: number;
  result?: string;
}

function subagentRow(id: string, parent?: string): Subagent | undefined {
  const r = cursorDb()
    .prepare(
      `SELECT json_extract(value,'$.name') name, json_extract(value,'$.status') status, json_extract(value,'$.subtitle') subtitle,
              json_extract(value,'$.subagentInfo.subagentTypeName') type, json_extract(value,'$.subagentInfo.parentComposerId') parent,
              json_extract(value,'$.createdAt') created, json_extract(value,'$.lastUpdatedAt') updated,
              json_extract(value,'$.unfinishedRunAt') unfinished
       FROM cursorDiskKV WHERE key = ?`,
    )
    .get(`composerData:${id}`) as any;
  if (!r) return undefined;
  const p = parent || r.parent;
  if (p && !fileIndex.has(id)) {
    for (const proj of fs.readdirSync(PROJECTS)) {
      const f = path.join(PROJECTS, proj, "agent-transcripts", p, "subagents", `${id}.jsonl`);
      if (fs.existsSync(f)) {
        fileIndex.set(id, f);
        break;
      }
    }
  }
  // Cursor flags a live run with unfinishedRunAt; "status" lags and reads "aborted" mid-run.
  const s = String(r.status || "");
  const file = fileIndex.get(id);
  const fresh = file ? Date.now() - fs.statSync(file).mtimeMs < 15 * 60_000 : true;
  const status: Subagent["status"] =
    r.unfinished && fresh ? "running" : s === "aborted" ? "stopped" : s === "error" ? "failed" : "done";
  const type = r.type ? String(r.type).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase() : undefined;
  return {
    id,
    name: String(r.name || "Subagent"),
    type,
    status,
    activity: r.subtitle ? String(r.subtitle) : undefined,
    startedAt: Number(r.created) || undefined,
    updatedAt: file ? Math.round(fs.statSync(file).mtimeMs) : Number(r.updated) || Number(r.created) || undefined,
  };
}

function withSummary(s: Subagent): Subagent {
  const items = desktopTranscript(s.id)?.items || [];
  const brief = items.find((i) => i.kind === "user")?.text;
  const last = [...items].reverse().find((i) => i.kind === "assistant")?.text;
  return {
    ...s,
    brief: brief ? brief.replace(/\s+/g, " ").trim().slice(0, 240) : undefined,
    steps: items.filter((i) => i.kind === "tool").length,
    result: s.status === "running" || !last ? undefined : last.replace(/[#*`>|]+|^\s*[-•]\s+/gm, " ").replace(/\s+/g, " ").trim().slice(0, 240),
  };
}

/** Subagents a desktop chat spawned through its Task tool, oldest first. */
export function desktopSubagents(composerId: string): Subagent[] {
  try {
    const row = cursorDb()
      .prepare(`SELECT json_extract(value,'$.subagentComposerIds') ids FROM cursorDiskKV WHERE key = ?`)
      .get(`composerData:${composerId}`) as { ids?: string } | undefined;
    const ids: string[] = row?.ids ? JSON.parse(row.ids) : [];
    return ids
      .map((id) => subagentRow(String(id), composerId))
      .filter((s): s is Subagent => !!s)
      .map(withSummary)
      .sort((a, b) => (a.startedAt || 0) - (b.startedAt || 0));
  } catch (e: any) {
    log.warn(`cursor subagents: ${e.message}`);
    return [];
  }
}

export function desktopSubagent(id: string): (Subagent & { items: Item[] }) | undefined {
  try {
    const info = subagentRow(id);
    if (!info) return undefined;
    return { ...info, items: desktopTranscript(id)?.items || [] };
  } catch (e: any) {
    log.warn(`cursor subagent: ${e.message}`);
    return undefined;
  }
}

const promptKey = (t: string) => t.replace(/\s+/g, " ").trim().slice(0, 160);
const prompts = new Map<string, string>();

function subagentPrompt(id: string): string | undefined {
  if (prompts.has(id)) return prompts.get(id);
  const file = fileIndex.get(id);
  if (!file) return undefined;
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(262144);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    const first = JSON.parse(buf.subarray(0, n).toString("utf8").split("\n")[0]);
    const text = first?.message?.content?.find((c: any) => c.type === "text")?.text;
    const q = typeof text === "string" ? userText(text) : undefined;
    if (!q) return undefined;
    const key = promptKey(q);
    prompts.set(id, key);
    return key;
  } catch {
    return undefined;
  } finally {
    fs.closeSync(fd);
  }
}

/** Points each Task tool call at the subagent it spawned, matched by the prompt it was given. */
export function linkSubagents(items: Item[], subs: Subagent[]): void {
  const byPrompt = new Map<string, Subagent>();
  for (const s of subs) {
    const k = subagentPrompt(s.id);
    if (k) byPrompt.set(k, s);
  }
  for (const it of items) {
    if (it.kind !== "tool" || it.tool?.name !== "task") continue;
    const { prompt: p, resume } = it.tool.args || {};
    const s =
      (typeof resume === "string" ? subs.find((x) => x.id === resume) : undefined) ||
      (typeof p === "string" ? byPrompt.get(promptKey(p.replace(/…$/, ""))) : undefined);
    if (s) it.tool.meta = { ...(it.tool.meta || {}), subagentId: s.id, subagentStatus: s.status };
  }
}

/** Inline cards for this turn's subagents whose Task call isn't in the transcript file. */
export function orphanSubagents(composerId: string, items: Item[], subs: Subagent[]): Item[] {
  const linked = new Set(items.map((i) => i.tool?.meta?.subagentId).filter(Boolean));
  const rest = subs.filter((s) => !linked.has(s.id));
  if (!rest.length || !composerId) return [];
  let since = 0;
  try {
    const r = cursorDb()
      .prepare(`SELECT json_extract(value,'$.createdAt') at FROM cursorDiskKV WHERE rowid = (${LAST_USER_ROWIDS(1)})`)
      .get(`bubbleId:${composerId}:`, `bubbleId:${composerId};`, `bubbleId:${composerId}:`.length + 1) as { at?: string | number } | undefined;
    since = typeof r?.at === "number" ? r.at : Date.parse(String(r?.at || "")) || 0;
  } catch {}
  const last = items.at(-1)?.ts || Date.now();
  return rest
    .filter((s) => s.status === "running" || (s.startedAt || 0) >= since)
    .map((s, i) => ({
      id: `sub-${s.id}`,
      ts: last + i + 1,
      kind: "tool" as const,
      tool: { name: "task", status: s.status === "running" ? "running" : "completed", args: { description: s.name }, meta: { subagentId: s.id } },
    }));
}

function hash(s: string) {
  let h = 5381;
  for (let i = 0; i < Math.min(s.length, 400); i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

const fingerprint = (t: string) => t.trimStart().slice(0, 400).replace(/\s+/g, " ").trim().slice(0, 40);

function withThoughts(composerId: string, items: Item[]): Item[] {
  const all = thoughts(composerId);
  if (!all.length) return items;
  const out: Item[] = [];
  const seen = new Map<string, number>();
  const used = new Set<Thought>();
  const push = <K>(m: Map<K, Thought[]>, k: K, t: Thought) => (m.get(k) || m.set(k, []).get(k)!).push(t);
  const byTool = new Map<number, Thought[]>();
  const byText = new Map<string, Thought[]>();
  const byFp = new Map<string, Thought[]>();
  const shortText: Thought[] = [];
  const loose: Thought[] = [];
  for (const t of all) {
    push(byFp, fingerprint(t.text), t);
    if (t.beforeTool !== undefined) push(byTool, t.beforeTool, t);
    else if (t.beforeText !== undefined) t.beforeText.length < 40 ? shortText.push(t) : push(byText, t.beforeText, t);
    else loose.push(t);
  }
  const emit = (list: Thought[] | undefined, ts: number) => {
    for (const t of list || []) {
      if (used.has(t)) continue;
      used.add(t);
      // Keyed by content: positions shift whenever the thinking list refreshes.
      const base = `th-${hash(t.text)}`;
      const n = (seen.get(base) || 0) + 1;
      seen.set(base, n);
      out.push({ id: n > 1 ? `${base}-${n}` : base, ts, kind: "thinking", text: t.text, durationMs: t.durationMs });
    }
  };
  let tools = 0;
  for (const it of items) {
    if (it.kind === "tool") {
      emit(byTool.get(tools++), it.ts);
    } else if (it.kind === "assistant" && it.text) {
      const f = fingerprint(it.text);
      const twins = byFp.get(f);
      const same = twins?.find((t) => !used.has(t));
      if (!same && twins?.length) continue;
      if (same) {
        used.add(same);
        out.push({ ...it, kind: "thinking", text: same.text, durationMs: same.durationMs });
        continue;
      }
      const near = f.length < 40 ? [...byText.entries()].filter(([k]) => k.startsWith(f)).flatMap(([, v]) => v) : byText.get(f);
      emit([...(near || []), ...shortText.filter((t) => f.startsWith(t.beforeText!) || t.beforeText!.startsWith(f))], it.ts);
    }
    out.push(it);
  }
  emit(loose, items.at(-1)?.ts ?? Date.now());
  return out;
}
