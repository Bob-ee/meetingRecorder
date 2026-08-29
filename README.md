# Meeting Recorder

A native macOS app that records your meetings (Zoom, Google Meet, Slack huddles, Teams — anything that plays audio),
transcribes them **on-device for free**, and has Claude write the summary and action items.
Meetings are organized into **Projects → Meetings**, the way Claude organizes Projects → Chats.

## How it works

| Step | How | Cost |
|---|---|---|
| Capture | Core Audio process tap for system audio (what everyone else says) + AVAudioEngine for your mic, saved as two tracks | free |
| Transcribe | NVIDIA Parakeet TDT 0.6B v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine, plus offline speaker diarization | free, ~600 MB one-time model download |
| Summarize | `claude -p` (Claude Code headless) on your Claude subscription — no API key | included in your plan |
| Store | Plain Markdown + JSON under `~/Meetings/<Project>/<date title>/` — point Claude Code at the folder | — |

Because your mic is its own track, everything you say is labeled with your name exactly; diarization only has to
separate the remote participants ("Speaker 1", "Speaker 2", … — rename them in the Transcript tab).

## Build & run

Requires macOS 15+ on Apple Silicon and either Xcode or the Command Line Tools.

```sh
scripts/run.sh            # builds build/MeetingRecorder.app and launches it
scripts/build-app.sh      # just build
```

Open `Package.swift` in Xcode to edit/debug. The build script signs with the first valid **Apple Development**
identity in your keychain (falling back to ad-hoc); override with `SIGN_IDENTITY="…" scripts/build-app.sh`.

## First run

1. **Record** (toolbar, menu bar icon, or ⇧⌘R). macOS will ask for **Microphone** and **System Audio Recording** access — grant both.
2. **Stop** when the call ends. The app transcribes (first time downloads the models), then summarizes with Claude.
3. Every tab has its own **Copy** button (⇧⌘C): the summary (with decisions, action items and open questions),
   the transcript, the action-item checklist, or your notes. Copies land on the clipboard as formatted text *and*
   Markdown, so they paste with headings/bold/checklists intact into Gmail, Mail, Docs, Slack, Notes — and as plain
   Markdown into editors or Claude. The ⋯ menu has **Copy Everything** for the whole meeting in one go. Or just point
   Claude Code at `~/Meetings`.

Turn on *Detect meetings automatically* (Settings / menu bar) and the app notices when another app opens the
microphone and asks whether to record.

## Processing on a hub (optional)

The app can hand all processing — transcription, speaker identification, summarization — to a **hub**: a small
server you run on an always-on Mac (a Mac mini, an old MacBook with the lid closed) so your laptop can go offline
or to sleep the moment a call ends. The hub also holds the database, so phones and other computers can read and
edit the same meetings. See [docs/architecture.md](docs/architecture.md).

**Install the hub** on the always-on machine (Command Line Tools / Swift required):

```sh
curl -fsSL https://raw.githubusercontent.com/Bob-ee/meetingRecorder/main/scripts/install-hub.sh | sh
```

That builds `meetinghub`, starts it as a background service and prints a **pairing code** like
`mh1:labmbp.tail22b52.ts.net:8787:mh_…`. Paste it into the app under **Settings → Hub**. Both machines being on
the same [Tailscale](https://tailscale.com) network is the easiest way to reach the hub from anywhere; the hub only
accepts connections from localhost and the tailnet unless you add ranges to `~/MeetingHub/config.json`.

**Pick a summarizer** in the app (Settings → Hub → Summarizer), or with the API:

| Provider | What you need |
|---|---|
| Claude subscription | run `claude setup-token` on any computer where Claude Code is logged in, paste the token |
| Anthropic API | an API key (a one-hour meeting costs a few cents) |
| OpenAI-compatible | a base URL — OpenAI, or a local Ollama / LM Studio for fully offline summaries |

Useful commands on the hub machine:

```sh
meetinghub pair --name "Bobby's iPhone"   # another pairing code
meetinghub tokens                          # list devices; --revoke NAME to revoke
meetinghub service status|restart          # launchd service
tail -f ~/MeetingHub/logs/hub.log
```

Everything the hub knows is also written as plain Markdown/JSON under `~/MeetingHub/export/`, in the same layout
the app uses locally.

## Bringing in recordings from elsewhere

Recorded a meeting on your phone, or have a Zoom cloud/local recording? Any of these runs the full pipeline:

- **Drag the file onto a project** in the sidebar (or anywhere in the window → current project).
- **Put it in the project's folder** in Finder: `~/Meetings/<Project>/recording.m4a` — the app watches those folders and
  imports it (works while the app is closed too; it's picked up on next launch). A new folder there becomes a new project.
- **Open it with the app** — Finder "Open With", drop on the Dock icon, or `open -a "Meeting Recorder" file.m4a`.
- **Import…** in the toolbar (⌘I).

Audio formats: m4a, mp3, wav, aiff, caf, flac, and video (mp4, mov, …) — audio gets extracted automatically.
Since everyone is on one track, all voices come out as "Speaker 1…N" (rename them in the Transcript tab).

## Project context

Right-click a project → **Edit Project Context**. Whatever you write there (who's who, jargon, goals) is given to
Claude before every summary in that project — same idea as Claude project instructions.

## Stable permissions

Ad-hoc signed builds get a new signature on every rebuild, so macOS re-asks for Microphone and System Audio Recording
each time. With an Apple Development certificate (Xcode → Settings → Accounts → Manage Certificates → + → Apple
Development) the permissions stick. If `security find-identity -v -p codesigning` says "0 valid identities" even though
the cert exists, the WWDR G3 intermediate is missing — install it with
`curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`.

## Layout on disk

```
~/Meetings/
  Product Launch/
    project.json
    CONTEXT.md
    2026-08-28 1400 Weekly sync/
      meeting.json        # title, status, action items, speaker names
      mic.m4a             # your mic (recorded as CAF, compressed to AAC after transcription)
      system.m4a          # everyone else (or import.<ext> for imported files)
      transcript.json     # segments with speaker + timestamps
      transcript.md
      summary.md
      notes.md
```

## Settings

- **Your name**: defaults to your macOS account's first name; it labels your mic track and is how Claude refers to you in summaries.
- **Speech model**: Parakeet v3 (25 languages) or v2 (English-only, slightly better recall).
- **Echo cancellation**: uses Apple's voice-processing unit so speaker audio doesn't bleed into your mic track.
- **Claude model**: sonnet / opus / haiku.
- **Path to claude**: auto-detected (`~/.local/bin/claude`, Homebrew, etc.).
