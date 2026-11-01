import fs from "node:fs";
import path from "node:path";
import { LOG_DIR } from "./config.ts";

const file = fs.createWriteStream(path.join(LOG_DIR, "hub.log"), { flags: "a" });
const debugOn = !!process.env.HELM_DEBUG;

function write(level: string, msg: string) {
  const line = `${new Date().toISOString()} ${level.padEnd(5)} ${msg}`;
  file.write(line + "\n");
  if (level !== "debug" || debugOn) (level === "error" ? process.stderr : process.stdout).write(line + "\n");
}

export const log = {
  debug: (m: string) => (debugOn ? write("debug", m) : file.write(`${new Date().toISOString()} debug ${m}\n`)),
  info: (m: string) => write("info", m),
  warn: (m: string) => write("warn", m),
  error: (m: string) => write("error", m),
};
