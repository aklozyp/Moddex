# Moddex Security Review (v0.4)

> Pre-release security review across all three repositories — `Moddex`
> (installer/packaging/CI), `Moddex-Backend` (Kotlin/Spring Boot) and
> `Moddex-Frontend` (Angular). Tracked in
> [#46](https://github.com/aklozyp/Moddex/issues/46).

| Field | Value |
|-------|-------|
| Date | 2026-06-27 |
| Scope | Backend, Frontend, Build/Packaging/CI |
| Method | Manual code review of the authentication, CORS, file/download, secret-handling, XSS and CI surfaces |

## Severity scale

**High** — exploitable remotely with meaningful impact · **Medium** — exploitable
under a realistic configuration or defense-in-depth gap · **Low** — hardening /
limited impact · **Info** — accepted trade-off, documented.

## Summary

No High-severity issues were found. The backend is well-hardened: strong path
sanitisation and a trust policy for modpack imports, an SSRF-resistant artifact
downloader, bcrypt credentials with login rate-limiting, fail-closed CORS and
public-safe error responses. The findings below are two Medium defense-in-depth
gaps and several Low/Info hardening items.

| ID | Severity | Area | Finding | Status |
|----|----------|------|---------|--------|
| B1 | Medium | Backend | `serversettings.json` (JWT secret, admin hash, API key) written with default file permissions | **Fixed** — backend PR |
| B2 | Medium | Backend | `X-Forwarded-For` trusted unconditionally → IP spoofing when directly exposed in `public` mode | **Fixed** — backend PR ([#47](https://github.com/aklozyp/Moddex/issues/47)) |
| F1 | Low | Frontend | Unused `SafeHtmlPipe` (`bypassSecurityTrustHtml`) — latent XSS footgun | **Fixed** — frontend PR |
| F2 | Low | Frontend | No Content-Security-Policy | **Fixed** — frontend PR |
| C1 | Medium | CI | `ci.yml`/`smoke.yml` had no least-privilege `permissions` | **Fixed** — this PR |
| C2 | Low | CI | Actions pinned by mutable tag, not commit SHA | **Fixed** — [#52](https://github.com/aklozyp/Moddex/issues/52) |
| C3 | Low | Repo | No `SECURITY.md` disclosure policy | **Fixed** — this PR |
| C4 | Low | Repo | No Dependabot / dependency scanning | **Fixed** (meta) — this PR |
| B3 | Info | Backend | Console WebSocket auth via token query param | Accepted (documented) |
| F3 | Info | Frontend | JWT stored in `localStorage` | Accepted (documented) |

---

## Backend

### B1 — Secrets file written without restrictive permissions (Medium)

`ServerSettingsService` persists `serversettings.json` containing the JWT signing
secret, the bcrypt admin password hash, the CurseForge API key and the webhook
URL. It is written via `ObjectMapper.writeValue(file, …)`, which creates the file
with the process umask (typically `0644`, group/world-readable).

On Linux the installer creates `/etc/moddex` as `0750 root:moddex`, which limits
exposure, but the secrets file itself is not restricted, and the service also
re-creates the directory at runtime (`Files.createDirectories`) without an
explicit mode. Defense in depth: the file should be owner-only (`0600`).

**Recommendation / fix:** after writing, set POSIX permissions `rw-------` on the
settings file (skip gracefully on non-POSIX/Windows). Implemented in the backend.

### B2 — Unconditional trust of forwarded client IP (Medium → Fixed)

`application.yml` sets `server.forward-headers-strategy: framework`, so
`request.remoteAddr` reflects client-supplied `X-Forwarded-For`. Behind a
properly configured reverse proxy this is correct, but in `public` mode exposed
directly (the installer permits `--mode public` binding `0.0.0.0`) an attacker
can spoof the header to evade the login rate-limiter (keyed on `remoteAddr`) and
forge audit-log client IPs.

**Fixed:** `forward-headers-strategy` now defaults to `none` — the client IP
comes from the direct socket and forwarded headers are not trusted. Operators
behind a reverse proxy that overwrites/clears *all* forwarded headers opt back
in via `MODDEX_FORWARD_HEADERS_STRATEGY=framework`
(see `Moddex-Backend/docs/security-configuration.md` and the reverse-proxy
section in this README). Tracked in
[#47](https://github.com/aklozyp/Moddex/issues/47).

### Strengths confirmed

- **Modpack import** (`ModpackImportSecurity`): path traversal, absolute/drive
  paths, reserved names and control chars rejected; `resolveWithin` re-checks the
  resolved path stays inside the instance dir; HTTPS host allowlist; mandatory
  integrity hashes; per-file/total size and count ceilings with a zip-bomb guard.
- **Artifact download** (`SecureArtifactDownloader`): HTTPS + host allowlist,
  manual redirects re-validated at every hop and bounded, streaming hash, copy
  aborted mid-flight past the byte cap, atomic move, temp cleanup on failure.
- **Auth**: bcrypt, `LoginAttemptService` rate-limiting, audit logging, stateless
  JWT (HS256, 256-bit `SecureRandom` secret), CSRF disabled appropriately for a
  token (non-cookie) API.
- **CORS**: fail-closed for `lan`/`public`, credentials disabled.
- **Error responses**: messages, stack traces and binding errors never returned.

### B3 — Console WebSocket token in query param (Info)

Browsers cannot set the `Authorization` header on a WebSocket handshake, so the
console authenticates via a token query parameter. Tokens in URLs can be captured
by intermediary access logs. Accepted trade-off; mitigated by short token
lifetime and TLS at the proxy.

---

## Frontend

### F1 — Unused `SafeHtmlPipe` footgun (Low)

`src/app/pipes/safe-html.pipe.ts` calls `DomSanitizer.bypassSecurityTrustHtml`.
It is imported in `mod-detail-page.component.ts` but **not used in any template**.
The one `[innerHTML]` binding (`project.body | markdown`) passes a plain string,
so Angular's built-in sanitiser runs — that path is safe. The unused bypass pipe
is a latent hazard if later applied to untrusted content.

**Recommendation / fix:** remove the pipe and its import. Implemented.

### F2 — No Content-Security-Policy (Low)

`index.html` ships no CSP. A CSP is meaningful defense in depth against XSS even
with Angular's sanitiser (it would blunt an accidental future bypass and block
unexpected origins).

**Recommendation / fix:** add a restrictive CSP `<meta>` (self-only scripts/
styles, images from self/data, connect to self). Implemented.

### F3 — JWT in `localStorage` (Info)

The bearer token lives in `localStorage`, readable by any script in the origin.
This is the pragmatic choice for a header-based (non-cookie) API and is acceptable
given the sanitiser and the CSP added in F2. Documented trade-off.

---

## Build / Packaging / CI

### C1 — Missing least-privilege `permissions` (Medium → Fixed)

`ci.yml` and `smoke.yml` declared no `permissions`, inheriting the repository
default `GITHUB_TOKEN` scope. Both only read code and build. Added
`permissions: contents: read`. (`release.yml` already scopes `contents: write`
per job.)

### C2 — Actions pinned by tag, not SHA (Low → Fixed)

Workflows referenced `actions/checkout@v4`, `softprops/action-gh-release@v2`,
etc. A compromised tag could inject malicious action code with access to
`MODDEX_CHECKOUT_TOKEN`. Pinning to full commit SHAs (especially for the
third-party `softprops/action-gh-release`) removes that risk.

**Fixed** ([#52](https://github.com/aklozyp/Moddex/issues/52)): every `uses:`
in `ci.yml`, `smoke.yml` and `release.yml` is pinned to the full commit SHA of
the previously used version tag (annotated `# v4`/`# v2`). Dependabot (C4)
keeps the pins current.

### C3 — No SECURITY.md (Low → Fixed)

Added `SECURITY.md` with a private vulnerability-reporting policy (referenced by
`SUPPORT.md` and the issue-template config).

### C4 — No dependency scanning (Low → Fixed here, follow-up for app repos)

Added `.github/dependabot.yml` for the GitHub Actions ecosystem in this repo.
Equivalent Maven (backend) and npm (frontend) Dependabot configs were added in
those repositories alongside the B1 and F1/F2 fixes.

### Strengths confirmed

- Linux installer writes `moddex.env` with `umask 027` (`0640 root:moddex`),
  config dir `0750`, secrets not world-readable; idempotent upgrades preserve
  operator config.
- WinSW is checksum-pinned in both the installer and the bundle builder.
- Release artifacts ship SHA-256 checksums; downloads verify them.

---

## Remediation tracking

| Finding | Where |
|---------|-------|
| B1 | Backend PR (this review) |
| F1, F2 | Frontend PR (this review) |
| C1, C3, C4 | This (meta) PR |
| B2 | Backend PR ([#47](https://github.com/aklozyp/Moddex/issues/47)) |
| C2 | Recommendation — apply with Dependabot follow-up |
| B3, F3 | Accepted, documented |
