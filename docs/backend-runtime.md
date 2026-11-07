# Native runtime adapters

The companion routes Hermes, Codex, OpenCode, Pi, OpenClaw, Claude Code,
DeepSeek Harness, Antigravity CLI and Cursor CLI through `RuntimeTransport`. Each
uses its existing native setup. [Verification](verification.md) records installed
versions, real checks and open acceptance work; [adapter
acceptance](multi-harness-handover.md) defines the required checks, upstream
protocol references and distribution boundaries. A technical interface does not
establish permission to redistribute a runtime or offer its subscription login.

## Multi-harness contract

`RuntimeKind` preserves unknown persisted strings: an unavailable future adapter
cannot discard the registry or fall through to Hermes/Codex. Runtime
installation, canonical profile, project directory and native session identity
stay separate. OpenClaw adds its configured agent to the canonical
state-directory identity, encoded without delimiter collisions. Started
conversations keep their identity when defaults change; draft/profile changes
clear obsolete model metadata.

No agent frontend starts at launch. Sends, explicit model requests and setup
connection checks connect the needed route. Model discovery never saves an
unlisted conversation or sends a prompt: DeepSeek ACP and Claude reuse an
initialized session in the same project, Pi reuses a matching session or briefly
opens `pi --mode rpc --no-session`, and OpenCode reads its native HTTP provider
catalog. The first send uses the configured native model unless the user selects
another. Catalogs and context are scoped to profile and project. Billing totals
are never interpreted as current occupancy; unknown usage stays unknown.

`runtime.configuredProfiles` stores the canonical profile of a successful
Settings connection check. Finding an executable alone does not make a harness
ready. Readiness survives orderly disconnects and restarts; location changes and
failed connections invalidate it, and checks cancelled by reconnect or a
location change cannot register stale setup. The draft's harness dropdown lists
only ready, supported profiles without pending location changes; all nine stay
in Settings. A new draft prefers the ready `runtime.default`, then the first
ready harness. With none ready, the UI links to Settings and disables Send while
keeping drafts and attachments. Picker selection launches nothing. Established
conversations keep their runtime/profile and recovery controls when setup is
unavailable. Setup never installs, upgrades, signs in or collects provider
credentials. Claude, Antigravity and Cursor (`requiresProjectTrust`) need a saved
project-trust decision before headless hooks load; changing the profile or
project invalidates it.

