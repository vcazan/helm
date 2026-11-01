// A stand-in hub full of made-up projects, for trying the app without a Mac setup and for screenshots.
//   node demo/server.mjs            → listens on 127.0.0.1:7879
// Pair with: helm://pair?url=http%3A%2F%2F127.0.0.1%3A7879&token=demo&name=Studio%20Mac
import http from "node:http";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 7879);
const now = Date.now();
const min = 60_000;
const home = "/Users/me/Projects";

const ws = (id, name, extra = {}) => ({
  id, name, folders: [`${home}/${name}`], source: "cursor", pinned: false, hidden: false,
  createdAt: now - 90 * 24 * 60 * min, lastActiveAt: now - 60 * min, ...extra,
});
const workspaces = [
  ws("w1", "storefront", { pinned: true, openOnLaptop: true, lastActiveAt: now - 2 * min }),
  ws("w2", "mobile-app", { openOnLaptop: true, lastActiveAt: now - 5 * min }),
  ws("w3", "design-system", { pinned: true, lastActiveAt: now - 3 * 60 * min }),
  ws("w4", "payments-api", { lastActiveAt: now - 8 * min }),
  ws("w5", "docs-site", { openOnLaptop: true, lastActiveAt: now - 40 * min }),
  ws("w6", "infra", { lastActiveAt: now - 26 * 60 * min }),
  ws("w7", "analytics-dashboard", { lastActiveAt: now - 3 * 24 * 60 * min }),
  ws("w8", "marketing-site", { lastActiveAt: now - 6 * 24 * 60 * min }),
];

const agents = [
  { id: "a1", workspaceId: "w4", name: "Release agent", model: "auto", runtime: { kind: "local" }, status: "waiting",
    statusDetail: "Which version should I tag?", lastText: "Release notes are drafted.", unread: 1, queue: 0, createdAt: now - 30 * min, updatedAt: now - 1 * min },
  { id: "a2", workspaceId: "w4", name: "Webhook retries", model: "auto", runtime: { kind: "local" }, status: "idle",
    lastText: "Retries now back off exponentially, capped at 5 attempts.", unread: 0, queue: 0, createdAt: now - 26 * 60 * min, updatedAt: now - 20 * 60 * min },
];

const decisions = [
  { id: "d1", agentId: "a1", question: "Which version should I tag this release?", options: ["v2.4.0", "v2.4.0-rc.1", "Hold for now"],
    context: "3 features and 7 fixes since v2.3.0. One fix changes the webhook payload.", createdAt: now - 1 * min },
];

const desktop = {
  available: true,
  windows: [
    { id: "win-store", title: "storefront", workspace: "storefront", working: true, manageable: true, activeComposerId: "c1",
      chats: [
        { title: "Checkout redesign", age: "now", status: "working", selected: true, composerId: "c1", updatedAt: now },
        { title: "Fix flaky cart test", age: "2h", status: "done", selected: false, composerId: "c2", updatedAt: now - 120 * min },
        { title: "Add Apple Pay", age: "1d", status: "idle", selected: false, composerId: "c3", updatedAt: now - 26 * 60 * min },
      ] },
    { id: "win-mobile", title: "mobile-app", workspace: "mobile-app", working: false, manageable: true, activeComposerId: "c4",
      pending: { chat: "Offline sync", label: "pnpm test --filter sync", approve: "Run", reject: "Skip" },
      chats: [
        { title: "Offline sync", age: "now", status: "attention", selected: true, composerId: "c4", updatedAt: now - 1 * min },
        { title: "Push notification copy", age: "3h", status: "done", selected: false, composerId: "c5", updatedAt: now - 180 * min },
      ] },
    { id: "win-docs", title: "docs-site", workspace: "docs-site", working: false, manageable: true, activeComposerId: "c6",
      chats: [{ title: "API reference refresh", age: "40m", status: "done", selected: true, composerId: "c6", updatedAt: now - 40 * min }] },
  ],
};

let seq = 0;
const at = (minsAgo) => now - minsAgo * min;
const user = (text, m) => ({ id: `i${++seq}`, ts: at(m), kind: "user", text });
const say = (text, m) => ({ id: `i${++seq}`, ts: at(m), kind: "assistant", text });
const tool = (name, args, m, meta, status = "completed") => ({ id: `i${++seq}`, ts: at(m), kind: "tool", tool: { name, status, args, meta } });

