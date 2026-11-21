# HCG Connect readiness

Reviewed 21 November 2026 against this repository, HCG Store (`web-hcg-store/docs/MAIN-SITE-INTEGRATION.md`, the main
site's recorded answers of 16 November), HCG Executable Maker (`docs/hcg-connect/`) and HCG Server
(`internal/hcgconnect`).

## Answer in one table

| Question | Finding |
| --- | --- |
| Does Sentinel have a registered HCG Connect client? | **No.** No client ID, registration, redirect URI or sign-in code exists in this repository, and the main site's records list none for Sentinel. |
| Does Sentinel have a product ID? | **No.** The main site lists `hcg-sentinel` as "not registered, D3: to register". HCG Store's catalogue keeps Sentinel unmapped (`registry.centralId: null`, edition `app` without a central key). |
| Is there an entitlement contract for Sentinel? | **No.** There are no Sentinel feature keys, licences or `/check` rules. The general contract exists (Ecosystem API `/me`, `POST /check`), but nothing in it names Sentinel. |
| Can the documented flow be verified for Sentinel today? | **No, there is nothing to verify end to end** without a client. What can be checked without an account is HCG Connect's own configuration (issuer, keys, refusal of unknown clients, `/me` needing a token). This session's network does not reach HCG, so those checks run in GitHub Actions: **Actions › HCG Connect readiness (manual) › Run workflow** (`.github/workflows/connect-readiness.yml`, read-only, no credentials). Run 44859350703 on 21 November 2026: results below. |
| Does Sentinel need an account to work? | **No, and it must stay that way.** Every current feature (Check My Network, Bluetooth Explorer, capture inspection, Security Lab, Request Composer, Radio Lab, helper link) runs locally with no sign-in. An account would only ever add things that need HCG: syncing reports or running Security Lab on a paired HCG Server. |

## Checked from GitHub Actions, 21 November 2026 (run 44859350703, no account)

| Check | Result |
| --- | --- |
| Discovery document | issuer `https://qggdyzoydveafkmjgkpq.supabase.co/auth/v1`; authorize, token, userinfo and `jwks.json` endpoints as below; grants `authorization_code`, `refresh_token`; `revocation_endpoint` and `end_session_endpoint` absent. Matches the main site's answers. |
| PKCE methods offered | `S256` and `plain`. The server also accepts `plain`, so Sentinel must always send S256 and never fall back. |
| Signing keys | One EC key, `ES256`. Sentinel's ID-token check must accept ES256 (not only RS256). |
| Authorize with an unregistered client and Sentinel's planned redirect | `HTTP 400 {"error_code":"oauth_client_not_found","msg":"invalid client_id"}`. Unknown clients are refused before any redirect is used. This confirms Sentinel has no client, as expected. |
| `GET /me` on the Ecosystem API without a token | `HTTP 401`. Account data needs a token. |

## What exists centrally (from the main site's recorded answers, not re-verified beyond the checks above)

| Item | Value |
| --- | --- |
| Issuer | `https://qggdyzoydveafkmjgkpq.supabase.co/auth/v1` |
| Endpoints | `{issuer}/oauth/authorize`, `{issuer}/oauth/token`, `{issuer}/oauth/userinfo`, `{issuer}/.well-known/jwks.json` |
| Clients | Public (`token_endpoint_auth_method: none`), PKCE S256, grants `authorization_code` and `refresh_token` |
| Scopes | `openid email profile` (identity only; no product scopes) |
| Tokens | `aud` = `authenticated`, `sub` = central account ID; no revocation or end-session endpoint |
| Ecosystem API | `https://beta.hakmicapitalgroup.com/api/public/ecosystem/v1`: `GET /me`, `POST /check {org_id, product_id, feature_key}` (always 200 with `allowed`, `reason`) |
| Native precedent | HCG Executable Maker's production client `fb9b6edf-…` (public, loopback callbacks), status `configured_untested`. Its open question also applies to Sentinel: whether the Ecosystem API accepts a native app's OAuth access token as a bearer. |

## Registration request for the main HCG project

Copy this section into the request. Nothing has been registered or changed.

### 1. Register the product (D3)

| Field | Value |
| --- | --- |
| Product ID | `hcg.sentinel`, following `hcg.terminal`, `hcg.mail` and the others. Check for duplicates first. |
| Name | HCG Sentinel |
| Edition key | `ios`, for the iPhone and iPad app. HCG Store would record it as `centralEditionKey: "ios"` on its `app` edition. |
| Features | **None needed now.** Local diagnostics are never gated by an account or a licence. If and when they are built, Sentinel would ask for two features, created disabled with no grants: `sentinel.server-assessments` (Security Lab on a paired HCG Server) and `sentinel.report-sync` (keeping redacted reports with the account). |

### 2. Issue one public client for the iOS app

Use the ERP App integrations workflow ("Inspect registrations", then "Issue or reuse login client"). Do not reuse another
app's client.

| Registry field | Value |
| --- | --- |
| Product | `hcg.sentinel` |
| Integration key | `hcg-sentinel-ios-development` (development first; production after the first real sign-in passes) |
| Name on the consent page | HCG Sentinel |
| Platform | iOS and iPadOS (native) |
| Client type | Public: `token_endpoint_auth_method: none`, **no secret** |
| Grants | `authorization_code`, `refresh_token` |
| PKCE | S256 only |
| Scopes | `openid email profile` |
| Access-token audience | `authenticated` |
| Redirect URI | `com.hcg.sentinel:/oauth2/callback`: a private-use URI scheme built from the app's bundle identifier (RFC 8252 §7.1), received through `ASWebAuthenticationSession`, so no other app can claim it during sign-in |
| Logout return URL | None (there is no end-session endpoint; Sentinel signs out locally) |
| Status | `configured_untested` until the acceptance below passes |

Registration body:

```json
{
  "client_name": "HCG Sentinel",
  "application_type": "native",
  "client_type": "public",
  "token_endpoint_auth_method": "none",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "redirect_uris": ["com.hcg.sentinel:/oauth2/callback"],
  "scope": "openid email profile",
  "code_challenge_methods": ["S256"],
  "product_id": "hcg.sentinel",
  "integration_key": "hcg-sentinel-ios-development"
}
```

**Please confirm:** whether the identity server accepts a private-use scheme as a redirect URI. If it does not, say so
rather than registering something else. The alternative is an HTTPS universal link on a host HCG controls (for example
`https://beta.hakmicapitalgroup.com/apps/sentinel/oauth2/callback`). That needs that host to serve an
`apple-app-site-association` file naming the app, and Sentinel to carry the Associated Domains entitlement, which
needs a paid Apple Developer team.

### 3. Confirm two contract details

1. Whether `GET /me` and `POST /check` accept an access token issued to a native public client as `Authorization: Bearer`.
   This is the same open item as Executable Maker's.
2. For a personal account with no organisation: does `/check` have an answer for it, or does Sentinel show
   "no licence information" (and keep working locally)?

**Send back:** the product ID, the client ID (not a secret), the registered redirect URI, and the answers to 2 and 3.

## Acceptance once a client exists

Run on a Mac with the app in the Simulator or on an iPhone. A person has to sign in, so none of this can run in CI:

1. Sign-in opens `ASWebAuthenticationSession` with PKCE S256, `state` and `nonce`; the consent page names HCG Sentinel.
2. The callback returns to Sentinel; the code is exchanged; the ID token's issuer, audience and signature
   (`jwks.json`) are checked, and `sub` matches `GET /me`.
3. Tokens live only in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); refresh rotates them; relaunch
   restores the session.
4. Sign-out deletes the stored tokens; `/me` is no longer called.
5. With no network, or signed out, every local feature still works, and the account area says "Not signed in". It
   never says "not licensed".

## What Sentinel has to build after registration (not started)

A small `HCGConnectClient` behind the existing capability model: a capability "HCG account", interface only until a
client ID exists, with sign-in via `ASWebAuthenticationSession` (iOS 12+, so both schemes), Keychain token storage
and an Account card in Settings. Nothing in the current app depends on it.
