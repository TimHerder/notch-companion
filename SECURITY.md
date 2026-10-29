# Security

Notch Companion connects to local agents that can run tools, read files and
contact model providers. Each agent's own configuration, permissions and account
stay in charge. **Full access** is a real change in what an agent can do, not a
cosmetic setting.

## Report a vulnerability

Report privately through GitHub:
[Security → Report a vulnerability](https://github.com/TimHerder/notch-companion/security/advisories/new).
If that isn't available, open an issue asking for a private contact, and leave
out the vulnerability details.

Include the app version and build, your macOS version, the affected agent and
its version, a minimal reproduction and the expected impact. Never include API
keys, authentication files, session registries, private conversations or
screenshots with unrelated sensitive content. Please don't publish an exploit
while a fix is being coordinated.

## Supported releases

Fixes target the latest beta. Older versions aren't maintained separately.

Beta apps are ad-hoc signed and not notarized, so macOS asks you to approve the
first launch. Download only from the project's Releases page, compare the
checksums, and use [Apple's approval flow](https://support.apple.com/102445).
Leave Gatekeeper enabled. Checksums confirm the bytes match, but they don't
prove who built the app.
