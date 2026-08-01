# Contributing

Issues and pull requests are welcome. Keep changes focused, preserve local-only
transcription, and test on an Apple Silicon Mac running macOS 14 or newer.

## Before opening a pull request

The same three commands CI runs, in the same order:

```bash
./scripts/check.sh
swift build -c debug --package-path swift
swift/.build/debug/Dictor --self-test all
```

`check.sh` compiles nothing — it is a static pass over the manifests, the
signing pin, the site markup and a set of grep rules. If you edited Swift, build
first, or the self-tests run yesterday's binary.

⚠️ **`--self-test all` writes to the real preferences domain.** One suite swaps
the dictation history for fixtures and restores it in a `defer`; if it dies
half-way, your history dies with it. Take a copy first:

```bash
defaults export com.raul.dictor ~/dictor-settings-backup.plist
```

Three suites are deliberately outside `all` and have to be run by name:

| Suite | Why it is separate |
|---|---|
| `insertion-target-live` | probes the accessibility API of whatever app is in front |
| `clipboard-paste-live` | uses the real clipboard and a second process to read it |
| `corrections-cost` | prints a measurement, asserts nothing |

## Screens

Every screen is verified by rendering it, not by eye:

```bash
swift/.build/debug/Dictor --export-settings-preview   /tmp/shots   # 14 PNG
swift/.build/debug/Dictor --export-history-preview    /tmp/shots ru
swift/.build/debug/Dictor --export-onboarding-preview /tmp/shots
swift/.build/debug/Dictor --export-popover-preview    /tmp/shots ru
swift/.build/debug/Dictor --export-update-preview     /tmp/shots
swift/.build/debug/Dictor --export-status-preview     /tmp/shots
swift/.build/debug/Dictor --export-capsule-preview    /tmp/shots ru
swift/.build/debug/Dictor --export-hud-animation      /tmp/shots ru
```

The loop is: render → look at the PNG → fix → render again.

## Versions and releases

The version lives in `swift/Info.plist` and nowhere else — the git tag, the
update manifest and the archive URL are all derived from it. Published assets
are immutable: release a new version rather than replacing an archive people may
already have.

Two things you cannot run without access to this project's machine, and that is
expected:

- `scripts/make-dmg.sh` arranges the Finder window through AppleScript and needs
  automation permission;
- `scripts/make-release.sh` needs `scripts/release.env` and an SSH key to the
  update channel.

## Style

Comments are written in Russian and explain *why*, not *what* — the code already
says what. User-visible strings are bilingual through `t("рус", "eng")`.
`ARCHITECTURE.md` in the repository root describes how the pieces fit together
and which invariants are load-bearing; read it before refactoring concurrency,
resource loading or code signing.
