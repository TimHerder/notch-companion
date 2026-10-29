# Native app build and sound palette

The native app is a Swift Package targeting macOS 26 or newer (Liquid Glass). Build on a Mac
with Xcode command line tools installed. The executable and app display name
are `NotchCompanion` and **Notch Companion**, respectively. Hosted CI and its
ARM/Intel runner selection are described in [releasing](releasing.md).

From the repository root:

```sh
./scripts/build-app.sh
open "build/Notch Companion.app"
```

Or build and launch in one command:

```sh
./scripts/run-app.sh
```

The build script compiles the release executable, copies its SwiftPM resource
bundles and the root [MIT license](../LICENSE) into `Contents/Resources`, validates
the app's property list, and ad-hoc signs the local bundle. The license is stored
as `Contents/Resources/LICENSE` before signing and must match the root file
byte for byte during package verification. Version metadata is stamped from
the JSON file selected by `NOTCH_VERSION_FILE`, falling back to `app/version.json`
for local builds. Hosted workflows generate `build/ci-version.json` without
committing it. `Info.plist` is a template, not the version source. Debug symbols
are stripped from the staged executable before signing. `CompanionResources.bundle`
resolves resources relative to the app or standalone executable; only debug
builds retain SwiftPM's absolute-path fallback. Release verification rejects an
executable containing the checkout's absolute path.
It stages the complete bundle before replacing a previous generated build.
It does not install into `/Applications`, terminate any running process, or
change the Hermes installation. A rebuild doesn't update the running copy:
quitting stops owned runtimes, so first verify every app-owned session and
delegated child is idle.

`LSUIElement` keeps the companion out of the Dock. Bundled resources include
the original interaction sounds, app icon, and the app's bridge resources.
No sound is downloaded at runtime. The original icon is a native vector drawing
of the existing left-side cream eyes within one matte black notch silhouette,
on a soft cream tile. It includes standard and Retina icon sizes.

Regenerate the checked-in `app/AppIcon.icns` with:

```sh
xcrun swift scripts/generate-icon.swift
```

The script uses AppKit and the macOS `iconutil` command. Intermediate PNGs are
written into the ignored `build/AppIcon.iconset` directory. No generated image
service or external art is needed.

## Mascot assets

