#!/usr/bin/env python3
"""Mock Sentinel Node Protocol v2 node for development (standard library only).

This is NOT a radio and NOT a Wi-Fi scanner. It generates synthetic spectrum frames and a fixed, fabricated list of
Wi-Fi networks, and always announces itself with "simulated": true, so HCG Sentinel labels its data as simulated and
never marks radio hardware or Wi-Fi discovery as verified.

Version 2 requires a shared pairing key (at least 32 bytes, given as hex). Without --key a new one is generated and
printed; enter it in Sentinel's Radio Lab.

  python3 Tools/mock_radio_node.py --host 127.0.0.1 --port 8765 [--key HEX] [--no-hardware] [--no-wifi]

Connect from the app with ws://<host>:8765/
"""
import argparse
import base64
import hashlib
import hmac
import os
import json
import math
import random
import socketserver
import struct
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ARGS = None


def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def read_frame(sock):
    b1, b2 = recv_exact(sock, 2)
    opcode, length = b1 & 0x0F, b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    if length > 1 << 20:
        raise ConnectionError("frame too large")
    mask = recv_exact(sock, 4) if b2 & 0x80 else b"\0\0\0\0"
    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(sock, length)))
    return opcode, payload


def write_frame(sock, lock, payload, opcode=1):
    header = bytes([0x80 | opcode])
    if len(payload) < 126:
        header += bytes([len(payload)])
    elif len(payload) < 65536:
        header += bytes([126]) + struct.pack(">H", len(payload))
    else:
        header += bytes([127]) + struct.pack(">Q", len(payload))
    with lock:
        sock.sendall(header + payload)


def spectrum(center, span, bins, t):
    out = []
    for i in range(bins):
        x = i / (bins - 1)
        level = -95 + random.uniform(-2.5, 2.5)
        level += 45 * math.exp(-((x - 0.3) ** 2) / 0.0004)
        level += 30 * math.exp(-((x - (0.65 + 0.05 * math.sin(t))) ** 2) / 0.001)
        out.append(round(level, 1))
    return out


CONTEXT = "snp-v2"


def mac(key, *parts):
    return hmac.new(key, "|".join((CONTEXT,) + parts).encode(), hashlib.sha256).digest()


def b64(data):
    return base64.b64encode(data).decode()


FAKE_NETWORKS = [  # Fabricated; documentation-style BSSIDs (locally administered).
    {"ssid": "SIMULATED-LabNet", "bssid": "02:00:00:00:10:01", "channel": 6, "frequencyMHz": 2437, "rssiDbm": -47, "security": "wpa2"},
    {"ssid": "SIMULATED-Guest", "bssid": "02:00:00:00:10:02", "channel": 11, "frequencyMHz": 2462, "rssiDbm": -66, "security": "open"},
    {"ssid": None, "bssid": "02:00:00:00:10:03", "channel": 36, "frequencyMHz": 5180, "rssiDbm": -72, "security": "wpa3"},
]


