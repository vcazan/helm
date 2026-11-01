import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import readline from "node:readline";
import { log } from "./log.ts";

const MARK = "\u001eHELM ";

export interface RunnerSpec {
  key: string;
  label: string;
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  prepare?: () => Promise<void>;
}

export class RunnerConnection extends EventEmitter {
  spec: RunnerSpec;
  proc?: ChildProcessWithoutNullStreams;
  ready = false;
  private starting?: Promise<void>;
  private replies = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  private registered = new Map<string, any>();
  private initMsg: () => any;
  private stopped = false;
  private failures = 0;

  constructor(spec: RunnerSpec, initMsg: () => any) {
    super();
    this.spec = spec;
    this.initMsg = initMsg;
  }

  start(): Promise<void> {
    if (this.ready) return Promise.resolve();
    if (this.starting) return this.starting;
    this.stopped = false;
    this.starting = this.launch().finally(() => (this.starting = undefined));
    return this.starting;
  }

  private async launch() {
    if (this.spec.prepare) await this.spec.prepare();
    log.info(`runner ${this.spec.label}: launching`);
    const proc = spawn(this.spec.command, this.spec.args, {
      cwd: this.spec.cwd,
      env: { ...process.env, ...this.spec.env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc = proc;
    const readyP = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.spec.label} runner did not start within 120s`)), 120_000);
      this.once("ready", () => {
        clearTimeout(timer);
        resolve();
      });
      proc.once("exit", (code) => {
        clearTimeout(timer);
        reject(new Error(`${this.spec.label} runner exited during startup (code ${code})`));
      });
    });
    readline.createInterface({ input: proc.stdout }).on("line", (line) => {
      const i = line.indexOf(MARK);
      if (i < 0) return;
      let msg: any;
      try {
        msg = JSON.parse(line.slice(i + MARK.length));
      } catch {
        return;
      }
      this.onMessage(msg);
    });
    readline.createInterface({ input: proc.stderr }).on("line", (line) => {
      if (line.trim()) log.debug(`runner ${this.spec.label} stderr: ${line}`);
    });
    proc.on("exit", (code, sig) => {
      if (this.proc !== proc) return;
      this.ready = false;
      this.proc = undefined;
      for (const r of this.replies.values()) r.reject(new Error("runner exited"));
      this.replies.clear();
      log.warn(`runner ${this.spec.label}: exited code=${code} sig=${sig}`);
      this.emit("exit");
      if (!this.stopped && this.registered.size > 0) {
        this.failures++;
        const delay = Math.min(30_000, 1000 * 2 ** this.failures);
        setTimeout(() => !this.stopped && this.start().catch((e) => log.error(`runner ${this.spec.label} restart: ${e.message}`)), delay);
      }
    });
    this.write(this.initMsg());
    await readyP;
    this.failures = 0;
    for (const [id, opts] of this.registered) this.write({ t: "register", id, opts });
  }

  private onMessage(msg: any) {
    if (msg.t === "ready") {
      this.ready = true;
      log.info(`runner ${this.spec.label}: ready (${msg.platform} node ${msg.node})`);
      this.emit("ready");
      return;
    }
    if (msg.t === "reply" || msg.t === "pong") {
      const r = this.replies.get(msg.rid);
      this.replies.delete(msg.rid);
      if (!r) return;
      if (msg.t === "pong" || msg.ok) r.resolve(msg.data);
      else r.reject(new Error(msg.error));
      return;
    }
    if (msg.t === "log") {
      (log as any)[msg.level === "error" ? "error" : "warn"](`runner ${this.spec.label}: ${msg.msg}`);
      return;
    }
    if (msg.t === "sdk_agent") {
      const opts = this.registered.get(msg.id);
      if (opts) opts.sdkAgentId = msg.sdkAgentId;
    }
    this.emit("message", msg);
  }

  write(msg: any) {
    if (!this.proc) throw new Error(`${this.spec.label} runner is not running`);
    this.proc.stdin.write(JSON.stringify(msg) + "\n");
  }

  async request(msg: any, timeoutMs = 60_000): Promise<any> {
    await this.start();
    const rid = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.replies.delete(rid);
        reject(new Error("runner request timed out"));
      }, timeoutMs);
      this.replies.set(rid, {
        resolve: (v) => (clearTimeout(timer), resolve(v)),
        reject: (e) => (clearTimeout(timer), reject(e)),
      });
      this.write({ ...msg, rid });
    });
  }

  async register(id: string, opts: any) {
    this.registered.set(id, { ...opts });
    await this.start();
    this.write({ t: "register", id, opts });
  }

  unregister(id: string) {
    this.registered.delete(id);
    if (this.ready) this.write({ t: "unregister", id });
  }

  async send(msg: any) {
    await this.start();
    this.write(msg);
  }

  stop() {
    this.stopped = true;
    this.proc?.kill();
  }
}
