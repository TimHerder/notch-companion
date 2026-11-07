# Third-party marks

Notch Companion shows each agent's official mark next to its name where you pick
an agent: the agent chooser (including the default agent in Settings), the
welcome's agent step and a draft's harness menu. The marks are used only to
identify the agent the companion connects to. They aren't the companion's
branding, and they don't appear on the island, in session rows, on the app icon
or in marketing material.

Each file is bundled byte for byte as its owner published it, in
`Sources/NotchCompanion/Resources/AgentLogos/<runtime>.svg`, and is never
recoloured, tinted, cropped or stretched (`.gitattributes` keeps git from
touching them). The app may scale a mark optically to offset padding built into
the file.

| Agent | File | Owner | Source |
| --- | --- | --- | --- |
| Claude Code | `claude.svg` | Anthropic | https://claude.ai/favicon.svg |
| Codex | `codex.svg` | OpenAI | `OAI_OpenAI-Blossom_White.svg` from https://cdn.openai.com/brand/openai-logos.zip ([openai.com/brand](https://openai.com/brand)) |
| OpenCode | `opencode.svg` | OpenCode maintainers (anomalyco) | `opencode-logo-transparent-dark.svg`, [opencode.ai/brand](https://opencode.ai/brand) |
| Pi | `pi.svg` | Pi maintainers (earendil-works) | `favicon.svg` square badge, [pi.dev](https://pi.dev) press kit |
| OpenClaw | `openclaw.svg` | OpenClaw maintainers | `openclaw-mascot.svg`, brand kit in [github.com/openclaw/carapace](https://github.com/openclaw/carapace) |
| DeepSeek Harness | `deepseek.svg` | DeepSeek (deepseek-ai) | `apps/web/public/favicon-dark.svg`, [github.com/deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) |
| Antigravity CLI | `antigravity.svg` | Google | `antigravity-icon__full-color.svg`, [antigravity.google/press](https://antigravity.google/press) |
| Cursor CLI | `cursor.svg` | Anysphere | `marketing-static/favicon.svg`, [cursor.com](https://cursor.com) |
| Hermes Agent | `hermes.svg` | Nous Research | `assets/nous-girl-white.svg`, [github.com/NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) |

Claude Code, Codex, OpenCode, Pi, OpenClaw, DeepSeek Harness, Antigravity,
Cursor and Hermes Agent and their logos are trademarks of their respective
owners. Notch Companion is not affiliated with or endorsed by them. The app
shows the same line at the bottom of Settings.

The marks haven't had a rights review; each vendor publishes its own rules
(see [verification](verification.md)). To add an agent's
mark, record it here with its source, add the unmodified file under its runtime
identifier, and keep the `RuntimeChoiceTests` logo check passing.