class Node(socketserver.BaseRequestHandler):
    def send_raw(self, envelope):
        write_frame(self.request, self.lock, json.dumps(envelope, separators=(",", ":")).encode())

    def send(self, kind, payload=None):
        """Authenticated session message."""
        text = json.dumps(payload if payload is not None else {}, separators=(",", ":"), sort_keys=True)
        with self.seq_lock:
            self.seq += 1
            seq = self.seq
            tag = mac(self.session_key, "message", "node", str(seq), kind, text)
            self.send_raw({"v": 2, "type": kind, "seq": seq, "payload": text, "mac": b64(tag)})

    def reject(self, code, message):
        self.send_raw({"v": 2, "type": "error", "payload": json.dumps({"code": code, "message": message})})

    def handle(self):
        self.lock = threading.Lock()
        self.seq_lock = threading.Lock()
        self.stream = None
        self.seq = 0
        self.client_seq = 0
        self.session_key = b""
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self.request.recv(4096)
            if not chunk or len(request) > 16384:
                return
            request += chunk
        headers = {}
        for line in request.decode("latin-1").split("\r\n")[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        key = headers.get("sec-websocket-key")
        if not key:
            self.request.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        print("client connected", self.client_address, flush=True)
        phase = "hello"
        client_nonce = node_nonce = ""
        try:
            while True:
                opcode, payload = read_frame(self.request)
                if opcode == 8:
                    break
                if opcode == 9:
                    write_frame(self.request, self.lock, payload, opcode=10)
                    continue
                if opcode != 1:
                    continue
                try:
                    envelope = json.loads(payload)
                    kind = envelope["type"]
                    if envelope.get("v") != 2:
                        raise ValueError
                except (ValueError, KeyError, TypeError):
                    self.reject("bad_message", "Expected a version 2 envelope.")
                    break
                if phase == "hello":
                    try:
                        hello = json.loads(envelope["payload"])
                        client_nonce = hello["clientNonce"]
                        assert kind == "hello" and 2 in hello["protocolVersions"] and len(base64.b64decode(client_nonce)) == 32
                    except Exception:
                        self.reject("bad_hello", "Expected a version 2 hello.")
                        break
                    node_nonce = b64(os.urandom(32))
                    hardware = [] if ARGS.no_hardware else [{
                        "id": "sim0", "driver": "simulated", "description": "Synthetic signal generator (not a radio)",
                        "minFrequencyHz": 24e6, "maxFrequencyHz": 1.766e9, "maxSpanHz": 2.4e6}]
                    features = ["spectrum"] + ([] if ARGS.no_wifi else ["wifi_scan"])
                    body = json.dumps({"protocolVersion": 2, "nodeNonce": node_nonce,
                                       "node": {"nodeName": "mock-node", "nodeSoftware": "mock_radio_node.py 2.0", "simulated": True},
                                       "capabilities": {"features": features, "hardware": hardware, "maxBins": 2048}},
                                      separators=(",", ":"), sort_keys=True)
                    self.send_raw({"v": 2, "type": "challenge", "payload": body,
                                   "mac": b64(mac(KEY, "challenge", client_nonce, body))})
                    phase = "authenticate"
                    continue
                if phase == "authenticate":
                    expected = mac(KEY, "authenticate", client_nonce, node_nonce)
                    try:
                        given = base64.b64decode(envelope.get("mac") or "")
                    except Exception:
                        given = b""
                    if kind != "authenticate" or not hmac.compare_digest(expected, given):
                        self.reject("authentication_failed", "Client proof rejected.")
                        break
                    self.session_key = mac(KEY, "session", client_nonce, node_nonce)
                    phase = "session"
                    self.send("ready")
                    continue
                # Session: every client message must carry the next sequence number and a valid MAC.
                seq, text = envelope.get("seq"), envelope.get("payload") or ""
                try:
                    given = base64.b64decode(envelope.get("mac") or "")
                except Exception:
                    given = b""
                expected = mac(self.session_key, "message", "client", str(seq), kind, text)
                if seq != self.client_seq + 1 or not hmac.compare_digest(expected, given):
                    print("rejected unauthenticated or out-of-order message", flush=True)
                    break
                self.client_seq = seq
                body = json.loads(text) if text else {}
                if kind == "get_status":
                    self.send("status", {"state": "streaming" if self.stream else "idle", "hardwarePresent": not ARGS.no_hardware})
                elif kind == "subscribe_spectrum":
                    self.stop_stream()
                    self.stream = threading.Event()
                    threading.Thread(target=self.run_stream, args=(body, self.stream), daemon=True).start()
                elif kind == "unsubscribe_spectrum":
                    self.stop_stream()
                elif kind == "get_wifi_scan":
                    if ARGS.no_wifi:
                        self.send("error", {"code": "unsupported", "message": "Wi-Fi scanning is disabled on this node."})
                    else:
                        self.send("wifi_scan", {"scannedAt": time.time(), "interface": "sim0", "networks": FAKE_NETWORKS})
                elif kind == "ping":
                    self.send("pong")
                elif kind == "bye":
                    break
                else:
                    self.send("error", {"code": "unknown_type", "message": "Unsupported message type."})
        except (ConnectionError, OSError):
            pass
        finally:
            self.stop_stream()
            print("client disconnected", self.client_address, flush=True)

    def stop_stream(self):
        if self.stream:
            self.stream.set()
            self.stream = None

    def run_stream(self, body, stop):
        bins = max(16, min(int(body.get("bins", 512)), 2048))
        rate = max(0.5, min(float(body.get("maxFramesPerSecond", 5)), 30))
        center, span = float(body.get("centerFrequencyHz", 1e8)), float(body.get("spanHz", 2e6))
        sequence = 0
        try:
            while not stop.wait(1 / rate):
                sequence += 1
                now = time.time()
                self.send("spectrum_frame", {"sequence": sequence, "timestamp": now, "centerFrequencyHz": center,
                                             "spanHz": span, "unit": "dBFS", "powers": spectrum(center, span, bins, now)})
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


KEY = b""


def main():
    global ARGS, KEY
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--key", default="", help="pairing key as hex (64+ digits); generated when omitted")
    parser.add_argument("--no-hardware", action="store_true", help="report no radio hardware")
    parser.add_argument("--no-wifi", action="store_true", help="do not offer the wifi_scan feature")
    ARGS = parser.parse_args()
    KEY = bytes.fromhex(ARGS.key) if ARGS.key else os.urandom(32)
    if len(KEY) < 32:
        parser.error("the pairing key must be at least 32 bytes (64 hex digits)")
    with Server((ARGS.host, ARGS.port), Node) as server:
        print(f"Mock SNP v2 node (SIMULATED) on ws://{ARGS.host}:{ARGS.port}/", flush=True)
        print(f"Pairing key: {KEY.hex()}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
