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

## Current status — 2026-10-29

**Release pipeline**

- On 2026-10-29 this repository was recreated from a single snapshot. It has no
  releases yet. The earlier beta `2026.10.28-r2` and the runs below belong to the
  private `notch-companion-prerelease` archive.
- Archived evidence: native ARM CI passed (run `40799805580`): 570 Swift tests
  (18 live tests skipped), 30 Python backend tests (22 native-Hermes tests
  skipped) and 31 release/recovery tests. An ARM runner allocation failure
  happened once (run `40722456527`, no runner and no steps). Automatic Intel
  recovery is unit-tested but hasn't yet recovered a real outage.
- No beta has been published from native ARM CI yet.
- Repository settings were read back on 2026-10-29: private, issues on, PR
  creation limited to collaborators, workflow token read-only, and only the owner
  as collaborator. Branch protection isn't available on the current plan.

**Adapters**

Live acceptance from earlier private development hasn't been re-run against this
source snapshot. Known limits:

- Cursor CLI: experimental, with no live acceptance against an installed CLI.
- DeepSeek Harness: experimental; profile and extension parity needs live acceptance.
- Antigravity CLI: headless mode can't ask questions, request approvals or take images.
- Pi: no terminal-rendered extension UI and no built-in tool approvals.
- OpenCode: the child-discovery race and the unstable pre-send snapshot are
  covered by offline fixtures only, not live OpenCode.

**Not yet done**

- A downloaded beta hasn't been installed through Gatekeeper on another Mac.
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
- Keep Cursor and DeepSeek labeled experimental until they pass live acceptance.

When recording results, include the tested OS, architecture, runtime version,
scenario and outcome. Leave out account names, profile contents, raw transcripts
and real session identifiers.
