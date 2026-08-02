# How Dictor is built

Five minutes of reading for someone who wants to know what happens between
pressing a key and text appearing in a field, and which parts of this code are
load-bearing.

## Three processes, not one

`main.swift` is the only place where this is visible, and it explains most of
the rest of the design.

| Process | Started by | What it owns |
|---|---|---|
| `Dictor --agent` | LaunchAgent `com.raul.dictor.agent` | the event tap, audio, recognition, insertion, the recording capsule, the menu-bar item and its popover |
| `Dictor` (no arguments) | the person, or the agent on demand | the main window: Today, History, Statistics, Dictionary, Settings |
| `Dictor --update-progress …` | the updater | the progress window during an update |

The agent is `LSUIElement` and lives forever; the window is an ordinary app that
comes and goes. They are **separate processes sharing one bundle**, which is why
settings travel through `UserDefaults` and not through memory: the window
writes, the agent re-reads once a second (`settingsWatchTimerFired`) and applies
what changed. Anything that must reach the running service without a restart —
hotkeys, the floating capsule, the microphone, the dictionary — is applied
there.

The third process exists because a bundle cannot replace itself while running:
the helper has to outlive the bundle it is overwriting.

## The path of one dictation

Seven links, `App.swift` `handleRelease` being the spine:

1. **`HotkeyListener`** — a `CGEventTap` sees the key go down and up. Only the
   bound key is swallowed; its companion modifier is left to the system, because
   eating Command breaks Cmd+Tab in a way that is very hard to attribute later.
2. **`AudioCapture`** — an `AVAudioEngine` tap accumulates float samples and
   converts them to 16 kHz mono. Deliberately **not** `@MainActor`: the tap
   fires on an audio thread, and main-actor entry would trap under Swift 6
   strict concurrency.
3. **`TranscriptionWorker`** — an actor holding FluidAudio's `AsrManager` with
   NVIDIA Parakeet TDT v3 running through CoreML on the Neural Engine. One
   `[Float]` in, one string out; there is no streaming.
4. **`RecordingLifecycle.processedDictationText`** — the single place where text
   is transformed: model repair, then the dictionary (the user's entries, 239
   built-in spellings, 74 Latin-script restorations), then filler-word removal.
   The order is an invariant: an explicit user correction must win.
5. **`TextInsertion`** — the text is placed in the clipboard **lazily** and
   ⌘V is synthesised. The receiving app pulls the text when it asks for it, and
   only then does the previous clipboard come back. If nobody pulls the text
   within 10 seconds, the paste never happened: the dictation stays in the
   clipboard for a manual ⌘V, Enter-after-insert is withheld, and the person
   is told — a silent rollback would leave the optimistic “Inserted” HUD as
   an unfixable lie.
6. **`Statistics` and history** — both written before insertion, so what the
   person sees in History is exactly what was pasted.
7. **`DictationLatencyMetrics`** — 26 measurements of that path, one line per
   dictation in `~/Library/Logs/Dictor.log`.

Measured on real use: about **97% of the delay is the model itself**; everything
else together is under 10 ms.

One deliberate exit from this path: the 20-minute recording ceiling. An
auto-stopped recording is almost always a forgotten toggle-mode one, so the
text goes to History only — never to the cursor, which by then may sit in an
unrelated field — and the error capsule says where to find it.

## Invariants that cost something to learn

- `AudioCapture` is not `@MainActor` (above).
- `AVAudioConverter`'s input block must return `.noDataNow`, never
  `.endOfStream` — the latter puts the converter in a terminal state and every
  press after the first captures silence.
- AVFoundation raises Objective-C exceptions that Swift cannot catch, and an
  uncaught raise on a background thread does not crash: AppKit swallows it and
  suspends the thread, leaving the app frozen behind a healthy-looking status.
  Anything that can raise goes through `withObjCExceptionsAsErrors`, which is
  why there is a tiny Objective-C target in the package.
- Resources are loaded through `Bundle.main`, never `Bundle.module`: SwiftPM's
  generated resource bundle has no Info.plist and breaks `codesign --deep`.
- Self-tests run **before** `NSApplication` is created, so they can build views
  without an app being up.
- The LaunchAgent uses `KeepAlive: {SuccessfulExit: false}`. Plain `true` means
  "relaunch after any exit", which once made the app impossible to quit.