| Adapter | Native frontend and profile | Boundaries |
| --- | --- | --- |
| Hermes | Authenticated headless frontend; selected native Hermes profile | Read-only authentication and source/config protections ([Shared Hermes](#shared-hermes)). |
| Codex | `codex app-server`; selected `CODEX_HOME` | See [Codex](#codex). |
| OpenCode | Owned `opencode serve`, native V1/V2 HTTP/SSE; `OPENCODE_CONFIG_DIR`, project `cwd` | Version/schema-guarded 1.18.34–1.18.x and 2.0.30–2.0.x. Paginated history, exact resume, tools, permissions/questions, session models, owned parent/child status. Saved protections from the older ACP frontend stay intact. |
| DeepSeek Harness | `dsh --profile <existing-name>` with original `$DSH_HOME/profiles/<name>` | ACP. Never creates or patches an `acp`/`sdk` replacement profile. Resume, tools, approvals, negotiated model/image/context support. |
| Pi | `pi --mode rpc`; `PI_CODING_AGENT_DIR`, native session file | Native extensions/dialogs, tools, per-session models, images, settled lifecycle. Context from `get_session_stats.contextUsage` only. Bundled process-only extension provides `notch_ask_user`. Terminal-rendered extension UI and built-in tool approvals are unavailable. |
| OpenClaw | Authenticated WebSocket to the existing loopback Gateway; selected agent | Protocol 4 pairing, sessions/history, chat, approvals/questions, models, tool/child activity, delegation tools through a second role-`node` connection. Never starts/stops the Gateway. Remote/TLS unsupported. |
| Claude Code | Installed unmodified `claude --print` stream-json; `CLAUDE_CONFIG_DIR`, trusted `cwd` | Native hooks/memory, exact UUID resume, models, permissions/questions, child events. Context = latest parent request's input/cache counts against the reported window. Never `--bare`, an SDK replacement or copied credentials; bypass only for confirmed [Full access](#permission-modes). |
| Antigravity CLI | Installed [`agy acp`](https://antigravity.google/docs/ide/extensions/acp/) (ACP v1, shared ACP adapter) with its cached sign-in, never `authenticate`; original `~/.gemini/antigravity-cli`, trusted `cwd` | Exact conversation IDs and resume, file references, tools, approvals, native questions, Auto-edit/Plan modes, model discovery and exact-ID switching, delegation hosting. Context only from ACP `usage_update`. No images. Native permission rules still decide which actions ask. |
| Cursor CLI | Installed `cursor-agent acp` after `authenticate` with `cursor_login`; native `~/.cursor`, trusted `cwd` | Shared ACP adapter. `cursor/ask_question` → question card, `cursor/create_plan` → plan approval, answered in the documented `outcome` shape; requests without `sessionId` are attributed by `toolCallId` or the sole active session, else declined. Sign-in stays with `cursor-agent login`; no profile override. |

### Installed harness compatibility

**Processes and environment.** `NativeJSONProcess` owns bounded JSONL framing,
FIFO final-frame delivery, stale-generation filtering and EOF-first cleanup;
stderr is drained, never stored raw. Reopening waits for retiring owned processes
to release native persistence. Each protocol owns its correlation, deadlines and
terminal semantics: Pi waits for settled lifecycle, OpenClaw uses run/sequence
identities, Claude keeps active children beyond a parent result. ACP Stop
answers the session's open requests as cancelled after `session/cancel`. A
turn's 30-minute deadline restarts while it waits on the user and after each
answer. Expiry sends `session/cancel` for that turn only, with a notice, and
keeps it busy for a 45-second grace: the agent's answer settles it as failed,
and only a missing answer restarts the shared process, leaving the send
unconfirmed. A process exit or lost acknowledgement never implies a successful
turn. Native provider/tool environment is kept; inherited host-chat session
IDs, frontend IPC and unrelated runtime identity are removed
(`RuntimeEnvironment.native`). Finder launches get
user/Homebrew search paths, never shell rc evaluation or another app's login.
Claude's default profile leaves `CLAUDE_CONFIG_DIR` unset (setting even the
default path changes its login lookup); a matching inherited override keeps its
exact spelling and a custom profile is pinned explicitly.

**OpenCode.** The server uses a random process-only Basic credential on an
OS-selected loopback port. Subscriptions and bounded snapshots follow exact
owned parent/child identities, and snapshot revisions stop old idle responses
overwriting newer work. Each snapshot rechecks immediate child identities
(including nested descendants); if the set changed, the root stays busy while a
fresh snapshot runs, so a child whose SSE events lag is not missed. A prompt is
posted only after a verified-idle snapshot (briefly rechecked within the
session-opening settling window). A session's native agent is kept on later
turns. Input usage is an estimate; limits come from the native catalog. V2 uses
`/api` endpoints, a fixed `opencode` Basic username, startup-address wire
selection and version/schema checks before session creation. V2 catalogs use the
canonical project, filter disabled entries and keep the native selection ID;
model changes use the session model endpoint and verify readback before Send.
History and inbox entries keep exact client message IDs; queued input, pending
forms/permissions and owned descendants keep work busy. Forms keep field keys,
option values, descriptions and multi-select; unsupported conditional/external
forms are declined visibly.

**Pi.** Models load with `get_state` and `get_available_models`. The temporary
`--no-session` discovery frontend loads the normal profile, project and
extensions, receives no prompt or model command, and closes after discovery or
failure. Context refreshes after responses, compaction and settlement from
`contextUsage` only; null clears stale occupancy. Extensions are passed with
`--extension` without editing the profile or replacing existing extensions.
Question choices include a written answer.

**Antigravity.** One owned `agy acp` process serves every session of the native
profile. Before a session opens, models come from `agy --output-format json
models` and `--print /model`, which start no turn and save no conversation. An
open session's catalog is its ACP `models` state, which uses the same IDs; its
`model` config option names only the family (the thinking level is separate), so
it never replaces the exact model. A change on an idle session uses
`session/set_model`; agy keeps it per session and its empty reply is the only
readback. A cold resume reports the native default, so the saved choice is
applied again before the next send. The global model setting is never changed.
agy's load accepts an ID it never saved, so a resume first pages
`session/list` and refuses an ID agy does not list, unless nothing was ever sent
to that conversation (an unprompted conversation is not listed yet). Resume
replays no history, so history stays incomplete. Questions arrive as
`session/request_permission` with `interaction_` tool-call IDs, because the
companion advertises no elicitation form to agy; their options are answers (one
choice, no written answer), never approvals, and an ambiguous one is cancelled
with a notice. Tool titles drop agy's `Running ` prefix, so the companion's own
tools get their labels.

**OpenClaw.** The companion reads only the selected Gateway/agent configuration
and connects to loopback. It owns a separate device identity and scoped Gateway
credential in Keychain (not copied OAuth). Pairing and scopes stay
Gateway-controlled. Text attachments use native file tools, images the Gateway
attachment format; work folders stay inside the agent workspace. The read-only
JSON5 include resolver follows native merge order, nested relative includes and
`OPENCLAW_INCLUDE_ROOTS`, with canonical and lexical containment, guarded
regular-file reads, cycle/depth/size bounds and no hardlinks. Configuration,
environment and auth are never rewritten.

**History and delivery receipts.** No adapter imports an external roster or
recreates native history from the companion transcript, and incomplete replay
never replaces preserved local history. **Check last send** accepts an exact
native receipt even when display history is partial: OpenClaw checks the saved
input run ID and native input custody; OpenCode uses persisted message IDs and
its unbounded message endpoint. Absence from partial history never proves
non-delivery. DeepSeek, Pi, Claude, Antigravity and ID-less ACP replay keep
unresolved intents protected; no automatic retry is offered. Queued native
input, pending questions/permissions and children stay busy beyond an interim
parent answer.

A quiescent unconfirmed send shows **Send unconfirmed** with an unread failure
dot (not an input-request dot). Reading it or **Mark all as read** acknowledges
that exact send ID persistently, removing it from **Needs you** and **Unread**;
intent, identity, transcript and recoverable input remain, and the next send
still checks delivery. An unresolved intent on a live session blocks silent
reload; a detached historical intent survives Quit/Reconnect without counting as
active work. Native busy/child snapshots are tracked before delivery
reconciliation. Live parent/child work, real questions and unverified native
activity keep their indicators regardless of reading.

## Composer steering and queuing

Return steers while running; Command–Return queues. Both send normally when
idle. Queueing uses the durable `queuedSends` registry and ordinary
`prompt.submit`, so every harness (including Legacy Hermes) supports follow-ups.
Attachments stay with their queued message. User queues are FIFO and wait for
owned children as well as the parent.

| Harness/interface | Steering | Native mechanism and limits |
| --- | --- | --- |
| Codex app-server | Text/files/images | `turn/steer` with `expectedTurnId`, exact client message ID, text and `localImage` inputs. |
| Pi RPC | Text/files/images | Native [`steer`](https://pi.dev/docs/latest/rpc-commands#steer); `agent_settled` stays the completion boundary. |
| Shared Hermes | Text/file references | Typed `session.steer {session_id, text}`; only `status: queued` is acceptance, `rejected` restores the draft. Images require queuing. Acceptance does not prove the model saw it (Hermes may defer during compaction). |
| OpenCode 2 HTTP | Text/files/images | [`POST /api/session/{sessionID}/prompt`](https://dev.opencode.ai/v2/docs/api) with `delivery: steer` and an exact inbox receipt; only after negotiating `opencode-http-v2`. |
| OpenCode 1 HTTP | Queue only | No delivery distinction. |
| Claude Code | Text/files/images | User input with `priority: now`, `origin: {kind: human}` ([SDK changelog](https://github.com/anthropics/claude-agent-sdk-typescript/blob/main/CHANGELOG.md#03286)). Enabled only when `system/init` reports CLI 2.x ≥ 2.1.286. |
| DeepSeek and Cursor ACP v1 | Queue only | Standard [`session/prompt`](https://agentclientprotocol.com/protocol/v1/prompt-turn) has no same-turn steering. |
| Antigravity ACP v1 | Queue only | agy [steers](https://antigravity.google/docs/ide/extensions/acp/) with a second `session/prompt` during a turn; the shared ACP adapter allows one prompt per session, so it queues. |
| OpenClaw Gateway | Queue only | Upstream [`/steer`](https://docs.openclaw.ai/tools/steer) can fall back to a normal turn and has no verified receipt/run mapping here. |
| Legacy Hermes | Queue only | Protected bridge. |

Steering stages the draft/files and saves a `PendingSubmission` with
`isSteering` before delivery. Its user row belongs to the running turn,
preserving changes and child ownership. Ordinary turn events cannot confirm it:
only its correlated receipt or the explicit native-history check clears the
intent. Definitive rejection restores the draft beside newer typing; ambiguous
delivery blocks retries. Steering never silently becomes a new turn or an
interrupt.

Claude: only human composer input takes the priority path with `origin: human`;
delegation messages are never labeled human. The adapter waits for the exact
`command_lifecycle.command_uuid` receipt (or matching user replay), never an
original-turn result; `refused` restores the draft. Accepted IDs survive resume
in-process; a fresh process cannot prove absent history. Pending inputs and
native background tasks prevent premature completion. Session-state events are
enabled process-locally, and Stop sends `cancel_queued` so pending steering
cannot restart work.

Queue entries' attachment and pause fields are optional for older registries.
Stop, failure, disconnect and restart pause the queue (with resume/cancel
controls); a failed head blocks later entries. Delivery uses the ordinary
staged/pending protections without overwriting the current draft; after restart
a staged entry is kept once, not also restored into the editor. Paused queues do
not keep the app busy. Approval and question cards stay authoritative; sending
cannot bypass them.

## Shared architecture

`RuntimeTransport` is the shared `@MainActor` conversation contract.
`RuntimeRouter` owns the adapters and normalizes their events for the app model.

## Session identity and ownership

Each registry entry stores runtime, canonical profile path, native `storedID`,
working folder, local conversation ID, drafts, attachment references, read
receipts and `lastSeenAt` (optional; older entries decode without it), which
only drives the derived auto-archive and never reaches a runtime. `runtimeID`
is a connection-local alias cleared on restart. Native IDs are never rewritten
into another profile's IDs. The router isolates identical
live and request IDs across runtimes/profiles; a connection failure interrupts
only that route, and an unavailable installation does not disable others.
Projects derive from each entry's working folder; there is no project field.

Only companion-created entries (and their delegated children) appear in lists,
search, navigation and indicators. The router refuses `session.list`, ignores
unknown-session events and requires the local identity for create/resume. The
native store stays authoritative; the JSON registry is UI metadata, not an agent
home. Codex's native source may be `vscode`, so source is never an ownership
filter.

Saved app preferences beat environment overrides. Hermes profile fallback is
`NOTCH_HERMES_SOURCE_HOME`, `HERMES_HOME`, then `~/.hermes`; Codex uses
`CODEX_HOME` then `~/.codex`. The default never follows Hermes's mutable
active-profile marker. A profile change affects only the current unstarted draft
and future sessions; started, submitted, ambiguous and legacy conversations keep
their identity, and a moved draft drops its model override/context metadata.
Installation changes apply on reconnect with the usual wait/stop/cancel policy.
Reconnect invalidates cached catalogs and ignores replies from older
connections.

`RuntimeInstallation` searches explicit app locations,
`NOTCH_HERMES_SOURCE`/`NOTCH_CODEX_EXECUTABLE`, PATH, user/Homebrew bins,
literal official Hermes wrappers, Hermes source-root hints and known
Codex/ChatGPT app bundles. It never runs a shell or reads credentials. An invalid
explicit location fails with guidance rather than choosing another installation.
Hermes needs a checkout with `hermes_cli/main.py` and either a `venv`/`.venv`
Python or the managed `.hermes/bin/hermes` launcher, which wins over an old
venv; only its literal interpreter path is read. Bootstrap uses existing native
dependencies with lazy installs and update completion disabled. Arbitrary
pipx/package layouts are unsupported.

## Shared Hermes

`SharedHermesClient` launches the installed interpreter with the bundled
`hermes_frontend.py`, which imports `hermes_cli.main` once (never as a second
`__main__`) and runs `hermes serve` on an ephemeral loopback port with explicit
`--profile` and `serve --isolated`, so the profile stays pinned and no re-exec
discards process-local protections. Swift connects to `/api/ws` with a random
process-only credential and ephemeral URLSession. `session.create` sends
`source: notch_companion` and `follow_profile_config: true`. Hermes persists
history in its usual store and owns session search and memory; the adapter never
inserts rows or copies memory.

The launcher adds a process-local platform hint describing the notch's Markdown
and asking for files as `MEDIA:/absolute/path` lines. Nothing is written; a
user's `platform_hints.notch_companion` overrides it, and an incompatible Hermes
keeps no hint. Once a session asks for delegation, the hint also carries the
delegation instructions and the launcher adds the companion's tools
([Delegation](#delegation)).

Hermes builds with typed wire contracts reject unknown params (error 4000), so
the adapter strips companion-only fields (`project_trusted`,
`activity_unverified`, `pending_turn_id`, `turn_id`, `delegation`,
`native_submission_attempted`) and resume's `cwd`. Those
builds also use JSON-RPC server→client requests (`srq-…` ids): after
`gateway.ready` the adapter sends `client.capabilities {server_requests: true}`,
ignoring rejection from builds without it, which keep `*.request`/`*.respond`.
`approval` and `clarify` become the existing cards: approvals answer with a
response frame; each clarify answer goes through `clarify.lock`, the last lock
resolving the request. `request.cancel` removes the card; `open_requests` on
resume are re-delivered. Other server requests (sudo, secret, vault, desktop
bridges, setup, unknown) get an immediate `-32601` decline and a notice.

**Authentication.** `hermes_shared_auth.py` installs read-only guards before
frontend initialization. Hermes resolves provider, model, endpoint, environment
and static keys itself; profile dotenv loading is kept, inherited
frontend/gateway/session identity removed. Finder launches cannot see
shell-only exports, so credentials belong in Hermes's own setup/.env. Static
credential pools keep native selection and process-local cooldowns but never
persist changes or admit OAuth grants. Codex access tokens are read from native
stores, reread after owner renewal and never refreshed here. Supported: native
API-key providers, named custom endpoints, keyless/local endpoints and read-only
Hermes Codex OAuth. Declined until a reviewed adapter exists: other OAuth,
Copilot token exchange, cloud SDK credential chains (Bedrock, Vertex, Entra),
external-process providers and Codex subprocess transport. Auxiliary model paths
keep the same no-refresh boundary. Public-dashboard authentication is
unsupported; the companion never disables that gate or claims desktop service
ownership to bypass it. Incompatible auth interfaces fail with an authored
message.

**Protection.** macOS sandboxing denies writes to installed source, profile
configuration, `.env`, auth, SOUL, gateway identity, skills, profiles, Codex
state, managed interpreter/tool stores and dependency venvs (native generation
leases beside them stay writable). Lexical and canonical paths are both
protected, including symlink targets and missing directories. Named profiles
also protect root identity/auth/shared stores and sibling profiles. Native
session databases, logs and memory stay writable. The worker never sets
`HERMES_DESKTOP`, removes inherited Hermes/Codex frontend identity, and uses a
parent ownership pipe so a dead companion leaves no frontend; the same pipe
carries the delegation tools and per-session bindings. Only its own
process is terminated; the messaging gateway is never restarted or stopped. The
launcher refuses to run with automatic session archiving, managed local-model
service ownership or dashboard turn isolation enabled, without changing those
preferences. Startup diagnostics are authored; backend logs, transport
credentials and raw stderr are never shown or saved.

Hermes creates records lazily on the first prompt. If an unused native ID
disappears after restart, a replacement is allowed **only** when persisted
metadata proves no send was attempted and no history exists. A missing submitted
history keeps its original ID and reports an error.

## Hermes computer-use launch compatibility

LaunchServices startup can fail inside the protected frontend, so the bundled
`hermes_computer_use.py` installs a process-local hook that relays only the
CuaDriver launch request to `ComputerUseLaunchRelay` in the companion. Hermes
still resolves the driver and chooses its permission mode, capability manifest,
overlay policy, readiness check, MCP client and session behavior; installed
files are not patched. Missing optional dependencies do not block chat. An
incompatible helper is blocked at tool invocation and never falls back to an
unreviewed relay; a changed upstream launch shape fails closed. Legacy Hermes
does not use this path.

The relay treats launch messages as untrusted. It accepts only the fixed
private-daemon command, a valid future deadline, matching permission-mode flags,
manifest acknowledgement and an unused socket inside its own 0700 lease; it
rechecks lease owner/device/inode and refuses symlinks. It verifies the app
signature and exact CuaDriver bundle/team identity before a fixed `/usr/bin/open`
argument vector. No generic launch facility is exposed, no credentials are
passed, and the user's approval mode is never switched.

Only private sockets issued by that frontend are stopped. Its parent-EOF watcher
cleans up CUA before SIGTERM (Hermes's SIGTERM skips `atexit`) and tracks
partially started backends and late launches through their deadline; Swift
tracks leases independently with awaited cleanup. Existing standard/gateway
CuaDriver processes are untouched. Reference: [Cua Driver daemon
CLI](https://cua.ai/docs/cua-driver/reference/cli/daemon). Fixture coverage is
not live acceptance.

## Codex

`CodexClient` runs `codex app-server --listen stdio://` with the existing home,
authentication, configuration and project, initializes as `notch_companion`,
and requests persistent threads. It inherits model, instructions, approvals and
sandbox except explicit model choices and [permission modes](#permission-modes),
sent on `turn/start`. It strips this host chat's origin override, thread/session
IDs and desktop-tools pipe. Thread names use native RPC; no files are copied or
edited.

`thread/start`, `thread/resume` and `turn/start` map to the shared contract.
Streaming agent-message items form one response; native turn completion gives
one receipt. Tool items use stable IDs. Delegated thread activity stays under
its companion parent. Resume checks active state; turn IDs guard against stale
notifications. Approvals and multi-question requests use the offered choices and
native wire request IDs; option descriptions and headers stay separate fields.

`request_user_input_async` questions arrive on an `agentMessage` item
(`questions: [{title, options}]`, `delivery: "async"`) whose text merely renders
them. The adapter emits `message.questions`, omits that text (and deltas) from
the answer and resume history, and the card replies with an ordinary send.
Completed `imageGeneration` items with an absolute `savedPath` add a Markdown
image to the answer, live and on resume.

Images use `localImage`; other attachments are local-path references read with
the agent's own tools and policy. Interrupts target only the parent and known
owned children. Shutdown closes only the owned app-server. Reference: [Codex App
Server](https://learn.chatgpt.com/docs/app-server). Native thread persistence
does not imply visibility in the Codex desktop sidebar.

## Change summaries

`CodexProtocolState` turns the owned, active parent's `turn/diff/updated`
aggregate into `turn.changes`. Each update replaces the turn's aggregate (never
summed). External, stale and completed turns are rejected, and child aggregates
are never added to a parent's (shared-file edits would double-count).

For every harness, including Legacy Hermes and Codex without a native aggregate,
the project's Git root and HEAD are recorded off the UI actor before a prompt.
At settled completion with no native aggregate, `WorkspaceChanges` diffs against
that commit plus untracked non-ignored regular files, so commits made during the
turn stay visible and pre-existing or simultaneous edits are labeled workspace
changes. An unborn repository uses an empty baseline. Nested folders resolve to
their Git root. Git runs with fixed arguments, `core.fsmonitor=false`,
`--no-ext-diff`, `--no-textconv`; untracked symlinks are not followed; no index,
refs, files, configuration, auth or history are changed. Capture needs settled
completion: Pi interim messages and OpenClaw queued runs do not trigger it, and
known children or unverified activity block it. Non-Git folders without a native
aggregate have no summary; edits outside the selected project are invisible
(app-owned children add their own groups, see [Delegation](#delegation)).

`TurnChanges` is optional presentation state with a local user-turn identity,
workspace, base revision, source and timestamp; old registries decode without
it, and resume never erases it. A following send waits for the session's pending
snapshot. Background results are scoped to their session/turn, cannot overwrite
a native aggregate and are cancelled on shutdown. Parent completion does not
snapshot while a delegated child is busy.

Limits (`UnifiedDiff`): 4 MiB of Git output or native diff, 200 files, 64 KiB
preview per file (counts cover the full diff). Git commands time out after 5
seconds; untracked scans have a 15-second overall deadline. Errors and limits
produce a visible notice and editor action, never fabricated counts.

## Models and context usage

`notch.showModelPicker` and `notch.showContextUsage` default on and persist an
explicit off; `notch.showPermissionModes` defaults off. They reveal a compact
row below the prompt field. The model picker is a bounded overlay (search,
refresh, Close) that does not move the transcript. The choice is saved per
conversation and applies on explicit Send. Busy parents, delegated children and
unresolved sends block model changes. Changing a draft's runtime clears its
model choice but keeps text/files. Choosing the default for an existing session
stages the concrete current default for the next send.

**Reasoning effort** appears only when the catalog supplies efforts (Hermes,
Codex, Claude). `RuntimeModelChoice.reasoningEffort` persists and reaches the
next explicit send, including effort-only changes and after resume. A model
change keeps an effort only if the new catalog allows it. Other adapters keep
their native effort.

- **Codex:** paginated `model/list` plus `config/read` for the working folder;
  configured models beat catalog recommendations. Efforts come from
  `supportedReasoningEfforts`; returning to default uses the configured effort.
  Model and effort go on `turn/start`. A configured context limit shown in
  Settings is not a claim about the active window.
- **Hermes:** `model.options`, with the launcher adding the installed
  `VALID_REASONING_EFFORTS` and honoring per-model reasoning capabilities.
  Choices are restricted to the configured provider, which is pinned explicitly
  (bare names can auto-route to an unauthenticated aggregator). Before
  switching, poll `session.activate` with `omit_messages` until `info` is not
  lazy (30-second bound) so the deferred default build cannot overwrite the
  choice. Apply with session-scoped `config.set` (`model`, then `reasoning`),
  then verify model and provider in a second snapshot before submitting.
  Busy/deferred switches do not submit; native expensive-model confirmations are
  kept; cancellation or rejection leaves the draft unsent. Never writes a global
  preference. Legacy Hermes has no model selection.
- **Claude:** dedupes resolved model IDs, prefers named labels, excludes
  disabled rows. Without a session, `runtime.models` runs a throwaway
  `--print` frontend with `--no-session-persistence`,
  `--settings {"disableAllHooks":true}`, `--strict-mcp-config` and
  `ENABLE_CLAUDEAI_MCP_SERVERS=false` that answers `initialize` and is stopped
  without a prompt; an untrusted project is probed from a neutral temporary
  folder. A running session's catalog is used instead. Efforts come only from
  `supportsEffort`/`supportedEffortLevels`. Each selection is applied before
  Send with `set_model` and session-only `apply_flag_settings.effortLevel`, and
  `get_settings.applied` must confirm both before the prompt; omitting effort
  clears a prior override. Never `update_settings` or user/project defaults. A
  CLI that cannot apply or verify effort leaves the message unsent.

Context usage is the latest native occupancy/request snapshot (`context_used`
or `last.totalTokens`; Hermes `session.info`/`session.usage`/completion usage,
Codex `thread/tokenUsage/updated` and reroute events), never cumulative usage
and never guessed. The composer shows a monochrome gauge; hover and a click
overlay show percentage and abbreviated counts (`20k / 828k`, `42k used` without
a window), with `≈` for estimates, `—` and a dashed ring for unknown values.
The percentage is not clamped (`110%` over the window) while the gauge and bar
are; the overlay's bar takes the warning color from 90 %, and its caption names
an estimate, an unreported window or an over-limit report before the report
time ([wording](interaction-design.md#composer-model-controls)). Samples may drop
after compaction, survive restart as a last report, and clear when the reported
model changes. Children never overwrite their parent's context. A late Codex
final usage event counts for the latest turn; old-turn and unowned-thread events
do not. Model names and windows are never hard-coded.

## Permission modes

A session's optional `permissionMode` (`ask`, `autoEdit`, `plan`, `fullAccess`;
none = Inherit) persists; an unknown saved value decodes as Inherit.
`RuntimeCapabilities.permissionModes` lists the modes a harness maps (empty
hides the control; capabilities saved without it get the static mapping).
Changes wait for parent, child and unresolved-send work. On explicit Send,
before the model is applied, AppModel calls `session.permission.set` with the
mode, or without one to return to Inherit after an override was sent this run.
Nothing reaches the runtime on selection, and native configuration is never
written. A failed or unverified change leaves the message unsent with the draft
restored. Mode changes the agent makes itself are not tracked; the saved mode
is reapplied on the next send. The persistent `always` approval is never
exposed.

| Harness | Mapping |
| --- | --- |
| Codex | Sent on `turn/start` only. Ask: `on-request` + `readOnly`; Auto-edit: `on-request` + `workspaceWrite` (the thread's own policy when it has one); Full access: `never` + `dangerFullAccess`; Plan: experimental `collaborationMode` `plan` with the selected or thread model. Overrides persist natively, so Inherit sends the thread's own `approvalPolicy`/`sandbox` from `thread/start`/`thread/resume` (or `collaborationMode: default`) once. `thread/start` omits overrides. Resets stay pending until `turn/start` acknowledges them, and attempted overrides stay tracked if the reply is lost. |
| Claude Code | `set_permission_mode` (`default`, `acceptEdits`, `plan`, `bypassPermissions`), verified against the echo. Before the first override the profile mode is read from `get_settings` (`effective.permissions.defaultMode`, `manual` = `default`); Inherit restores it once. `--allow-dangerously-skip-permissions` is passed only to a session opened with Full access or an idle session switched to it, which reopens its process (resuming if history exists). The reopen rechecks ownership after the old process exits; a disconnect during it cancels the launch. |
| ACP (DeepSeek) | Advertised `modes.availableModes` matching a known name (`default`/`ask`, `acceptEdits`/`auto-edit`, `plan`, `bypassPermissions`/`full-access`/`yolo`) are offered via `session/set_mode`; Inherit restores the opening `currentModeId` once. |
| ACP (Cursor) | Only `plan` (Cursor's `ask` is read-only Q&A, not Ask); Inherit restores the opening mode. |
| ACP (Antigravity) | Advertised `accept-edits` → Auto-edit and `plan` → Plan (agy 1.5). Its `default` mode follows the native permission rules, which may never ask, so it is Inherit, not Ask; Inherit restores it once. 1.4 advertises no modes. |
| Others | Hermes, Pi, OpenClaw and OpenCode map none. OpenCode V2 prompts have no agent/permission field. |

## Usage

`RuntimeCapabilities.rateLimits` marks harnesses reporting account limits
(Codex, Claude). `RuntimeRateLimit` keeps window name, used percentage, reset
time, reached flag and report time; missing values stay nil. AppModel keeps the
latest per runtime in preferences, merged by window name, cleared when the
profile location changes. The router forwards `runtime.rateLimits` by route.
Views order windows by the duration in their names (`RuntimeRateLimit.sorted`,
the inverse of `label(minutes:)`), extra usage last; a bar's fraction is 1 when
reached, nil when unknown; a reset time already past makes the window unknown
until the next report.

- **Codex:** `account/rateLimits/read` (`rateLimitsByLimitId` or single
  `rateLimits`; `primary`/`secondary` with `usedPercent`, `windowDurationMins`,
  `resetsAt`) and `account/rateLimits/updated`. A read from the Usage page
  connects the route but creates no thread or prompt.
- **Claude:** `rate_limit_event.rate_limit_info` during turns only
  (`unifiedWindows` when present, else the top-level window; `status: rejected`
  marks it reached).

**Companion totals** count only companion turns. Adapters report
`session.info.turn_tokens` (the current turn's running total), stored as the
latest user turn's persisted `turnTokens`. Codex: parent-thread
`total.totalTokens` minus the turn-start total, known only for threads started
or first observed in this process; children are not added. Claude: the change in
summed `modelUsage` (input, output, cache read/creation, including subagents)
between results. Other harnesses report none: unreported, not zero.

## Delegation

An agent in the notch can hand a task to another configured harness. Tool names,
shapes, error codes and limits follow T3 Code's `orchestratorMcp.ts`. Native
subagents (`subagent.*` events, `ChildAgent` without a session) are separate;
this adds app-owned children.

**Server.** `DelegationServer` listens on `127.0.0.1` only, OS-chosen port,
`/mcp`, server name `notch`: minimal MCP Streamable HTTP (`initialize`, `ping`,
`tools/list`, `tools/call` as JSON-RPC `POST`, single or batch; notifications
get 202; `GET`/`DELETE` get 405). `initialize` returns the delegation
instructions (empty for OpenCode, whose session instruction entry carries them).
Each native session gets one token (32 random bytes, base64url);
only its SHA-256 is kept, in memory, scoped to the companion session, harness
and a `subagent` flag. Missing/unknown bearer: 401. A `tools/call` whose
`_meta["ai.opencode/sessionID"]` is neither the caller's native session nor one
of its native subagents is `capability_denied`. Tokens expire after 24 hours
unused unless the session is busy, and are revoked when the session's process is
released (`session.disconnected`, route/app disconnect, deletion), its launch
fails, or its installation reports it cannot host (`hosts_delegation: false`,
OpenCode 1.x). Reopening reuses a live token. **Cross-agent delegation** in Settings
(default on) controls injection for new launches; while off, calls fail with
`capability_denied`.

**Tools.**

| Tool | Behavior |
| --- | --- |
| `orchestrator_capabilities {search?}` | Caller's runtime, model and mode (`runtimeMode`/`interactionMode`); every ready harness plus the caller's, with up to 12 models (50 with `search`), efforts, `runtimeModes`, `canRunChildTask` and constraints; `maxBatchThreads: 20`. Catalogs load as explicit model requests. |
| `delegate_task` | `{task ≤120,000, target{runtime, model?, options{effort}?}, title?, role?, isolation: shared\|worktree, mode: async\|wait, timeoutMs?, clientRequestId? ≤256, runtimeMode?, interactionMode?}` → `{taskId, childSessionId, runtime, model, title, status, workState, summary, hasPendingQuestion, pendingApproval, waitTimedOut, next?}`. `parent_not_active` unless the caller's turn is live. |
| `task_status {taskId}` | Same shape, caller's tasks only (`task_not_found`). A settled result read here is acknowledged and will not wake. |
| `task_cancel {taskId}` | Stops the child's subtree depth-first, drops its wake and queued messages. |
| `create_sessions {sessions[1…20]{prompt?, title?, target?, runtimeMode?, interactionMode?}, clientRequestId?}` | Ordinary top-level sessions in the caller's folder; a prompt is sent first. Same target, mode and trust rules; needs an active turn. |
| `notch_session_list {projectPath?, statuses?, titleContains?, includeSubagents?, cursor?, limit? ≤100}` | Companion sessions of a folder (default: caller's), newest first. |
| `notch_session_read {sessionId?, view? messages\|activity, afterPosition?, limit? ≤100, maxCharsPerItem? ≤50,000}` | Positioned items, paged by `nextPosition`. Reading a child's final answer acknowledges it. |
| `notch_session_send {sessionId, message, mode? auto\|queue\|steer\|restart, clientRequestId?}` | `auto` starts an idle session, steers a running Codex turn, or queues; `steer` fails without one; `restart` interrupts (not children) and sends. A send to a settled child starts a fresh task (new `taskId`, waking its parent). Shown as “From another session”. |
| `notch_session_wait {sessionId, timeoutMs?}` | Until the session's work ends (a caller's child: until its result, `next` on timeout). |
| `notch_session_interrupt {sessionId}` | Plain interrupt of a top-level turn; children keep running. Delegates get `thread_not_interruptible`. |
| `notch_session_update {sessionId?, action: rename, title}` | Renames the session. |
| `pending_request_list` / `pending_request_read` / `pending_request_respond {sessionId?, requestId, answers{questionId: answer}}` | Pending questions only, answered through the card's path. Approval IDs get `capability_denied`: no approval rights. |

`status` is `queued`, `running`, `waiting`, `completed`, `failed`, `cancelled` or
`interrupted`; `workState` is `working`, `waiting_for_children` or
`result_available`. `summary` is the latest answer once settled. Errors are T3
codes in an `isError` result. `wait` defaults to 10 minutes, max 60 (OpenClaw
callers: at most 110 seconds, inside the Gateway's 120-second node call),
counted from the call so creating the child is included, and a timeout never
cancels the child; there is no depth, count or concurrency limit.
Task, send and creation IDs derive from caller + operation + `clientRequestId`
(SHA-256, UUID-formatted), so retries (even concurrent) reach the same work and
are checked against the target's messages, saved intent and queue; without a
key each call is new.

`notch_session_send` and `notch_session_interrupt` refuse a target with a
broader mode than the caller (Inherit target needs a Full access or Inherit
caller; an Inherit caller reaches only Ask and Plan targets). Waiting messages
go to the target's `queuedSends` and the background send path once its turn
ends; one already in history after restart is dropped, and one the harness
refuses stays queued for the next launch rather than retrying on every event.

**Children.** A child is an ordinary session of its target harness and default
profile in the parent's folder (OpenClaw keeps its agent workspace), with
`parentSessionID` and optional `delegation {taskID, clientRequestID, role,
completionWake, readCompletionID, wokenCompletionID, wakeMessageID, cancelled}`.
Its first message is the task, prefixed `Act as the <role> sub-agent for this
task.` when a role is given, sent as a background send through the normal
staging, intent, duplicate and delivery protections without touching the
composer or banner. A child inherits the parent's model only on the same
harness. Any ready harness can be a child; only hosting harnesses give it tools.
Claude, Antigravity and Cursor children need the user's existing trust for that
harness and folder (`capability_denied` otherwise).

**Worktrees.** `isolation: worktree` runs `git worktree add -b notch/<name>` from
HEAD of the parent folder's repository into `Worktrees/<repository>-<hash>/`
beside the registry and starts the child in the matching subfolder. Uncommitted
edits stay out; outside Git is `invalid_request`. The worktree inherits the
folder's trust. Worktrees and branches are never removed by the app.

**Questions.** A child's question (not an approval) queues a “Delegated
question” notice to its parent pointing at `pending_request_read`/`respond` or
the user, unless a blocking `wait` returns it instead; the notice is dropped if
answered or expired first. The user can always answer in the child.

**Permission modes.** Plan < Ask < Auto-edit < Full access. A child inherits the
parent's mode stepped down to the broadest the target maps. A target mapping
none runs only under a Full access or Inherit parent (else refused, reported as
`canRunChildTask: false`). An explicit mode above the parent's is
`runtime_mode_escalation_denied` (or `interaction_mode_escalation_denied` from
Plan); one the target lacks is `invalid_request`. Under Inherit only Plan and
Ask are allowed. Inherited Full access counts as confirmed.

**Results and wakes.** A settled child result (with completion receipt) wakes
its parent for async tasks or a `wait` that returned early. `wait` polls every
250 ms and returns early on a question or approval. A due wake is saved in the
child's record before sending. If the parent's turn has ended, it is a
background `delegationResult` message (the “Delegation result” row) naming
`taskId` and `sessionId` and inlining the answer up to 16,000 bytes, else
pointing at `task_status`. While a Codex parent runs, the wake steers that turn
(`turn/steer`) so its changes, tokens and failures stay together; a refused
steer waits for the turn end and that parent is not steered again until then. A
wake that lost the parent to another send waits for that turn. After a crash, an
undelivered wake is sent; one received or held as an unconfirmed send is not. A
failed wake send is kept for the next launch, not retried in a loop.

**Change summaries.** Each child's settled snapshots fold into the parent
`TurnChanges` of the delegating turn (`ChildAgent.turnID`) as `delegated`, one
group per child labeled “Title · Harness” (“· worktree”), latest per path across
its settled turns. A child's baseline records `preexisting` fingerprints
(SHA-256 of counts and preview patch) of files dirty at its start; a workspace
capture drops files whose fingerprint is unchanged, so earlier user/parent edits
are not credited to it (agent-reported aggregates stay whole). Shared children's
paths are excluded from the parent's own list when workspaces match
(`ownFiles`); worktree paths stay separate. Limits: one level (grandchildren stay
with the child); parent edits in a shared folder during a child run are credited
to the child; a rename shows on the next settled turn.

**Busy and stop.** App-owned children are mirrored into the parent's `agents` as
`ChildAgent` rows with `sessionID`, `runtime` and `role`, so busy, attention,
team counts and Quit/Reconnect waiting treat them like native children. A parent
whose turn ended stays Working while a child works or a wake is due. **Stop**
interrupts the parent then its children depth-first and drops their wakes;
`interrupt(cascade: false)` leaves them running. Pending child creation is
tracked under its parent before catalog or worktree preparation; cascading Stop,
Reconnect and shutdown cancel it, and a cancelled preparation never registers or
sends a child (created worktrees remain). A client closing its connection
cancels its tool call; an abandoned `wait` never acknowledges a result. An ACP
session reloaded while live keeps the bridge it was opened with.

**Injection** (`hostsDelegation`: Claude, Codex, OpenCode 2, DeepSeek, Pi,
Cursor, Antigravity, Hermes, OpenClaw; version-specific, rerun native acceptance before release). An adapter
may report `hosts_delegation` with a session or model catalog; `false` drops
that route from hosting until it reports otherwise, and `orchestrator_capabilities`
then says its children cannot delegate:

| Harness | Mechanism |
| --- | --- |
| Claude Code 2.1.287 | `--allowedTools mcp__notch__*` (Plan: only `orchestrator_capabilities`, `notch_session_list`, `notch_session_wait`, `pending_request_list`, `pending_request_read`); instructions as `appendSystemPrompt` in `initialize`; then the server, bearer header and 65-minute `timeout` via `mcp_set_servers`, so the token never enters argv. No `--mcp-config`/`--strict-mcp-config`: user servers stay. A failed registration leaves the session usable with a notice. |
| Codex 0.162.1 | Per-thread `config` on `thread/start`/`thread/resume` with only `mcp_servers.notch` (`url`, `http_headers.Authorization`, `tool_timeout_sec: 3900`), keeping user servers. Instructions as `additionalContext` `notch_delegation` (`kind: application`) on the thread's first turn in this process; `developerInstructions` untouched. |
| ACP (DeepSeek, Cursor) | A stdio MCP server in `session/new`/`session/load` `mcpServers`: the companion executable with `--notch-delegation-bridge`, endpoint and token in its `env`. It relays JSON-RPC lines concurrently (65-minute timeout) and answers a revoked token with an error. Instructions come from the server's `initialize`. Without delegation `mcpServers` is `[]`. |
| Antigravity CLI 1.5.2 | The same stdio bridge in `session/new`/`session/resume` `mcpServers`; agy starts it when the session opens and caches the tool descriptors and server instructions (never the endpoint or token) under its app data `mcp/notch/`. Instructions also go in `_meta.antigravity.systemPrompt.append` on every open when `initialize` advertises it, since agy keeps them only for its process. Nothing is written to its configuration (`agy mcp add` would). |
| Pi 1.3.0 | Bundled `pi_delegation.mjs` via `--extension`, endpoint and token in the process environment (deleted before the agent runs commands). Registers tools as `mcp__notch__<tool>`; `before_agent_start` appends instructions. Uses `node:http`, not `fetch`, so hour-long waits are not cut. Nothing written to the Pi home. |
| OpenCode 2.0.30 | One runtime server per session, `notch-<first 16 hex of SHA-256(native ID)>`, added with `PUT /api/experimental/mcp/{server}?location[directory]=<session folder>` (`type: remote`, bearer header, `oauth: false`); runtime-only, so it ends with the owned server and nothing is written to configuration. Added when the session opens and again before each prompt, because an idle folder drops runtime servers. Every server at a folder is visible there, so each session's rules (`PATCH /api/session/{id}` `permissions`, its other rules kept) end with deny `notch-????????????????_*` (one `?` per hex digit, so a user's own `notch-…` server stays usable), then allow its own `<server>_*`; earlier companion rules, the old `notch-*` deny included, are replaced. A session opened without delegation gets the deny alone and loses a stale `notch` instruction entry. Instructions as session instruction entry `notch`. A failure leaves the session usable with a notice. OpenCode 1.x reports `hosts_delegation: false`. |
| Hermes 0.22.3 | No per-session MCP option on `hermes serve`, so the companion's `hermes_frontend.py` registers native tools `mcp__notch__<tool>` in a `notch` toolset (`execution_timeout` 3900). Before a frontend's first delegating `session.create`/`session.resume`, the client writes the tools and instructions as a JSON line on the ownership pipe and waits for `NOTCH_DELEGATION {"ready": true}`; after each reply it writes `{"bind": <live session id>, url, token}`. Tokens stay in the frontend's memory, out of argv, environment, disk and `session.*` params. A call finds its live session by the agent's stored key (also after a compression rotation) and posts `tools/call` with that session's bearer; unbound callers, Hermes subagents and revoked tokens (401 forgets the binding) get `capability_denied`; Stop closes the request. `notch` joins an explicit toolset list (`tui_gateway.server._load_enabled_toolsets`); `None` already means all, `[]` stays empty. Instructions extend the `notch_companion` platform hint; tool search may defer the tools as it does MCP tools. Changed internals or a name clash (a user MCP server called `notch`) fail closed with a notice; the session stays usable. Nothing is written to the profile. Legacy Hermes does not host. |
| OpenClaw (Gateway protocol 4) | A second Gateway connection with role and client mode `node`, the same Keychain device, no operator scopes and its own per-role device token in Keychain. Every agent profile of one Gateway shares that device, so their connections share one node link: it opens with the first session launched with delegation, serves the delegating sessions of every profile, and closes when the last operator connection that launched a delegating session disconnects, so the Gateway withdraws the tools. It declares only `mcp.tools.call.v1` and publishes every tool with `node.pluginTools.update` as `notch_<tool>` (`pluginId: node-mcp`, `mcp {server: notch, tool}`). A `node.invoke.request` runs only for a companion-owned session key that was launched with delegation, as that session through the loopback server with its own token; any other caller gets `capability_denied`. The Gateway's invoke deadline bounds the call, and a cancelled invoke cancels it. Instructions come in the `orchestrator_capabilities` result. Node pairing and command approval stay with OpenClaw (silent for a local Gateway by default). A required pairing, filtered tools (unapproved commands or `gateway.nodes.pluginTools.enabled: false`) or a dropped link become notices; chat keeps working and the next session launch retries. The Gateway lists the tools for every agent while the node is connected. Nothing in the OpenClaw configuration is written. |

## Capability boundaries

UI approval buttons honor offered scopes; `always` approval is never exposed.
Codex question options honor native free-text availability. The companion is not
a secret-entry or native-dashboard surface: Hermes secure input,
terminal/preview/window actions, tours and MCP setup callbacks, and Codex secret
questions, MCP elicitation, device-auth and unknown server requests are declined
explicitly with a visible notice, never left waiting. The user authenticates in
the runtime's own interface.

## Preservation, transition, and duplicate-send protection

Registry entries decoded with native IDs or history but no runtime become
`Legacy Hermes`, pinned to the original private profile; old empty drafts become
shared Hermes drafts. The registry is backed up to
`sessions.json.before-runtimes` first; an unreadable registry or failed backup
is never overwritten. **Continue in Hermes…** creates a separate shared Hermes
draft with a private transcript export (visible messages, tools, child
summaries) attached, plus the old draft and attachments. The original stays
unchanged and resumable; nothing native happens until Send, and no history is
rewritten or merged. Exports are mode 0600 in the private `Migration Context`
directory.

A saved staging record keeps submitted text/files as the composer clears, before
any asynchronous setup, and is projected into the transcript without touching
native history. Setup failure or restart before the send intent restores it
beside any newer draft. A durable send intent is written immediately before
native submission. Acknowledgement or observed turn events discard the staging
record without consuming newer input, even identical text. A lost
acknowledgement keeps a recoverable intent, blocks automatic retry and silent
reload of an attached session, and offers **Check last send**. After disconnect
or restart that input alone does not block Quit/Reconnect, but its receipt
protection persists. Resume reconciles the intent against recorded user turns
before another send; a missing submitted record is never guessed away. Busy
native conversations are observed without appending competing turns.
Quit/Reconnect offer wait, explicit stop or cancel, and wait for tracked
parent/child terminal events, not just interrupt acknowledgements.

## Validation

Run `scripts/check.sh` for the offline suite and packaged-app checks. Native
acceptance is opt-in; see [native build](native-build.md#validation) and
[verification](verification.md). Never enable live account tests in a public
pull-request runner or copy authenticated profiles into CI.

## Legacy private Hermes adapter

`HermesClient` runs the installation's `venv/bin/python` (or `.venv`) with the
bundled `hermes_bridge.py`, which imports Hermes's `tui_gateway.entry`
dispatcher and never launches, restarts or stops the messaging gateway. Private
state lives in `~/Library/Application Support/NotchCompanion/hermes/`;
`Workspace/` there is the default working directory. `sandbox-exec` denies
writes anywhere in the original Hermes home and checkout, including from child
tools; bytecode writes are disabled. This protects the installation; it is not
an application sandbox.

On connection the bridge copies the owner's configuration and dotenv into 0600
files in a 0700 directory, keeping model, reasoning and tool settings, using a
separate workspace, enabling tool lifecycle events, disabling compute-host
isolation and clearing provider fallbacks. SOUL.md is copied if present.
Sessions, databases, schedules, memories, hooks and plugins are never copied.
Owner settings take effect on reconnect.

### OAuth is borrowed without taking ownership

The `openai-codex` refresh grant is single-use, so the bridge **never copies or
uses the original refresh token**. A process-local adapter reads the current
unexpired access token from the original store whenever Hermes (or the
auxiliary model) resolves it. Static API-key pool rows may be copied; OAuth rows
and grants never are. The original Hermes is the only refresh owner: an expired
token yields an actionable error (renew in Hermes, then reconnect), never silent
authentication, rotation, a paid-model fallback or an auth edit. Source files
are not patched.

`disconnect()` terminates only its own process, letting Hermes's SIGTERM handler
persist history, with a bounded fallback. Reconnect resumes known conversations
via `session.resume`; transient runtime IDs are never durable identity.

## Normalized conversation contract

```swift
@MainActor
protocol RuntimeTransport: AnyObject {
    var onEvent: ((String, [String: Any]) -> Void)? { get set }
    var onConnectionChange: ((Bool, String?) -> Void)? { get set }
    func connect() async throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func disconnect()
}
```

The legacy stdio wire is newline-delimited JSON-RPC 2.0 with ID-correlated
replies. Connect waits for `gateway.ready`; RPCs time out after 90 seconds.
Parsing is incremental and bounded; raw stderr is never displayed or persisted.
Wire events (`method: "event"`, `params: {type, session_id, payload}`) reach
`onEvent` as the type plus a **flattened payload with `session_id` added**; UI
never parses envelopes or terminal output. Other adapters normalize to the same
methods and events.

| RPC | Request | Important result |
| --- | --- | --- |
| `session.create` | `title?`, `cwd?` | `session_id` (live), `stored_session_id` (durable), `info` |
| `session.resume` | `session_id: durableID` | `session_id`, `session_key`, `messages`, `running`, `status`, `info` |
| `prompt.submit` | `session_id`, `text`, `surface: "hud"` | `status: "streaming"`; content arrives by event |
| `session.interrupt` | `session_id` | acknowledgement; wait for the terminal turn event |
| `file.attach` | `session_id`, absolute `path` | `attached`, `path`, `ref_path`, `ref_text` |
| `image.attach` | `session_id`, absolute `path` | image added to pending attachments |
| `image.detach` | `session_id`, attached `path` | `detached`, remaining `count` |
| `approval.respond` | `session_id`, `request_id`, `choice` | `resolved` |
| `clarify.respond` | `request_id`, `answer`, optional `question_id` | `status`, optional remaining question IDs |

Dropping and submission are separate: hover and drop make no runtime requests.
On explicit Send the app creates/resumes the runtime and calls the attachment
RPCs. Non-image `ref_text` is appended to the submitted prompt (removing its chip
omits it). Images are implicit pending attachments, so removing one must call
`image.detach`. Attachment RPCs never submit a turn.

| Event | Payload |
| --- | --- |
| `message.start` | starts a turn |
| `message.delta` | `text` delta |
| `message.interim` | `text`, `already_streamed` |
| `message.complete` | authoritative `text`, `status` (`complete`, `interrupted`, `error`), `usage`, optional warning/error |
| `tool.start` | `tool_id`, `name`, `context`, optional `args` |
| `tool.complete` | same `tool_id`, `name`, `summary`, `result`, `duration_s` |
| `session.info` | model, working directory, tools and other metadata |
| `error` | `message` |
| `approval.request` | `request_id`, redacted `command`, allowed `choices` (`once`, `session`, `always`, `deny`) |
| `clarify.request` | `request_id`, `question`, `choices`, optional `multi_select`; or `questions: [{qid,question,choices,multi_select}]` |
| `clarify.expire` | `request_id` to dismiss |

**Reply segments.** The app keeps a turn's text in the order it was written,
adapter-agnostically. Once a `tool.start` follows text or non-blocking
questions in the current assistant message, the next text (delta, interim,
completion or non-blocking questions) starts a new assistant message, dated
when its first text arrives; a leading blank-line separator is dropped. `message.interim` and `message.complete` text
that the turn's segments already hold (compared without whitespace: all of them
joined, as Codex, ACP and OpenCode report, or a suffix, as Claude and Hermes
report only the final message) keeps them; other text replaces the current
segment's, or starts a new one after a tool call. Calls still running at
completion are finished with an end time. The latest visible user row's
`turnEndedAt` is saved when the turn completes, fails (`error`), or is
interrupted by a disconnect, so a steer or wake keys its own block; its
`turnOutcome` saves how the turn itself ended (a failed delegated child leaves
it finished). A turn the runtime never reports ending (a relaunch while busy,
the client disconnecting, a Stop it never confirms) records `interrupted` unless
an outcome is already saved, and loading an older save records its latest
turn's stop or own failure the same way; a turn without an outcome reads as
finished, so the session's later state never relabels it. The final segment is the session's latest answer
(`latestResponse`, delegation summaries and results). Native history splits replies at the same boundaries, keeping
per-role counts aligned with saved messages: Codex rows end at tool items (a
turn's first reply keeps the turn ID, later ones `turn:item`), OpenCode joins
consecutive assistant messages and splits at tool parts (a refresh delivers text
written before a tool part it has not seen yet, then the poll's tools, then
later text), and ACP load replay joins agent chunks until a
tool call. A restored reply without a native time or saved match takes the
previous row's time instead of the restore time.

Native delegated work emits `subagent.start`, `subagent.thinking`,
`subagent.tool` and `subagent.complete` on the parent session, identified by
`subagent_id`, `child_session_id`, `delegation_id`, optional `parent_id` and
`depth`, with `goal`, `task_count`, `task_index`, `model`, `tool_count`,
`toolsets`; progress adds `text`, `tool_name`, `tool_preview`; completion adds
`status`, `summary`, `duration_seconds` and usage. **Delegation is
asynchronous:** the parent's `message.complete` may precede its children, so
keep each child active until its own `subagent.complete`.

## Legacy verification

`Tests/Backend/verify_bridge.py` and `verify_approval.py` have live modes that
use real account quota, temporary app-owned state and clearly named test
sessions; read their arguments first. Use the installed Hermes dependency
interpreter, never run live modes in ordinary CI, and never change the source
profile, config, auth or Gateway identity to make them pass.
`NOTCH_HERMES_SOURCE`, `NOTCH_HERMES_SOURCE_HOME` and `NOTCH_HERMES_HOME`
override development discovery; the bridge refuses app storage overlapping the
original home.
