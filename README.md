# WorkSlop — Mobile (New)

WorkSlop Mobile by **adnan.120hz**. The tweak engine / apply method in this
app is a fork of **GoldenNugget by
[awesomenull-dev](https://github.com/awesomenull-dev/GoldenNugget)**
(GoldenNugget-Team /
[GoldenNugget-mobile](https://github.com/GoldenNugget-Team/GoldenNugget-mobile)),
imported from the fork `adnan120hz/GoldenNugget-mobile`. The user interface
is WorkSlop's own; the GoldenNugget UI is not used. Licensed under
**AGPL-3.0** (see `LICENSE`), following the upstream license.

## Status (honest)

- **2026-10-22 — backend replaced.** The previous home-grown Swift/FFI
  tweak engine did not work reliably, so it was removed entirely and
  replaced with the GoldenNugget-mobile backend (`GoldenNuggetEngine`,
  TweakCatalog specs, Minimuxer/EMProxy tunnel, AirliftFFI PosterBoard).
  The WorkSlop UI was kept and rewired to that engine
  (`BackendAdapter.swift`, `BackendBootstrap.swift`).
- **Supported devices: iOS 26.0 and newer only** (the GN backend requires
  the iOS 26 SDK surface). The app says so on unsupported versions.
- Apply flow (from the GN engine, unchanged): tweaks are compiled to
  payloads, PosterBoard is applied via Airlift or backup fetch, iOS 27+
  first takes a protective mobilebackup2 backup, iOS 26 uses the
  synthetic partial-restore path. There is **no automatic reboot** and
  **no backup-password / Find My step** in this engine — an encrypted
  device backup fails fast instead.
- Pairing file (`.plist` from `idevicepair pair`) is imported once in the
  app and stored in the app container, same as before.

## Features removed in the 2026-10-22 migration

These WorkSlop features have **no engine in GoldenNugget-mobile** and were
removed rather than left as dead UI:

- **PosterBoard Templates (`.batter`)** — not ported upstream. `.tendies`
  wallpapers and the three PosterBoard reset modes remain.
- **AirFlit** (AirCard passcode themes + Wallet images) — removed by
  decision; not part of this build.
- One Liquid Glass legibility toggle whose key does not exist in the GN
  backend.

Everything else in the UI (Liquid Glass, SpringBoard, Internal Options,
Daemons incl. Recommended set, PosterBoard) maps 1:1 onto specs in the GN
TweakCatalog.

**Icon Themes came back the same day** (v2.0): upstream has no icon-theme
spec, but the feature is WebClip files — plain payloads at a HomeDomain
path — so it is implemented as a WorkSlop payload producer whose files
ride the engine's unchanged delivery (see Changes from upstream).

## Changes from upstream

- Replaced the GoldenNugget UI with the WorkSlop UI (SwiftUI); only the
  backend (`Nugget/Core`, tunnel stack, vendored Minimuxer / IDevice /
  AirliftFFI frameworks) is imported, unmodified except for project
  integration.
- App identity: bundle `com.adnan120hz.workslop`, name "WorkSlop".
- Feature catalogue presented in WorkSlop's grouping; daemon groups are
  driven from the upstream `DaemonGroups.all` data.
- Bootstrap sequence extracted from the upstream app's views into
  `BackendBootstrap` so the WorkSlop UI can start the same stack.
- `GoldenNuggetEngine.applyTweaks` gained a defaulted `extraPayloads`
  parameter: caller-built `TweakPayload`s appended to the same delivery
  list the compiled tweaks use. Used by Icon Themes (WebClip folders in
  HomeDomain, the desktop's delivery shape). No upstream delivery code
  changed.
- Liquid Glass menu extended with the WorkSlop Desktop registry's specs
  (2026-10-22): nine specs added to `TweakCatalog` (the iOS 26 exterior-
  effects set, whose keys have no reader on iOS 27 per the WorkSlop
  firmware audit; `com.apple.SwiftUI.DisableSolarium`; the UIKit glass
  legibility value; the square-corner key pair) and six catalog version
  windows widened to iOS 26 where the Desktop registry and firmware
  evidence support it (`SBDisallowGlassButtons`,
  `SBDisallowGlassLockScreen`, `SolariumUseDisplayAngle`,
  `SolariumHighlightWhite`, `SolariumBackgroundFilter`,
  `UISolariumFloatingContentViewEnableBackgroundFills`).
- The upstream status-bar override engine got its missing page
  (`StatusBarView`): Apply now sends the selection the page saves
  instead of an empty one.

## Credits

- [awesomenull] Lead developer
- [Wind0ws11Aero] for helping with development a lot.
- [@mak5er](https://github.com/mak5er): AirCard developer.
- [NeoSpring](https://github.com/rooootdev/neospring): Swift implementation by **[@skadz108](https://github.com/skadz108)** and **[@rooootdev](https://github.com/rooootdev)**, and **[@neonmodder123](https://github.com/neonmodder123)** for the WebKit GPU process respring technique.
- [LeminLimez] for creating Nugget.
- [0xjonhnnydev] for [AirLift]
- [iTechExpert][iTechExpertTwitter] for various Springboard/Internal Options
- [Mikasa-san][Mikasa-sanGitHub] for [Quiet Daemon][QuietDaemonGitHub]
- WorkSlop UI and integration: adnan.120hz

[awesomenull]: https://github.com/awesomenull-dev
[Wind0ws11Aero]: https://github.com/Wind0ws11Aero
[LeminLimez]: https://github.com/leminlimez
[iTechExpertTwitter]: https://x.com/iTechExpert21
[Mikasa-sanGitHub]: https://github.com/Mikasa-san
[QuietDaemonGitHub]: https://github.com/Mikasa-san/QuietDaemon
