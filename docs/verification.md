# Verification

This file records what has and hasn't been verified for the current source and
release, plus what each kind of evidence proves. It isn't a change log: a PR
description lists the checks run for that change. Update this file when support
status, acceptance status or a known gap changes.

## Evidence categories

| Evidence | Establishes | Does not establish |
| --- | --- | --- |
| Swift/Python offline tests | Covered routing, persistence, protocol and UI-model scenarios | Real account access or every upstream version |
| Subprocess/protocol fixtures | Message shapes and lifecycle behavior against deterministic fixtures | Live provider behavior |
| Build/signature/resource checks | The built bundle's structure and ad-hoc signature integrity | Developer ID, notarization or Gatekeeper download acceptance |
| Hosted CI on Intel with an ARM cross-build | Tests on Intel and a correctly built `arm64` package | Native ARM test execution |
| Live native prompt | The tested installed runtime/profile and specific scenario | Other runtime versions, accounts or features |
| Offscreen UI fixtures | Layout at sampled endpoints | Physical notch alignment, live hover/drag, glass or smooth motion |
| Downloaded-app test | Installation and launch for that exact ZIP on the tested Mac | Every supported Mac configuration |

Listing and reading tasks through Codex desktop doesn't establish that a session
appears in its visible sidebar, or that live handoff works in general.

## Current status — 2026-11-07

**Release pipeline**

- On 2026-10-29 this repository was recreated from a single snapshot. It has no
  releases yet. The earlier beta `2026.10.28-r2` and the runs below belong to the
  private `notch-companion-prerelease` archive.
- Archived evidence: native ARM CI passed (run `40799805580`): 570 Swift tests
  (18 live tests skipped), 30 Python backend tests (22 native-Hermes tests
  skipped) and 31 release/recovery tests. An ARM runner allocation failure
  happened once (run `40722456527`, no runner and no steps). Automatic Intel
  recovery is unit-tested but hasn't yet recovered a real outage.
- No release has been published from native ARM CI yet. Releases are now full
  GitHub releases marked Latest, with no Beta title or pre-release flag.
- Repository settings were read back on 2026-10-29: private, issues on, PR
  creation limited to collaborators, workflow token read-only, and only the owner
  as collaborator. Branch protection isn't available on the current plan.

**Adapters**

No adapter carries an experimental label any more (maintainer decision,
2026-11-07); the gaps below still need live acceptance before a public release.
Every harness now hosts cross-agent delegation. Live acceptance from earlier
private development hasn't been re-run against this source snapshot. Known limits:

- Cursor CLI: not installed here, so prompts and delegation hosting are covered
  by protocol fixtures only. ACP has no pre-approval, so it may ask before every
  companion tool call, and its tool rows may miss the delegation labels.
- DeepSeek Harness: profile and extension parity, and delegation hosting through
  the stdio bridge, are covered by protocol fixtures only.
- Antigravity CLI: now runs over `agy acp`. Checked live against agy 1.5.2 with no
  prompt: `initialize`, `session/list`, `session/new` and the delegation bridge
  starting from the session. Still unverified with a real prompt: question and
  MCP tool-call shapes, ACP `usage_update`, whether `session/set_model` stays
  per-session, and resuming an older stream-json conversation that has content.
  No images. Running `agy acp` lets agy's own self-updater run.
- Hermes: delegation hosting relies on Hermes 0.22.3 internals and fails closed
  with a notice if they change. Checked against the installed 0.22.3 with a
  throwaway frontend and no model call; no live delegating prompt yet.
- OpenClaw: delegation hosting through a role-`node` Gateway connection is
  covered by a fake-Gateway fixture only (OpenClaw isn't installed). Node
  pairing, command approval and the agent's `sessionKey` form are unverified.
- OpenCode: 2.0.30 per-session delegation servers were checked live with no
  prompt (opt-in test with an isolated data folder; `~/.config/opencode`
  unchanged). Not yet checked with a model call: whether the deny rule hides
  other sessions' servers or only refuses them, and whether child sessions
  inherit the rules; the `_meta` ownership check covers both. OpenCode 1.x
  doesn't host. The child-discovery race and the unstable pre-send snapshot are
  covered by offline fixtures only, not live OpenCode.
- Pi: no terminal-rendered extension UI and no built-in tool approvals.

**Interface**

- The island update, stage, "Worked for" fold, context bubble and session list
  are covered by offscreen fixtures in all three designs. No physical-notch,
  live-hover or VoiceOver acceptance has been done for them.

**Not yet done**

- A downloaded release hasn't been installed through Gatekeeper on another Mac.
- No third-party rights or full secret review has been done. Pattern scans found
  nothing, but they aren't a certification.
- No physical UI acceptance of a release build has been done.

## Public release acceptance

Before the first public release, in addition to the repository steps in
[releasing](releasing.md#before-public-launch):

- Test the exact downloaded ZIP on another Mac or clean account: extract, move to
  Applications, Gatekeeper approval, launch and agent setup.
- For each agent advertised as supported, test a real prompt, a tool or approval
  interaction, cancellation, restart and exact native session resume.
- Check provider/profile continuity without copying or changing credentials.
- Check physical-notch and external-display placement, hover, keyboard input,
  drag/drop, readable text, Reduce Motion and ordinary macOS permission prompts.
- Replace the app with an update only after all parent and child work is idle,
  then check that drafts, history, native IDs and read receipts survived.
- Run live acceptance, including a delegating prompt, for Cursor, DeepSeek and
  OpenClaw before advertising them in a public release.

When recording results, include the tested OS, architecture, runtime version,
scenario and outcome. Leave out account names, profile contents, raw transcripts
and real session identifiers.
