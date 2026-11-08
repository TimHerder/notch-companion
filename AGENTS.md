# Project guidance for agents

Notch Companion is a native macOS notch interface to the user's existing AI agent
harnesses. The product direction is settled: build on it and on the user's feedback.

## Read the contract first

Before editing, read every reference whose trigger matches the task, and follow
its adapter-specific pointers as needed.

| Task | Required reference |
| --- | --- |
| Scope or product decisions | [Product brief](docs/product.md) |
| UI, geometry, motion, controls, conversation, unread state, or file drops | [Interaction design](docs/interaction-design.md) |
| Runtime connection, profile, session lifecycle, persistence, auth, models, context usage, or delegation | [Runtime contract](docs/backend-runtime.md) |
| Adding a harness or changing adapter capabilities | [Multi-harness acceptance](docs/multi-harness-handover.md) |
| Versioning, packaging, CI or public release | [Release guide](docs/releasing.md) |
| Building, packaging, sounds, mascots, or native UI fixtures | [Native build](docs/native-build.md) |
| Claiming support or acceptance | [Verification](docs/verification.md) |

Current user instructions take precedence over the docs. When code and contract
disagree, establish which one is intended before treating the discrepancy as correct.

## Preserve these boundaries

- **Continuity:** use each runtime's existing authenticated profile, configuration,
  identity/memory, skills/tools, and native persistence through supported interfaces.
  Native history remains authoritative; the local registry tracks companion
  ownership, routing, drafts, and presentation state.
- **Ownership:** lists, search, navigation, and indicators show companion-created
  sessions only, with delegated children inside their parent. Native memory/history
  retrieval remains available as context. Retain saved runtime/profile/session
  identities and history when an adapter is unavailable.
- **Protection:** preserve installed runtime source, configuration, authentication,
  and environment files and external services. Hermes OAuth refresh stays with
  its existing owner. Legacy Hermes retains its separate protected home; shared
  Hermes uses the supported headless frontend. Claude uses the installed,
  unmodified CLI. Credentials stay where the runtime keeps them, isolation stays
  intact, and continuity always runs on the real native setup.
- **Lifecycle:** retain durable send receipts, duplicate-send protection, and
  parent/child busy tracking. Before quitting or reloading for development,
  verify every app-owned session and delegated child is idle. A rebuilt bundle
  does not update the running copy.
- **Presentation:** expansion uses one `CompanionPanel`, one `UnifiedNotchView`
  and one `NotchPresentation`, whose tiers share one clock. The edge aura is a
  click-through window that only mirrors it. Bounded content keeps its natural
  text scale.

## Finish implementation work

1. Work on a task branch; `main` takes reviewed merges only. Run checks for the
   changed behavior (see the runtime and build references). For app changes,
   finish with `scripts/build-app.sh` so the launchable bundle contains the
   change. Documentation-only work needs link and content checks instead.
2. When behavior changes, update its contract. List the checks you ran in the PR
   description, naming the kind of evidence (protocol fixture, live native
   prompt, offscreen render, physical interaction). Update
   `docs/verification.md` when support status or a known gap changes.
3. Stage only this task's changes and check the staged diff for whitespace errors
   and secrets. Leave out builds, local session data and credentials. Leave any
   unrelated local work in place and mention it.
4. Commit as `TimHerder <134063417+TimHerder@users.noreply.github.com>` and verify
   the author. Push with a normal push (set an upstream for a new branch), and
   confirm the remote branch matches `HEAD`. Open a PR against `main`, attach it
   to the current task, and report its checks and Preview download.
5. Merge only when the user authorizes merging this task, after reviewing the
   final diff and seeing the relevant checks pass. GitHub requires a PR for
   `main` but can't require the checks, so confirm them yourself. An authorized merge of an app change also authorizes the
   automatic release publication.
6. Report the change, checks, commit, branch and PR, plus release status after
   a merge. After a rebuild, tell the user an idle Quit/reopen is needed unless
   you performed it. If something is blocked, name the exact blocker and the
   remaining work.

Commit, push and PR are part of finishing by default; an explicit request to keep
work local overrides this. Read-only reviews and planning need no commit or PR.

## Repository boundaries

- This repository starts from a reviewed snapshot. Earlier history stays in the
  separate private archive: its branches, tags, logs, profiles and captures stay out.
- CI stays credential-free on GitHub-hosted runners, never the maintainer's
  authenticated Mac.
- Release versions come from tags, as described in the release guide. Release
  tags are permanent (a ruleset blocks moving or deleting them), versions never
  come from bot commits, and Preview builds
  never become releases.
- External code and documentation contributions are closed, and PR creation is
  limited to collaborators. The repository is public (since 2026-11-08): everything
  pushed, including Actions logs and artifacts, is visible to anyone. Only the
  maintainer changes repository visibility, rulesets or security settings.
