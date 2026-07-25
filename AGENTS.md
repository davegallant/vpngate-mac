# AGENTS.md

Guidance for AI agents working in this repo. Distilled from the
original design spec, implementation plan, and release-workflow spec
(now removed — this file is the source of truth going forward).

## What this is

A native macOS menu bar client for vpngate.net: pick a server, connect/
disconnect via a privileged background helper running OpenVPN, view
live status and logs. Extracted from `davegallant/vpngate` (a Go CLI/
daemon for the same purpose) as a standalone Swift implementation —
**not** a wrapper around the Go binary; the server-list fetch/cache,
OpenVPN management-protocol client, and process supervision are all
reimplemented natively in Swift. The Go project is a separate repo now;
don't expect to find it here.

Status: working end to end (helper registration, connect/disconnect,
live status/logs) — this is a maintained app, not a work-in-progress
scaffold.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for a full runtime walkthrough
(diagrams, XPC contract, the OpenVPN wrapper's connect flow, logging,
lifecycle). This section stays as the terse summary + the conventions
below it that must not drift.

Two processes split by privilege, talking over XPC:

```
┌─────────────────────────────┐        XPC          ┌───────────────────────────┐
│  VPNGate.app (user, no root) │ ◄──────────────────► │  VpngateHelper (root)     │
│  SwiftUI MenuBarExtra        │                      │  SMAppService daemon      │
│  - server list + filters     │                      │  - launches `openvpn`     │
│  - connect/disconnect UI     │                      │  - owns mgmt-interface    │
│  - status polling            │                      │    connection             │
│  - log viewer                │                      │  - writes daemon.log      │
└───────────────┬───────────────┘                      └──────────────┬───────────┘
                │ URLSession                                          │ subprocess
                ▼                                                     ▼
        vpngate.net API                                          openvpn (root)
```