const checkout = [
  user("The checkout page feels cramped on phones. Can you make it a single column with a sticky order summary, and keep Apple Pay above the fold?", 14),
  say("I'll look at how checkout is put together first.", 14),
  tool("read", { path: "app/checkout/page.tsx" }, 13, { lines: 182 }),
  tool("grep", { pattern: "OrderSummary", path: "app" }, 13, { files: 4 }),
  tool("read", { path: "components/OrderSummary.tsx" }, 13, { lines: 96 }),
  say("Checkout renders the form and the summary side by side at every width, so on a phone the summary squeezes the form. Here's the flow I'm aiming for:\n\n```mermaid\nflowchart LR\n  Cart --> Pay{Apple Pay?}\n  Pay -->|yes| Confirm\n  Pay -->|no| Address --> Card --> Confirm\n  Confirm --> Done[Order placed]\n```", 12),
  tool("edit", { path: "app/checkout/page.tsx" }, 11, { added: 48, removed: 31,
    diff: "@@ -12,9 +12,14 @@ export default function Checkout() {\n-  <div className=\"grid grid-cols-2 gap-8\">\n+  <div className=\"flex flex-col gap-6 md:grid md:grid-cols-[1fr_360px]\">\n+    <ExpressPay />\n     <CheckoutForm />\n-    <OrderSummary />\n+    <StickySummary />\n   </div>" }),
  tool("write", { path: "components/StickySummary.tsx" }, 10, { added: 64, lines: 64 }),
  tool("edit", { path: "components/OrderSummary.tsx" }, 10, { added: 22, removed: 9 }),
  tool("shell", { command: "pnpm test checkout" }, 9, { exitCode: 0, output: " ✓ checkout/form.test.tsx (9)\n ✓ checkout/summary.test.tsx (5)\n\n Test Files  2 passed (2)\n      Tests  14 passed (14)" }),
  say("Checkout is now a single column on phones:\n\n- **Apple Pay** sits at the top, so most people never scroll.\n- The order summary is a bar pinned to the bottom; tap it to see line items.\n- Tablets and up keep the two-column layout.\n\nAll 14 checkout tests pass. I'm running a production build to check bundle size.", 8),
  tool("shell", { command: "pnpm build" }, 1, undefined, "running"),
];

const offline = [
  user("Users lose drafts when they go through a tunnel. Queue edits while offline and sync them when the connection comes back.", 9),
  say("I'll add a small outbox: edits go to local storage first, and a sync worker drains it when the network is back.", 9),
  tool("read", { path: "src/sync/SyncEngine.ts" }, 8, { lines: 140 }),
  tool("write", { path: "src/sync/Outbox.ts" }, 6, { added: 88, lines: 88 }),
  tool("edit", { path: "src/sync/SyncEngine.ts" }, 5, { added: 31, removed: 12 }),
  say("The outbox is in place and the engine drains it on reconnect, oldest edit first. I'd like to run the sync tests before going further.", 2),
];

const docs = [
  user("Refresh the API reference for the new webhook fields.", 50),
  tool("read", { path: "content/api/webhooks.mdx" }, 49, { lines: 210 }),
  tool("edit", { path: "content/api/webhooks.mdx" }, 46, { added: 34, removed: 6 }),
  say("Added `attempt`, `next_retry_at` and `signature_version` to the webhook reference, with an example payload.", 42),
];

const release = [
  user("Draft release notes for everything merged since v2.3.0, then tag the release.", 6),
  tool("shell", { command: "git log v2.3.0..HEAD --oneline" }, 6, { exitCode: 0, output: "a41c2e9 Exponential backoff for webhook retries\n7be10d3 Add signature_version to webhook payload\n52f9a11 Idempotency keys on refunds\n…" }),
  tool("write", { path: "CHANGELOG.md" }, 3, { added: 27, lines: 27 }),
  say("Release notes are drafted in `CHANGELOG.md`: 3 features and 7 fixes. One fix adds a field to the webhook payload, which some integrations may notice.", 2),
  { id: `i${++seq}`, ts: at(1), kind: "decision", decisionId: "d1", text: decisions[0].question },
];

const transcripts = { c1: checkout, c2: [], c3: [], c4: offline, c5: [], c6: docs };
const agentItems = { a1: release, a2: [] };

const hub = { name: "Studio Mac", version: "1.0.0", push: true, cursorLoggedIn: true, cursorEmail: "me@example.com", cursorRunning: true, defaultModel: "auto" };
const snapshot = () => ({ hub, workspaces, agents, decisions, desktop });

const send = (res, code, body) => {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;
  if (process.env.DEMO_LOG) console.log(req.method, req.url);
  if (p === "/api/state") return send(res, 200, snapshot());
  if (p === "/api/desktop") return send(res, 200, desktop);
  let m = p.match(/^\/api\/desktop\/[^/]+\/transcript$/);
  if (m) {
    const win = desktop.windows.find((w) => p.includes(w.id));
    const chat = win?.chats.find((c) => c.title === url.searchParams.get("chat"));
    const id = url.searchParams.get("composerId") || chat?.composerId || "";
    const items = transcripts[id] || [];
    return send(res, 200, { composerId: id, items, total: items.length, updatedAt: now });
  }
  if ((m = p.match(/^\/api\/agents\/([^/]+)\/transcript$/))) return send(res, 200, agentItems[m[1]] || []);
  if (p === "/api/models") return send(res, 200, [{ id: "auto", name: "Auto" }]);
  if (p === "/api/changes") return send(res, 200, { git: true, root: url.searchParams.get("root"), branch: "main", files: [], added: 0, removed: 0 });
  if (p === "/api/activity") return send(res, 200, { working: 1, waiting: 2, rows: [] });
  if (req.method === "GET") return send(res, 404, { error: "not in the demo" });
  return send(res, 200, { ok: true });
});

new WebSocketServer({ server, path: "/ws" }).on("connection", (sock) => {
  if (process.env.DEMO_LOG) {
    console.log("ws open");
    sock.on("close", (code, why) => console.log("ws close", code, String(why)));
    sock.on("error", (e) => console.log("ws error", e.message));
  }
  sock.send(JSON.stringify({ type: "snapshot", ...snapshot() }));
});
server.listen(PORT, "127.0.0.1", () => console.log(`Demo hub on http://127.0.0.1:${PORT}`));
