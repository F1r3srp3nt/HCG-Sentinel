#!/usr/bin/env python3
"""Contract tests for Tools/hcg_server_assessment_harness.py. Standard library only; uses 127.0.0.1 only.

    python3 -m unittest Tools/test_hcg_server_assessment_harness.py
"""
import json
import os
import sys
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hcg_server_assessment_harness as harness  # noqa: E402

TOKEN_A = "dev-token-device-a"
TOKEN_B = "dev-token-device-b"


class Target(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requested = []

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        Target.requested.append(self.path)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://169.254.169.254/latest/meta-data/")
        else:
            self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


class HarnessContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = harness.serve(0, {TOKEN_A: "phone-a", TOKEN_B: "phone-b"})
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}/security-lab/v1"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.target = ThreadingHTTPServer(("127.0.0.1", 0), Target)
        cls.target_url = f"http://127.0.0.1:{cls.target.server_address[1]}"
        threading.Thread(target=cls.target.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.target.shutdown()

    def call(self, method, path, token=TOKEN_A, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        if data:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def start(self, targets, token=TOKEN_A, confirmed=True):
        return self.call("POST", "/assessments", token, {"module": "exposureCheck", "authorizationConfirmed": confirmed,
                                                         "scope": {"targets": targets}})

    def finish(self, job_id, token=TOKEN_A):
        for _ in range(100):
            status, body = self.call("GET", f"/assessments/{job_id}", token)
            if body.get("status") != "running":
                return body
            time.sleep(0.05)
        self.fail("assessment did not finish")

    def test_requires_a_paired_device(self):
        self.assertEqual(self.call("GET", "/capabilities", token=None)[0], 401)
        self.assertEqual(self.call("GET", "/capabilities", token="not-a-device")[0], 401)

    def test_capabilities_are_honest(self):
        status, body = self.call("GET", "/capabilities")
        self.assertEqual(status, 200)
        modules = {m["module"]: m for m in body["modules"]}
        self.assertEqual(modules["exposureCheck"]["status"], "partial")
        self.assertEqual(modules["authDefenseLab"]["status"], "unsupported")
        self.assertEqual(modules["secretScanner"]["status"], "unsupported")
        self.assertEqual(self.call("POST", "/assessments", body={"module": "authDefenseLab", "authorizationConfirmed": True})[0], 409)

    def test_reports_are_private_to_the_requesting_device(self):
        status, job = self.start([{"url": f"{self.target_url}/ok", "localNetwork": True}])
        self.assertEqual(status, 202)
        self.finish(job["id"])
        self.assertEqual(self.call("GET", f"/assessments/{job['id']}/report")[0], 200)
        self.assertEqual(self.call("GET", f"/assessments/{job['id']}/report", TOKEN_B)[0], 404)
        self.assertEqual(self.call("GET", f"/assessments/{job['id']}", TOKEN_B)[0], 404)
        self.assertEqual(self.call("POST", f"/assessments/{job['id']}/cancel", TOKEN_B, {})[0], 404)
        listed = self.call("GET", "/assessments", TOKEN_B)[1]["assessments"]
        self.assertNotIn(job["id"], [item["id"] for item in listed])
        reference = self.call("GET", f"/assessments/{job['id']}")[1]
        self.assertNotIn("scope", reference, "references carry no report contents")

    def test_scope_is_validated_on_the_execution_side(self):
        self.assertEqual(self.start([{"url": "http://169.254.169.254/latest/"}])[0], 202)  # literal: rejected at execution
        status, body = self.start([{"url": "http://metadata.google.internal/"}])
        self.assertEqual((status, body["code"]), (400, "bad_scope"))
        self.assertEqual(self.start([{"url": "https://u:p@example.com/"}])[0], 400)
        self.assertEqual(self.start([{"url": "ftp://example.com/"}])[0], 400)
        self.assertEqual(self.start([{"url": f"{self.target_url}/ok", "localNetwork": True}], confirmed=False)[0], 400)

        status, job = self.start([{"url": "http://169.254.169.254/latest/", "localNetwork": True},
                                  {"url": f"{self.target_url}/ok", "localNetwork": False}])
        report_job = self.finish(job["id"])
        report = self.call("GET", f"/assessments/{report_job['id']}/report")[1]
        outcomes = [check["outcome"] for check in report["checks"]]
        self.assertEqual(outcomes, ["unsupported", "unsupported"], "metadata always blocked; loopback needs the local flag")

    def test_redirects_are_reported_not_followed(self):
        Target.requested.clear()
        status, job = self.start([{"url": f"{self.target_url}/redirect", "localNetwork": True}])
        self.finish(job["id"])
        report = self.call("GET", f"/assessments/{job['id']}/report")[1]
        self.assertIn("not followed", report["checks"][0]["detail"])
        self.assertEqual(Target.requested, ["/redirect"])

    def test_cancellation(self):
        status, job = self.start([{"url": f"{self.target_url}/ok", "localNetwork": True}] * 5)
        self.call("POST", f"/assessments/{job['id']}/cancel", body={})
        final = self.finish(job["id"])
        self.assertIn(final["status"], ("cancelled", "completed"))


if __name__ == "__main__":
    unittest.main()