Service identifier: `com.davegallant.vpngate.helper` (see "Conventions
that must not drift" below).

- **`App/`** — `VPNGate.app` (SwiftUI, `MenuBarExtra` only, no Dock
  icon). `ServerListStore` fetches/caches the vpngate.net server CSV;
  `HelperClient` is the async XPC wrapper (`connect`, `disconnect`,
  `status`, `streamLogs`); `LogViewerWindow` live-tails helper logs.
- **`Helper/`** — `VpngateHelper`, a privileged `SMAppService.daemon`
  embedded in the app bundle (not a separate install step —
  registration triggers one admin approval prompt, no more after
  that). `OpenVPNSupervisor` owns the `openvpn` subprocess and its
  management-interface connection; `HelperXPCService` is the XPC entry
  point. Writes `daemon.log` to
  `/Library/Application Support/Vpngate/daemon.log`.
- **`Shared/`** — `VpngateShared`, a local SPM package (no privilege)
  holding the `@objc` XPC protocol and plain data types (`Server`,
  `ConnectionState`, `LogLine`), imported by both targets so the
  app/helper contract can't drift between them. This is the only part
  of the app testable with plain `swift test` — everything in
  `App/`/`Helper/` needs Xcode (MenuBarExtra, cross-process XPC, and
  `SMAppService` registration all require a live session).

One active connection at a time — same as the original Go daemon.

## Conventions that must not drift

- Bundle/service identifiers: app `com.davegallant.vpngate`, helper
  `com.davegallant.vpngate.helper` — used in the Xcode project,
  `Info.plist`, the embedded launchd plist, and XPC connection setup.
  Keep them consistent across all of those.
- `openvpn` invocation matches the original Go CLI exactly: `openvpn
  --verb 4 --config <path> --data-ciphers AES-128-CBC --management
  <host> <port>` — no `--management-client` flag.
- Management-protocol semantics also match the Go implementation: on
  connect, read and discard one greeting line; a state query is
  `"state\n"`, read lines until one equals `"END"`, and the connection
  state is the second comma-separated field (index 1) of the first
  line with a non-empty field there; disconnect is `"signal
  SIGTERM\n"`.
- Server-list cache TTL: 24 hours, cached at
  `~/Library/Caches/vpngate/servers.json`.
- Tests use XCTest only — don't introduce Quick/Nimble or
  swift-testing.
- v1 scope is intentionally narrow: country filter only. No
  ping/score filtering, sort options, proxy/socks5, `--reconnect`-loop
  mode, random connect, or a NetworkExtension-based connection engine.
  Don't add these without discussing scope first.

## Building, testing, packaging

Use the `justfile` targets — they wrap commands in a clean,
non-nix environment:

```
just test              # swift test in Shared/
just test-filter X     # swift test --filter X in Shared/
just build             # swift build in Shared/
just package           # ./build-and-package.sh (archive + zip the app)
```

**Why the clean-env wrapper exists:** on machines set up for Go/nix
tooling, the nix profile's `PATH` puts a nix `xcrun`/SDK shim ahead of
the real one, breaking `swift build`/`swift test`/`xcodebuild` with
SDK-mismatch errors (`no such module 'SwiftShims'` or similar).
Per-invocation `env -i ... DEVELOPER_DIR=/Applications/Xcode.app/...`
overrides are what actually work — exporting `DEVELOPER_DIR` alone in
a nix shell does not stick. If you're not using `just`, replicate that
env wrapper by hand.

**Swift/Xcode toolchain cannot run in a sandboxed agent environment**
(hardcoded writes to sandbox-blocked temp paths). Ask the user to run
`swift`/`xcodebuild`/`just` commands themselves via a `!`-prefixed
shell command rather than attempting them directly.

`build-and-package.sh` produces `build/VPNGate.zip`. It does not use
`xcodebuild -exportArchive` — a free/personal Apple ID has no
distribution profiles to resolve an export method against, so the
script copies the signed `.app` straight out of the archive instead.
It also accepts optional `CODE_SIGN_STYLE_OVERRIDE` /
`CODE_SIGN_IDENTITY_OVERRIDE` env vars (used by CI, see below) that
are no-ops when unset.

`openvpn` is meant to be bundled inside `VPNGate.app`
(`Contents/Library/openvpn/openvpn`) rather than requiring
`brew install openvpn`. As of this writing that's not yet wired into
the Xcode project — see README's "Installing" section for the manual
steps (`scripts/build-openvpn.sh` + a Copy Files build phase). The
helper's path resolution already looks there first, falling back to
system search paths if absent.

## Signing, distribution, and releases

Signed with a free Apple ID **Development** certificate (Personal
Team, `DEVELOPMENT_TEAM = 8P4N929397` in the Xcode project) — not a
paid Developer ID, so builds are **not notarized**. This is a real
signing identity (required for `SMAppService` app↔helper trust; ad-hoc
signing doesn't satisfy that), just not one that satisfies Gatekeeper.
Known costs, not bugs: the cert expires ~yearly, and every release
re-triggers Gatekeeper's "unidentified developer" prompt for users.
Upgrading to Developer ID + notarization (needs a paid $99/yr Apple
Developer Program membership) would be a drop-in improvement, not a
redesign — not planned unless the project explicitly decides to pay
for it.

**Team-ID trap:** `security find-identity -v -p codesigning` prints
identities like `"Apple Development: <email> (26MUC8RGU5)"` — that
parenthetical is *not* the Team ID, it's a separate per-certificate
identifier. The real Team ID (`8P4N929397`) is buried in the
certificate's OU field, invisible in that command's output. Don't
grep `find-identity` output for the Team ID string; it won't match.

Releases are automated: pushing a tag matching `v*.*.*` triggers
`.github/workflows/release.yml`, which runs the `Shared` test suite,
signs with the same Development certificate (imported into a per-run
temp keychain from `MACOS_CERT_P12_BASE64` / `MACOS_CERT_PASSWORD`
repo secrets — see README's "Releasing" section for the export
steps), packages via `build-and-package.sh`, and publishes
`VPNGate.zip` as a GitHub Release. The workflow also supports
`workflow_dispatch` for a dry run (build/sign/package without
publishing) — use that to validate changes to the workflow before
tagging a real release. Pinned to Xcode `26.6` via
`maxim-lobanov/setup-xcode`, confirmed present on the `macos-26-arm64`
runner image (alongside 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1) as
of 2026-07-24; if GitHub later drops it from the image, the step
fails listing what's still available — update the pin to match.

**Deployment target:** the Xcode *project-level* default
`MACOSX_DEPLOYMENT_TARGET` is 26.5, but both shipped targets
(`Vpngate`, `VpngateHelper`) override it down to 14/14.0 at the
target level — that's what actually applies, matching the design's
macOS 14 Sonoma+ minimum. Don't take the project-level 26.5 at face
value; check the target-level build settings.

## Testing strategy

What actually exists, not what was once planned:

- `VpngateShared` (`just test` / `swift test`): real XCTest coverage,
  including a fake TCP management server for testing
  `OpenVPNSupervisor`'s protocol client without a real `openvpn`
  process or root. This is the only part of the repo with an
  automated test loop.
- `App/` and `Helper/` (the Xcode targets): **no automated tests.**
  `MenuBarExtra`, cross-process XPC, and `SMAppService` registration
  all need a live Xcode session/GUI, so there's no `swift test`
  equivalent for them — don't go looking for one, and don't assume
  one should already exist just because the design spec once
  described how it might be tested.
- Everything Xcode-side is instead covered by the manual checklist in
  `SMOKE_TEST.md` (helper registration, connect/disconnect, helper
  resilience, missing-`openvpn` handling, Gatekeeper path) — run it
  before every release.

## Known limitations (not bugs to silently "fix")

- Not notarized; Gatekeeper bypass required per the README's
  "Installing" section.
- If the helper is killed while connected, the app's `refreshStatus()`
  correctly reports "Not connected" after the killed helper is
  relaunched by launchd, since its in-memory `OpenVPNSupervisor` state
  is gone — a known v1 limitation, not something to patch around.
- `openvpn` bundling into the app isn't fully automated yet (manual
  Xcode build-phase step required).
