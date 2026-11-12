# Sentinel Node Protocol (SNP) — version 1

SNP connects the Radio Lab to an **external analysis node**: a computer you operate that has radio hardware (for
example an SDR on a Mac, Linux box or single-board computer). The iPhone or iPad never receives RF itself; it only
displays what the node sends.

Reference client: `SentinelCore/Sources/SentinelCore/Radio/` (`NodeCodec`, `RadioNodeSession`).
Development mock: `Tools/mock_radio_node.py` (always declares itself simulated).

## Scope and non-goals

* Version 1 is **receive-side analysis only**. It defines no transmit, replay, jamming or baseband operation, and a
  node must reject unknown message types.
* No arbitrary command execution. Every message has a fixed schema.
* A real node implementation does not exist yet. Until one is written and attached to hardware, "Spectrum from node
  hardware" cannot be verified.

## Transport

* WebSocket, text frames, UTF-8 JSON. Binary frames are a protocol error.
* `ws://` only on a local network you control (iOS App Transport Security permits local addresses only);
  `wss://` everywhere else.
* Maximum message size: 1 MiB. Larger messages end the session.

## Envelope

```json
{ "v": 1, "type": "<message type>", "id": "<optional correlation id>", "payload": { } }
```

`v` is the protocol version of the message. A receiver that does not support `v` must close the session.

## Session flow

```
client                                   node
  | -- hello ----------------------------> |
  | <-------------------------- hello_ack  |   (or error, then close)
  | -- get_capabilities ----------------> |
  | <------------------------ capabilities |
  | -- get_status ----------------------> |
  | <------------------------------ status |
  | -- subscribe_spectrum --------------> |
  | <---------------------- spectrum_frame |   (repeated)
  | -- unsubscribe_spectrum ------------> |
  | -- bye ------------------------------> |
```

The client sends `hello` first and must receive `hello_ack` within 10 seconds. Any other message before `hello_ack`
(except `error`) is a protocol violation.

## Client → node

| type | payload |
| --- | --- |
| `hello` | `protocolVersions: [Int]`, `client: String`, `clientVersion: String`, `authToken: String?` |
| `get_capabilities` | none |
| `get_status` | none |
| `subscribe_spectrum` | `hardwareID: String`, `centerFrequencyHz: Number`, `spanHz: Number`, `bins: Int`, `maxFramesPerSecond: Number` |
| `unsubscribe_spectrum` | none |
| `ping` | none |
| `bye` | none |

## Node → client

| type | payload |
| --- | --- |
| `hello_ack` | `protocolVersion: Int`, `nodeName: String`, `nodeSoftware: String`, `simulated: Bool` |
| `capabilities` | `features: [String]`, `hardware: [Hardware]`, `maxBins: Int` |
| `status` | `state: "idle" \| "streaming" \| "error"`, `hardwarePresent: Bool`, `activeHardwareID: String?`, `message: String?` |
| `spectrum_frame` | `sequence: Int`, `timestamp: Number` (Unix seconds), `centerFrequencyHz`, `spanHz`, `unit: "dBFS"`, `powers: [Number]` |
| `error` | `code: String`, `message: String` |
| `pong` | none |

`Hardware`: `id`, `driver`, `description`, `minFrequencyHz`, `maxFrequencyHz`, `maxSpanHz`.

Feature strings in version 1: `"spectrum"`.

## Validation performed by the client

* `protocolVersion` in `hello_ack` must be supported (currently only 1).
* `spectrum_frame.powers` must have 16–8192 values, each finite and within −300…100; `unit` must be `"dBFS"`;
  `spanHz` > 0. An invalid frame ends the session.
* Frames are ignored unless a stream was requested.
* Before `subscribe_spectrum` is sent: the node must list the `spectrum` feature, report `hardwarePresent`, list the
  requested hardware, and the requested range, span, bin count and frame rate (≤ 30/s) must be within what it reported.

## Honesty requirements for nodes

* A node that generates test data instead of reading a radio **must** set `simulated: true`. The app then labels
  every frame "SIMULATED NODE DATA" and never marks hardware spectrum as verified.
* A node without attached hardware must report `hardwarePresent: false` and an empty `hardware` list.

## Authentication

`authToken` is an optional pre-shared token configured on the node and stored in the iOS Keychain. It is sent only in
`hello`. It is adequate on a trusted local network or inside TLS (`wss://`); it does not protect a `ws://` link from
someone who can observe that network.

## Versioning

Additive, backward-compatible fields may be added within version 1; receivers ignore unknown payload fields. Any new
message type or change of meaning requires a new version number, offered in `hello.protocolVersions`.
