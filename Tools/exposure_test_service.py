#!/usr/bin/env python3
"""Local HTTP and HTTPS test service for HCG Sentinel's Exposure Check.

Standard library plus the openssl command. Binds to 127.0.0.1 only. The HTTPS listener uses a freshly generated
self-signed certificate issued for "sentinel-test.invalid", so a correct client must refuse it: that is how the
untrusted-certificate and name-mismatch paths are exercised without touching any real service.

    python3 Tools/exposure_test_service.py --http-port 8081 --https-port 8444

Paths (same on both listeners)
  /plain              200 HTML, no security headers, Server and X-Powered-By with versions
  /hardened           200 HTML with CSP (incl. frame-ancestors), nosniff, Referrer-Policy, HSTS, versionless Server
  /api                200 JSON without security headers
  /redirect-metadata  302 to http://169.254.169.254/latest/meta-data/ (must never be followed)
  /redirect-elsewhere 302 to https://example.invalid/ (out of scope, must not be followed)
  /redirect-loop      302 to itself
  /slow               waits 4 seconds, then 200
  /big                200 with a 1 MiB body
  /error              500
  /__log              JSON list of paths requested so far (for tests)
"""
import argparse
import json
import os
import ssl
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
LOG_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HCGTestServer/1.2.3"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, body=b"", headers=None, server=None):
        self.send_response_only(status)
        self.send_header("Server", server or self.server_version)
        self.send_header("Date", self.date_time_string())
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        with LOG_LOCK:
            LOG.append(path)
        html = {"Content-Type": "text/html; charset=utf-8"}
        page = b"<!doctype html><title>Sentinel test page</title><p>Synthetic test page.</p>"
        if path in ("/", "/plain"):
            return self._send(200, page, {**html, "X-Powered-By": "Synthetic/9.9"})
        if path == "/hardened":
            return self._send(200, page, {
                **html,
                "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'",
                "X-Content-Type-Options": "nosniff",
                "Referrer-Policy": "no-referrer",
                "Strict-Transport-Security": "max-age=31536000",
            }, server="HCGTestServer")
        if path == "/api":
            return self._send(200, b'{"ok":true}', {"Content-Type": "application/json"})
        if path == "/redirect-metadata":
            return self._send(302, b"", {"Location": "http://169.254.169.254/latest/meta-data/"})
        if path == "/redirect-elsewhere":
            return self._send(302, b"", {"Location": "https://example.invalid/"})
        if path == "/redirect-loop":
            return self._send(302, b"", {"Location": "/redirect-loop"})
        if path == "/slow":
            time.sleep(4)
            return self._send(200, page, html)
        if path == "/big":
            return self._send(200, b"x" * (1024 * 1024), {"Content-Type": "text/plain"})
        if path == "/error":
            return self._send(500, b"error", {"Content-Type": "text/plain"})
        if path == "/__log":
            with LOG_LOCK:
                body = json.dumps(LOG).encode()
            return self._send(200, body, {"Content-Type": "application/json"})
        return self._send(404, b"not found", {"Content-Type": "text/plain"})

    do_HEAD = do_GET


def self_signed_context(directory):
    key = os.path.join(directory, "key.pem")
    cert = os.path.join(directory, "cert.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2",
         "-subj", "/CN=sentinel-test.invalid", "-addext", "subjectAltName=DNS:sentinel-test.invalid"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    return context


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--http-port", type=int, default=8081)
    parser.add_argument("--https-port", type=int, default=8444)
    args = parser.parse_args()

    http = ThreadingHTTPServer(("127.0.0.1", args.http_port), Handler)
    https = ThreadingHTTPServer(("127.0.0.1", args.https_port), Handler)
    with tempfile.TemporaryDirectory() as directory:
        https.socket = self_signed_context(directory).wrap_socket(https.socket, server_side=True)
        threading.Thread(target=https.serve_forever, daemon=True).start()
        print(f"Exposure test service: http://127.0.0.1:{args.http_port}/ and https://127.0.0.1:{args.https_port}/ (self-signed)", flush=True)
        try:
            http.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