- Code signing uses a stable self-signed certificate. Ad-hoc signatures change
  every build, and macOS ties microphone, accessibility and input-monitoring
  grants to the signature — with ad-hoc, every install demands all three again.

## Where state lives

| What | Where |
|---|---|
| Settings, history, statistics, dictionary | `~/Library/Preferences/com.raul.dictor.plist` |
| Service status for the window, panel PID, dictionary sync file | `~/Library/Application Support/Dictor/` |
| Log | `~/Library/Logs/Dictor.log`; launchd captures the same stream into `~/Library/Logs/Dictor-agent.launchd.log` |
| Speech model (~460 MB, downloaded once) | `~/Library/Application Support/FluidAudio/Models/` |
| Audio | nowhere after the text exists; during recording, a crash-recovery journal that is deleted as soon as the dictation is handled |

## Updates

The app updates itself from a self-hosted channel, and the reasoning behind each
check — why the archive URL is derived from the version instead of read from the
manifest, why a pinned leaf certificate rather than plain `codesign --verify` —
is written out in [docs/updates.md](docs/updates.md).

## How the project checks itself

- **`scripts/check.sh`** — static: manifests, the signing pin against the
  keychain, site markup and asset existence, and grep rules that guard defects
  this project has actually shipped. It does not compile.
- **Self-tests** — 32 suites in `SelfTests.swift`, 29 in `all`, three excluded
  by name because they need a live machine. They exist only in DEBUG builds.
  Several assert *reachability* rather than behaviour: that a control is not
  covered by another view, that an action has a receiver, that a suite is
  reachable from `all`.
- **Rendered screens** — every screen can be exported to PNG in both themes
  without launching the app; that is how layout is reviewed.
- **CI** (`.github/workflows/build.yml`) — runs the first two on every push,
  plus a release build and a set of assertions about the produced bundle. It
  cannot build the disk image (Finder scripting) or publish a release (SSH).

## A decision that was measured and refused

[docs/vocabulary-boosting.md](docs/vocabulary-boosting.md) records why the app
does **not** feed the recogniser a custom vocabulary: the encoder required for
it has 1024 tokens and not one of them is Cyrillic, so every Russian name
collapses into the same run of unknowns. It is here because a documented "no" is
worth as much as a feature, and it stopped this question from being reopened.

## The files

| File | What it is |
|---|---|
| `main.swift` | entry point, argument handling, the three process modes |
| `App.swift` | the agent: menu bar, hotkey handling, the dictation pipeline, diagnostics |
| `ControlPanel.swift` | the window: sections, settings tabs, dictionary |
| `MainWindow.swift`, `SettingsUI.swift`, `SDTheme.swift` | the design system — every control is drawn by hand to match the mockups in both themes |
| `HotkeyListener.swift` | the event tap and chord handling |
| `AudioCapture.swift`, `AudioInputDevices.swift` | recording, conversion, device selection |
| `TranscriptionWorker.swift` | the model |
| `TranscriptCorrections.swift`, `BuiltInSpellings.swift`, `LatinTermRestorations.swift`, `FillerWordRemoval.swift` | text after recognition |
| `TextInsertion.swift` | clipboard and keystroke insertion |
| `Settings.swift`, `CoreTypes.swift` | stored settings and shared types |
| `SettingsCatalog.swift` | the settings registry: every `Settings` var is declared shown-somewhere, internal, or user data — `check.sh` cross-checks the list, the `settings-reachable` suite proves the shown rows are clickable |
| `Statistics.swift` | what the Statistics section shows |
| `UpdateCheck.swift`, `UpdateWindow.swift` | the updater |
| `ModelIntegrity.swift` | per-file SHA-256 verification of the model, cache paths, disk space |
| `Permissions.swift`, `PermissionsDoctor.swift` | the three macOS permissions and the three reasons a granted one still gets asked for |
| `InstallLocation.swift` | moving the app into Applications, quarantine |
| `ServiceStatus.swift`, `FloatingCapsule.swift`, `QuickPanel.swift` | service state, the floating capsule, the menu-bar popover |
| `Onboarding*.swift` | first-run flow inside the window |
| `SelfTests.swift` | all suites (DEBUG only) |
