import type { Item } from "./store.ts";

/**
 * MCP calls reach Helm in four shapes: Cursor's transcript (`CallMcpTool`, `CallDynamicTool`), its
 * database (`mcp-<server>-<tool>`), and the SDK (`mcp`). They all become one tool item:
 * `{ name: "mcp", args: { server, tool, description?, arguments? } }`, so the phone shows them the same way.
 */

/** Helm's own tools (ask_user, notify_user, ...) arrive as MCP calls to this server. */
export const HELM_SERVER = "custom-user-tools";

export interface McpTool {
  name: string;
  args: Record<string, unknown>;
}

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);

export function mcpTool(server: unknown, tool: unknown, args: unknown, description?: unknown): McpTool {
  return {
    name: "mcp",
    args: {
      server: str(server) ?? "",
      tool: str(tool) ?? "tool",
      description: str(description),
      arguments: args && typeof args === "object" && Object.keys(args).length ? args : undefined,
    },
  };
}

/** Looking up which tools a server has, before calling one. */
export function mcpDiscover(server: unknown, tool?: unknown, pattern?: unknown): McpTool {
  return { name: "mcp_discover", args: { server: str(server) ?? "", tool: str(tool), pattern: str(pattern) } };
}

/** Cursor's transcript tool calls. Returns undefined for anything that isn't MCP. */
export function fromTranscript(name: string, input: any): McpTool | undefined {
  if (name === "CallMcpTool") return mcpTool(input.server, input.toolName, input.arguments, input.description);
  if (name === "CallDynamicTool" && input.namespace !== "cursor") {
    return mcpTool(input.namespace, input.toolName, input.arguments, input.mcpDetails?.description ?? input.description);
  }
  if (name === "GetDynamicTools" || name === "GetMcpTools") return mcpDiscover(input.namespace ?? input.server, input.toolName, input.pattern);
  if (name === "FetchMcpResource") return { name: "mcp_resource", args: { server: str(input.server) ?? "", uri: str(input.uri) } };
  return undefined;
}

/** Cursor's database rows: `name` is `mcp-<provider>-<tool>`; rawArgs has the full server id. */
export function fromDatabase(name: string, raw: any): McpTool {
  // While a call runs, Cursor's row is just "mcp--" with no arguments.
  const tool = str(raw.toolName) ?? (name.replace(/^mcp-/, "").replace(/^-$/, "") || "tool");
  const full = str(raw.name);
  const server = full && full.endsWith(`-${tool}`) ? full.slice(0, -(tool.length + 1)) : str(raw.providerIdentifier) ?? "";
  return mcpTool(server, tool, raw.args);
}

/** The SDK's `mcp` tool calls. Helm's own tools keep their names so the phone shows them as such. */
export function fromSdk(args: any): McpTool | undefined {
  const server = str(args?.providerIdentifier) ?? str(args?.server) ?? str(args?.serverName) ?? "";
  const tool = str(args?.toolName) ?? str(args?.name) ?? str(args?.tool);
  if (!tool) return undefined;
  const inner = args?.args ?? args?.arguments ?? args?.input;
  if (server === HELM_SERVER || server.endsWith(HELM_SERVER)) return { name: tool, args: inner && typeof inner === "object" ? inner : {} };
  return mcpTool(server, tool, inner);
}

/** The text an MCP result carries (`{content: [{type: "text", text}]}`, possibly JSON-encoded). */
export function resultText(result: unknown): string | undefined {
  let r: any = result;
  for (let i = 0; i < 3 && typeof r === "string"; i++) {
    try {
      r = JSON.parse(r);
    } catch {
      break;
    }
  }
  if (typeof r === "string") return r;
  const content = r?.content ?? r?.result?.content ?? r?.value?.content;
  if (Array.isArray(content)) {
    const text = content.map((c: any) => (c?.type === "text" ? c.text : c?.type ? `[${c.type}]` : "")).filter(Boolean).join("\n");
    if (text) return text;
  }
  if (typeof r?.result === "string") return resultText(r.result);
  return undefined;
}

export function clipOutput(s: string, n = 6000) {
  return s.length > n ? s.slice(0, n) + `\n… (${s.length - n} more characters)` : s;
}

