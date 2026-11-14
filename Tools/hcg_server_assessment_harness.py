#!/usr/bin/env python3
"""Development harness for the HCG Server Security Lab contract (docs/SECURITY_LAB_SERVER.md).

This is NOT HCG Server. It exists so the contract can be exercised before HCG Server implements it:
per-device authorisation, report ownership, scope validation on the execution side, bounded execution,
cancellation and capability reporting. It binds to 127.0.0.1 only.

Real HCG Server authenticates paired devices with mutual TLS and pinned key fingerprints. The harness stands that in
with one bearer token per simulated device (--device NAME:TOKEN); tokens are development values, never real ones.

What it actually executes: the "reachability" check of exposureCheck (one GET per entered URL, redirects reported but
never followed). Everything else is reported as unsupported. It never returns results it did not produce.

    python3 Tools/hcg_server_assessment_harness.py --port 7700 --device phone-a:dev-token-a --device phone-b:dev-token-b
"""
import argparse
import ipaddress
import json
import socket
import threading
import time
import urllib.parse
import uuid
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONTRACT_VERSION = 1
MAX_TARGETS = 5
REQUEST_TIMEOUT = 8
METADATA_HOSTS = {"metadata", "metadata.google.internal", "metadata.goog", "instance-data", "instance-data.ec2.internal",
                  "metadata.azure.com"}
METADATA_ADDRESSES = {ipaddress.ip_address(a) for a in ("169.254.169.254", "169.254.170.2", "100.100.100.200", "fd00:ec2::254")}


class ScopeError(Exception):
    pass


def classify(address):
    ip = ipaddress.ip_address(address)
    if getattr(ip, "ipv4_mapped", None):
        ip = ip.ipv4_mapped
    if ip in METADATA_ADDRESSES:
        return "metadata"
    if ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved:
        return "blocked"
    if ip.is_loopback or ip.is_private or ip in ipaddress.ip_network("100.64.0.0/10"):
        return "local"
    return "public"


def parse_target(entry):
    url = urllib.parse.urlsplit(entry.get("url", ""))
    if url.scheme not in ("http", "https") or not url.hostname:
        raise ScopeError("only http and https URLs are accepted")
    if url.username or url.password:
        raise ScopeError("URLs with credentials are not accepted")
    host = url.hostname.rstrip(".").lower()
    if host in METADATA_HOSTS:
        raise ScopeError(f"{host} is a cloud metadata service")
    return {"url": urllib.parse.urlunsplit((url.scheme, url.netloc, url.path or "/", url.query, "")),
            "scheme": url.scheme, "host": host, "port": url.port or (443 if url.scheme == "https" else 80),
            "path": (url.path or "/") + (f"?{url.query}" if url.query else ""), "local": bool(entry.get("localNetwork"))}


