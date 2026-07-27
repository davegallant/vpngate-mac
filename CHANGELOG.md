# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.0.2] - 2026-07-27

### Added

- Kill switch: while armed (default on), a dropped OpenVPN tunnel
  blocks non-tunnel traffic via a pf-based anchor instead of leaking
  it, until reconnect or explicit disconnect. Toggle lives in the
  menu bar UI; an unexpected tunnel drop surfaces as a new "Blocked"
  status instead of a stale "Connected".

## [0.0.1] - 2026-07-25

First stable release.

### Added

- Homebrew Cask install option (`brew install --cask
  davegallant/public/vpngate-mac`) alongside the manual `.zip` install.
- ARCHITECTURE.md documenting the app/helper/XPC runtime architecture,
  linked from the README and AGENTS.md.
- Built app bundle and release zip renamed to `VPNGate.app` /
  `VPNGate.zip`, matching the display name.
- Log viewer now uses an adaptive text color in dark mode.
- Menu bar app (`Vpngate.app`) with server list, country filter,
  connect/disconnect, live status, and a log viewer.
- Privileged `VpngateHelper` background daemon (`SMAppService`)
  that owns the `openvpn` subprocess and management-interface
  connection, talking to the app over XPC.
- `openvpn` bundled inside the app instead of requiring
  `brew install openvpn`.
- GitHub Actions release workflow: pushing a `v*.*.*` tag builds,
  signs, and publishes `Vpngate.zip` as a GitHub Release.

[Unreleased]: https://github.com/davegallant/vpngate-mac/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/davegallant/vpngate-mac/compare/v0.0.1...v0.0.2