The three [mascots](interaction-design.md#mascot-stage), Mote,
Fold and Soot, are each modeled, animated and rendered by their own script in
Blender (the render scripts target 5.2, using Cycles on Metal): `scripts/mascot/<id>.py`. They share
[`scripts/mascot/mascot_kit.py`](../scripts/mascot/mascot_kit.py), whose
docstring is the character contract: the camera and lights, per-frame keying,
rendering, sprite-sheet packing and face anchors. Reference art guided the
modeling, but every sprite is rendered from the Blender scene. Regenerate with:

```sh
scripts/render-mascot.sh mote                          # every clip of one character
scripts/render-mascot.sh all                           # Mote, Fold, then Soot
scripts/render-mascot.sh soot --preview stage-emerge,done --eyes   # review stills + contact.png
scripts/render-mascot.sh fold --turnaround --eyes --size 512        # front, 3/4, side, rear
scripts/render-mascot.sh mote --clips done             # re-render some clips into the manifest
scripts/render-mascot.sh mote --anchors-only           # rewrite <id>.json without rendering
```

Set `BLENDER=/path/to/Blender` if it is not in `/Applications`. Full renders
queue behind one lock (`build/mascot/.render-lock`) so two characters never
share the GPU; previews and turnarounds run at once into `build/mascot/<id>/`,
with `--eyes` adding flat preview eyes that production sprites never contain.
Every clip is a pure function of time keyed on each frame, so loops close
exactly; motion blur, denoising and a transparent film are on. Each character
writes transparent 288-pixel WebP sprite sheets (8 columns) to
`Sources/NotchCompanion/Resources/Mascot/` as `<id>-<clip>.webp` (the
resources are flattened into the bundle, hence the prefix), plus `<id>.json`:
frame size, fps, the ground line and, for every frame, the face's projected
centre, one eye unit along its x and y-down axes, and how squarely it faces the
camera. The app draws the live eyes with that transform. Clips named
`stage-<clip>` replace `<clip>` on the popup stage; a clip with a `ledge`
records where the island's bottom edge crosses the frame, so the body can hide
behind it. `build/mascot/<id>/<id>.blend` (open it to inspect the rig) and the
intermediate PNGs stay in the ignored `build/` directory; `--resume` skips
frames already rendered.

Blender 5.2 crashed while caching Cycles' background-specialized Metal
kernels, so the kit turns kernel optimization off.
Sharing the GPU between a full render and previews ran Metal out of memory,
so while the lock is held `render-mascot.sh` renders previews on the CPU
(`--cpu`).

Soot's fur is real Cycles hair: a geometry-nodes groom on separate Curves
objects parented to each body part (fur generated on a mesh object did not
render as hair in 5.2). `soot.py --fur 0.25` thins it for quick previews only.
Its stage clips scale Soot ×1.75 behind a holdout sill so the head and
shoulders fill the stage; the fur's soft alpha is why its sheets are larger.
Its fur follows through on a slow, well-damped spring (2 Hz, ζ 0.6, a fifth
of the crown's trailing distance). Higher-frequency springs can flicker at the sprite frame rate; review jumps
and landings when changing the fur simulation.

The app decodes a clip's sheet off the main thread when it is first needed and
keeps at most three decoded, dropping all but the emerge clip once the mascot
is hidden. Newly decoded sheets refresh the drawing even when Reduce Motion
pauses the animation clock, including after changing the companion's
appearance. `scripts/render-ui-fixtures.sh` renders `mascot-clips`, a contact
sheet of every clip with the eyes drawn on the face, to check anchors.

## Sounds

The seven cues are generated mathematically using
[`scripts/generate-sounds.py`](../scripts/generate-sounds.py). They contain no
third-party recordings. Most cues combine struck mallet-like tones (1.5–3 ms
attacks, upper partials that decay faster than the fundamental), tiny
band-passed noise transients for tactile snap, short pitch glides, and a small
generated room; Collapse is deliberately one soft pure tone. Endpoints are
silent. Timings follow the eye animations. Let a tone decay fully before its
duration ends: a tone cut off while audible makes the room's sparse echoes
flutter on alone, which sounds like a gated snare.

| Cue | When | Character | Duration | Peak before app volume |
| --- | --- | --- | --- | --- |
| Expand | Hover, click, or shortcut opens the notch | Soft tick, rising bloop, small glint | 0.420 s | -12.77 dBFS |
| Collapse | Pointer departure, click, Escape, or shortcut closes it | One pure tone falling a fifth (B4→E4) with a gentle 10 ms start, ringing out on its own; no impact | 0.650 s | -16.59 dBFS |
| Attach | File accepted (drop or picker) | Two crunchy bites on the chomp frames (0 s, 0.24 s), a gulp, sparkle with the smile | 0.850 s | -7.13 dBFS |
| Send | Prompt submitted; approval/question answered | Rising air sweep, bright pluck | 0.380 s | -12.77 dBFS |
| Complete | A session finishes | Struck rising fifth (E5→B5) with shimmer | 1.000 s | -11.06 dBFS |
| Attention | Approval or question arrives | Curious pair bending upward with the eyes' hop | 0.600 s | -13.15 dBFS |
| Failure | A session enters the failed state | Gentle falling minor third that wobbles with the worried shake | 0.700 s | -14.89 dBFS |

Levels are balanced by short-term (50 ms) loudness rather than peak: Complete
is the loudest reward, Attention just below, then Attach, Expand and Send,
with Collapse and Failure quietest.

`SoundPlayer.shared` exposes persisted `enabled` and `volume` settings for the
interface. Sound is initially enabled at volume **0.28**; turning it off also
fades any cue currently playing. The operating system's output volume applies
as usual. The opening cue plays once when hover dwell, click, or shortcut
starts an expansion. Clicking an already-open preview only pins it and does
not replay the cue. Closing after pointer departure plays the collapse cue
once, respecting Sounds and volume. Routine tool events, file-drag preview
opening, and pointer tracking stay silent. Failure plays once per transition,
whichever event caused it; user interruption is silent.

Playback never loops. Opposing expansion/collapse cues fade one another out.
The player caps concurrent cues, filters duplicates, and limits repeats:
Attention at most every four seconds, Failure every two.

Regenerate the WAVs and print their duration, peak, and RMS measurements with:

```sh
python3 scripts/generate-sounds.py
```

All files are stereo 16-bit PCM at 48 kHz. The generator asserts zero-valued
first/last frames and no clipping. A single cue can be auditioned from the
repository root using the macOS command below; it plays at the WAV's original
level, so `-v 0.28` matches the app's initial gain:

```sh
afplay -v 0.28 Sources/NotchCompanion/Resources/Sounds/expand.wav
```

## Validation

The shared local/CI entry point is:

```sh
./scripts/check.sh
```

It requires macOS 26+, an Xcode/Swift toolchain with the macOS 26 SDK, and
Python 3 and Node.js on PATH. It builds the test fixture executable,
runs Swift tests, discovers `test_*.py` in `Tests/Backend` and `Tests/Release`,
builds the release app and verifies its signature, version and bundled resources.
New tests in those suites are automatically discovered. No real agent account is
required. `NOTCH_RUN_*` opt-ins are cleared for this command, and installed-Hermes
checks are explicitly skipped; a skip is not a native compatibility pass.

While developing, use targeted commands such as:

```sh
swift test --filter RuntimeTests
python3 -B -m unittest discover -s Tests/Release -p 'test_*.py'
```

Use meaningful regression scenarios, not tests that only restate implementation.
For changed app behavior, run the relevant checks and rebuild. Tests cannot
establish live glass, hover, notch alignment or animation smoothness.

Native acceptance runs separately on a trusted local Mac with existing agent
setup. These opt-ins can send real prompts and consume account quota:

```sh
NOTCH_RUN_LIVE_RUNTIME_TESTS=1 NOTCH_LIVE_RUNTIMES=codex,claude swift test --filter RuntimeLiveTests
NOTCH_RUN_BUSY_INPUT_TEST=1 NOTCH_LIVE_RUNTIMES=codex,claude swift test --filter RuntimeLiveTests/testBusyComposerSteeringAndQueue
```

Read the chosen test before enabling it. Other opt-ins cover Hermes startup,
profile/catalog checks, questions, model selection and delegation. Native Hermes
Python checks need the interpreter from its installed dependency environment;
no Hermes installation or credentials belong in GitHub CI. Preserve original
profiles and existing conversations. A temporary companion registry separates
verification sessions from the running app; it does not replace native storage.

Report checks in the PR; update [verification](verification.md) when support
or acceptance status changes. Rebuilding a tagged release is covered in
[releasing](releasing.md#versions).

## Reproducible native UI fixtures

Use `--settings-only` for full-height Settings captures at compact and narrow
widths, including the version footer. The standalone fixture executable says
`Development build`; a fixture bundle with the release Info.plist shows the
stamped release label.

`scripts/render-ui-fixtures.sh --changes-only` renders the collapsed change
summary, expanded file diff, narrow workspace summary, and integrated compact
and full-session conversations using synthetic change metadata and no runtime.

Run `scripts/render-ui-fixtures.sh` to render the actual SwiftUI/AppKit views
with a mock transport and temporary session storage. It writes PNGs under
`build/ui-review/` for compact conversation, sessions, settings, the four
welcome steps (`compact-welcome-0`…`3`, and `-1-mascot` with Soot chosen; the agent step lists the harnesses
installed on the rendering Mac), clarification,
failure, full conversation (also at 1440 × 900, `full-conversation-wide`), the
full-session window's empty Activity and Team tabs, Settings and Usage, and
Markdown with a long code line. The renderer supports both native SwiftPM and Swift 6.3 swiftbuild resource
layouts and copies the resource bundle beside its standalone executable. The fixture
never starts Hermes or modifies saved user sessions. Offscreen fixture renders
verify layout endpoints, not live focus, physical hover/drag, or motion.

The expanded panel renders in the Refined design by default.
`--theme tahoe` or `--theme instrument` renders that design into
`build/ui-review-tahoe/` or `build/ui-review-instrument/`, and `--theme all`
compiles once and renders all three (Refined still into `build/ui-review/`).
The renderer registers the theme as a default, so no preference is persisted.
The compact tiers are identical in every design; comparing them across theme
directories is a quick check that a panel change has not reached them.

`scripts/render-ui-fixtures.sh --theme all --full-body-only` renders full-window
Conversation and Settings with Black, Glass and Smoked in each design. These
offscreen captures check layout and controls, not behind-window blur.
`--full-body-smoke` instead opens the production full-session window with a mock
transport and temporary storage, checks its transparent backing, then switches
Black → Glass → Smoked → Black on that same window and checks the native backdrop.
It registers fixture preferences without persisting them and closes its own
windows when done; it does not restart the user's running app.

`scripts/render-ui-fixtures.sh --theme all --busy-composer-only` renders the
running composer's empty steering hint, typed draft with a queued message,
full-window composer and queue-only harness hint in all three designs.

The `island-*` fixtures place the glance, announcements, and aura over a
simulated desktop and menu bar for both an external display and a MacBook
camera, including fixed-time aura and morph contact sheets sampled from the
real timelines. `scripts/render-ui-fixtures.sh --island-only` renders just
those for faster iteration. Fixed-time stills are not a frame-rate recording.
They also cover the live activity (working,
waiting and alone, on both displays), the interactive glance (approval and
choices), the first-run hello, the dozing eyes in `eyes-expressions`, and
live-shoulder and panel-spring morph sheets. `eyes-motion` samples nodding off,
the startled wake, finishing sparkles and the writing waveform, and
`island-working-rim` the rim comet at fixed lap positions. `--island-smoke` drives the real
host and windows, including the launch unfurl, the failure shake and the live shoulder.
