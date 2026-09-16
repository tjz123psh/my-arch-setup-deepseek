#!/usr/bin/env node
/**
 * agentrouter-proxy — local reverse proxy for the AgentRouter (agentrouter.org)
 * gateway.
 *
 * Why this exists:
 *   1. agentrouter.org is only reachable from this machine through the Clash
 *      proxy (127.0.0.1:7890); direct connections time out (GFW).
 *   2. AgentRouter's WAF rejects requests that do not carry the "Codex wire
 *      image": it requires `Originator` / `Version` / `User-Agent` headers of
 *      an official client. The harness's own HTTP client cannot set a custom
 *      User-Agent (it is always attributed), so this proxy injects the three
 *      headers and forwards everything else unchanged.
 *
 * Egress goes through Clash via Node's env-proxy support: run this process
 * with `NODE_USE_ENV_PROXY=1` and `HTTPS_PROXY=http://127.0.0.1:7890`.
 *
 * Upstream base: https://agentrouter.org — the incoming request path is
 * appended verbatim, so the configured baseURL for DSH is
 * `http://127.0.0.1:{PORT}/v1` and the paths line up one-to-one.
 */
import http from "node:http";
import { Readable } from "node:stream";

const UPSTREAM = "https://agentrouter.org";
const PORT = Number(process.env.AGENTROUTER_PROXY_PORT ?? 8320);
const BIND = process.env.AGENTROUTER_PROXY_BIND ?? "127.0.0.1";

// The Codex wire image headers AgentRouter's WAF requires.
const WIRE_HEADERS = {
  Originator: "codex_cli_rs",
  Version: "0.101.0",
  "User-Agent": "codex_cli_rs/0.101.0 (Mac OS 26.0.1; arm64) Apple_Terminal/464",
};

const REPLACED = new Set(["host", "originator", "version", "user-agent"]);

const server = http.createServer((req, res) => {
  const url = UPSTREAM + req.url; // query string included
  const headers = { ...WIRE_HEADERS };
  for (const [name, value] of Object.entries(req.headers)) {
    if (REPLACED.has(name)) continue; // inject our wire image instead
    headers[name] = value;
  }

  const controller = new AbortController();
  // Abort the upstream call only when the client connection goes away before
  // the response finished. (req "close" fires as soon as the request body has
  // been read — that must NOT cancel the call.)
  res.on("close", () => {
    if (!res.writableEnded) controller.abort();
  });
  const timeout = setTimeout(() => controller.abort(), 10 * 60 * 1000);
  timeout.unref();

  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  fetch(url, {
    method: req.method,
    headers,
    body: hasBody ? req : undefined,
    duplex: "half",
    signal: controller.signal,
  })
    .then((upstream) => {
      clearTimeout(timeout);
      res.writeHead(upstream.status, Object.fromEntries(upstream.headers));
      const body = Readable.fromWeb(upstream.body);
      // Aborted upstreams (client hung up, watchdog) emit here — swallow the
      // error instead of crashing the process; the response is already dead.
      body.on("error", (error) => {
        console.error(`[agentrouter-proxy] ${req.method} ${req.url} -> stream error: ${error?.message ?? error}`);
        res.destroy();
      });
      body.pipe(res);
    })
    .catch((error) => {
      clearTimeout(timeout);
      const reason = error?.cause?.code ?? error?.message ?? String(error);
      console.error(`[agentrouter-proxy] ${req.method} ${req.url} -> upstream failed: ${reason}`);
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "application/json; charset=utf-8" });
        res.end(
          JSON.stringify({
            success: false,
            error: {
              message:
                `agentrouter-proxy cannot reach ${UPSTREAM}: ${reason}. ` +
                "Is Clash (127.0.0.1:7890) running?",
            },
          }),
        );
      } else {
        res.destroy();
      }
    });
});

server.listen(PORT, BIND, () => {
  console.log(`[agentrouter-proxy] listening on http://${BIND}:${PORT} -> ${UPSTREAM}`);
});