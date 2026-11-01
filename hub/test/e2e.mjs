// End-to-end check against a running hub: creates a workspace on a scratch folder, starts
// two agents, has one ask the other a question through message_agent, and has one call
// ask_user, which this script answers like the phone would.
import fs from "node:fs";
import os from "node:os";
import WebSocket from "ws";

const cfg = JSON.parse(fs.readFileSync(`${os.homedir()}/.helm/config.json`, "utf8"));
const H = `http://127.0.0.1:${cfg.port}`;
const dir = process.argv[2] || "/tmp/helm-e2e";
const api = async (method, path, body) => {
  const r = await fetch(H + path, { method, headers: { authorization: `Bearer ${cfg.token}`, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json();
  if (!r.ok) throw new Error(`${method} ${path}: ${j.error}`);
  return j;
};

const ws = new WebSocket(`ws://127.0.0.1:${cfg.port}/ws?token=${cfg.token}`);
const seen = { appends: 0, items: 0, decisions: [] };
const agentStatus = {};
ws.on("message", (raw) => {
  const ev = JSON.parse(raw);
  if (ev.type === "append") seen.appends++;
  if (ev.type === "item") {
    seen.items++;
    const it = ev.item;
    if (it.kind === "tool" && it.tool.status !== "running") console.log(`  [${ev.agentId}] tool ${it.tool.name} → ${it.tool.status}`);
    if (it.kind === "agent_message") console.log(`  [${ev.agentId}] got agent message from ${it.from?.name}`);
    if (it.kind === "assistant" && !it.streaming) console.log(`  [${ev.agentId}] assistant: ${it.text.slice(0, 140).replace(/\n/g, " ")}`);
    if (it.kind === "error") console.log(`  [${ev.agentId}] ERROR ${it.text}`);
  }
  if (ev.type === "agent") {
    if (agentStatus[ev.agent.id] !== ev.agent.status) console.log(`  [${ev.agent.id}] ${ev.agent.name}: ${ev.agent.status}${ev.agent.statusDetail ? ` (${ev.agent.statusDetail})` : ""}`);
    agentStatus[ev.agent.id] = ev.agent.status;
  }
  if (ev.type === "decision" && !ev.decision.answeredAt) {
    console.log(`  decision: "${ev.decision.question}" options=${JSON.stringify(ev.decision.options)}`);
    seen.decisions.push(ev.decision);
    setTimeout(() => api("POST", `/api/decisions/${ev.decision.id}`, { answer: "2" }).then(() => console.log("  answered decision with option 2")), 1500);
  }
});
await new Promise((r) => ws.once("open", r));

const waitIdle = async (id, label, timeoutMs = 240_000) => {
  const t0 = Date.now();
  await new Promise((r) => setTimeout(r, 1500));
  while (Date.now() - t0 < timeoutMs) {
    const s = await api("GET", "/api/state");
    const a = s.agents.find((x) => x.id === id);
    if (a && (a.status === "idle" || a.status === "error") && a.queue === 0) return a;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`${label} did not finish in time`);
};

const w = await api("POST", "/api/workspaces", { name: "Helm E2E", folders: [dir] });
console.log(`workspace ${w.id} → ${w.folders}`);

console.log("\n1) single agent edits a file");
const a = await api("POST", "/api/agents", { workspaceId: w.id, name: "Builder", model: "auto", prompt: "Create a file named hello.txt containing exactly the text: hello from helm. Then reply with one short sentence." });
const a1 = await waitIdle(a.id, "Builder");
console.log(`   status=${a1.status} file=${JSON.stringify(fs.existsSync(`${dir}/hello.txt`) && fs.readFileSync(`${dir}/hello.txt`, "utf8").trim())}`);

console.log("\n2) ask_user decision round-trip");
await api("POST", `/api/agents/${a.id}/messages`, { text: "Use the ask_user tool to ask me which color to write into color.txt, with options red, green, blue. Then write my answer into color.txt and reply with the color." });
await waitIdle(a.id, "Builder decision");
console.log(`   color.txt=${JSON.stringify(fs.existsSync(`${dir}/color.txt`) && fs.readFileSync(`${dir}/color.txt`, "utf8").trim())}`);

console.log("\n3) agent-to-agent messaging");
const b = await api("POST", "/api/agents", { workspaceId: w.id, name: "Reviewer", model: "auto" });
await api("POST", `/api/agents/${a.id}/relay`, { targetId: b.id, instruction: "Ask Reviewer what the secret word is and wait for its reply. Then write the word into secret.txt." });
await new Promise((r) => setTimeout(r, 1000));
await api("POST", `/api/agents/${b.id}/messages`, { text: "Remember: if anyone asks, the secret word is PINEAPPLE. Just acknowledge with OK." });
await waitIdle(a.id, "Builder relay", 300_000);
await waitIdle(b.id, "Reviewer");
console.log(`   secret.txt=${JSON.stringify(fs.existsSync(`${dir}/secret.txt`) && fs.readFileSync(`${dir}/secret.txt`, "utf8").trim())}`);

console.log(`\nstream: ${seen.appends} text deltas, ${seen.items} item events, ${seen.decisions.length} decisions`);
for (const id of [a.id, b.id]) await api("DELETE", `/api/agents/${id}`);
await api("DELETE", `/api/workspaces/${w.id}`);
ws.close();
