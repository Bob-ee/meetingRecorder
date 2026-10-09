# Architecture

Meeting Recorder is three programs that share one Swift package:

```
┌──────────────────────┐          Tailscale            ┌──────────────────────────────┐
│  Mac app             │ ───── upload audio ─────────▶ │  meetinghub (self-hosted)     │
│  · records calls     │ ◀──── change feed ──────────▶ │  · SQLite + audio files       │
│  · local Markdown    │                               │  · job queue: transcribe →    │
│    folder            │                               │    diarize → summarize        │
├──────────────────────┤                               │  · provider keys (encrypted)  │
│  iPhone / iPad app   │ ───── upload audio ─────────▶ │  · export mirror (Markdown)   │
│  · records the room  │ ◀──── change feed ──────────▶ │                               │
│  · local cache       │                               │                               │
└──────────────────────┘                               └──────────────────────────────┘
```

## Why a hub

* The laptop that records a call is often closed or offline right afterwards. Processing should not wait for it.
* Phones cannot record Zoom/Meet/Slack calls (iOS has no system-audio capture; Android's playback capture is
  opt-in per app). Their job is recording in-person meetings and reading/editing notes, which only needs an API.
* Users own their data. A hub is a single binary on a Mac mini or Linux box, not a service someone else runs.

## Package layout

| Target | What | Depends on |
|---|---|---|
| `MeetingCore` | Models, prompts, JSON repair, Markdown rendering, `Transcriber`/`Summarizer` protocols, API wire types, pairing codes. Pure Foundation — builds anywhere. | — |
| `MeetingSync` | What every client needs to talk to a hub: `HubClient`, the sync engine (`SyncEngine`, `SyncMerge`), and `HubConnection`, which keeps a device in step while it is online. Apple platforms. | Core |
| `MeetingEngine` | The processing stack: `AudioLoader`, `TranscriptionService` (FluidAudio/Parakeet + diarization, Apple platforms), `ClaudeCLISummarizer`, `AnthropicSummarizer`, `OpenAICompatibleSummarizer`, `AudioArchiver`. | Core, FluidAudio (macOS only) |
| `MeetingRecorder` | The macOS app. Capture (Core Audio taps, AVAudioEngine), local file store, SwiftUI. Can process locally or through a hub. | Core, Sync, Engine |
| `MeetingHub` (`meetinghub`) | Vapor server: API, job worker, SQLite via Fluent, launchd service, CLI. | Core, Engine, Vapor, Fluent |

The iOS app is an Xcode project (`Apps/iOS`, generated from `project.yml` by `scripts/ios-project.sh`) that uses
`MeetingCore` and `MeetingSync` from this package.

Prompts and the reply schema live in `MeetingCore/Prompts.swift`, so summaries read the same whether the app
or the hub produced them, and whichever model wrote them.

## Hub

**Data directory** (`$MEETINGHUB_DATA`, default `~/MeetingHub`):

```
config.json      port, bind address, extra allowed CIDRs
hub.sqlite       everything structured
master.key       32 random bytes, mode 0600 — encrypts provider secrets in the DB
audio/<workspace>/<meeting>/{mic,system,import}.<ext>
export/<Workspace>/<Project>/<yyyy-MM-dd HHmm Title>/{meeting.json,transcript.md,summary.md,notes.md}
logs/hub.log
```

