#!/usr/bin/env python3
"""Writes small synthetic pcap and pcapng files for manual import testing.

Every packet is fabricated and uses documentation-only address ranges
(RFC 5737 / RFC 3849). Never commit real captured traffic to this repository.

  python3 Tools/make_synthetic_capture.py out_dir
"""
import struct
import sys
from pathlib import Path

MAC_A, MAC_B = bytes.fromhex("020000000001"), bytes.fromhex("020000000002")


def checksum(data):
    total = sum(struct.unpack(">%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def ipv4(src, dst, proto, payload):
    header = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), 0x1234, 0, 64, proto, 0, bytes(src), bytes(dst))
    return header[:10] + struct.pack(">H", checksum(header)) + header[12:] + payload


def tcp(sport, dport, seq, ack, flags, payload=b""):
    return struct.pack(">HHIIBBHHH", sport, dport, seq, ack, 0x50, flags, 65535, 0, 0) + payload


def udp(sport, dport, payload=b""):
    return struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload


def eth(payload, ethertype=0x0800, src=MAC_A, dst=MAC_B):
    return dst + src + struct.pack(">H", ethertype) + payload


def frames():
    client, server, resolver = (192, 0, 2, 10), (198, 51, 100, 20), (192, 0, 2, 53)
    http = b"GET /health HTTP/1.1\r\nHost: test.example\r\n\r\n"
    return [
        eth(ipv4(client, resolver, 17, udp(53124, 53, bytes(29)))),
        eth(ipv4(client, server, 6, tcp(50000, 80, 1000, 0, 0x02))),
        eth(ipv4(server, client, 6, tcp(80, 50000, 5000, 1001, 0x12)), src=MAC_B, dst=MAC_A),
        eth(ipv4(client, server, 6, tcp(50000, 80, 1001, 5001, 0x10))),
        eth(ipv4(client, server, 6, tcp(50000, 80, 1001, 5001, 0x18, http))),
        eth(ipv4(client, server, 1, bytes([8, 0, 0, 0, 0, 1, 0, 1]))),
    ]


def pcap(packets, start=1_700_000_000):
    out = struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1)
    for index, packet in enumerate(packets):
        micros = index * 125_000
        out += struct.pack("<IIII", start + micros // 1_000_000, micros % 1_000_000, len(packet), len(packet)) + packet
    return out


def pcapng(packets, start=1_700_000_000):
    def block(kind, body):
        body += bytes((4 - len(body) % 4) % 4)
        length = 12 + len(body)
        return struct.pack("<II", kind, length) + body + struct.pack("<I", length)

    out = block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1))
    out += block(1, struct.pack("<HHI", 1, 0, 262144))
    for index, packet in enumerate(packets):
        ts = start * 1_000_000 + index * 125_000
        out += block(6, struct.pack("<IIIII", 0, ts >> 32, ts & 0xFFFFFFFF, len(packet), len(packet)) + packet)
    return out


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    packets = frames()
    (out / "synthetic.pcap").write_bytes(pcap(packets))
    (out / "synthetic.pcapng").write_bytes(pcapng(packets))
    (out / "truncated.pcap").write_bytes(pcap(packets)[:-7])
    (out / "not-a-capture.pcap").write_bytes(b"This file is not a packet capture.\n")
    print("wrote", ", ".join(sorted(p.name for p in out.iterdir())), "to", out)


if __name__ == "__main__":
    main()
