# Privacy

Dictor is designed for local dictation.

## Data that stays on the Mac

- Microphone audio is processed locally and is not sent to a transcription API.
- Successful transcripts, timing statistics, corrections, and preferences are
  stored in the app's preferences file,
  `~/Library/Preferences/com.raul.dictor.plist`. Service state and the
  crash-recovery journal live under `~/Library/Application Support/Dictor`.
- Diagnostic logs are stored under `~/Library/Logs` and avoid transcript text;
  they do record the name of the app each dictation was inserted into.
- Pending audio is kept only as a crash-recovery safeguard and is removed after
  it has been handled.
- The speech model is cached by FluidAudio under
  `~/Library/Application Support/FluidAudio/Models`.

## Network access

Dictor uses the network only to download the speech model — the files come
from `huggingface.co`, where FluidAudio hosts them — and to ask the update
channel at `https://dictor.raulgumerov.com` for the latest version number, at
most once every six hours. Turn the update check off in Settings → General and
the app stops going online on its own, with one exception: if the cached model
files ever fail their integrity check, the model is re-downloaded from
`huggingface.co` regardless of that switch.

An app update can bring a new speech model. In that case dictation keeps
working on the model already on the Mac while the new one is downloaded in the
background from the same place; nothing else is requested, and the old model
is never downloaded again.

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

## Reporting a problem

"Report a Problem…" (in the menu-bar menu and in Settings) packs three things
into a zip archive: the diagnostics report described above, the tail of the
app's own log (no dictated text, by construction), and any crash reports for
Dictor found in `~/Library/Logs/DiagnosticReports`. It then opens a new
message in your mail app with the archive attached and the recipient filled
in. Nothing is uploaded by the app itself: the message goes out only if you
press Send, and you can open the archive and read every file before you do.
If no mail account is configured, the system share sheet is offered instead,
and failing that the archive is simply shown in Finder.

## Sharing your dictionary

"Share the dictionary" (Settings → Text) writes your own corrections — what the
model hears and what the text should say — into one file, the same file Export
produces, and opens a new message in your mail app with it attached and the
recipient filled in. The built-in sets are not included, and the file holds no
dictated text. As with a problem report, nothing is sent by the app: the
message goes out only if you press Send, and the file can be opened and read
first. Corrections can contain names you taught the app, so look before you
send.

## What smart insertion reads

To tell whether a dictation continues a sentence, smart insertion looks at the
last 80 characters before the cursor in the field the text is about to go
into, and at which app that field belongs to. It does this through the
Accessibility permission the app already needs for inserting text. Those
characters are used for one decision and dropped: they are not stored, not
written to the log, and not sent anywhere. Password fields are not read, and
neither are the common terminal apps — what stands before the cursor there is
a prompt, not a sentence. Switch smart insertion off in Settings → Text and the
app stops reading the field altogether.

## macOS permissions

- **Microphone** records speech while dictation is active.
- **Accessibility** inserts the resulting text into the focused field and, with
  smart insertion on, reads the few characters before the cursor there.
- **Input Monitoring** observes the configured global hotkey.