/**
 * Results seen while a turn was live, by call id. The transcript file never has them, so once a turn
 * ages out of the live window this keeps its MCP output on screen.
 */
const seen = new Map<string, { status?: string; meta: Record<string, unknown> }>();

export function rememberResults(items: Item[]) {
  for (const it of items) {
    const t = it.tool;
    if (!t?.callId || !t.name.startsWith("mcp") || !t.meta || (!t.meta.output && !t.meta.error)) continue;
    seen.set(t.callId, { status: t.status, meta: t.meta });
  }
  if (seen.size > 3000) for (const k of [...seen.keys()].slice(0, seen.size - 3000)) seen.delete(k);
}

export function withRememberedResults(items: Item[]): Item[] {
  return items.map((it) => {
    const t = it.tool;
    if (!t?.callId || !t.name.startsWith("mcp") || t.meta?.output || t.meta?.error) return it;
    const hit = seen.get(t.callId);
    if (!hit) return it;
    return { ...it, tool: { ...t, status: hit.status === "error" ? "error" : t.status, meta: { ...(t.meta || {}), ...hit.meta } } };
  });
}

const BRANDS: Record<string, string> = {
  clickup: "ClickUp", posthog: "PostHog", github: "GitHub", gitlab: "GitLab", newrelic: "New Relic", figma: "Figma",
  slack: "Slack", atlassian: "Atlassian", jira: "Jira", confluence: "Confluence", shopify: "Shopify", linear: "Linear",
  notion: "Notion", sentry: "Sentry", stripe: "Stripe", supabase: "Supabase", vercel: "Vercel", kicad: "KiCad",
  openscad: "OpenSCAD", outlook: "Outlook", gmail: "Gmail", "cursor-origin": "Cursor Origin", portskill: "Portskill",
  pencil: "Pencil", sprites: "Sprites",
  [HELM_SERVER]: "Helm",
  helm: "Helm",
};

/** "user-Atlassian-MCP-Server" → "Atlassian", "plugin-figma-figma" → "Figma", "user-platform-github" → "Platform GitHub". */
export function serverName(id: string): string {
  let s = id.replace(/^(user|project|plugin)-/, "").replace(/[-_]?mcp[-_]?server$/i, "").replace(/[-_]mcp$/i, "").replace(/^mcp[-_]/i, "");
  if (id.startsWith("plugin-")) s = s.split("-").pop() || s;
  const key = s.toLowerCase();
  if (BRANDS[key]) return BRANDS[key];
  if (!s) return "MCP";
  return s.split(/[-_]/).filter(Boolean).map((w) => BRANDS[w.toLowerCase()] ?? w[0].toUpperCase() + w.slice(1)).join(" ");
}

const ACRONYMS = new Set(["jql", "sql", "url", "api", "id", "ids", "pr", "prs", "ui", "csv", "json", "html", "pdf", "svg", "dns", "ip", "ssh", "mcp", "llm", "bom", "drc", "erc", "pcb", "3d", "2d"]);

/** "searchJiraIssuesUsingJql" → "Search Jira issues using JQL"; "clickup_get_task" → "Get task". */
export function toolTitle(tool: string, server = ""): string {
  const prefix = server.replace(/^(user|project|plugin)-/, "").split("-").pop()?.toLowerCase() ?? "";
  let t = tool;
  if (prefix && t.toLowerCase().startsWith(prefix + "_")) t = t.slice(prefix.length + 1);
  const words = t
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((w, i) => {
      const l = w.toLowerCase();
      if (ACRONYMS.has(l)) return l.toUpperCase();
      if (/^[A-Z][a-z]/.test(w) && i > 0 && BRANDS[l]) return BRANDS[l];
      return i === 0 ? l[0].toUpperCase() + l.slice(1) : /^[A-Z]{2,}$/.test(w) ? w : l;
    });
  return words.join(" ") || tool;
}

/** One short line for the lock screen. */
export function mcpLine(args: any): string {
  const name = serverName(String(args?.server || ""));
  const d = str(args?.description);
  return d ? `${name}: ${d}` : `${name} · ${toolTitle(String(args?.tool || ""), String(args?.server || ""))}`;
}
