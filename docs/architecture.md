# Architecture

Meeting Recorder is two programs that share one Swift package:

```
┌──────────────────────┐        HTTPS/Tailscale        ┌──────────────────────────────┐
│  Mac app (capture +  │ ───── upload audio ─────────▶ │  meetinghub (self-hosted)     │
│  client)             │ ◀──── events / results ────── │  · SQLite + audio files       │
│  · records calls     │                               │  · job queue: transcribe →    │
│  · offline outbox    │        phone / web            │    diarize → summarize        │
│  · local Markdown    │ ◀──────── same API ─────────▶ │  · provider keys (encrypted)  │
│    mirror            │                               │  · export mirror (Markdown)   │
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
| `MeetingEngine` | The processing stack: `AudioLoader`, `TranscriptionService` (FluidAudio/Parakeet + diarization, Apple platforms), `ClaudeCLISummarizer`, `AnthropicSummarizer`, `OpenAICompatibleSummarizer`, `AudioArchiver`. | Core, FluidAudio (macOS only) |
| `MeetingRecorder` | The macOS app. Capture (Core Audio taps, AVAudioEngine), local file store, SwiftUI. Can process locally or through a hub. | Core, Engine |
| `MeetingHub` (`meetinghub`) | Vapor server: API, job worker, SQLite via Fluent, launchd service, CLI. | Core, Engine, Vapor, Fluent |

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
plus `device_tokens` (hashed, revocable, per device) and `settings` (per workspace; the summarizer block is
AES-GCM encrypted). There is one user and one workspace today. Nothing about billing exists.
`meetings.events` holds the suggested calendar events as JSON (with the user's added/dismissed state);
`action_items.due_date` is the resolved deadline and `calendar_added_at` when it went into a calendar.

**Auth**: `Authorization: Bearer <device token>` on every `/api/v1` call except `/health`. Tokens are 256-bit
random, stored as SHA-256. Before auth, `RemoteAllowlistMiddleware` only admits localhost, the Tailscale range
(100.64.0.0/10, fd7a:115c:a1e0::/48) and any `allowedCIDRs` from `config.json` — the tailnet may contain other
people's machines, so being on it is not enough.

**Pairing**: `meetinghub setup` / `meetinghub pair` print `mh1:<host>:<port>:<token>`; the client pastes that one
string. Host is the Tailscale MagicDNS name when available. `mh1s:` means TLS.

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
PUT    /meetings/:id/audio/:kind            raw body, streamed to disk; X-File-Name, X-Content-SHA256
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
2. The app follows `/events` (falling back to polling) and mirrors `transcribing → summarizing → ready` locally,
   then pulls the transcript, summary and action items into its files.
3. Local edits (title, notes, action items, speaker names, project, calendar events) are pushed as patches; edits made elsewhere
   (phone, web) arrive through `GET /meetings?since=` and events. Last write wins per field.
4. No network? The meeting waits in `uploading` with "Waiting for the hub…" and retries with backoff; nothing is lost.
5. Projects are matched by id, and on first connect by name: a local "Inbox" adopts the hub's "Inbox" id instead of
   becoming "Inbox 2". Local projects the hub doesn't have are created there.
6. `Settings → Upload existing meetings` pushes meetings processed before the hub existed (transcript, summary,
   action items, notes, compressed audio) so other devices can see them.

## Roadmap

* Web UI served by the hub (browse, search, copy, notes, in-browser mic recording) → phones immediately.
* iOS app: share-sheet import from Voice Memos, background mic recording; reuses `MeetingCore` and the API client.
* Linux transcription engine + Docker image; `tailscale cert` TLS by default.
* Real multi-user: login, workspace members, per-workspace plans. The schema is ready; the UI isn't written.
