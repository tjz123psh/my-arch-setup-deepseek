#!/usr/bin/env python3
"""Small delayed threaded HTTP server for pacman downloader experiments."""
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(SimpleHTTPRequestHandler):
    server_version = "download-mode-lab/1"

    def log_message(self, *_args: object) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        state = self.server.state  # type: ignore[attr-defined]
        now = time.time()
        with state["lock"]:
            state["seq"] += 1
            request_id = state["seq"]
            state["active"] += 1
            state["max_active"] = max(state["max_active"], state["active"])
            state["events"].append({"event": "start", "id": request_id, "path": self.path, "active": state["active"], "time": now})
        try:
            time.sleep(state["delay"])
            super().do_GET()
        finally:
            with state["lock"]:
                state["active"] -= 1
                state["events"].append({"event": "end", "id": request_id, "path": self.path, "active": state["active"], "time": time.time()})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--directory", type=Path, required=True)
    ap.add_argument("--port-file", type=Path, required=True)
    ap.add_argument("--log-file", type=Path, required=True)
    ap.add_argument("--delay", type=float, default=0.5)
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()
    args.port_file.parent.mkdir(parents=True, exist_ok=True)
    args.log_file.parent.mkdir(parents=True, exist_ok=True)
    state = {"delay": args.delay, "lock": threading.Lock(), "seq": 0, "active": 0, "max_active": 0, "events": []}
    handler = lambda *a, **kw: Handler(*a, directory=str(args.directory), **kw)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    server.state = state  # type: ignore[attr-defined]
    args.port_file.write_text(str(server.server_address[1]) + "\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        with args.log_file.open("w") as fh:
            json.dump({"delay": args.delay, "max_active": state["max_active"], "events": state["events"]}, fh, indent=2)
            fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
