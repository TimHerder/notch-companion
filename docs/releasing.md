# Releasing Notch Companion

Open a pull request, check its preview, merge. GitHub then re-checks the merged
source, ad-hoc signs the app and publishes the ZIP as the latest release. No Apple
developer account is needed, and the repository stays private until an explicit
public-launch decision.

## Everyday workflow

1. **Branch and PR.** Run the relevant local checks, push, and open a PR against `main`.
2. **Preview.** CI runs `scripts/check.sh` and attaches an artifact named
   `notch-companion-preview-pr-<PR>-…` (ZIP, `SHA256SUMS`, `release.json`) to the
   run for 7 days. The app is labeled **Preview**, is built from the PR's merge
   revision, and can never be published as a release. Fix red checks before merging.
3. **Merge.** Merging an app-affecting change authorizes release publication; there
   is no extra approval step. Agents may merge only when the user authorizes
   merging that task.
4. **Confirm.** Check the Actions run and the
   [release](https://github.com/TimHerder/notch-companion/releases). A merge alone
   doesn't mean the release succeeded.

The private plan can't enforce branch protection, so the maintainer's
"review and green checks before merging" rule is a habit, not a GitHub setting.
Only the owner is a collaborator; external contributions are closed
([policy](../CONTRIBUTING.md)).

## Which merges release

A release needs a green `main` check on the merge commit of a merged PR. A
direct push to `main` never releases. Only changes to these paths release:

- `Sources/**`, `app/**`, `Package.swift`, `Package.resolved`, `LICENSE`
- `scripts/build-app.sh`, `scripts/release.py`, `scripts/ci-release.py`

Changes to other files are still checked but don't publish, and they don't
publish an earlier failed app change either. To ship that change, rerun its
workflow or merge the next app-affecting PR. Release runs on `main` queue rather
than cancel. If a newer commit already has a release tag, an older queued commit
is skipped. PR runs cancel outdated runs for the same PR.

A green run covers the offline tests, signature and bundle checks. It doesn't
cover signed-in agent behavior, physical notch interaction or Gatekeeper on
another Mac. Track those in [verification](verification.md), and keep the
authenticated Mac mini off hosted jobs.

## When GitHub cannot allocate an ARM runner

CI prefers `macos-26` (Apple Silicon). Small Linux jobs pick the runner before
each stage. If GitHub reports that an ARM job was never picked up (no runner
assigned, no steps run, and the annotation *"The job was not acquired by Runner
of type hosted even after multiple attempts"*), the `Recover runner allocation`
workflow reruns that stage once on `macos-26-intel`. Recovery applies only to
`main` pushes, and to open collaborator PRs whose head hasn't changed.

Anything else stays failed for you to investigate: a failed test, build or
publish, a manual cancellation, an unknown error, or a second attempt. A check
recovery cross-builds the same `arm64` app. A publish recovery reuses the
already-checked artifact without rebuilding.

- **Intel tests plus an ARM cross-build aren't native ARM test coverage.** The
  check name and `ci-runner.txt` show the test host. Look at them before merging.
- To retry by hand, rerun the selector job too. Rerunning only the Mac job keeps
  the old runner choice.
- Recovery has `actions: write` only, checks out default-branch code, and never
  runs PR code or downloaded artifacts. If GitHub changes its error message,
  recovery stops instead of guessing.

## Versions

Versions are `YYYY.M.D-rN` (e.g. `2026.10.28-r2`). The date is the time the
workflow was created, in Europe/Berlin, and the build number increases across
every release. CI reads the existing tags to pick the next unused counter and
writes `build/ci-version.json` (`NOTCH_VERSION_FILE`). There are no bot commits.
`app/version.json` is only a fallback for local builds.

The bundle stores the date in `CFBundleShortVersionString`, the build in
`CFBundleVersion`, and the full version in `NotchCompanionReleaseVersion`. Each
release's annotated tag and packaged `release.json` record the version, build,
commit, run and PR.

To rebuild a release, check out its tag and confirm `release.json` names that
commit. Copy just its `version` and `build` into `build/rebuild-version.json`, then:

```sh
NOTCH_VERSION_FILE=build/rebuild-version.json ./scripts/build-app.sh
```

This uses the same source and version, though the bytes may differ. Never
upload a rebuild over a published ZIP.

## Pipeline and retries

`scripts/ci-release.py` runs in three stages: `plan` (preview, release or
nothing, plus the version), `package` (zips the already-checked app), and
`publish` (eligible `main` releases only). `scripts/release.py` remains an
optional manual tool.

Published tags and assets are permanent. A retry may complete the same release,
but it never moves a tag or replaces different bytes.

- **Publish failed after checks passed:** rerun only the failed publish job. It
  reuses the original artifact. Rerunning the whole workflow rebuilds the app,
  and the new bytes are refused if the release already has assets.
- **Checks failed:** investigate, then rerun. Source fixes go through a new PR.
- **Mismatched metadata or assets:** investigate and make a new release. Never
  force-push, or delete a published release.

There is no in-app updater. Users replace the app once their sessions are idle.

## License and history

The build copies [LICENSE](../LICENSE) into `Contents/Resources/LICENSE` before
signing. This repository starts from a single reviewed snapshot. Earlier history
lives in the private `notch-companion-private` and `notch-companion-prerelease`
archives, including their PRs, tags and releases. Never merge or push their commits,
branches or tags here.

## Before public launch

A release in a private repository is still private. Before changing visibility:

- Review the source, secrets and third-party rights. Pattern scans alone aren't enough.
- Confirm hosted checks and a release passed for the intended source. Verify its
  ZIP, checksum, metadata and license.
- Pass the app [acceptance checklist](verification.md#public-release-acceptance)
  using that exact download.
- Enable private vulnerability reporting. Check [SECURITY.md](../SECURITY.md),
  the issue templates and links. Keep PR creation limited to collaborators.
- Check that the [verification record](verification.md) states each adapter's evidence.

Developer ID signing and notarization, universal binaries and an in-app updater
are future options. No workflow changes repository visibility.
