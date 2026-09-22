#!/usr/bin/env node
/**
 * anyrouter-proxy — local reverse proxy for the AnyRouter (anyrouter.top) gateway.
 *
 * Why this exists:
 *   anyrouter.top is only reachable from this machine through the Clash proxy
 *   (127.0.0.1:7890). Direct connections fail during the TLS handshake even on
 *   IPv4 (verified 2026-09-18), exactly like agentrouter.org.
 *
 *   Egress goes through Clash via Node's env-proxy support: run this process
 *   with `NODE_USE_ENV_PROXY=1` and `HTTPS_PROXY=http://127.0.0.1:7890`
 *   (see ~/.config/systemd/user/anyrouter-proxy.service).
 *
 * Upstream base: https://anyrouter.top — the incoming request path is appended
 * verbatim, so the configured DSH baseURL is `http://127.0.0.1:{PORT}/v1`
 * and paths line up one-to-one (`/v1/models`, `/v1/responses`, ...).
 *
 * No header rewriting: unlike AgentRouter, AnyRouter accepted plain requests
 * (Authorization + default UA). Everything is forwarded unchanged.
 */
import http from "node:http";
import { Readable } from "node:stream";

const UPSTREAM = process.env.ANYROUTER_PROXY_UPSTREAM ?? "https://anyrouter.top";
const PORT = Number(process.env.ANYROUTER_PROXY_PORT ?? 8321);
const BIND = process.env.ANYROUTER_PROXY_BIND ?? "127.0.0.1";

const server = http.createServer((req, res) => {
  const url = UPSTREAM + req.url; // query string included
  const headers = {};
  for (const [name, value] of Object.entries(req.headers)) {
    if (name === "host") continue; // let fetch set the upstream host
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
      body.on("error", (error) => {
        console.error(`[anyrouter-proxy] ${req.method} ${req.url} -> stream error: ${error?.message ?? error}`);
        res.destroy();
      });
      body.pipe(res);
    })
    .catch((error) => {
      clearTimeout(timeout);
      const reason = error?.cause?.code ?? error?.message ?? String(error);
      console.error(`[anyrouter-proxy] ${req.method} ${req.url} -> upstream failed: ${reason}`);
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "application/json; charset=utf-8" });
        res.end(
          JSON.stringify({
            error: {
              message:
                `anyrouter-proxy cannot reach ${UPSTREAM}: ${reason}. ` +
                "Is Clash (127.0.0.1:7890) running?",
              type: "proxy_error",
            },
          }),
        );
      } else {
        res.destroy();
      }
    });
});

server.listen(PORT, BIND, () => {
  console.log(`[anyrouter-proxy] listening on http://${BIND}:${PORT} -> ${UPSTREAM}`);
});
