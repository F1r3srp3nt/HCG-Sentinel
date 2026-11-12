#!/usr/bin/env python3
"""Mock Sentinel Node Protocol v1 node for development (standard library only).

This is NOT a radio. It generates synthetic spectrum frames and always
announces itself with "simulated": true, so HCG Sentinel labels its data as
simulated and never marks radio hardware as verified.

  python3 Tools/mock_radio_node.py --host 127.0.0.1 --port 8765 [--token SECRET] [--no-hardware]

Connect from the app with ws://<host>:8765/
"""
import argparse
import base64
import hashlib
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


class Node(socketserver.BaseRequestHandler):
    def send(self, kind, payload=None):
        message = {"v": 1, "type": kind}
        if payload is not None:
            message["payload"] = payload
        write_frame(self.request, self.lock, json.dumps(message).encode())

    def handle(self):
        self.lock = threading.Lock()
        self.stream = None
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
        greeted = False
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
                    message = json.loads(payload)
                    kind, body = message["type"], message.get("payload") or {}
                    if message.get("v") != 1:
                        raise ValueError
                except (ValueError, KeyError, TypeError):
                    self.send("error", {"code": "bad_message", "message": "Malformed envelope."})
                    break
                if not greeted:
                    if kind != "hello" or 1 not in body.get("protocolVersions", []):
                        self.send("error", {"code": "bad_hello", "message": "Expected a version 1 hello."})
                        break
                    if ARGS.token and body.get("authToken") != ARGS.token:
                        self.send("error", {"code": "unauthorized", "message": "Token rejected."})
                        break
                    greeted = True
                    self.send("hello_ack", {"protocolVersion": 1, "nodeName": "mock-node",
                                            "nodeSoftware": "mock_radio_node.py 1.0", "simulated": True})
                elif kind == "get_capabilities":
                    hardware = [] if ARGS.no_hardware else [{
                        "id": "sim0", "driver": "simulated", "description": "Synthetic signal generator (not a radio)",
                        "minFrequencyHz": 24e6, "maxFrequencyHz": 1.766e9, "maxSpanHz": 2.4e6}]
                    self.send("capabilities", {"features": ["spectrum"], "hardware": hardware, "maxBins": 2048})
                elif kind == "get_status":
                    self.send("status", {"state": "streaming" if self.stream else "idle",
                                         "hardwarePresent": not ARGS.no_hardware})
                elif kind == "subscribe_spectrum":
                    self.stop_stream()
                    self.stream = threading.Event()
                    threading.Thread(target=self.run_stream, args=(body, self.stream), daemon=True).start()
                elif kind == "unsubscribe_spectrum":
                    self.stop_stream()
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


def main():
    global ARGS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", default="")
    parser.add_argument("--no-hardware", action="store_true", help="report no radio hardware")
    ARGS = parser.parse_args()
    with Server((ARGS.host, ARGS.port), Node) as server:
        print(f"Mock SNP v1 node (SIMULATED) on ws://{ARGS.host}:{ARGS.port}/", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