**Schema** — every row hangs off a workspace so multi-user is "add rows", never "add columns":
`users → workspaces → projects → meetings → {action_items, transcripts, summaries, audio_files, jobs}`,
plus `device_tokens` (hashed, revocable, per device), `settings` (per workspace; the summarizer block is
AES-GCM encrypted) and `tombstones` (what was deleted — see Sync). There is one user and one workspace today. Nothing about billing exists.
`meetings.events` holds the suggested calendar events as JSON (with the user's added/dismissed state);
`action_items.due_date` is the resolved deadline and `calendar_added_at` when it went into a calendar.

**Auth**: `Authorization: Bearer <device token>` on every `/api/v1` call except `/health`. Tokens are 256-bit
random, stored as SHA-256. Before auth, `RemoteAllowlistMiddleware` only admits localhost, the Tailscale range
(100.64.0.0/10, fd7a:115c:a1e0::/48) and any `allowedCIDRs` from `config.json` — the tailnet may contain other
people's machines, so being on it is not enough.

**Pairing**: `meetinghub setup` / `meetinghub pair` print `mh1:<host>:<port>:<token>`; the client pastes that one
string. Host is the Tailscale MagicDNS name when available. `mh1s:` means TLS. A device that is already paired can
ask for a code for another one (`POST /devices`); the Mac app shows it as a QR holding
`meetingrecorder://pair?code=…`, so pairing a phone is pointing its camera at the Mac.

**Jobs**: `POST /meetings/:id/process` enqueues `[transcribe, summarize]` (or a subset). `JobRunner` is an actor
that works one job at a time — the speech models are heavy and one meeting at a time is the right speed for a
16 GB machine. Progress is written to the job and meeting rows and pushed over `GET /events` (server-sent events;
a ping every 20 s). Jobs that were running when the process died go back to the queue on start.

**Summarizers** are selected per workspace from the client (`GET /capabilities` describes each provider's fields
so the settings form is data-driven; `PUT /settings` merges — secrets come back redacted and stay unchanged if the
client sends the placeholder back):

| Provider | How | Cost |
|---|---|---|
| `claude-cli` | `claude -p --json-schema …` on the hub. Headless login via `claude setup-token` pasted into settings (`CLAUDE_CODE_OAUTH_TOKEN`). | Claude subscription |
| `anthropic` | Messages API, forced tool call so the reply is schema-validated server-side. | per token |
| `openai-compatible` | `/chat/completions` with `response_format: json_object` (dropped if the server rejects it). Covers OpenAI, Ollama, LM Studio, Groq, OpenRouter. | per token / free locally |

Any free-text reply goes through `JSONRepair` (fences, prose, raw newlines in strings, trailing commas).

**Dates.** The prompt states the meeting's weekday, date, time and zone, and asks for deadlines and events as
local strings (`2026-09-04`, or `2026-09-04T15:00` when a time was said) — models resolve "next Thursday" well
and UTC offsets badly. `LocalDate.parse` reads them on the same machine that rendered the prompt, drops anything
before the meeting day or years out, and stores an `EventDate` (instant + whether a time was given + the zone it
was resolved in), so a whole-day event stays on its day on every device. Events and resolved deadlines are
merged into the meeting like action items are, keeping what the user did with them (added, dismissed).

**Transcription** on the hub is the same `TranscriptionService` the app uses (Parakeet TDT v3 + offline
diarization, CoreML). On Linux that target compiles to a stub that reports "unavailable" — the slot is there for a
Linux engine (sherpa-onnx) or a cloud provider.

## Sync

Several devices edit the same meetings, and most of them are offline or asleep most of the time. Three pieces
make that safe.

**Revisions.** Each workspace has a counter. Every write to a project or meeting takes the next value and records
it on the row (`RevisionMiddleware` — it is model middleware, so no write can forget), and a delete leaves a
tombstone carrying one. `GET /changes?since=N` returns everything after N: changed projects, changed meetings
(with their action items and notes), and tombstones, plus the revision to ask from next time. No device clock is
involved. Revisions are handed out inside the transaction that writes the row, and SQLite runs one writing
transaction at a time, so they commit in order — a device that has read up to N has not missed anything below it.

**Tombstones.** A deleted meeting or project is remembered. Devices that were away learn of the delete from the
feed, and the hub answers `410 Gone` to anyone who tries to create it again — which is what a stale device does
when it pushes an edit to something it doesn't know was deleted.

**Three-way merge.** A device keeps, next to its own copy of each project and meeting, the copy the hub last gave
it (the *base*, in `SyncLedger`). What it changed is whatever differs from the base, and that is all it sends: one
`POST /meetings/:id/edits` carrying the changed fields, the action items it added, changed and removed, and the
events it marked — applied by the hub as one write. The reply is the meeting as the hub now holds it, and is merged
exactly like a meeting from the feed: the hub's copy wins except where this device has an edit the hub hasn't
seen (`SyncMerge`). So two devices editing different things both keep their edits; two editing the same field
converge on whichever reached the hub last.

Only what a person edits takes part — titles, notes, speaker names, a meeting's project, an action item's wording
and state, whether a suggested event was added or dismissed. Status, transcripts, summaries and the advice written
for an action item are the hub's, and always flow one way. Transcripts and summaries are large, so the feed carries
a `contentTag` per meeting instead; a device refetches them only when the tag changes.

`HubConnection` runs this while a device is online: local edits are pushed about a second after they stop, the
hub's server-sent events trigger a pull, and a sync runs every minute regardless. The Mac's replica is its
Markdown folder; the iOS app's is a JSON cache.

## API (v1)

```
GET    /health                              no auth; HubInfo
GET    /me                                  who am I, which workspace, which device
GET    /capabilities                        providers + their fields, transcription engines
GET    /projects · POST /projects · GET|PATCH|DELETE /projects/:id
GET    /meetings?project=&since=&limit=     Meeting[] (action items embedded)
POST   /meetings                            CreateMeetingRequest (client may supply the id → idempotent)
GET    /meetings/:id                        MeetingDetail (transcript, summary, notes, audio, latest job)
PATCH  /meetings/:id                        title, titleIsAuto, notes, speakerNames, projectID, events, …
DELETE /meetings/:id
GET    /changes?since=&limit=               ChangeSet — everything written after a revision
POST   /meetings/:id/edits                  MeetingEdit → MeetingRecord (what one device changed, as one write)
POST   /devices                             a pairing code for another device
PUT    /meetings/:id/audio/:kind            raw body, streamed to disk; X-File-Name, X-Content-SHA256;
                                            X-Meeting creates the meeting if needed, X-Process queues the job
GET    /meetings/:id/audio · /audio/:kind
POST   /meetings/:id/process                {steps:[transcribe,summarize]} → JobInfo (idempotent while pending)
GET    /meetings/:id/job · GET /jobs
POST|PUT /meetings/:id/action-items · PATCH|DELETE /meetings/:id/action-items/:item
GET    /meetings/:id/{transcript,summary,export}.md
GET    /search?q=&project=
GET|PUT /settings · POST /settings/test
GET    /events                              text/event-stream of HubEvent
```

Wire types are the structs in `MeetingCore/API.swift`; dates are ISO-8601.

## The app in hub mode

The app stays offline-first. Its local folder remains the UI's source of truth; the hub replaces *processing*:

1. Recording stops → tracks are compressed to AAC → the meeting is created on the hub with the same id → tracks
   are uploaded (resumable by re-PUT; checksum-verified) → `process` is called. Status: `uploading → queued`.
2. From there the meeting is the hub's: `transcribing → summarizing → ready`, the transcript, the summary and the
   action items arrive through the change feed like any other change, and the progress line follows `/events`.
3. Local edits (title, notes, action items, speaker names, project, calendar events) and edits made elsewhere
   travel as described under Sync.
4. No network? The meeting waits in `uploading` with "Waiting for the hub…" and retries with backoff; nothing is lost.
5. Projects are matched by id, and on first connect by name: a local "Inbox" adopts the hub's "Inbox" id instead of
   becoming "Inbox 2". Local projects the hub doesn't have are created there.
6. `Settings → Upload existing meetings` pushes meetings processed before the hub existed (transcript, summary,
   action items, notes, compressed audio) so other devices can see them.

## The iOS app

A phone can't capture a call, so its job is the meeting in the room, and everything after any meeting.

* **Recording**: the microphone, to AAC, continuing with the screen locked. A phone recording is one track with
  everyone on it, so it is uploaded as the `import` kind and the hub separates the speakers.
* **Upload**: one background `URLSession` request per recording that also creates the meeting and queues the job
  (`X-Meeting`, `X-Process`). The system delivers it whenever the hub is reachable, whether or not the app runs
  again — a recording doesn't depend on a second request.
* **Import**: an audio file shared or opened into the app (Voice Memos, Files) goes the same way.
* **Everything else** — browsing, search, notes, action items, calendar, advice — works on the cache and syncs.

The hub is plain HTTP inside the tailnet's WireGuard tunnel; the app's transport-security exception is limited to
`*.ts.net` and local addresses.

## Roadmap

* Web UI served by the hub (browse, search, copy, notes, in-browser mic recording).
* Push notifications when a meeting is ready; a share extension so importing doesn't open the app.
* Linux transcription engine + Docker image; `tailscale serve` TLS by default.
* Real multi-user: login, workspace members, per-workspace plans. The schema is ready; the UI isn't written.