def resolve_and_validate(target):
    """Validated on the execution side: every resolved address must be allowed."""
    try:
        infos = socket.getaddrinfo(target["host"], target["port"], type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        raise ScopeError(f"{target['host']} did not resolve: {error}")
    addresses = sorted({info[4][0] for info in infos})
    for address in addresses:
        kind = classify(address)
        if kind in ("metadata", "blocked"):
            raise ScopeError(f"{target['host']} resolved to {address} ({kind}); never contacted")
        if kind == "local" and not target["local"]:
            raise ScopeError(f"{target['host']} resolved to local address {address} but was not marked local-network")
    return addresses[0]


class Job:
    def __init__(self, owner, module, targets):
        self.id = str(uuid.uuid4())
        self.owner = owner
        self.module = module
        self.targets = targets
        self.status = "running"
        self.started = time.time()
        self.ended = None
        self.checks = []
        self.errors = []
        self.not_tested = []
        self.cancel = threading.Event()

    def reference(self):
        return {"id": self.id, "module": self.module, "status": self.status, "startedAt": self.started,
                "endedAt": self.ended, "findingCount": 0}

    def report(self):
        return {"contractVersion": CONTRACT_VERSION, "id": self.id, "module": self.module, "moduleVersion": "harness-0.1",
                "location": {"kind": "pairedServer", "name": "development harness"},
                "scope": [t["url"] for t in self.targets], "status": self.status, "startedAt": self.started,
                "endedAt": self.ended, "checks": self.checks, "findings": [], "notTested": self.not_tested,
                "errors": self.errors,
                "limitations": ["Development harness: only the reachability check is implemented; it is not HCG Server."]}


def run_reachability(job):
    for target in job.targets:
        if job.cancel.is_set():
            job.not_tested.append(f"{target['url']}: cancelled before it was reached")
            continue
        try:
            address = resolve_and_validate(target)
            factory = HTTPSConnection if target["scheme"] == "https" else HTTPConnection
            connection = factory(address if target["scheme"] == "http" else target["host"], target["port"], timeout=REQUEST_TIMEOUT)
            connection.request("GET", target["path"], headers={"Host": target["host"], "User-Agent": "HCG-SecurityLab-Harness/0.1"})
            response = connection.getresponse()
            location = response.getheader("Location")
            detail = f"HTTP {response.status}" + (f"; redirect to {location} reported, not followed" if location else "")
            job.checks.append({"id": f"reachability@{target['host']}", "outcome": "passed", "detail": detail})
            connection.close()
        except ScopeError as error:
            job.checks.append({"id": f"reachability@{target['host']}", "outcome": "unsupported", "detail": str(error)})
            job.errors.append(str(error))
        except Exception as error:  # connectivity problems are execution failures, never findings
            job.checks.append({"id": f"reachability@{target['host']}", "outcome": "failedToExecute", "detail": str(error)})
    job.status = "cancelled" if job.cancel.is_set() else "completed"
    job.ended = time.time()


class Harness:
    def __init__(self, devices):
        self.devices = devices  # token -> device name
        self.jobs = {}
        self.lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    harness = None

    def log_message(self, fmt, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, code, message):
        self.send_json(status, {"error": message, "code": code})

    def device(self):
        header = self.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        return self.harness.devices.get(token)

    def owned_job(self, device, job_id):
        with self.harness.lock:
            job = self.harness.jobs.get(job_id)
        # Another device's job is indistinguishable from a missing one.
        return job if job and job.owner == device else None

    def do_GET(self):
        device = self.device()
        if not device:
            return self.error(401, "unauthorized", "a paired device credential is required")
        path = self.path.split("?")[0].rstrip("/")
        if path == "/security-lab/v1/capabilities":
            return self.send_json(200, {"contractVersion": CONTRACT_VERSION, "server": "development harness", "modules": [
                {"module": "exposureCheck", "status": "partial", "checks": ["reachability"], "maxTargets": MAX_TARGETS},
                {"module": "secretScanner", "status": "unsupported", "reason": "no approved server workspaces in the harness"},
                {"module": "authDefenseLab", "status": "unsupported",
                 "reason": "external authentication testing needs a separate authorised-test configuration"}]})
        if path == "/security-lab/v1/assessments":
            with self.harness.lock:
                mine = [job.reference() for job in self.harness.jobs.values() if job.owner == device]
            return self.send_json(200, {"assessments": mine})
        parts = path.split("/")
        if len(parts) == 5 and parts[3] == "assessments":
            job = self.owned_job(device, parts[4])
            return self.send_json(200, job.reference()) if job else self.error(404, "not_found", "no such assessment")
        if len(parts) == 6 and parts[3] == "assessments" and parts[5] == "report":
            job = self.owned_job(device, parts[4])
            if not job:
                return self.error(404, "not_found", "no such assessment")
            if job.status == "running":
                return self.error(409, "not_finished", "the assessment is still running")
            return self.send_json(200, job.report())
        return self.error(404, "not_found", "unknown endpoint")

    def do_POST(self):
        device = self.device()
        if not device:
            return self.error(401, "unauthorized", "a paired device credential is required")
        path = self.path.split("?")[0].rstrip("/")
        length = min(int(self.headers.get("Content-Length") or 0), 65536)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.error(400, "bad_request", "invalid JSON")
        if path == "/security-lab/v1/assessments":
            module = body.get("module")
            if module != "exposureCheck":
                return self.error(409, "unsupported_module", f"{module} is not supported by this server")
            if body.get("authorizationConfirmed") is not True:
                return self.error(400, "authorization_required", "the requester must confirm authorisation for every target")
            entries = body.get("scope", {}).get("targets", [])
            if not entries or len(entries) > MAX_TARGETS:
                return self.error(400, "bad_scope", f"between 1 and {MAX_TARGETS} targets are required")
            try:
                targets = [parse_target(entry) for entry in entries]
            except ScopeError as error:
                return self.error(400, "bad_scope", str(error))
            job = Job(device, module, targets)
            with self.harness.lock:
                self.harness.jobs[job.id] = job
            threading.Thread(target=run_reachability, args=(job,), daemon=True).start()
            return self.send_json(202, job.reference())
        parts = path.split("/")
        if len(parts) == 6 and parts[3] == "assessments" and parts[5] == "cancel":
            job = self.owned_job(device, parts[4])
            if not job:
                return self.error(404, "not_found", "no such assessment")
            job.cancel.set()
            return self.send_json(202, job.reference())
        return self.error(404, "not_found", "unknown endpoint")


def serve(port, devices):
    Handler.harness = Harness(devices)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=7700)
    parser.add_argument("--device", action="append", default=[], help="NAME:TOKEN for a simulated paired device")
    args = parser.parse_args()
    devices = {}
    for item in args.device:
        name, _, token = item.partition(":")
        if not name or len(token) < 8:
            parser.error("--device needs NAME:TOKEN with a token of at least 8 characters")
        devices[token] = name
    if not devices:
        parser.error("add at least one --device")
    server = serve(args.port, devices)
    print(f"Security Lab contract harness on http://127.0.0.1:{args.port}/security-lab/v1 (development only)", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
