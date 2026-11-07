# Notch Companion

Your AI agents, living in the MacBook notch. Start a conversation, watch the
work, answer approvals and drop in files from a small panel beside the camera,
using the agents you already have installed. On a display without a notch, it
draws a small one.

> **Private release.** Apple Silicon, macOS 26 or newer.

## What it does

- **One place for your agents.** Talk to Claude Code, Codex, Hermes, OpenCode
  and others through their own installs. Notch Companion uses your existing
  logins, configuration, tools, memory and history. It doesn't replace any of them.
- **Cross-agent delegation.** An agent can hand a task to another agent. Claude
  Code can ask Codex for a review, or Codex can send research to Claude, each
  with its own model, role and, if you want it, a separate git worktree. The
  delegated agents run under their parent in **Team**. The parent picks up their
  results when they finish. Their questions and approvals come to you, and their
  file changes appear in the parent's change summary. A delegated agent can keep
  or narrow its parent's permissions, never widen them. Claude Code, Codex,
  OpenCode 2, Hermes, Pi, DeepSeek Harness, Antigravity CLI and Cursor CLI
  sessions can delegate, to any agent that's ready on your Mac.
- **Glance, don't switch.** Hover to see what's happening, click to open the
  conversation. Each session has its own working and unread state, and closing
  the panel leaves the work running.
- **Approvals and questions inline.** Answer them in the conversation as they
  come in.
- **Files and screenshots.** Drop files onto the notch or capture a window with
  SnapShot. Attachments wait for review and are only sent when you send.
- **Change summaries.** See which files each turn changed, with line counts and
  diffs.
- **A bit of character.** Animated eyes, or a mascot (Mote, Fold or Soot), that
  react to what your agents are actually doing.

## Supported agents

Install and sign in to at least one agent with its own setup first. Notch
Companion doesn't bundle agents, sell model access or sign in for you.

| Agent | Connects through | Status |
| --- | --- | --- |
| Claude Code | Installed `claude` CLI | Supported |
| Codex | `codex app-server` | Supported |
| Hermes Agent | Headless frontend on your existing profile | Supported |
| OpenCode | Local HTTP server | Supported |
| Pi | RPC frontend | Supported |
| OpenClaw | Local Gateway | Supported |
| Antigravity CLI | `agy acp` | Supported. Can't take images |
| DeepSeek Harness | ACP | Supported |
| Cursor CLI | `cursor-agent acp` | Supported |

What each agent can do depends on that agent. See the
[runtime contract](docs/backend-runtime.md) and [verification record](docs/verification.md)
for details.

## Install

1. Download the ZIP from [Releases](https://github.com/TimHerder/notch-companion/releases)
   and move **Notch Companion.app** to **Applications**.
2. The app isn't notarized yet. If macOS blocks it, go to **System Settings →
   Privacy & Security → Open Anyway** ([Apple's guide](https://support.apple.com/102445)).
3. Open Settings in the app to connect your agents.

To update, wait until your sessions are idle, quit, and replace the app.

**Control–Option–Space** opens the composer and **Escape** closes it. Your draft
is kept.

## Build from source

```sh
./scripts/build-app.sh            # builds build/Notch Companion.app
./scripts/check.sh                # offline tests and packaged-app checks
```

Needs macOS 26+, Xcode command-line tools, Python 3 and Node.js. See
[native build](docs/native-build.md) and the [docs index](docs/README.md).

## Privacy

On your Mac, Notch Companion stores session routing, drafts, attachment paths
and display state. Conversations, credentials and provider connections stay with each agent,
and prompts go wherever that agent sends them. SnapShot asks for Screen
Recording permission and captures only the window you choose.

## Project

Notch Companion is built and maintained by one person. Bug reports and
[private security reports](SECURITY.md) are welcome. External pull requests
aren't accepted ([policy](CONTRIBUTING.md)). It's licensed under [MIT](LICENSE).
