import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { DATA_DIR, HOME } from "./config.ts";
import type { Item } from "./store.ts";

const pexec = promisify(execFile);

/**
 * Images agents make or look at (screenshots, generated art, MCP results), found in their tool calls
 * and served to the phone, scaled down so a 6K screenshot doesn't cross Tailscale at full size.
 */

const IMAGE_EXT = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".tiff", ".bmp"]);
const MIME: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".heic": "image/heic", ".tiff": "image/tiff", ".bmp": "image/bmp" };
const PRIVATE_DIRS = [".ssh", ".helm", ".aws", ".gnupg", ".kube", ".docker"];
const TEMP_ROOTS = ["/private/tmp", "/private/var/folders"];
export const IMAGE_DIR = path.join(DATA_DIR, "images");
const THUMB_DIR = path.join(DATA_DIR, "cache", "thumbs");

export const isImagePath = (p: string) => IMAGE_EXT.has(path.extname(p).toLowerCase());

/** Resolves an image path the phone asked for, or throws if it's outside what Helm will serve. */
function allowedImage(p: string, root?: string): string {
  const expanded = p.replace(/^file:\/\//, "").replace(/^~(?=$|\/)/, HOME);
  const abs = fs.realpathSync(path.resolve(root ? root.replace(/^~(?=$|\/)/, HOME) : HOME, expanded));
  if (!isImagePath(abs)) throw Object.assign(new Error("Not an image"), { status: 415 });
  if (abs.startsWith(IMAGE_DIR + path.sep)) return abs;
  const rel = path.relative(HOME, abs);
  const inHome = !rel.startsWith("..") && !path.isAbsolute(rel);
  if (inHome && !PRIVATE_DIRS.includes(rel.split(path.sep)[0])) return abs;
  if (TEMP_ROOTS.some((r) => abs.startsWith(r + path.sep))) return abs;
  throw Object.assign(new Error("That image isn't somewhere Helm can show"), { status: 403 });
}

/** The image's bytes, scaled to fit `width` points' worth of pixels when asked. */
export async function imageFile(p: string, root?: string, width?: number): Promise<{ file: string; mime: string }> {
  const abs = allowedImage(p, root);
  const st = fs.statSync(abs);
  const ext = path.extname(abs).toLowerCase();
  if (!width || ext === ".gif") return { file: abs, mime: MIME[ext] || "application/octet-stream" };
  const px = Math.min(2400, Math.max(64, Math.round(width)));
  const key = crypto.createHash("sha1").update(`${abs}|${st.mtimeMs}|${st.size}|${px}`).digest("hex");
  const out = path.join(THUMB_DIR, `${key}.jpg`);
  if (!fs.existsSync(out)) {
    fs.mkdirSync(THUMB_DIR, { recursive: true, mode: 0o700 });
    await pexec("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "82", "-Z", String(px), abs, "--out", out], { timeout: 20_000 });
  }
  return { file: out, mime: "image/jpeg" };
}

/** Images in MCP results (`{type: "image", data, mimeType}`), saved so the phone can load them by path. */
export function saveResultImages(result: unknown): string[] {
  let r: any = result;
  for (let i = 0; i < 3 && typeof r === "string"; i++) {
    try {
      r = JSON.parse(r);
    } catch {
      return [];
    }
  }
  const content = r?.content ?? r?.result?.content ?? r?.value?.content;
  if (!Array.isArray(content)) return [];
  const out: string[] = [];
  for (const c of content) {
    if (c?.type !== "image" || typeof c.data !== "string") continue;
    const ext = String(c.mimeType || "image/png").includes("jpeg") ? ".jpg" : String(c.mimeType || "").includes("webp") ? ".webp" : ".png";
    const file = path.join(IMAGE_DIR, crypto.createHash("sha1").update(c.data).digest("hex") + ext);
    if (!fs.existsSync(file)) {
      fs.mkdirSync(IMAGE_DIR, { recursive: true, mode: 0o700 });
      fs.writeFileSync(file, Buffer.from(c.data, "base64"), { mode: 0o600 });
    }
    out.push(file);
  }
  return out;
}

const PATH_RE = /(?:^|[\s"'=(:,\[])((?:~|\/)[^\s"'()<>|;&,\]]+\.(?:png|jpe?g|gif|webp|heic|tiff|bmp))(?=$|[\s"'()<>|;&,\]])/gi;
const REL_RE = /(?:^|[\s"'=])((?:\.{0,2}\/)?[\w.-]+(?:\/[\w.-]+)*\.(?:png|jpe?g|gif|webp))(?=$|[\s"'])/gi;
const exists = new Map<string, { ok: boolean; at: number }>();

function fileExists(p: string) {
  const hit = exists.get(p);
  // A screenshot command may still be writing its file; don't remember "missing" for long.
  if (hit && Date.now() - hit.at < (hit.ok ? 60_000 : 4_000)) return hit.ok;
  let ok = false;
  try {
    ok = fs.statSync(p.replace(/^~(?=$|\/)/, HOME)).isFile();
  } catch {}
  exists.set(p, { ok, at: Date.now() });
  if (exists.size > 5000) exists.delete(exists.keys().next().value!);
  return ok;
}

/** Image files a tool call read, wrote or produced (a screenshot command's output, say) that are on disk. */
export function toolImages(t: NonNullable<Item["tool"]>): string[] {
  const a: any = t.args || {};
  const found: string[] = [];
  const add = (p: string) => {
    if (!found.includes(p) && !p.startsWith(THUMB_DIR) && fileExists(p)) found.push(p);
  };
  for (const k of ["path", "file_path", "target_file", "filePath"]) if (typeof a[k] === "string" && isImagePath(a[k]) && path.isAbsolute(a[k].replace(/^~/, "/"))) add(a[k]);
  const name = t.name.toLowerCase();
  if (name === "shell" || name === "generateimage" || name === "mcp") {
    const cwd = typeof a.workingDirectory === "string" ? a.workingDirectory : typeof a.working_directory === "string" ? a.working_directory : undefined;
    const text = [a.command, typeof t.meta?.output === "string" ? t.meta.output : "", typeof t.result === "string" ? t.result : ""].filter(Boolean).join("\n");
    for (const m of text.matchAll(PATH_RE)) add(m[1]);
    if (cwd && typeof a.command === "string") for (const m of a.command.matchAll(REL_RE)) if (!m[1].startsWith("/")) add(path.resolve(cwd, m[1]));
  }
  for (const p of (t.meta?.images as string[] | undefined) || []) add(p);
  return found.slice(0, 12);
}

/** Tags tool items with the images they touched, so the phone can show them. */
export function withImages(items: Item[]): Item[] {
  return items.map((it) => {
    if (it.kind !== "tool" || !it.tool) return it;
    const imgs = toolImages(it.tool);
    if (!imgs.length) return it;
    return { ...it, tool: { ...it.tool, meta: { ...(it.tool.meta || {}), images: imgs } } };
  });
}
