# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions or pull requests.**

Instead, use GitHub's private vulnerability reporting: open the **Security** tab
of the [Moddex repository](https://github.com/aklozyp/Moddex) and choose
**“Report a vulnerability”**. This keeps the report confidential until a fix is
available.

Please include, as far as you can:

- the affected component (backend, frontend, installer/packaging) and version
  (`moddex version` on Linux, or the release tag);
- the operating mode (`local` / `lan` / `public`) and platform;
- a description of the issue and its impact;
- steps to reproduce or a proof of concept;
- any relevant logs — **with secrets, tokens and passwords removed**.

## Scope

Moddex consists of three repositories that are released together:

- `aklozyp/Moddex` — installer, packaging, CI and documentation;
- `aklozyp/Moddex-Backend` — the API/service (Kotlin/Spring Boot);
- `aklozyp/Moddex-Frontend` — the web UI (Angular).

A vulnerability in any of them is in scope; report it through the public
`Moddex` repository as described above.

## Supported versions

Moddex is pre-1.0 and ships from the latest release. Security fixes target the
most recent release; there is no long-term support branch yet.

## Hardening guidance

Operators should review the secure-operation guidance before exposing Moddex
beyond `localhost`:

- [README — Private Linux Operation](README.md#private-linux-operation)
  (operating modes, authentication, firewall, reverse proxy with TLS);
- [Troubleshooting — CORS / security mode](docs/troubleshooting.md);
- the security review of the current release in
  [docs/qa/security-review.md](docs/qa/security-review.md).

## Our commitments

- We aim to acknowledge a report within a few days.
- We will keep the report confidential and coordinate a fix and disclosure.
- We credit reporters who wish to be named once a fix ships.
