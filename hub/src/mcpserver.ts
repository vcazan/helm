import fs from "node:fs";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import { HOME } from "./config.ts";
import type { AgentManager } from "./agents.ts";
import type { Item } from "./store.ts";
import { log } from "./log.ts";

/**
 * Helm as an MCP server for Cursor's desktop chats, so a chat can see and message Helm agents and
 * other chats the same way Helm agents can. Cursor connects over streamable HTTP from this Mac.
 */

const SERVER = "helm";

const TOOLS = [
  {
    name: "list_agents",
    description:
      "List everyone you can message: the user's Helm agents and their other Cursor chats, across all workspaces, with id, name, kind, workspace and status.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "message_agent",
    description:
      "Send a message to a Helm agent or another Cursor chat (by id or name from list_agents). By default waits up to a minute for its reply; if it needs longer, its reply arrives in this chat as a new message. Set wait_for_reply to false to just hand something off.",
    inputSchema: {
      type: "object",
      properties: {
        agent: { type: "string", description: "Target id or name. Cursor chats have ids like chat:<id>." },
        message: { type: "string" },
        wait_for_reply: { type: "boolean", description: "Default true." },
      },
      required: ["agent", "message"],
    },
  },
  {
    name: "get_reply",
    description: "Fetch a reply that arrived after message_agent stopped waiting, by the ref it gave you.",
    inputSchema: { type: "object", properties: { ref: { type: "string" } }, required: ["ref"] },
  },
];

/** How long a chat's call is held open: Cursor's MCP client gives up on requests after about a minute. */
const CHAT_WAIT_MS = 50_000;

export async function handleMcp(req: IncomingMessage, res: ServerResponse, body: any, agents: AgentManager) {
  const json = (status: number, data: unknown) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(data));
  };
  if (req.method === "GET") return json(405, { error: "Helm doesn't stream server events" });
  if (req.method === "DELETE") return json(200, {});
  const batch = Array.isArray(body) ? body : [body];
  const out = (await Promise.all(batch.map((m) => answer(m, agents)))).filter(Boolean);
  if (!out.length) {
    res.writeHead(202);
    return res.end();
  }
  json(200, Array.isArray(body) ? out : out[0]);
}

async function answer(m: any, agents: AgentManager) {
  if (!m || typeof m !== "object" || m.id === undefined) return undefined;
  const ok = (result: unknown) => ({ jsonrpc: "2.0", id: m.id, result });
  switch (m.method) {
    case "initialize":
      return ok({
        protocolVersion: m.params?.protocolVersion || "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: SERVER, version: "1.0.0" },
        instructions: "Talk to the user's other agents: list_agents shows Helm agents and Cursor chats; message_agent sends one a message and returns its reply.",
      });
    case "ping":
      return ok({});
    case "tools/list":
      return ok({ tools: TOOLS });
    case "tools/call": {
      const name = String(m.params?.name || "");
      const args = m.params?.arguments || {};
      const text = (t: string, isError = false) => ok({ content: [{ type: "text", text: t }], isError: isError || undefined });
      try {
        if (name === "list_agents") {
          const me = await agents.callingChat(name);
          return text(JSON.stringify(agents.directory(me), null, 1));
        }
        if (name === "message_agent") {
          const me = await agents.callingChat(name);
          if (!me) log.warn("helm mcp: couldn't tell which Cursor chat sent a message");
          return text(await agents.messageAgent(me, args, CHAT_WAIT_MS));
        }
        if (name === "get_reply") return text(agents.getReply(args.ref));
        return text(`Unknown tool ${name}`, true);
      } catch (e: any) {
        return text(e.message, true);
      }
    }
    default:
      return { jsonrpc: "2.0", id: m.id, error: { code: -32601, message: `Method not found: ${m.method}` } };
  }
}

/** Adds Helm to Cursor's MCP servers (~/.cursor/mcp.json), keeping everything else in the file as it is. */
export function registerWithCursor(port: number, token: string) {
  const file = path.join(HOME, ".cursor", "mcp.json");
  let cfg: any = { mcpServers: {} };
  try {
    if (fs.existsSync(file)) cfg = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    log.warn("~/.cursor/mcp.json isn't valid JSON; not adding Helm to it");
    return;
  }
  cfg.mcpServers ||= {};
  const want = { url: `http://127.0.0.1:${port}/mcp`, headers: { Authorization: `Bearer ${token}` } };
  if (JSON.stringify(cfg.mcpServers[SERVER]) === JSON.stringify(want)) return;
  cfg.mcpServers[SERVER] = want;
  fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
  log.info("added Helm to Cursor's MCP servers");
}

const HEADER = /^\[(Message|Reply) from (?:(agent|Cursor chat) "(.+?)" \(id (\S+)\)(?: in workspace "(.*?)")?|another agent)(?: to your message)?(?: · ref \S+)?\]\n/;
const FOOTER = /\n\n(They are waiting: your final response[^\n]*|They are not waiting for a reply;[^\n]*)\s*$/;

/** Messages agents sent into a Cursor chat show as agent messages, not as if the user typed them. */
export function asAgentMessages(items: Item[]): Item[] {
  return items.map((it) => {
    if (it.kind !== "user" || !it.text?.startsWith("[")) return it;
    const m = it.text.match(HEADER);
    if (!m) return it;
    const text = it.text.slice(m[0].length).replace(FOOTER, "").trim();
    const name = m[3] ? (m[1] === "Reply" ? `${m[3]} (reply)` : m[3]) : "Another agent";
    return { ...it, kind: "agent_message", text, from: { agentId: m[4] || "", name, workspace: m[5] || "" } };
  });
}
