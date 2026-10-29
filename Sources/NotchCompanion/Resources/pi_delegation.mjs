// Loaded only by this frontend with --extension; the Pi home is untouched.
// Registers Notch Companion's delegation tools from its loopback MCP server,
// as T3 Code's Pi extension does, and appends their instructions.
import http from "node:http";

export default async function (pi) {
  const endpoint = process.env.NOTCH_DELEGATION_URL;
  const token = process.env.NOTCH_DELEGATION_TOKEN;
  // Commands the agent runs do not inherit the session's token.
  delete process.env.NOTCH_DELEGATION_URL;
  delete process.env.NOTCH_DELEGATION_TOKEN;
  if (!endpoint || !token) return;
  const url = new URL(endpoint);
  let nextId = 0;
  // node:http, not fetch: a delegation wait can outlast fetch's header timeout.
  const request = (method, params, signal) => new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: "2.0", id: ++nextId, method, params });
    const call = http.request({
      hostname: url.hostname, port: url.port, path: url.pathname, method: "POST", signal,
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream",
                 authorization: "Bearer " + token, "content-length": Buffer.byteLength(body) },
    }, (response) => {
      let data = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { data += chunk; });
      response.on("end", () => {
        if (response.statusCode !== 200) return reject(new Error("Notch Companion answered " + response.statusCode));
        try {
          const reply = JSON.parse(data);
          reply.error ? reject(new Error(reply.error.message)) : resolve(reply.result);
        } catch (error) { reject(error); }
      });
    });
    call.on("error", reject);
    call.end(body);
  });

  let instructions = "";
  let tools = [];
  try {
    const signal = AbortSignal.timeout(10_000);
    const initialized = await request("initialize", { protocolVersion: "2025-06-18", capabilities: {},
      clientInfo: { name: "notch-pi", version: "1" } }, signal);
    instructions = initialized?.instructions ?? "";
    tools = (await request("tools/list", {}, signal))?.tools ?? [];
  } catch {
    return; // The session still works without delegation.
  }
  for (const tool of tools) {
    pi.registerTool({
      name: "mcp__notch__" + tool.name,
      label: tool.name,
      description: tool.description ?? tool.name,
      parameters: tool.inputSchema,
      async execute(_id, params, signal) {
        const result = await request("tools/call", { name: tool.name, arguments: params ?? {} }, signal);
        return { content: result?.content ?? [], details: { server: "notch", tool: tool.name },
                 ...(result?.isError ? { isError: true } : {}) };
      },
    });
  }
  pi.on("before_agent_start", (event) => {
    if (!instructions) return undefined;
    const sections = event.systemPromptOptions?.sections;
    if (sections && typeof sections === "object" && event.systemPromptOptions?.forceSystemPrompt === undefined) {
      sections.notch_delegation = instructions;
      return undefined;
    }
    return { systemPrompt: event.systemPrompt + "\n\n" + instructions };
  });
}
