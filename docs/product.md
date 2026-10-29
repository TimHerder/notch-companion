# Product

Notch Companion is a native macOS interface to a user's existing AI agent
harnesses. The notch is a complete, compact place to start work, send prompts
and files, inspect conversation/tool history, answer questions and approvals,
and follow work agents delegate to each other. The larger session window is optional.

## Runtime continuity

Use the selected runtime's existing installation, authenticated profile, project
context, identity, configured memory, skills, tools and native persistence.
Starting a supported frontend against that setup is acceptable. Copying tokens,
creating an empty replacement home or substituting a model SDK with different
context is not. Each runtime remains responsible for provider access and its
own memory policy.

Only companion-created conversations appear in lists, search and indicators.
Native memory and history retrieval can still use existing context. The local
registry tracks ownership, routing, drafts and presentation; native history is
authoritative. Saved runtime/profile/native IDs remain intact when an adapter
is missing or settings change. Legacy Hermes remains resumable in its original
protected profile, with an explicit reviewed transition to a new shared draft.

The runtime catalog has Hermes, Codex, OpenCode, DeepSeek Harness, Pi, OpenClaw,
Claude Code, Antigravity CLI and Cursor CLI. Capabilities differ. Experimental
or unavailable behavior must be labeled; enum cases and fixtures alone do not
establish end-to-end support. See the [runtime contract](backend-runtime.md).

## Interface

Quiet Companion uses white eyes immediately left of a seamless black notch,
with the same resting height as the physical camera housing. On other displays,
a simulated notch retains the same character. One native panel and one shared
presentation clock drive the bounded expansion, glance and announcement tiers;
text retains its natural scale.

Users can independently choose Eyes or Mascot (Mote, Fold or Soot), Compact or
Popup updates, and panel/body appearance. Motion communicates real state and
respects Reduce Motion. Hover is passive; clicking or a shortcut opens for
input. File drops stage attachments, never submit a task. Drafts survive closing,
settings changes, connection errors and unavailable agents.

Each session has its own work/unread indicator. Children stay under the parent.
Reading a result acknowledges that result without erasing its outcome/history;
a later result becomes unread again. Busy parents/children and uncertain sends
retain their protections regardless of reading.

New drafts offer only configured, ready agents. Setup stays in Settings. With
none ready, preserve text/files and disable every send path. Model and context
controls use native catalogs/reports, with unknown values and estimates labeled.
Do not guess token windows or edit native global settings for a per-session
selection. Permissions remain explicit and routed to the correct native request.

## Delegation

Agents can delegate to each other across harnesses: a supported session hands a
task to any ready agent, with its own model, role and optional worktree. The
delegated agent runs as a child of that session and stays under it. It can keep
or narrow the parent's permissions, never widen them, and its approvals belong to
the user. See the [runtime contract](backend-runtime.md#delegation).

## Lifecycle

Closing the notch leaves work running. Quit/Reconnect must offer wait, explicit
stop or cancel while any owned parent/child work is active. A rebuild never
implicitly quits or replaces a running app. Agent installers, credentials,
configuration and external gateways must remain untouched.

## Distribution

This is a solo-maintainer project under the [MIT License](../LICENSE). External
contributions are closed ([policy](../CONTRIBUTING.md)). Releases are
ad-hoc-signed Apple Silicon ZIPs for macOS 26+, published automatically when the
maintainer merges an app change. The repository stays private until the
maintainer decides to launch publicly. See [releasing](releasing.md).
