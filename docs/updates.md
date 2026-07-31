# How Dictor updates itself

Dictor is distributed outside the App Store, so it has to answer a question the
App Store normally answers for you: why is it safe to let this application
replace itself on your machine?

This is the answer, in the order the code performs it.

## The channel

A static host serves three things:

- `update.json` — `{ "version": "1.1.3", "sha256": "…", "notes": "…" }`
- `Dictor-<version>.zip` — the bundle the updater installs
- `Dictor-<version>.dmg` — the disk image for a first install

There is no API, no account, and nothing that identifies the machine asking.
The check sends a fixed `User-Agent` of `dictor-update-check` and no other
header. It runs 30 seconds after the service starts and every six hours after
that, and it can be switched off in the menu-bar panel — with it off, the app
makes no network calls at all once the speech model is downloaded.

**Why not GitHub Releases:** the update flow predates this repository being
public, and it stays as it is because the app must not depend on a service that
rate-limits anonymous requests. The `.dmg` is mirrored to GitHub Releases for
people who look for a download button there.

## What is checked before anything is replaced

1. **The version in the manifest must match the version being installed.**
   A manifest that offers a different version than the one the user agreed to
   aborts the update.

2. **The archive URL is derived from the version, not read from the manifest.**

   ```swift
   func updateArchiveURL(forVersion version: String) -> URL {
       UPDATE_CHANNEL_PAGE.appendingPathComponent("Dictor-\(version).zip")
   }
   ```

   A substituted manifest therefore cannot redirect the download to another
   host. The manifest is our own file, but it is still treated as untrusted
   input.

3. **The download is capped** at 64 MB, and its SHA-256 must equal the digest
   in the manifest.

4. **The extracted bundle must satisfy a code-signing requirement**, not merely
   be signed:

   ```
   =identifier "com.raul.dictor" and certificate leaf = H"<fingerprint>"
   ```

   This is the part that matters. `codesign --verify` alone confirms only that
   a bundle is intact and signed *by someone* — any correctly signed
   application passes it. Pinning the leaf certificate means an archive placed
   at the update URL by anyone else is rejected.

   `scripts/check.sh` compares the pinned fingerprint against the signing
   identity in the keychain, so re-issuing the certificate fails the build
   rather than silently breaking updates for everyone. A self-test signs a
   synthetic bundle with a foreign identity and asserts that validation
   refuses it.

5. **Symlinks inside the archive are rejected**, and the bundle's identifier
   and version are checked against what was promised.

## The replacement

The app cannot replace the bundle it is executing from, so a helper script
does it. The script:

- waits for the process that launched it to exit (and sends `SIGTERM` if it
  outstays a timeout),
- takes down **every** process of the application, not just the background
  service — the window is a separate process, and leaving it alive meant the
  final `open` found a live app with the same bundle id and merely raised it,
  so nothing installed the launchd job and dictation quietly disappeared,
- moves the current bundle aside rather than deleting it,
- copies the new one into place with `ditto`,
- verifies the installed bundle's identifier, version and signature,
- **rolls back** to the moved-aside copy if any step fails,
- reopens the app and bootstraps the launchd job itself.

Progress is written to a state file that a small progress window reads, so the
update is visible while it happens rather than being a period of silence.

## Releasing

`scripts/make-release.sh` performs the whole sequence and refuses to publish
anything that would fail on the user's side:

1. the working tree must be clean and the tag must not exist yet,
2. `check.sh` runs,
3. the app, the disk image and the archive are built,
4. **the archive is unpacked and verified against the same code-signing
   requirement the updater enforces** — if the release would not install, it is
   not published,
5. the version inside the archive is compared with the version being released,
6. files are uploaded with the manifest **last**, so the app never sees a
   version announced before its archive exists,
7. the published manifest and archive are downloaded back and compared with
   the local ones,
8. the commit is tagged.

The version lives in `swift/Info.plist` and the git tag is derived from it, so
the two cannot drift apart.

`--dry-run` builds everything and stops before publishing; it does not require
a clean tree, so it can be used mid-work.
