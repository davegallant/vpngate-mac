# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.0.1] - 2026-07-25

First stable release, promoting `0.0.1-rc2` to general availability.

### Added

- Homebrew Cask install option (`brew install --cask
  davegallant/public/vpngate-mac`) alongside the manual `.zip` install.
- ARCHITECTURE.md documenting the app/helper/XPC runtime architecture,
  linked from the README and AGENTS.md.

### Changed

- README now states the macOS 14 (Sonoma)+ requirement and notes the
  build is a universal binary (arm64 + x86_64).

## [0.0.1-rc2] - 2026-07-25

### Changed

- Built app bundle and release zip renamed to `VPNGate.app` /
  `VPNGate.zip`, matching the display name.
- Log viewer now uses an adaptive text color in dark mode.

## [0.0.1-rc1] - 2026-07-25

Initial release candidate. Native macOS menu bar client for
vpngate.net, extracted and reimplemented in Swift from
`davegallant/vpngate`.

### Added

- Menu bar app (`Vpngate.app`) with server list, country filter,
  connect/disconnect, live status, and a log viewer.
- Privileged `VpngateHelper` background daemon (`SMAppService`)
  that owns the `openvpn` subprocess and management-interface
  connection, talking to the app over XPC.
- `openvpn` bundled inside the app instead of requiring
  `brew install openvpn`.
- GitHub Actions release workflow: pushing a `v*.*.*` tag builds,
  signs, and publishes `Vpngate.zip` as a GitHub Release.

### Known limitations

- Signed with a free Apple Development certificate, not notarized —
  Gatekeeper's "unidentified developer" prompt appears on install.
- Single active connection at a time; no ping/score filtering, sort
  options, proxy/socks5, or `--reconnect`-loop mode (see AGENTS.md
  for full v1 scope).

[Unreleased]: https://github.com/davegallant/vpngate-mac/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/davegallant/vpngate-mac/compare/v0.0.1-rc2...v0.0.1
[0.0.1-rc2]: https://github.com/davegallant/vpngate-mac/compare/v0.0.1-rc1...v0.0.1-rc2
[0.0.1-rc1]: https://github.com/davegallant/vpngate-mac/releases/tag/v0.0.1-rc1
