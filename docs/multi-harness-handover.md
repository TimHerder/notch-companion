# Multi-harness acceptance

This is the maintained adapter acceptance guide. The current catalog and protocol
boundaries are in [backend-runtime.md](backend-runtime.md). Implemented behavior,
protocol-fixture coverage and live acceptance are different kinds of evidence.

## Architecture and ownership

Extend `RuntimeTransport`, `RuntimeRouter` and the normalized app model. Each
adapter must preserve the user's actual installed and authenticated runtime,
profile/agent identity, working folder, native persistence, resources and memory
policy. An empty app-specific agent home or replacement model loop does not meet
that requirement. Never copy login credentials or silently substitute another
provider. Native tools, skills, hooks and plugins may differ between runtimes.

| Source | Responsibility |
| --- | --- |
| `Runtime.swift` | Runtime catalog, routing, connection lifecycle and companion ownership |
| `RuntimeInstallation.swift`, `RuntimeSettings.swift`, `RuntimeSetupView.swift` | Discovery, existing profiles, trust and setup |
| Native client/protocol files | Structured transport, capabilities, receipts, cancellation and replay |
| `AppModel.swift`, `Models.swift` | Persistence, drafts, owned sessions/children and pending submissions |
| `RuntimeModels.swift`, `ModelControlsView.swift` | Native catalogs, per-session overrides and context reports |
| `Tests/NotchCompanionTests`, `Tests/Backend` | Deterministic regressions, protocol fixtures and opt-in live probes |

Audit setup, startup, persistence migrations, model/context controls and test
loops when adding a runtime. A new enum case or launch button is insufficient.
Unknown persisted runtimes must remain preserved rather than falling through to
a different adapter. Missing optional installations must not stop other agents.

Use bounded structured framing, correlated requests, deadlines and generation
checks. Read stderr without saving arbitrary sensitive output. A parent result,
process exit or accepted prompt is not proof that children/queued work finished.
Preserve exact runtime/profile/session/request routing for approvals, questions,
interrupts and retries. Lost acknowledgement must not produce a duplicate send.
Stop only owned processes and work; never stop an external Gateway.

## Protocol references

These links are entry points for reviewing upstream contracts, not a claim that
the latest upstream version has been tested. Match changes to installed versions
and the version/capability checks implemented in the adapter.

| Agent | Native interface |
| --- | --- |
| Hermes | Existing `hermes serve` frontend and native typed contracts; [Hermes documentation](https://hermes-agent.nousresearch.com/docs/) |
| Codex | [`codex app-server`](https://learn.chatgpt.com/docs/app-server) |
| OpenCode | [V1 server](https://opencode.ai/docs/server/) and [V2 API](https://dev.opencode.ai/v2/docs/api) |
| Pi | [RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md) and [extension dialogs](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md) |
| OpenClaw | [Gateway protocol](https://docs.openclaw.ai/gateway/protocol) and [client guide](https://docs.openclaw.ai/gateway/clients) |
| DeepSeek Harness | [ACP](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/acp/acp/README.md) and [native profiles](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/README.md) |
| Claude Code | [Unmodified programmatic CLI](https://code.claude.com/docs/en/headless) |
| Antigravity CLI | [Headless interface](https://www.antigravity.google/docs/cli/headless/) |
| Cursor CLI | [ACP interface](https://cursor.com/docs/cli/acp) |

ACP capabilities are negotiated; a shared protocol does not guarantee identical
profile composition, approval behavior, extensions or persistence. In particular,
DeepSeek's existing selected profile must remain intact. Do not create a minimal
replacement profile to make its ACP startup succeed. Cursor remains experimental
until its installed CLI has passed live acceptance. Antigravity's opaque question
steps cannot be treated as answered questions or approvals.

Claude uses the installed unmodified CLI, not `--bare`, copied credentials or a
separate SDK agent. Normal default authentication must leave `CLAUDE_CONFIG_DIR`
implicit. Headless hooks require deliberate saved project trust; a changed
project/profile invalidates it. OpenClaw pairs as a scoped client to an existing
loopback Gateway, without taking its process ownership.

## Acceptance checklist

For every adapter, record the actual runtime version, interface, capabilities,
automated checks and remaining limits in [verification](verification.md).

| Check | Required evidence |
| --- | --- |
| Existing setup | Selected native profile and working folder load existing context and a configured tool/skill; authentication stays with the runtime. |
| Native persistence | Create a labeled test conversation, restart the owned frontend and resume its exact ID; verify native lookup where supported. |
| Memory | Read/write only harmless test context through the runtime's ordinary memory policy, where supported. |
| Conversation | A real prompt, stream, tool call, follow-up and final success/error reach the shared conversation model. |
| Attachments | Explicitly send a harmless fixture; verify supported images and a useful rejection for unsupported formats. |
| Permissions/questions | Deny a safe request and answer a native question where supported, with exact correlation and no automatic bypass. |
| Models/context | Native readback confirms the selection before send; occupancy is the latest reported snapshot, with unknown/estimated data labeled. |
| Delegation | Children retain correct ownership, results and pending requests; parent completion does not clear active descendants. |
| Recovery | Disconnects, restarts, auth expiry, malformed events and lost receipts preserve drafts/history and duplicate-send protection. |
| Isolation | Identical native IDs in separate routes cannot collide; external conversations stay out of companion lists and indicators. |
| Native UI | Setup, ready-agent selection, keyboard use, bounded layout and requests work in the real app. |

Live tests use existing native setup and clearly titled disposable test sessions.
A temporary companion registry is appropriate; an empty agent home does not prove
continuity. Do not overwrite real memory, change credentials/configuration,
restart external services or alter existing conversations to obtain a pass.
Missing native access is a reported test gap, not a reason to fabricate success.

## Distribution boundaries

Agent runtimes are installed independently and are not bundled in releases.
Review third-party source/assets, licenses and attribution before public launch.
Review current provider terms and trademarks before advertising account or
subscription compatibility; use of a documented protocol alone is not permission
to resell access or redistribute a runtime. Claude and Antigravity authentication
terms require particular attention. Do not contact vendors or accept agreements
for the user without authorization.

This project does not supply provider accounts or handle subscription sign-in.
The initial release is an ad-hoc-signed Mac app; the [release guide](releasing.md)
tracks packaging and public launch separately from adapter correctness.
