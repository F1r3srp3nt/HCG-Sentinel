# Security Lab on HCG Server: contract (v1, proposed)

**Status: designed, not implemented in HCG Server.** HCG Server 0.1 has no assessment interface, and its pairing
connects Mac agents to each other. The iPhone/iPad companion is planned (HCG Server `docs/API.md`) but not built, so
Sentinel cannot pair with a server today. Sentinel therefore runs every assessment on the device, and its Execution
location card shows the server option as unavailable. This document is the contract for HCG Server to implement.
`Tools/hcg_server_assessment_harness.py` is a development harness that exercises it.

## Roles

| Product | Role in Security Lab |
| --- | --- |
| Sentinel | Configures assessments, shows evidence, findings and reports. |
| HCG Server | Executes supported, heavier assessments on explicitly authorised targets and server workspaces. |
| HCG Terminal | User-initiated technical investigation. Sentinel does not hand it commands. |
| Nexus | Shows assessment status and opens reports in Sentinel (`hcgsentinel://report/<id>`). |
| HCG Connect | Identity, pairing and permissions. Not configured yet: HCG Server's `internal/hcgconnect` reports `not-configured`. |

Pairing a server or signing in with HCG Connect never enables an assessment by itself. Each module needs (1) the
server's capability report saying it is supported, (2) a permission granted to this device for that module, and
(3) an explicit scope in the request.

## Transport and identity

The contract reuses HCG Server's existing device API instead of creating a new account or connection service. It sits
on `/peer/v1` with **mutual TLS 1.3 and pinned key fingerprints**, the same trust model as file access. The companion
enrols as device kind `companion`, as HCG Server's `docs/API.md` plans. The new endpoints are an additive v1 section
under `/peer/v1/security-lab/` and need new per-device permissions:

| Permission | Allows |
| --- | --- |
| `securityLab.read` | Capability report, own assessments and own reports |
| `securityLab.exposureCheck` | Starting Exposure Check on targets in the request |
| `securityLab.secretScan` | Scanning **owner-approved storage roots**, read-only (the existing `os.Root` confinement) |
| `securityLab.authTesting.external` | Reserved. Requires the authorised-test configuration in SECURITY_LAB.md. Never granted by default. |

The development harness stands in for mutual TLS with a bearer token per simulated device and is reached at
`http://127.0.0.1:<port>/security-lab/v1`. That shortcut is for development only.

## Endpoints

Errors use HCG Server's format: `{"error": "...", "code": "<stable_code>"}`.

| Method and path | Purpose | Notes |
| --- | --- | --- |
| `GET capabilities` | Modules this server can run | `{"contractVersion":1,"modules":[{"module":"exposureCheck","status":"supported"\|"partial"\|"unsupported","checks":[...],"reason":...}]}`. Sentinel enables only modules marked supported or partial, and only the checks listed. |
| `POST assessments` | Start | Body: `{"module", "authorizationConfirmed": true, "scope": {...}, "limits": {...}}`. Returns `202` with a reference. `409 unsupported_module`, `400 bad_scope`, `400 authorization_required`, `403 permission_denied`. |
| `GET assessments` | List | The requesting device's own references only. |
| `GET assessments/{id}` | Status | `404` for missing assessments **and** for other devices' assessments. |
| `POST assessments/{id}/cancel` | Cancel | The server stops at the next unit of work and keeps partial results. |
| `GET assessments/{id}/report` | Full report | Same shape as Sentinel's `SecurityAssessmentRecord`, with `location: {"kind":"pairedServer","name","deviceID"}`. `409 not_finished` while running. |

**References versus reports.** A reference holds id, module, status, times, finding count and highest severity.
It never contains scope, evidence or findings, so it is safe to show in Nexus and to store with account metadata.
Report contents are fetched only by the device that started the assessment, with `securityLab.read`, and are kept
separate from account metadata.

## Execution-side rules (the server must enforce these itself)

1. The scope comes only from the request. Discovered hosts, redirect targets and certificate names are never added.
2. Every resolved address is validated before connecting. Metadata, link-local, multicast, unspecified and reserved addresses are always refused. Private and loopback addresses are allowed only for targets marked `localNetwork`. Redirects are reported and never followed outside the scope.
3. The connection must go to the validated address (connect to the IP, send the original `Host` and SNI), so a DNS change between check and connect cannot redirect it.
4. Limits are enforced server-side: requests per target, spacing, timeouts, response size, total runtime, and for secret scans the files, bytes, archive entries and inflation ratio.
5. Secret scans run only inside owner-approved storage roots, read-only, never follow symlinks, never upload repositories elsewhere, and store only redacted evidence and keyed fingerprints.
6. Unavailable checks are reported as `unsupported` or `failedToExecute`, never as passed.
7. No credential found by a scan is ever tested against any service.

## Harness coverage (`Tools/test_hcg_server_assessment_harness.py`)

- **Authentication:** a paired-device credential is required.
- **Capability report:** honest. Only the reachability check of `exposureCheck` is implemented; the other modules are `unsupported`.
- **Other devices:** cannot read, list or cancel your assessments (`404`).
- **Scope, on the execution side:** metadata hosts and addresses, credentials in URLs, other schemes and loopback without the local flag are refused.
- **Redirects:** reported and never requested.
- **Cancellation:** cancelling a running assessment stops it.

## Not yet decided (needs HCG Server owners)

- Whether companions reach `/peer/v1` over the LAN only or through the planned relay.
- The UI on the Mac for granting `securityLab.*` permissions and approving workspaces.
- Retention of server-side reports, and whether a companion may delete them.
- How HCG Connect identities map to device permissions once HCG Connect is configured.
