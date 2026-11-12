#!/usr/bin/env python3
"""Local HTTP test service for the HCG Sentinel request composer.

Standard library only. Binds to 127.0.0.1 by default; pass --host 0.0.0.0 to
reach it from a physical device on the same network you control.

Endpoints
  ANY /echo[?query]   JSON echo of method, path, headers (lower-cased) and body
  ANY /status/<code>  empty response with that status code (100-599)
  ANY /delay/<secs>   echo after sleeping up to 30 seconds
  ANY /redirect       302 to http://example.invalid/ (Sentinel must NOT follow it)
  ANY /large          2 MB body, to exercise the response display limit
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 2 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SentinelTestService/1.0"

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return self._send(413)
        body = self.rfile.read(length) if length else b""
        path = self.path.split("?", 1)[0]
        if path.startswith("/status/"):
            try:
                code = int(path.rsplit("/", 1)[1])
            except ValueError:
                code = 400
            return self._send(code if 100 <= code <= 599 else 400)
        if path == "/redirect":
            return self._send(302, headers={"Location": "http://example.invalid/"})
        if path == "/large":
            return self._send(200, b"x" * MAX_BODY, {"Content-Type": "text/plain"})
        if path.startswith("/delay/"):
            try:
                time.sleep(min(float(path.rsplit("/", 1)[1]), 30))
            except ValueError:
                pass
        elif path != "/echo":
            return self._send(404, b'{"error":"not found"}', {"Content-Type": "application/json"})
        payload = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }
        self._send(200, json.dumps(payload, indent=2).encode(), {"Content-Type": "application/json"})

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _handle

    def log_message(self, fmt, *args):
        # Log method, path and status only: never headers or bodies.
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Sentinel test service on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
