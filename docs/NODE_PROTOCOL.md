# Sentinel Node Protocol (SNP) — version 2

SNP connects Radio Lab to an **external analysis node**: a computer you operate that has radio hardware (for
example an SDR, or a Wi-Fi adapter on a Mac or Linux machine). The iPhone or iPad never receives RF itself; it only
displays what an **authenticated** node sends.

Reference client: `SentinelCore/Sources/SentinelCore/Radio/` (`NodeCodec`, `NodeAuth`, `RadioNodeSession`).
Development mock: `Tools/mock_radio_node.py` (always declares itself simulated).

## What changed from version 1

Version 1 sent an optional token in the clear and accepted the node's capability report without proof. Version 2:

* requires a pre-shared **pairing key** (at least 32 random bytes) on both sides;
* the node proves it holds the key in a challenge that **also covers its capability report**, so capabilities
  cannot be forged or altered in transit;
* the client proves it holds the key before the node starts the session;
* every message after the handshake carries a **sequence number and an HMAC**, so messages cannot be forged,
  replayed, reordered or dropped unnoticed;
* adds the `wifi_scan` feature.

The app accepts **only version 2**. A version 1 node is rejected with a message asking for an update. Radio Lab
stays disconnected — and shows nothing from a node — until the authenticated capability handshake completes.

## Scope and non-goals

* Receive-side analysis only. There is no transmit, replay, jamming, injection, monitor-mode switching, tuning for
  transmission or baseband operation, and a node must reject unknown message types.
* Feature strings the client does not recognise are ignored; they never enable a control.
* No arbitrary command execution. Every message has a fixed schema.
* A real node implementation does not exist yet. Until one is written and attached to hardware, "Spectrum from node
  hardware" and "Nearby Wi-Fi discovery" cannot be verified.

## Transport

* WebSocket, text frames, UTF-8 JSON. Binary frames are a protocol error.
* `ws://` only on a local network you control (iOS permits plain connections to local addresses only); `wss://`
  everywhere else. The HMACs protect integrity, not confidentiality: use `wss://` if the data is sensitive.
* Maximum message size: 1 MiB.

## Envelope

```json
{ "v": 2, "type": "<message type>", "seq": 7, "payload": "<JSON text>", "mac": "<base64>" }
```

`payload` is a **string containing JSON**, so the MAC covers exact bytes regardless of how either side formats JSON.
`seq` and `mac` are absent on `hello` and on an unauthenticated `error`.

## Cryptography

`K` = pairing key. `HMAC` = HMAC-SHA256. `cn`, `nn` = the client's and node's 32-byte nonces **as their base64
strings**. Strings are joined with `|`:

| Value | Definition |
| --- | --- |
| Challenge MAC | `HMAC(K, "snp-v2|challenge|" + cn + "|" + challengePayloadText)` |
| Client proof | `HMAC(K, "snp-v2|authenticate|" + cn + "|" + nn)` |
| Session key `S` | `HMAC(K, "snp-v2|session|" + cn + "|" + nn)` |
| Message MAC | `HMAC(S, "snp-v2|message|" + sender + "|" + seq + "|" + type + "|" + payloadText)` where `sender` is `node` or `client` |

Comparisons are constant-time. Sequence numbers start at 1 in each direction and must increase by exactly 1.

## Handshake

| # | Direction | Message |
| --- | --- | --- |
| 1 | client → node | `hello` payload `{protocolVersions:[2], client, clientVersion, clientNonce}` |
| 2 | node → client | `challenge` payload `{protocolVersion:2, nodeNonce, node:{nodeName, nodeSoftware, simulated}, capabilities:{features, hardware, maxBins}}`, `mac` = challenge MAC |
| 3 | client → node | `authenticate`, `mac` = client proof — sent only if step 2 verified |
| 4 | node → client | `ready` (seq 1, message MAC) — the session is now connected |

A node that cannot authenticate the client sends `error` (no MAC) and closes. The client sends nothing further to a
node whose challenge fails verification. The whole handshake must finish within 10 seconds.

## Session messages (all with `seq` and `mac`)

Client → node:

| type | payload |
| --- | --- |
| `get_status` | `{}` |
| `subscribe_spectrum` | `{hardwareID, centerFrequencyHz, spanHz, bins, maxFramesPerSecond}` |
| `unsubscribe_spectrum` | `{}` |
| `get_wifi_scan` | `{hardwareID?}` |
| `ping` | `{}` |
| `bye` | `{}` |

Node → client:

| type | payload |
| --- | --- |
| `status` | `{state, hardwarePresent, activeHardwareID?, message?}` |
| `spectrum_frame` | `{sequence, timestamp, centerFrequencyHz, spanHz, unit:"dBFS", powers:[…]}` |
| `wifi_scan` | `{scannedAt, interface, networks:[{ssid?, bssid, channel, frequencyMHz, rssiDbm, security}]}` |
| `error` | `{code, message}` |
| `pong` | `{}` |

Recognised features: `spectrum`, `wifi_scan`.

## Validation performed by the client

* Any message failing its MAC or sequence check, any unauthenticated message after the handshake, and any message
  type out of place **ends the session**; nothing it carried is used.
* Capabilities: at most 32 hardware entries and 64 features; frequency ranges must be finite and ordered.
* `spectrum_frame`: 16–8192 finite values within −300…100, unit `dBFS`, span > 0. Ignored unless a stream was
  requested.
* `wifi_scan`: at most 512 networks; BSSID `xx:xx:xx:xx:xx:xx`; SSID ≤ 32 bytes; channel 1–233; frequency
  2400–7125 MHz; RSSI −120…0 dBm; security one of `open, wep, wpa, wpa2, wpa3, wpa2-enterprise, wpa3-enterprise,
  owe, unknown`. Ignored unless a scan was requested; a scan request times out after 30 seconds and can be cancelled.

## Honesty requirements for nodes

* A node that generates test data must set `simulated: true`. The app then labels its spectrum and scan results as
  simulated and never marks hardware spectrum or nearby Wi-Fi discovery as verified.
* A node without the relevant hardware must report `hardwarePresent: false` and omit the feature.

## Pairing

The node generates the key (the mock prints one; `--key HEX` sets it) and the user enters it in Sentinel's Settings,
where it is stored in the Keychain. The key itself is never sent.

## Versioning

Additive, optional payload fields may be added within version 2; receivers ignore unknown fields. A new message type
or a change of meaning requires a new version.
