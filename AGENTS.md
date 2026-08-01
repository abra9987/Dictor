# Working on Dictor

Short version for whoever — or whatever — edits this repository next. The *why*
behind the design lives in [ARCHITECTURE.md](ARCHITECTURE.md); this file is only
the procedure.

## Before every commit

```bash
./scripts/check.sh
swift build -c debug --package-path swift
swift/.build/debug/Dictor --self-test all
```

Both must pass. `check.sh` compiles nothing, so build first if you touched
Swift, or the self-tests run the previous binary. `--self-test all` writes to
the real preferences domain — see [CONTRIBUTING.md](CONTRIBUTING.md) before
running it on a machine whose dictation history matters.

## Rules that are not negotiable

- **No "done" without a render.** Any change to a screen is verified by
  exporting it to PNG and looking at it, in both light and dark. The eight
  export flags are listed in CONTRIBUTING.md.
- **New behaviour gets a self-test**, and the self-test asserts reachability,
  not just correctness: this project has shipped a fully written updater nobody
  could reach and a search-field clear button that never received a click.
- **The version lives in `swift/Info.plist`** and nowhere else. Tag, manifest and
  archive URL are derived from it.
- **Comments are Russian and explain why.** User-visible strings are bilingual
  through `t("рус", "eng")`.
- **The upstream project's name stays out of the sources and scripts.** It
  belongs in `LICENSE` and `NOTICE.md`, as MIT requires, and `check.sh` enforces
  exactly that.
- **Never invent data.** Where the engine records nothing, the UI says nothing —
  a plausible number is worse than an empty state.

## Installing a local build

In this order, or launchd unloads the service and the menu-bar icon disappears:

```bash
kill <pid of the process without --agent>
launchctl bootout gui/$(id -u)/com.raul.dictor.agent
rm -rf /Applications/Dictor.app
ditto dist/Dictor.app /Applications/Dictor.app
open /Applications/Dictor.app      # the panel installs the service itself
```

Permissions cannot be tested from a terminal: a process launched from a shell
inherits the terminal's TCC grants and reports everything as allowed.
