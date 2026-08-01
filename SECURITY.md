# Security

Please report a suspected vulnerability privately through GitHub's
**Security → Report a vulnerability** page for this repository. Do not include
private transcript text, audio, credentials, or full diagnostic logs in a public
issue.

## How the app is distributed

Dictor requires no account and no cloud transcription service. It is distributed
as a signed disk image from `https://dictor.raulgumerov.com` and updates itself
from the same channel.

The bundle is signed with this project's own certificate — **not** notarized by
Apple. On a first install macOS therefore says it cannot verify the developer,
and the person has to allow it in System Settings. That is the honest state of
things: an unnotarized app asks the user for a trust decision, and this document
exists partly so that decision can be an informed one.

## What the updater checks before replacing the bundle

Four things, and any one of them failing aborts the update:

1. the version in the manifest is newer than the running one;
2. the archive URL is **derived from that version**, never read from the
   manifest — a tampered manifest cannot point the download at another host;
3. the download is size-capped and its SHA-256 must match the manifest;
4. the unpacked bundle must satisfy a code-signing requirement pinning both the
   bundle identifier and the leaf certificate, not merely "is signed".

The mechanism is described in full, next to the code it corresponds to, in
[docs/updates.md](docs/updates.md).

## Quarantine

Opened from the disk image rather than from Applications, macOS runs the app
from a read-only throwaway copy: the LaunchAgent points at a path that will
vanish, and the permissions the person grants belong to a ghost. To avoid that,
Dictor offers to move itself into Applications, and the copy it places there has
the quarantine attribute removed (`swift/Sources/Dictor/InstallLocation.swift`,
`xattr -dr com.apple.quarantine`).

This does not bypass Gatekeeper. The person has already passed this exact bundle
through Gatekeeper by opening it, and the attribute is cleared only on the copy
Dictor just made from the bundle the user launched. Nothing downloaded
afterwards, and nothing the user has not already approved, is ever
unquarantined.
