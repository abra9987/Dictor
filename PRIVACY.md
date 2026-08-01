# Privacy

Dictor is designed for local dictation.

## Data that stays on the Mac

- Microphone audio is processed locally and is not sent to a transcription API.
- Successful transcripts, timing statistics, corrections, and preferences are
  stored under `~/Library/Application Support/Dictor`.
- Diagnostic logs are stored under `~/Library/Logs` and avoid transcript text.
- Pending audio is kept only as a crash-recovery safeguard and is removed after
  it has been handled.
- The speech model is cached by FluidAudio under
  `~/Library/Application Support/FluidAudio/Models`.

## Network access

Dictor uses the network only to download the speech model through FluidAudio
and to ask the update channel at `https://dictor.raulgumerov.com` for the
latest version number, at most once every six hours. Turn the update check off
in Settings → General and the app stops using the network altogether.

When an update is installed, the archive is downloaded from that same channel;
its address is derived from the version number rather than taken from the
manifest, and both its SHA-256 checksum and its code signature are verified
before anything is replaced.

The request carries no identifier of you or your machine, and nothing is sent
back: the app asks for a file and reads a version number out of it. There is no
account system, advertising, analytics, or telemetry.

## The update server's logs

Like any web server, the update channel records an ordinary access log: the
time, the file requested, and the IP address the request came from. It is used
for two things — counting how many times a release was downloaded and how many
times the page was opened.

Requests the app makes to the update manifest are deliberately **not** counted.
They would show how many installs are alive and when they are in use, and that
is watching people rather than watching a download page.

Those logs are not kept. An hourly job reduces them to per-day counts —
downloads per version, page views, number of distinct addresses — and stores
only those numbers; no address is written to the summary. The container's own
log holds at most 30 MB and rotates away on its own.

Nothing in this comes from the app. It reports nothing, and adding a way for it
to do so would contradict the reason it exists.

## macOS permissions

- **Microphone** records speech while dictation is active.
- **Accessibility** inserts the resulting text into the focused field.
- **Input Monitoring** observes the configured global hotkey.
