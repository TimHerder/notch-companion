# Contribution policy

Notch Companion is a solo-maintainer project. External code and documentation
contributions aren't accepted, and pull requests are limited to the maintainer
and explicitly added collaborators. Please don't prepare a patch expecting it to
be reviewed or merged.

Bug reports are welcome through GitHub Issues. Include the app version and build
(shown at the bottom of Settings), your macOS version, the affected agent and its
version, and a minimal reproduction. Remove credentials, private conversation
content and personal details. Report vulnerabilities privately through
[SECURITY.md](SECURITY.md).

The maintainer decides the roadmap and release schedule. There's no commitment
to provide support, reply to every report or implement feature requests.

## Building your own copy

The [MIT License](LICENSE) lets you modify and fork the project, including for
commercial use, as long as you keep its notice. This contribution policy doesn't
restrict those rights.

```sh
./scripts/check.sh
open "build/Notch Companion.app"
```

You need macOS 26+, Xcode command-line tools with the macOS 26 SDK, Python 3 and
Node.js. Start with the [documentation index](docs/README.md) and
[native build](docs/native-build.md). Keep credentials, agent profiles,
conversation data and builds out of Git.
