# Changelog

All notable changes to Moddex are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is the human-curated, high-level history. The per-release GitHub
Release page additionally carries auto-generated notes listing every merged pull
request (see [`docs/releasing.md`](docs/releasing.md)).

## [Unreleased]

The following work is merged on `develop` but not yet tagged in a release.

### Added

- **CurseForge integration** (epic #17 / #25): read-only CurseForge mod provider
  behind the existing marketplace abstraction (search, details, versions,
  filters) and CurseForge modpack import with format auto-detection and hardened,
  transactional file resolution. Frontend gains secret-safe API-key handling and
  provider-specific error messages.
- **Full 7-language UI** (#27): German, English, Spanish, French, Chinese,
  Japanese and Arabic, with right-to-left layout for Arabic and an enforced
  translation-parity test.
- **Windows support** (#26): PowerShell installer that registers the backend as a
  Windows service via WinSW, a `%ProgramData%\Moddex` path layout, a build/release
  pipeline producing a checksum-verified `windows-x64.zip`, plus uninstall and
  smoke-test scripts.
- **Operator documentation** (#40): troubleshooting / known-issues guide and an
  upgrade & rollback guide for both Linux and Windows; GitHub issue/PR templates
  and `SUPPORT.md` so problems can be reported in a structured way.
- **Release process** (#42): automatically generated GitHub Release notes
  (`.github/release.yml`), this changelog and [`docs/releasing.md`](docs/releasing.md).

### Changed

- Windows installer now records the installed version in
  `%ProgramFiles%\Moddex\VERSION` for parity with Linux.

> _v0.2 "Public Beta Foundation" (secure local/lan/public modes with fail-closed
> CORS and enforced authentication, the native Linux installer + systemd service +
> `moddex` CLI, backup/restore data-safety guarantees, Modrinth mod management and
> the QA/recovery checklists) is also part of this unreleased range._

## [0.1.1] - 2025-09-24

### Changed

- Maintenance and installer fixes on top of the initial release.

## [0.1.0] - 2025-09-22

### Added

- Initial Moddex release: native Linux deployment of the backend and web UI.

[Unreleased]: https://github.com/aklozyp/Moddex/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/aklozyp/Moddex/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/aklozyp/Moddex/releases/tag/v0.1.0
