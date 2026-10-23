<p align="center">
  <img src="assets/workslop-icon.png" width="160" alt="WorkSlop Mobile icon">
</p>

# WorkSlop — Mobile (New)

WorkSlop Mobile by **adnan.120hz** — a no-jailbreak iOS customization app.
Sideload the IPA, import your pairing file once, and apply everything
straight from your iPhone. The tweak engine / apply method is based on an
open-source upstream engine (see Credits below); the user interface is
WorkSlop's own two-slider interface. Licensed under **AGPL-3.0** (see
`LICENSE`), following the upstream license.

## v3.0

### Before you apply — read this first

## ⚠️ Find My iPhone must be turned OFF before applying tweaks

Applying with Find My still on can make the apply fail. Turn it off in
Settings → [your name] → Find My → Find My iPhone, apply your tweaks,
and you can turn it back on afterwards.

### Support

- **iOS 26 — Supported.** All features are active.
- **iOS 27 and later — Partially Supported.** The apply method works,
  but only part of the feature catalogue takes effect (see below).

### Features

- Liquid Glass tweaks
- Icon Themes
- Status Bar customisation
- Apple Internal options
- Daemons control
- PosterBoard wallpapers
- Remove Tweaks — undo applied tweaks and return the files to their
  defaults

### iOS 27+ — what works and what does not

Working on iOS 27+:

- Disable Liquid Glass on Dock
- Disable Liquid Glass Reflections

Not working on iOS 27+ yet:

- Status Bar
- The other Liquid Glass features

On iOS 26 everything listed under Features is active.

### Credits

- App and interface: **adnan.120hz**
- Beta tester team: Charlie, rfrz1d_, Davy, uggtx, Fayaz, alfndv1, s1gn
- Engine and upstream contributors: see "Changes from upstream" below.

## Status (honest)

- **Supported devices: iOS 26.0 through iOS 27.0.1 and newer** (the
  engine requires the iOS 26 SDK surface). The app says so on
  unsupported versions.
- Apply flow (from the engine, unchanged): tweaks are compiled to
  payloads, PosterBoard is applied via Airlift or backup fetch, iOS 27+
  first takes a protective mobilebackup2 backup, iOS 26 uses the
  synthetic partial-restore path. There is **no automatic reboot** and
  **no backup-password / Find My step** in this engine — an encrypted
  device backup fails fast instead.
- Pairing file comes in two ways. On **iOS 27** it is generated inside
  WorkSlop itself — Get Pairing File pairs the app as the host (turn on
  Developer Mode, pair with host, enter the PIN). On **iOS 26** the
  `.plist` is created on a computer with `idevicepair pair`, iLoader or
  similar tools and imported into the app. Either way it is set up once
  and stored in the app container.

## Features removed in the 2026-10-22 migration

These WorkSlop features have **no counterpart in the upstream app** and
were removed rather than left as dead UI:

- **PosterBoard Templates (`.batter`)** — not ported upstream. `.tendies`
  wallpapers and the three PosterBoard reset modes remain.
- **AirFlit** (AirCard passcode themes + Wallet images) — removed by
  decision; not part of this build.
- One Liquid Glass legibility toggle whose key does not exist in the
  upstream backend.

Everything else in the UI (Liquid Glass, SpringBoard, Internal Options,
Daemons incl. Recommended set, PosterBoard) maps 1:1 onto specs in the
engine's TweakCatalog.

**Icon Themes came back the same day** (v2.0): upstream has no icon-theme
spec, but the feature is WebClip files — plain payloads at a HomeDomain
path — so it is implemented as a WorkSlop payload producer whose files
ride the engine's unchanged delivery (see Changes from upstream).

## Changes from upstream

- The interface is WorkSlop's own original UI (SwiftUI), designed and
  built for this app — no upstream interface is used or replaced; only
  the Nugget/GoldenNugget backend (`Nugget/Core`, tunnel stack, vendored
  Minimuxer / IDevice / AirliftFFI frameworks) is imported, unmodified
  except for project integration.
- Upstream engine and contributors: engine by [awesomenull] and
  [Wind0ws11Aero], building on [LeminLimez] (Nugget),
  [@mak5er](https://github.com/mak5er) (AirCard),
  [NeoSpring](https://github.com/rooootdev/neospring) by
  [@skadz108](https://github.com/skadz108),
  [@rooootdev](https://github.com/rooootdev) and
  [@neonmodder123](https://github.com/neonmodder123), 0xjonhnnydev
  (AirLift), [iTechExpert][iTechExpertTwitter] (SpringBoard/Internal
  options) and [Mikasa-san][Mikasa-sanGitHub]
  ([Quiet Daemon][QuietDaemonGitHub]).
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
- Completion verdicts in the vendored gateway made evidence-based
  (2026-10-22): a restore is successful when the device's own verdict is
  ErrorCode 0 AND the host served every file the device asked for
  (delegate errors now fail the run instead of only being logged); the
  device's progress percent is the completion gate only when it gave no
  verdict — a complete restore can end at 99 % when the device already
  holds some files. The backup path now reads the device's ErrorCode
  too, so a protective backup the device ended in error aborts the run
  instead of letting the restore stage trust it.
- The upstream status-bar override engine got its missing page
  (`StatusBarView`): Apply now sends the selection the page saves
  instead of an empty one.
- App-layer fixes (2026-10-22): the Home Apply count is the real
  deliverable count (specs, icon themes, status bar overrides), not
  staged feature IDs; a Log page reads the engine's rotating log file
  (which survives restarts); the carrier name field has an explicit
  Save for its draft; staged selections persist in a Documents JSON
  file (the icon-stage pattern) instead of UserDefaults only; the
  corner-radius tweak takes the user's own number (0–60, like the
  desktop's NUMBER field) via a spec multi-value override; and a
  Remove Tweaks page records each successful apply and removes
  exactly those tweaks by nulling their files through the engine's
  `TweakReset` machinery (valid empty plist on every version — a
  deliberate deviation from the page reset's iOS 26 0-byte null,
  because a truncated plist is a SpringBoard boot loop on
  iOS 26.2+), gated on the apply-time pairing fingerprint.

## Credits

- **adnan.120hz** — WorkSlop Mobile lead developer. Builds the app and
  its interface, builds new code, builds new tweaks, and builds the iOS
  system adaptations that make them work on each iOS version.
- Beta tester team (WorkSlop Mobile): Charlie, rfrz1d_, Davy, uggtx,
  Fayaz, alfndv1, s1gn.

[awesomenull]: https://github.com/awesomenull-dev
[Wind0ws11Aero]: https://github.com/Wind0ws11Aero
[LeminLimez]: https://github.com/leminlimez
[iTechExpertTwitter]: https://x.com/iTechExpert21
[Mikasa-sanGitHub]: https://github.com/Mikasa-san
[QuietDaemonGitHub]: https://github.com/Mikasa-san/QuietDaemon

**Status-bar activation fix:** the reference turns the status-bar tweak
on when any value is edited; the port missed that, so edits with the
master switch off were saved but never delivered (Home Apply stayed
disabled with nothing staged; runs logged "status bar off"). Every
edit on the Status Bar page now activates the selection, and the Apply
preflight shows an off-but-set status bar instead of hiding it.
