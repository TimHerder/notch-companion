# Interaction design

This is the current UI contract: Quiet Companion, white eyes as the resting
character (joined by a [mascot](#mascot-stage), Mote, Fold or Soot, when the
island opens if selected), one continuously expanding notch with island tiers
(glance, announcement or stage, live activity), a two-row expanded header, and
per-session status dots. Test results and native evaluation limits live in
[verification](verification.md).

## Release version

The bottom of Settings (compact panel and full-session window) shows the
bundle's stamped calendar release and build, for example
`Notch Companion 2026.10.27-r1 · Build 1`, as selectable text. A bare SwiftPM
executable shows `Development build`. PR builds carry a preview marker and show
`Preview pr-N-HEAD12` even when numeric bundle version fields exist.

## Placement and expansion

The eyes sit in a black extension immediately left of the physical notch; the
camera housing hides anything drawn behind it.

- The resting extension has **exactly the notch's height**, top and bottom
  aligned, so both read as one seamless silhouette: no shorter capsule, step or
  floating container.
- With a physical notch, the band height is the reported top safe-area inset
  plus 1 point (the bare inset leaves a visible seam). Use that height for eyes,
  hit area, launch, live activity and announcements.
- Width is the camera width plus a 58-point left extension and a right shoulder
  of at least 24 points that grows to keep every dot outside the camera.
- Without a notch, simulate a 200-point camera: one centred 258 × 32 band.
  Account for neighboring menu-bar content.

Opening expands **one panel and one black silhouette** to 560 × 544 points
(clamped on small screens): a 64-point header above a fixed 560 × 480 content
region. The header is two rows on one grid:

- **Top row** (band height + 4): the eyes, 1.7× larger, with their left edge on
  the 20-point content margin, and 24-point icon controls (Mark all as read on
  Your sessions, New, Settings gear) at the right margin, 6 points from the
  top. No text, so a physical camera never splits a word.
- **Title row** (28 points): the page title with Back and the Team chip. On a
  session, a status dot follows the title (6.5 points in the session's status
  colour; a lit 6-point LED in Instrument): it breathes while work runs (still
  under Reduce Motion) and hides when nothing is live or unread. Its word
  (“Done”, “Needs your answer”, the running tool) is its tooltip and the
  title's spoken value; banners and the transcript explain the rest. States
  the user must act on (**Check native work**, **Send unconfirmed**) keep the
  word as a short amber subtitle directly under the title.

Content starts directly under the title row; the transcript's own 14-point
inset and edge fade give it air.

Displays without a notch use the 32-point simulated band, so the layout is the
same on every Mac. These are regions inside one `UnifiedNotchView`, not
separate windows.

One `NotchPresentation` snapshot supplies progress, native frame, header
height and the [island tiers'](#island-tiers) amounts (`peek`, `announce`,
`live`, `stage`, `hello`). That progress drives the host frame, outline clip,
mascot expansion and content fade; there is no independent body window, body
mask or expansion animation.

- Expansion uses the panel spring: 95% open at 0.23 s, content interactive at
  progress ≥ 0.95, outline overshooting about 1.5% and settling by 0.5 s.
  Progress itself never exceeds 1. Width trails height (see
  [organic island](#organic-island)).
- Collapse is a 200 ms ease-out. Both are top-anchored; reversals take time
  proportional to remaining progress. Reduced motion snaps all state together.
- Lay the transcript out at its endpoint size and reveal it through the one
  outer shape; never stretch text or draw beyond the curved outline.
  Pointer/drop hit testing matches the visible shape.
- Header and transcript use normal `VStack` layout (offset transforms blanked
  history during native resizing). Programmatic scrolling uses SwiftUI's scroll
  proxy with a zero-sized position observer. No force-redraw workarounds.

| State | Behavior |
| --- | --- |
| Resting | Small white capsule eyes, quiet idle, occasional blink. |
| Pointer nearby | Eyes follow the pointer with eased movement. |
| Pointer touches the companion | A boop: the eyes flinch shut, then pop into a `^ ^` smile with a small hop, within 0.85 s. A visible [mascot](#mascot-stage) also wobbles like jelly about its feet or sill, the eyes riding its face. Once per touch, at most every 0.85 s, never during a file drag; skipped under reduced motion. |
| Hover preview | With **Open on hover** on (`notch.openOnHover`, default on), 120 ms of resting-band hover opens the [glance](#island-tiers) or, with Hover preview set to Full panel, the passive panel. No typing focus. Off: the notch stays closed until a click, shortcut or file drag. |
| Open for input | Clicking opens and pins the panel; clicking a preview promotes it rather than closing it. Hover, click or shortcut opening plays the opening cue once (respecting Sounds and volume); pinning does not replay it. |
| Expanded character | Eyes: the same white eyes, 1.7× larger, at the left of the top row. No body, mouth or color inversion. Mascot: the eyes travel onto the [mascot's](#mascot-stage) face in the header's left column. |
| Thinking | Expanded, eyes look up and drift. |
| Answering | Expanded, eyes look toward the transcript. |
| New tool call | Expanded, a brief glance toward the transcript. |
| Working | Expanded, narrowed eyes scan like reading; the title's status dot breathes and its tooltip names the running tool. |
| Pointer leaves | A passive preview closes 300 ms after the pointer leaves the unified surface; the full panel plays the collapse cue once, the glance closes silently. Moving within it never dismisses it. |
| File approaching | Drag entry opens the panel before the drop, widens the eyes and shows Current session / New session targets. |
| Needs input | Wider eyes with a small periodic hop; expanded, they look toward the request. |
| Finished | A brief `^ ^` smile with three twinkles, then settled. |
| Dozing | After 150 s with no work, question, announcement, open tier or nearby pointer, the eyes nod off into soft `‿ ‿` lids that bob with slow breaths; a pointer within 140 points wakes them with a small start. |
| Disconnected or failed | Worried flat ovals, inner ends raised, one short shake; clear text when opened. |

Work-specific poses apply only in the expanded panel; the resting band and
glance keep pointer-following eyes while work runs.

Control–Option–Space opens the panel for input. Escape dismisses it and
suppresses automatic reopening until the pointer has left. Drafts survive
dismissal. Preserve keyboard access.

Gaze and blink are continuous, sampled at 60 Hz; one 18 ms exponential filter
eases gaze, with no second SwiftUI spring. Tracking reaches 1,200 points; the
expression/blink range is 140 points, and hover-to-open still requires entering
the resting band. Expression changes blend over 220 ms. Feeding widens the
eyes; avoid large idle bounces. Expanded attention uses fixed directions toward
the transcript and request area, not tracked row positions. Reduced motion
keeps each state's static pose, drops scans, hops, shakes, glances and timed
smiles, and suppresses pointer movement.

## Right-side session indicators

Each session has its own dot, in session-list order by stable ID. Delegated
children contribute to their parent instead of adding dots.

| Session state | Dot |
| --- | --- |
| Working session/child | Orange, breathing slowly (static under reduced motion). |
| Waiting session/child | Orange. |
| Unread failed session | Red. |
| Unchecked finished session | Green. |
| Idle, interrupted, or read finished/failed | Hidden. |

Dots are 5 points wide at 8-point spacing. A physical notch reserves at least
24 points on the right and grows that shoulder to keep every dot outside the
camera; a row wraps only at the screen edge. External mode fits dots inside the
simulated camera and stays 258 points wide. Expanded bounds do not change when
a dot is acknowledged. Sessions shown in the [live activity](#living-island)
fold their dots into it; other dots keep their order after it.

**Read receipts.** Only reading a selected conversation after the notch fully
expands (or the active full-session Conversation tab) acknowledges its current
result. Sessions, settings, activity, team views or a stored selection alone do
not. A result arriving while its conversation is shown is acknowledged
immediately. A locked or off-console desktop is not a check-in. Receipts persist
across relaunch; new turns, rejected sends and late delegated results can
produce new dots; duplicate terminal events never resurrect a read dot.

**Mark all as read** (checkmark beside Your sessions, notch and full-session
sidebar) acknowledges every current result and saves immediately, leaving work,
history and selection intact; it is disabled with nothing unread. Session rows
show a green check or red mark only while unread; once read they keep only a
quiet mark for a failure and dim their title. Tooltips and accessibility labels
distinguish read and unread.

## Island tiers

Between the resting band and the full panel sit small tiers of the **same**
silhouette, panel and clock: `NotchPresentation.peek` (glance) and `.announce`
(widened band) interpolate on one `UnifiedNotchMotion`.

**Glance (hover).** With Hover preview set to Glance (`notch.hoverPreview`,
default), resting-band hover opens a pure-black island about 420 points wide,
centred like the panel, top-anchored, covering the band and camera.

- The band keeps the eyes (slightly larger) at the left and, right of the
  camera, a summary (“1 needs you · 2 working · 1 new”, symbol counts where
  words do not fit, or “All caught up”).
- Below: up to three 44-point rows by priority (needs you, working, unread
  failure, unread result, then recent; quiet archived or
  [auto-archived](#conversation-usability-and-session-management) sessions and
  untouched drafts skipped). Each has a status glyph (spinning orange arc;
  solid discs with a dark mark for a pulsing amber question and, while unread,
  a green check or red warning, so the rows that need you are never the
  dimmest; quiet marks once read),
  title, runtime, live turn timer or age, and one line of real detail (the
  question, running tool and argument, streaming tail, failed child, “Asks: …”,
  or the result's first line, e.g. “Sent report.pdf”).
- A 34-point **New session** row names the harness a new draft would use; with
  no rows it is the only row. It opens the panel on a ready draft, reusing an
  untouched one. Height follows the rows and re-springs when they change.
- Opening uses a light spring (about 3% overshoot, settled in 460 ms); scalar
  states stay within their endpoints and rows materialize one after another.
  Closing is the 200 ms ease-out; promotion uses the panel spring.
- The glance is silent, takes no focus and never acknowledges a result.
  Clicking a row opens that session; clicking elsewhere, the shortcut or a file
  drag promotes it to the full panel with the opening cue and drop targets.
  Outside clicks close it.

**Announcement.** When a session finishes, fails or asks for input while the
notch is not expanded, the band keeps its height and widens on the right (the
camera-side edge never moves) to show the colored status icon and the session
title, then one line of the message, sized to the text within 120–230 points.
The icon and its color carry the verb, so no “Done”/“Failed”/“Needs you” word
is drawn; VoiceOver still hears “Done: <title>. <message>”, the message cut at
400 characters. The title comes first at its full width; the message follows
in secondary color only in the width left beside it, and is left out rather
than shown as a stub when less than 70 points remain (the stage and glance
still show it). Both truncate at the tail. It springs open, holds 4.2 / 5 /
6 s (done / failed / needs you), and retracts over 340 ms. The eyes take the result's expression
and look at the label. Clicking it opens the session; hovering opens the
glance. Dots stay to the label's right.

The message is a snapshot taken when the moment is announced, so it keeps
saying what happened even if the session moves on during the hold:

- Done: this turn's answer as one plain line (Markdown removed), never the
  prompt or an earlier turn's answer.
- Failed: the runtime's reason from its error event, else the reason the
  failed turn's own terminal event or notice gives, else “Send unconfirmed”,
  the failed delegated child, this turn's last answer, or “Something went
  wrong”.
- Needs you: the question's text, or the command an approval wants to run.
- The first-launch hello reads “Hi! Hover here to begin”.

**Aura.** A click-through, non-activating `NotchAuraPanel` ordered directly
**behind** the notch panel mirrors the presentation while an effect plays, then
orders out; the black body hides the inner half of each stroke so light seems
to come from the edge. Finished: two traces race from the bottom centre around
both corners (720 ms), a mint flare with streaming dashes, and an expanding
ring (about 2.1 s). Failed: a red double flicker while the island shakes (see
[island delight](#island-delight)). Needs input: two amber breaths and a gentle
ring. Reduced motion keeps only a soft fade. The aura owns no geometry, input
or expansion and never plays while the full panel is open.

**Toast.** In the open panel, a result from a session other than the one being
read appears as a small capsule below the header (status glyph, title, then
one line of the message by the band's rule, only in the width the title
leaves, and “Open”; no verb word, VoiceOver keeps it), at most 380
points wide, for the same hold, until the panel closes or that conversation
opens; clicking it opens the session. The band, toast and aura never play for a conversation
that is on screen. VoiceOver hears each announcement.

**Status effects** (`notch.statusEffects`, default on) controls announcements,
toasts, the aura and the rim comet; its Preview button closes the panel and
plays the finished effect. Dots, eyes, sounds and receipts are unaffected.

## Living island

None of these adds a window or a second outline animation.

**Live activity.** While sessions work or wait, the band's right shoulder shows
one glyph per busy session: needing-you first (amber pulsing question), then
working newest first, each a ring spinning around its running tool's glyph
(terminal, file, edit, search, web, delegated agents, plan, or a sparkle while
thinking), morphing as tools change. At most four glyphs; further sessions keep
their dots. No turn timer in the notch.

- Physical notch: the shoulder is an 8-point camera gap + glyph row (at least
  38 points; each glyph beyond two adds 21) + 12 points, so one or two glyphs
  mirror the eyes' 58. Simulated notch: the band widens 24 points, centred.
- `NotchPresentation.live` springs like the other tiers and retracts over
  340 ms; content materializes from a blur and glyphs scale in and out. An
  announcement takes the shoulder for its hold, then hands it back.
- Clicking a glyph opens its session. **Live activity** (`notch.liveActivity`,
  default on) off restores dots alone.

**Interactive glance.** A row whose pending request is simple gets a 30-point
line of choices answered in place: approvals offer **Deny** and **Allow once**
(broader grants stay in the full card; an approval without a one-time choice
opens the session); a single-choice question with up to four options totalling
56 characters offers each. Answers use the card's native path, duplicate
protection and send cue; the glance stays open. Hovering a running row swaps
its runtime name for a **Stop** that interrupts without opening or selecting.

**Motion language.** Panel content and announcement/live labels materialize
from a light blur; timers roll digits; tool
glyphs morph. A faint rim along the open island's sides and bottom (starting
below band height) defines it against dark wallpapers.

**Press.** Holding a click on the band or glance band squeezes the island about
its centre (2% of width, 3% of the glance body height, 110 ms) with the top on
the screen edge and the band at notch height. Release springs back, or straight
into the panel when the click opens it. Skipped under reduced motion.

**Launch and welcome.** At launch a drop with the eyes in it pops out of the
top edge (see [organic island](#organic-island)). On a new user's first launch
the [welcome](#welcome) follows at 3 s and ends with a sage **Hi! Hover here to
begin** announcement (skipped with Status effects off).

**Gestures, haptics, login.** **Swipe on the notch** (default on): a
two-finger swipe down over the band or glance opens the panel; up over the
glance or the panel's header row closes it. Transcript scrolling is unchanged,
finger direction counts regardless of natural scrolling, each gesture acts once
and momentum never acts. **Haptic feedback** (default on) taps a Force Touch
trackpad when the glance opens under the pointer, a swipe lands, or a dragged
file crosses between drop targets. **Open at login** registers a login item and
links to System Settings when macOS needs approval.

## Island delight

Each effect is brief, driven by real state, and dropped under reduced motion.

- **Failure shake.** The island shakes horizontally like a rejected Face ID:
  at most 6 points, dying away over 0.5 s. Only the notch and aura windows move;
  `NotchPresentation`, geometry and hit testing stay put, and the window lands
  exactly on the announced band.
- **Announcement icons act out their verb,** which they replace as a word in
  the band and on the stage: Done draws its check, Hi waves, Failed wiggles,
  Needs you hops.
- **Writing waveform.** While an answer streams, its live glyph is three bars
  that jump as text arrives and settle within about a second of a pause.
- **Working shimmer.** A soft highlight sweeps a glance row's tool or
  thinking line while work runs, never a streaming answer.
- **Rim comet.** While agents work, a small warm light laps the open glance or
  panel rim every 4 s, emerging below the band.
- **Landing dots.** A dot that becomes a result or question pops and sends one
  thin ring; unread dots also do this once at launch.

## Organic island

- **Flares.** Concave pure-black fillets join the silhouette's sides to the top
  edge: 8 points at rest, up to 12 as a tier opens, never more than a third of
  the height. They draw in a 12-point window margin each side, take no clicks,
  and leave geometry, layout and hit testing unchanged.
- **Launch hello.** The island pops out as a drop the camera's width (160
  points without one), hanging 30 points below the band, corners radius +10,
  eyes 1.3× larger in the middle of the part below the camera. `hello` lowers
  and enlarges the eyes with the height; `helloCentre` centres them with the
  width. On a notched Mac the drop grows from the bare physical notch (no
  flares, eyes hidden), forming its flares (`flares`) as it drops; without a
  camera it starts as a bead 45% of its width. It stretches about 20% deeper
  (ζ 0.45, 0.6 s) and spreads 0.2 s later (ζ 0.55, 0.62 s); eyes blink awake
  at 0.9 s; at 1.7 s it spreads to band width, the eyes sliding into the left
  extension, then rises into the band. Each phase settles within 1.4 s. A
  geometry change retargets the drop; hover opens the glance as usual. Dots and
  live activity fade in as it settles. Skipped under reduced motion.
- **Stretch and spread.** On every spring the growing dimension leads and the
  other follows 50 ms behind (40 ms for the panel), settling together: opening
  tiers grow tall and narrow, then the width overshoots slightly. Progress,
  opacity and interactivity follow the height. A springing outline is never
  shorter than both ends, so it cannot bare the camera's edge. Content is laid
  out at final width and clipped. Closing keeps its ease-out. Pin content to the
  window's top, not centred: AppKit rounds fractional frames outward, and
  centring uncovers the top pixel row mid-animation.
- **Pointer pull.** Within 90 points of the resting band, the nearest stretch
  of outline leans toward the pointer, up to 10 points, tapering to nothing at
  the edge so it never passes the pointer. It fades along the outline (24-point
  Gaussian) and to nothing at the top edge, only adds black outside the body,
  follows with a 60 ms ease and a critically damped depth spring (no wobble).
  Opening tiers absorb it. It draws in the window margins (11 points below the
  band), takes no clicks and leaves geometry unchanged; the aura ignores it.
  **Pointer pull** (`notch.pointerPull`, default on); skipped under reduced
  motion.

## Mascot stage

Appearance and update layout are independent settings; all four combinations
work:

- **Notch updates** (`notch.updateStyle`): **Compact** (`compact`) keeps the
  [announcement](#island-tiers) in the resting band; **Popup** (`popup`,
  default) opens the stage below.
- **Companion** (`notch.companionAppearance`): **Eyes** (`eyes`) or **Mascot**
  (`mascot`, default), which adds a character to the stage and full panel. The
  resting band and compact updates always show only the eyes.
- **Mascot** (`notch.mascotCharacter`, shown only with Mascot): **Mote**
  (`mote`, default), **Fold** (`fold`) or **Soot** (`soot`). Unknown values
  fall back to Mote; a character without bundled sprites falls back to the
  eyes. Switching while shown lets the new one emerge in place.

Saved values migrate at launch: `shoulder` becomes Compact; a missing
appearance follows the update style (Compact → Eyes, Popup → Mascot). Both are
then written, so changing one never changes the other after relaunch. Dots,
live activity, glance, toasts, sounds, aura and receipts behave the same in
every combination.

**The mascots.** Three Blender-rendered characters (see
[native build](native-build.md#mascot-assets)) of similar height with blank
faces darker than their bodies. The app draws the **live white eyes onto the
face** from per-frame anchors, so gaze, blinks and every expression carry over,
and the eyes hide when the face turns away. At rest only the eyes show.
Signature moments:

- **Mote — phase through:** drifts up through the stage's bottom edge, tail
  curling around the border.
- **Fold — unfold:** unfolds from a flat paper square around the eyes, hood
  first, then sleeves.
- **Soot — windowsill:** climbs up and hangs on the stage's bottom edge, mittens
  gripping over it, lower body hidden; on Done it hops up.

**Becoming the mascot.** As the panel or stage opens, the body grows around the
eyes (the emerge) while the eyes travel onto the face on the same clock. During
an emerge the eyes keep the size and turn of its last frame; only their centre
follows the body. Closing shrinks the body back toward the eyes. In the panel
the mascot stands in the header's left column across both rows; the title row
starts beside it.

**Acts.** The mascot acts from the eyes' mood: calm (ready, dozing), busy
(thinking, working, writing), a wave then eager wait (needs you, and the
first-launch “Hi, I’m <name>”), a celebration (done), failure settling into
sadness (failed). Entrances wait for the emerge, play once, then cut to their
loop; a newer act cross-fades over 0.22 s; an entrance older than a second does
not replay on reopen. Reduced motion shows each act's first pose without the
emerge.

**Boop.** Once the mascot is mostly out (reveal ≥ 0.5) the pointer boops its
body: an ellipse 60% of the figure frame wide, from 20% below its top to the
feet, cut off below the island edge plus overhang. Before that, and with Eyes,
the boop target is a 28 × 20 point ellipse around the eyes, scaled with them.

**Clips, ledges and overhang.** On the stage a character plays
`stage-<clip>` where rendered, else the base clip; the header always plays base
clips. Handing over to the panel cross-fades the clip set over 0.22 s while the
figure glides to the header. The 150-point stage frame (4 points from the
island's left) puts its **edge line** on the island's bottom edge: the clip's
`ledge` (behind which body and eyes hide), else a standing line 10 points below
the feet. On the stage only, the mascot may draw up to **16 points below the
island** (mittens, a tail), clipped to the silhouette lengthened by that margin
times stage progress; the panel and resting band never overhang. The native
window grows down by the margin only while the stage shows; that strip takes no
hover, clicks, swipes or drops, and the window top, flares, aura and hit regions
are unchanged.

**The stage.** With Popup, a result, question or failure (and the hello) grows
the notch into a 440-point-wide island below the band, top-anchored and
centred like the glance, on the glance's spring, corners radius +14. It uses
the one panel, silhouette and clock (`stage`), never shows while the panel is
open (the toast stands in) or over an open glance (the edge still lights).

- Rows, without a verb row:
  - a header: the acting status icon (14 points, colored), the title (15
    semibold, one line) and, trailing in faint monospaced digits, the runtime
    and how long the turn worked (“Codex · 2:14”);
  - the message (12.5 points, 78% white), up to three lines, two when answers
    or a command follow;
  - for a finished turn with changes, one quiet line such as “4 files +120 −8”
    with the counts in green and red;
  - for an approval, “Wants to run” and its command in a monospaced inset
    field that wraps between any characters for up to three lines and only
    then truncates at the tail, never in the middle; the body grows with it;
  - the answers directly beneath.

  Message, line, field and answers hang after the icon's column.
- Content is kind-aware. Results and failures show the announcement's snapshot
  (see [announcement](#island-tiers)), never live status such as “Thinking…”;
  a question shows the live request, so one answered meanwhile shows **Answer
  sent** (an answered approval keeps “Wants to run” and its snapshotted command
  in the field, the same full command as before the answer; only speech is
  cut to 400 characters).
- The body height is measured from this content and the text width before the
  stage opens, and re-springs if it changes (the next question, a late change
  summary). With Eyes, the eyes stay in the band; the text starts 8 points below
  it with a 20-point inset, and short results leave no empty space. With
  Mascot, the mascot stands at the left, about 150 points tall, the body keeps
  at least 132 points for it, and the text block is centred vertically beside
  it.
- The stage has **no buttons of its own**: clicking outside its answers opens
  the session on the panel spring, the mascot gliding into the header; hovering
  away lets it retract. The opening area shows a pointing hand; answer controls
  keep their cursors (the reply field an I-beam). VoiceOver reads it as a button
  with a Dismiss action.

**Answering on the stage.** A native question or approval shows up to two
lines of question with answers directly beneath, on the same native path and
duplicate protection as glance and card: **Deny** / **Allow once**; a
single-choice question's options (up to four, any length) as wrapped pills; and,
when the runtime allows a written answer, a reply field that sends on Return (a
failed send keeps the text). Each answer row is 26 points with 4 between, and
grows the stage. Clicking the field lets
the non-activating panel take the keyboard without activating the app; the stage
gives it back as it retracts. After answering it shows **Answer sent** and
retracts 1.6 s later, unless the batch's next question takes its place.
Several-choice questions, more than four options and approvals without a
one-time choice show the question only; clicking opens the full card.

**Holds.** The stage retracts after 6.5 / 7.5 / 12 / 7 s (done / failed / needs
you / hello). It stays while hovered or while its reply field is edited, then
retracts 0.3 s after the pointer leaves. Swipe up dismisses, down opens the
session. It retracts over 340 ms and suppresses the hover glance while shown.

## Welcome

First-run setup lives inside the notch, offers detected harnesses and live
appearance previews, and uses neutral wording without a character voice.

- **When.** 3 s after first launch, if `notch.welcomed` is unset and no session
  has messages or a native identity, the panel opens on the welcome. The key is
  set as it opens, so quitting midway does not repeat it; existing users are
  marked welcomed. Settings → **Welcome · Show again** replays it.
- **Where.** A page of the one panel (`PanelPage.welcome(step:)`). The header
  keeps only the eyes or mascot and a **Skip** button (not on the last step);
  New, Settings, Back, the title row and composer are hidden. Each step
  centres a title, a secondary line and its choices a little above the middle;
  the footer has a page indicator, **Back** and **Continue**/**Done** as the
  primary (Return). Steps blur through each other over 0.34 s (fade under
  reduced motion). The step lives in the page, so it survives the panel closing
  for a preview.
- **Agent** (*Choose your agent*): installed harnesses in catalog order, with
  install location; the default agent if
  found, else the first, is preselected. Choosing sets the default agent and the
  untouched first draft's harness; **Continue** checks the connection, showing
  failures in the panel's error line. With none found: *Install an agent*, setup
  links and **Check again**.
- **Look** (*Pick a companion*): cards for **Eyes**, **Mote**, **Fold** and
  **Soot**, each idling live with its signature. Each card uses its own mascot
  library holding one decoded sheet, so the header mascot is never trimmed.
  Choosing sets Companion and Mascot; the header shows it emerging.
- **Updates** (*How should updates appear?*): **Compact** and **Popup** cards.
  Every press sets Notch updates and plays the Settings preview (“Sample
  update”): the panel closes, then reopens on this step. No sample with Status
  effects off.
- **Start** (*Final touches*): the chosen companion above the Default folder
  and Open at login rows (the Settings controls).
- **Done or Skip** returns the page to the session, closes the panel and plays
  the hello in the chosen style. Open on hover, sounds and haptics stay on by
  default and are not asked.

## Compact panel

A stable structure: session heading, scrollable conversation region, composer.
The notch is a complete place to read the conversation, not a preview. Your
sessions has no composer: the list uses the whole content region and opening
the page focuses search. Drafts, attachments and file drops are unaffected (a
drop opens its session).

- Attachment chips and the bounded multiline editor use internal space; neither
  grows the panel.
- The header has New and a gear that toggles Settings in place. Settings uses
  the full content region without the composer, its destination controls or
  attachment strip, and links to the full-session window. Returning restores
  the composer with draft and attachments. Detail views keep Back.
- The transcript fades over 14 points at both edges, under the header and above
  the composer, in every design and both surfaces, on an eased ramp so a line
  cut by the edge dissolves instead of reading as sliced. Its 14-point inset
  keeps content at rest out of the fade.
- Show the full conversation in true order: a turn's text and tool calls appear
  in the order they began. Text the agent writes between calls is commentary,
  one step smaller and quieter, with no header or Copy. Consecutive calls form
  a run of single-line rows (status icon, name, middle-truncated detail; the
  status word is spoken, not shown) with no card in Refined and Tahoe and log
  lines in Instrument; a finished run outside a fold reads “N tool calls”. In
  Refined and Tahoe a failed call's name takes the failure colour beside its
  icon; Instrument marks it with its signal tag.
- **Live current-turn cap:** only the newest run shows its latest three calls,
  newest at the bottom, with older calls behind “N earlier tool calls”; new
  calls roll rows upward. Stable tool identities update rows in place. The cap
  limits only the live summary, never history. A footer under the newest
  content reads “Working for 42s”, ticking for the whole turn while text
  streams (“Waiting for your reply…” while the agent waits on you, beside a
  still question mark in the needs-you colour in Refined and Tahoe and a steady
  signal LED in Instrument; never the spinner), followed by
  any delegated agents still working.
- **Finished turns** read: your message, a **Worked for 2:14** fold (collapsed
  by default), the answer, then its changes. The answer is the last text the
  turn wrote; it keeps the full body style and Copy on hover, and ordinary
  replies carry no harness-name header (relayed messages keep their label). The
  fold holds the commentary and runs in order, indented on a thin leading rule;
  unfolding it stops transcript following. With nothing to fold, the duration
  is a quiet line; a turn saved without its end reads “Worked · N steps”.
  Durations read 8s, 2:14, 1:02:10.
- A turn that ended before writing any text has no answer: its work stays open
  under its header. A turn's own failure or stop names it, “Failed after 1:03”
  or “Stopped after 12s”, on that header or on the fold above whatever text it
  wrote (a failed delegated child does not, and a send that failed before it
  became a turn never relabels the one before: a turn ended by a quit, a
  disconnect or a Stop the runtime never confirms keeps “Stopped”). A turn
  whose questions above its answer are still open keeps its work unfolded, so
  the card stays in view; it folds once you reply. A steer or wake starts its own
  block; blocks split from a running turn stay open until the turn ends, and a
  block without its own end ends when the next one in its turn begins.
- Persist turn IDs, end times and outcomes with messages and tool metadata so
  blocks stay correct after reconnect or resume.
- Long tool labels truncate with a way to see the full text.
- Streaming updates within the existing region, never resizing the notch.
- Input and approval requests never rotate out with ordinary activity rows.
- Scrolling up stops following new content until the user returns with
  **Jump to latest** or scrolls to the end.
- Progress describes observable work, such as “Reading a file”.

## Change summaries

Each coding turn can show a collapsed **Changes · N files · +A −D** row directly
under its final answer (below the turn's folded work), in the notch and
full-session window. Expanding lists paths, change
kinds and per-file line counts; clicking a file opens its selectable unified
diff below it (green additions, red removals) in a bounded, independently
scrolling viewport. Binary files show a Binary label, not line counts.
Expanding or inspecting stops transcript following; the notch never grows.

**Open file/project in VS Code** uses the installed editor, else Cursor, Zed or
Xcode, else asks the user to pick an app. Right-click either action for
**Choose editor…**, which is remembered; the picker uses the above-notch modal
handling. Launch via LaunchServices with file URLs (no shell interpolation) and
collapse the notch after opening. Missing or deleted files stay reviewable in
the saved diff; deleted rows offer opening the project. The editor shows the
current file; the inline diff is the saved turn snapshot.

Codex's native aggregate is labeled **Changes** with an agent-reported note.
Other runtimes, or Codex turns without it, use **Workspace changes**: a Git
snapshot against the turn-start commit, including staged, unstaged and
untracked non-ignored files; its note says it includes pre-existing and
concurrent edits. Snapshots wait for parent and delegated work to settle.
Summaries stay attached to their turns; old conversations are not backfilled.
Empty results and non-Git folders without a native diff add no card. Read
errors and oversized diffs show an explanation and the editor action, never a
partial total. See the [runtime limits](backend-runtime.md#change-summaries).

## File eating

1. A dragged file enters the band; the eyes widen and the panel opens before
   the drop. A large rounded **inset tray** fills most of the surface:
   **Current session** (with its name) on the left, **New session** on the
   right, a subtle divider between. The conversation stays visible behind a
   light blur and darkening, with a subdued header and crisp eyes. Never
   separate floating windows.
2. The hovered half gains an accent fill and **Release to attach**. Only the
   tray accepts files; its corners, the header and margins reject drops while
   keeping the chooser open. No dead gap: the exact midpoint belongs to the
   right. The silhouette is unchanged. Targets accept files only after the
   expansion settles.
3. On drop the file shrinks toward the eyes, which chomp twice and smile.
   Current session keeps the destination shown at drag entry, including from a
   child/detail view. New session creates a fresh draft without interrupting
   work or changing other drafts.
4. The chooser disappears, the panel pins open, the conversation shows
   removable attachments and the composer takes focus.
5. The user adds instructions and sends explicitly.

Dropping never deletes or moves the original and never runs a task. Readable
regular files are staged locally; backend attachment RPCs run on send; errors
stay visible and staged files remain for retry. With no usable current session
only New session is available. Multiple files attach together; duplicates are
ignored. Cancelling creates nothing. The conversation stays mounted under the
chooser, and showing it does not acknowledge an obscured unread result.
Subdued background controls get no clicks or accessibility focus. The file
picker and full-session window attach to their composer directly. The
left/right split holds at small clamped sizes and never stacks.

## Delegated agents

One mascot shows the parent's overall state; never a separate panel or mascot
per child. Navigation:

```text
Parent session
  -> Team summary, e.g. “2 working · 1 finished”
    -> Bounded list of delegated agents
      -> Selected agent's status and recent activity
```

Each level replaces the detail region with a clear route back; outer
dimensions stay fixed, and larger teams scroll rather than grow. Name children
by role or task and distinguish running, finished, failed and waiting in text,
not only visually. Child results stay with the parent; final synthesis belongs
to the parent's result. Children started in another harness use the same
navigation; see [Delegation](#delegation).

## Visual identity

Quiet Companion: white eyes on the black notch, graphite surfaces, warm white
text and muted sage actions. The mascot is neutral, not green. Personality comes
from expressions, gaze, blink timing and restrained feeding motion. Keep the
expanded UI quiet and native; playful effects stay brief, with no constant
bouncing or unsolicited large expansions. The expanded panel has three
[designs](#panel-designs); the compact tiers look the same in all of them.

**Notch body** (`notch.bodyStyle`): **Black**, **Glass** or **Smoked**
(default: a 55% black layer over the glass). Glass and Smoked use an active
`NSVisualEffectView` with `.behindWindow` blending and dark HUD material so the
desktop shows through even in a non-key preview; a SwiftUI glass effect alone is
not a window backdrop, and a glass tint vanishes while non-key, so smoke is a
black layer. Resting is always pure black; glass styles keep the band height
black and fade to glass over the next 80 points. Body controls by design:

- **Refined and Tahoe:** on Black, header buttons and Jump to latest use Liquid
  Glass; on glass bodies, plain white-8% fills (no glass on glass). Refined's
  composer is a solid white-6% field on every body. Tahoe's composer is Apple's
  gray fill under Liquid Glass on Black, translucent on Glass and Smoked; its
  other fills stay translucent except the sent bubble, menus and drop tray.
- **Instrument:** flat hairline keys and inset fields on every body, no Liquid
  Glass; Jump to latest is a solid black key; the blur shows through the dot
  grid.

The full-session window follows the same Notch body setting immediately,
including controls, sidebar and the area under the title bar, with a uniform
material (no band or 80-point fade) and a clear, non-opaque backing, on every
page and design.

### Full-session window

A sidebar and main pane with no title strip: content runs under transparent
title-bar chrome so the sidebar tint and panel background reach the traffic
lights. The title stays set for Mission Control and the Window menu. Size and
position are remembered (`FullSessionWindow`).

- Every page uses one header: optional back chevron, 19-point title, optional
  one-line subtitle, trailing controls (Conversation / Activity / Team).
  A session's subtitle never contradicts its transcript: the harness and
  “Needs your answer”, “Working for 0:42” (ticking), **Send unconfirmed** or
  **Check native work**; otherwise a connection problem while idle; otherwise
  how the last turn ended (“Worked 2 min ago”, “Failed 1 h ago”, “Stopped just
  now”). “Connects when you send a message.” is left for a session with no
  connection that has not run a turn, and a connected one says so.
- Header, banners, transcript, tabs and composer share one centred column at
  most 820 points wide; Settings and Usage use 620.
- Settings opens in the main pane from a **Settings** row at the foot of the
  252-point sidebar, with **Usage** above it when **Show usage** is on.
  Clicking the selected row, Back or a session change returns to the session.
  Choosing a runtime from Settings opens its chooser or setup page; Back returns
  to Settings. Opening the window from the notch's Settings footer opens
  Settings.
- Empty Activity and Team say so instead of showing a blank pane.

### Panel designs

`PanelTheme` (`notch.panelTheme`, Settings → **Panel design**, default
Refined) selects one of three designs. `CompanionStyle` tokens dispatch on it,
and views whose anatomy differs switch on it. Switching rebuilds the panel roots
(`panelThemed()`) immediately; page, drafts and sessions survive. The resting
notch, dots, live activity, announcements, aura, rim comet, glance and stage use
`IslandStyle`, which is identical in every design.

- **Refined** (default): 4/8 grid; type scale 20/15/13/12/11; radii
  6/10/14/18; `well` cards and a `raised` bubble. Status colors match the
  island dots (working orange, needs-you amber, done green, failed red); sage
  only for the primary action. A faint bloom around the open eyes. The composer
  is one field with an inner bar (see [composer model controls](#composer-model-controls),
  as in every design); user messages are right-aligned bubbles; approvals,
  questions and project trust are amber-rimmed cards; copy on hover or focus;
  scroll edges fade.
- **Tahoe:** Apple-native. Dark-Aqua label opacities, gray fills,
  `Color.accentColor` for the primary action, switches and selection, system
  status colors. Lit disc header controls; capsule buttons with a lit glass
  edge; Settings, setup, projects and delegated work as grouped lists with
  colored icon tiles; menu-style choosers. The composer is a rounded field
  (18-point radius) with its bar inside.
- **Instrument:** monochrome plus one international-orange signal (`#FF5A1F`)
  for what needs you and the primary action. Tracked uppercase SF Mono for
  labels, states, counts and logs; SF Pro for prose. Hairlines, 3–4-point
  radii, a 16-point dot grid, a ruled scale under the header, viewfinder
  brackets around the open eyes, LED lamps, numbered rows (in the notch), tool
  calls as log lines, code line numbers, segmented meters, a diffstat, square
  switches and a fader slider. The composer is an inset readout: a prompt
  chevron on the first line and the bar along its bottom edge.

## Controls and window behavior

Use the shared controls in `NotchControls.swift`, which draw each control in
the current design. Reserve the accent (sage, system accent, or Instrument
orange) for the primary action (Send/Stop, Reply, Allow once, Save). Every
control has hover and press feedback. The gear toggles Settings directly;
**Open full session** lives in the Settings footer. Offline state appears in the
top banner and Settings, not in the composer.

Use inline choosers inside the fixed panel, with plain monochrome buttons and
no native menu tracking.

- The draft's agent button opens a compact names-only overlay of harnesses whose
  current profile passed a Settings connection check. Readiness survives
  restart; profile or installation changes and failed connections require a new
  check. With none ready, link to Settings and keep drafts and files editable
  with Send disabled. The detailed chooser stays in Settings for the default
  agent. Connection timing: [runtime contract](backend-runtime.md#multi-harness-contract).
- The Archived chip toggles; choosing it again returns to the active list. Row
  ellipses expand actions inline; right-click keeps the native menu.

`CompanionPanel` stays nonactivating and above the menu bar: set `.statusBar`
after `isFloatingPanel`, which resets the level (a lower level routes top-band
clicks to the menu bar and triggers outside-click dismissal). Header control
clicks pin an existing hover preview.

Pickers and alerts the notch opens run modally one level above it. `runModal`
drops a panel to the modal-panel level beneath the notch, so a common-mode
timer keeps it raised until the modal session ends. Outside clicks never
dismiss the notch while a modal is up. Anything opened in another app (file,
folder, link) collapses the notch so it is not hidden beneath it.

Background cursors need `HoverCursor` and the window-server
`SetsCursorInBackground` connection property; ordinary cursor setting is
ignored for a background app. Use its pointing-hand/I-beam regions and give new
pressable views `pressableCursor()` (shared button styles already do).

## Conversation usability and session management

Icon controls have subtle hover feedback; session rows visibly and accessibly
identify selection.

- **Composer.** Grows from one to four lines, then scrolls. Return or
  Command–Return sends when idle; Shift–Return inserts a newline; marked
  input-method text is never submitted. While working, Return steers where the
  native interface supports it and Command–Return queues a follow-up. The hint
  reads `↩ to steer, ⌘↩ to queue for later` and stays inside the field below
  typed text. Queue-only harnesses, Hermes image input, or a parent waiting only
  on children show a queue-only hint; Return then keeps the draft and explains
  Command–Return, never silently substituting interruption or queuing.
  [Runtime compatibility](backend-runtime.md#composer-steering-and-queuing)
  decides the hint in both surfaces and all designs.
- **Queue.** Queued messages appear above the field in order with cancel, three
  visible rows then scrolling; hover shows the full text and file names. Text
  and attachments are saved before the composer clears. Queues wait for parent
  and child work. Stop, a failed turn, a disconnected frontend or restart pauses
  them until **Resume queued messages**. A refused queued send keeps its one
  saved copy and pauses the rest. Unconfirmed sends keep **Check last send**
  protection. A normal idle send works while the queue is paused.
- **Sending.** After validation, text and files leave the composer immediately
  while setup continues. The message enters the transcript with an 8-point
  upward arrival and fade over 180 ms (immediate under Reduce Motion), with a
  “Sending…” label during setup; its identity is kept when native submission
  starts so it is never inserted twice. Animate only the transcript insertion,
  not the editor clearing. Definitive failure restores the original text ahead
  of any newer draft (separated by a blank line) and its files. Uncertain
  delivery keeps the message and **Check last send** instead of a duplicate
  retry.
- **Rendering.** Assistant and delegated results render headings, lists,
  quotes, rules and fenced code; code scrolls horizontally with its own Copy.
  User messages stay literal.
- **Destination.** On secondary pages with a composer (not Settings, Your
  sessions, runtime setup/chooser or Welcome), it names the selected parent
  session. The folder beside it is that session's: a draft chooses it until its
  native session exists (OpenClaw drafts keep their agent's workspace); a
  started session's folder opens in Finder. Settings labels the separate default “Default folder
  for new sessions.”
- **Session browsers.** Both share search, rename, archive/restore and one
  **Archived** chip inside the search capsule in every state, typing included.
  With Archived on, the title reads **Archived** and Back (the notch header's
  chevron; a chevron before the sidebar title) returns to the active list. The
  Needs you and Unread filters remain in the model, not the interface.
  - The default list shows only active sessions: working, needs you, unread
    result or failure, unconfirmed send, a draft with text or files, the
    selection, and read idle sessions not yet auto-archived. It ends with a
    quiet **Archived · N** row; with nothing active it reads “All caught up”
    above that row. Empty states start at the rows' content inset.
  - **Auto-archive** is derived, never a flag. A top-level session that is
    read, idle, not submitting, with no pending or queued send and an empty
    draft, lists under Archived once the later of its last activity and
    `lastSeenAt` is older than Settings → **Archive read sessions after**
    (`sessions.autoArchiveAfter`: 1 hour, 12 hours (default), 3 days, Never;
    1h, 12h, 3d where the 252-point sidebar is too narrow for the words).
    The selection never auto-archives; `lastSeenAt` is set when a session is
    opened, read, restored or stops being the selection. The list re-evaluates every minute. Sending,
    opening or Restore brings it back.
  - Archived lists manual and auto-archived sessions by project; archived
    attention and unread results keep their dots. A search query covers every
    top-level session, titles and conversations, archived ones marked.
  - Rows are about 34 points: status glyph (spinning arc, pulsing
    question, green check or red mark while unread; a quiet mark for a read
    failure; Instrument uses its lamps), title (dimmed once read), the runtime
    (notch only) and a compact age, or the ticking turn timer while working.
    The notch keeps each row to one line; the full-session sidebar wraps a
    title to two lines, with the glyph, age and ellipsis on its first line,
    and leaves out Instrument's row numbers.
    The latest message is the tooltip and part of the accessibility label.
    Hover, focus or open swaps the age for the ellipsis, which expands Rename,
    Archive or Restore, and Continue in Hermes… (legacy only) inline.
  - Order keeps the stable order used by the dots. Archiving keeps history,
    drafts, selection and receipts; active work cannot be archived. Sending
    restores an archived session.
- **Questions.** A pending question replaces the composer. Choices stay unsent
  until Reply. Free-text alternatives, progress, per-question state and
  duplicate protection are shared across windows; failed submissions keep the
  answer.
- **Failed delegated work** gives its parent red attention and a Review action.
  Child turn ownership keeps old failures from changing a later turn's outcome.
- **Quit and Reconnect** check all app-owned work, including submissions and
  children. When busy, a dialog offers When Work Finishes, Stop and
  Quit/Reconnect, or Cancel. Deferred operations can be cancelled in the panel
  or menu; an interruption acknowledgement is not completion.

## Projects

A project is a working folder. Both session browsers group visible sessions
under a header with a folder glyph, the folder's name (full path on hover) and
its row count, keeping stable order for groups and rows. A draft without its
own folder belongs to the default folder. Search, Archived, archive and
indicators are unchanged; a group shows only while it has visible rows, so a
folder whose sessions are all archived leaves the default list.

- Each project header's **+** starts a draft there. **New project** (the
  sessions title row in the notch; beside **+** in the full-session sidebar)
  picks a folder and starts its first draft.
- There is no project store: a project exists while it has visible sessions.
  Moving a draft to another folder moves it to that project.
- The global **+** uses the default folder. OpenClaw drafts group under their
  agent's workspace.

## Agent questions and delivered files

- **Blocking questions** (Hermes `clarify`, Claude Code `AskUserQuestion`,
  Codex `requestUserInput`, Pi `notch_ask_user`/extension dialogs, OpenCode
  questions/forms, Antigravity `ask_question`) use the card that replaces the
  composer. A native question header joins the runtime name in the title; option
  descriptions sit under their options. Pi's written-answer choice opens an input
  dialog in the same card. OpenCode replies keep native option values and
  multiple selections. Antigravity questions offer one choice from their options
  and no written answer.
- **Non-blocking questions** (Codex `request_user_input_async`) arrive with the
  answer that asked them and do not hold the turn. They render as a card under
  that message (options plus an always-allowed written answer). Reply sends one
  ordinary message (one answer alone; several as question/answer pairs) without
  touching the composer's draft or files, and waits while the session works or a
  send is unconfirmed. The card stays answerable while the agent writes or runs
  more in that turn, and its turn's work stays unfolded while it is open; once
  a later message of yours follows, it is read-only. A delegation result, a
  delegated question or a message from another session does not close it. The
  composer and Stop stay available. Question-only messages survive restart with
  their card.
- **Approvals** describe a Claude Code tool in its own terms (command and
  description, file, URL, search, or plan); other tools show readable JSON.
- **Delivered files.** `MEDIA:/absolute/path` (also quoted, emphasized,
  home-relative or with spaces, resolved against disk) and Markdown images of
  local files leave the text and appear below it: images as off-main-thread
  previews (at most 220 points tall, click to open), other files as cards with
  Open and Show in Finder, or “File not found.” Examples in code blocks stay
  text. Remote images become links; the transcript never loads remote content.
  Codex-generated images appear the same way. Links to local files, including
  Codex `path:line` and session-relative paths, open the file.

## Composer model controls

The composer is **one field in every design**: attachments and the editor on
top, and one bar along its bottom edge holding every control:
`[+] [SnapShot] [harness (drafts) · folder · session (secondary pages)] …
[model] [permission mode] [context gauge] [Send/Stop]`. Nothing sits in a row
above or under the field, so a tall draft, a queue or a banner can never push a
control out of view. Session settings (model with reasoning effort, permission
mode, context gauge) are plain secondary-color buttons in the bar's trailing
group, shown on the session page (compact) or always (full window). Each is
optional (model and context on by default, permission modes off). A draft's
harness chooser stays in the bar. A started session keeps a plain harness label
in Refined and Instrument, whose placeholder hides behind a draft or the busy
hint; Tahoe drops it (the placeholder “Ask Codex…” and the editor's spoken label
name the harness), and Legacy Hermes keeps its label everywhere. When the bar is
tight the model label truncates first, down to about a dozen characters, then
the session name, then the harness label, **Continue in Hermes…** and the folder
chip share what is left, truncating rather than pushing the field past the
panel's margins; the gauge, permission mode and Send keep their size.

The model label shows the runtime's display name for the selected, reported or
default model (the ID only when unnamed; **Runtime default** when none is
known), no “Next:” prefix, then the effort when the model has efforts (`xhigh`
reads **Extra high**), no chevron. It truncates within the bar.

The model picker is a bounded overlay rising from the bar with an inset **Search
models…** field, refresh and Close. Search filters by name or ID without
changing selection. Choosing a model with efforts keeps the picker open for
**Reasoning effort**; the section is omitted when unsupported. No footer hints.
Loading, errors and empty results stay visible. Choices apply on Send and are
disabled during parent/child work or unresolved sends. Changing session or
runtime, or collapsing, dismisses it. Model, permission and context overlays
open upward from the bar's trailing group, above the field's edge and the
editor. The context gauge stays as it is (a ring, Instrument's
segment meter). Its bubble has a fixed 264-point width, so it never jumps
between states: a **Context** section label with Close, the percentage
(unclamped, `≈` for estimates) with `42k / 200k` at the right and a
[usage bar](#usage); a report without a window heads with what is known
(`42k used`) and has no bar, and `—` stands only before the first report. A
caption follows (**Estimate**, **Window not
reported**, **Over the reported window**, then **Updated** and the report time;
**No report yet** before the first report). Hover, accessibility and dismissal
are unchanged. Opening one chooser closes the other; neither shifts the
composer or transcript.

Clicking outside the runtime picker, model picker or context bubble dismisses
it in both surfaces, including clicks in another window or app, and the click
still reaches its target. Inside clicks act normally: choosing a runtime closes
its picker; model search, selection and effort keep theirs open. Triggers
toggle on click. Closing removes the click monitoring.

## Permission modes

An optional control (icon and mode name) in the composer's bar, between the model
and the context gauge, sets how much the agent may do unasked in this conversation: **Default
permissions** (the harness's own settings), **Ask**, **Auto-edit**, **Plan**,
**Full access**. Off by default behind **Show permission modes**; shown only
for harnesses that map at least one mode, listing only those
([runtime mappings](backend-runtime.md#permission-modes)).

- The chooser is a bounded overlay like the model picker, one row per mode with
  a short description and a checkmark. Opening it closes the model picker and
  context bubble; outside clicks, a session change, the session getting busy
  or collapse dismiss it.
- The choice is saved with the conversation and applies to the next message.
  It is disabled while the session, a child or an unresolved send is busy.
  Default permissions removes the override.
- **Full access** asks for confirmation the first time in a session. While on,
  an amber shield sits beside the session title in the notch header and
  full-session window, whether or not the control is shown; the control's label
  is amber too.
- Approval cards are unchanged; a mode only changes how often they appear.

## Usage

**Show usage** (off by default) adds a chart button to the Your sessions title
row, opening **Usage**, a scrolling page within the panel bounds; Back returns.

- **Account limits**: each set-up harness that reports limits (Codex, Claude
  Code), headed by **Updated** and the report time (the date instead when not
  today). One row per window, shortest window first, a plain window before its
  per-model or per-bucket variants, **Extra usage** last. A row is the window
  name with the percentage used (or **Limit reached** in amber) at the right, a
  bar, and the reset: **Resets in 1 h 40 min** within a day, then weekday and
  time, a date beyond six days, all in one time style. Usage and context
  dates use the app's language with the system region and 12- or 24-hour
  clock (`Locale.app`), so an English interface never shows German weekdays.
  A reset already past reads **Reset since last report** and shows the window
  as unknown. Opening or refreshing asks Codex again; Claude Code reports only
  during a turn. Errors show under their harness.
- **Bars** fill with the share used and take the warning color (amber; the
  signal in Instrument) when reached or from 90 %. Unknown is a dim track with
  no fill and `—`, never 0 %. Refined draws a thin capsule, Tahoe an
  accent-colored capsule, Instrument a segment meter across the width.
- **Sessions started here**: tokens per day and harness for messages sent from
  the companion, newest first (30 rows). An unreported day shows `—`; a partly
  reported day adds “N unreported”.
- **In a session** (with Show usage and **Show context usage** on), the context
  bubble adds a **<Harness> usage** section below the context for a harness that
  reports limits: Updated time (Instrument's rule label shows the bare time)
  and a refresh button in its header, then the
  same rows as the page. Past four windows the rows scroll inside the bubble.
  Opening it asks Codex again; Claude Code's rows come from its last turn.

## SnapShot

**Show SnapShot** (off by default) adds a camera button beside the notch
composer's attach button for harnesses that accept images. It attaches a
picture of the window that was in front when the notch opened and never sends
by itself, like [file eating](#file-eating).

- **Which window.** As the panel opens, before it can take focus, record the
  frontmost app and its frontmost normal on-screen window (layer 0, at least
  40 points). The companion's own windows never qualify; if the companion is
  frontmost, the button is disabled. Its help names the window. The
  full-session window has no button.
- **Capture.** ScreenCaptureKit captures that window at pixel scale without the
  cursor. First use asks for Screen Recording permission; while missing, a hint
  above the composer links to that System Settings pane. No other route.
- **Staging.** The PNG, named after app and window title, goes in the private
  `SnapShots` folder beside the session registry and is staged with the eat
  animation as an ordinary attachment. Removing it before sending deletes the
  file; a sent picture stays for the agent.

## Delegation

An agent can hand a task to another harness set up here
([runtime contract](backend-runtime.md#delegation)). The child is a companion
session inside its parent; notch silhouette and bounds are unchanged.

- **Team.** The parent's Team button and summary count native and app-owned
  children together. An app-owned row shows a branch icon and harness and role
  under its title (“Codex · review”); selecting it opens the child's
  conversation, where the user may reply. A native row opens its activity. The
  full-session Team tab adds **Open conversation** to app-owned rows.
- **Child conversation.** A back chevron, “Back to the parent session”, returns
  to the parent's team. The child's composer, approvals and questions work as in
  any session; only the user grants a child's approvals.
- **Ownership.** Children never appear in Your sessions, its search or
  filters, the glance, live activity or dots. Their state reaches the notch
  through the parent: a working child keeps it Working; a child's question or
  approval makes it need you and is announced under the child, opening to that
  card. A child's finish or failure is not announced; its result wakes the
  parent.
- **Agent messages.** Messages the companion sends for an agent show a branch
  icon and a label instead of “You”, rendered as Markdown: **Delegated
  question** (relayed to the parent) and **From another session**
  (`notch_session_send`). A wake is one compact activity row,
  `Delegated task "Title" finished` (or `failed`), that opens the child.
- **Sessions an agent creates.** `create_sessions` adds ordinary sessions in the
  caller's project that list, search and notify normally.
- **Tools.** Companion tools read the same under any harness prefix
  (`mcp__notch__`, `notch.`, OpenCode's per-session `notch-<16 hex>_`, Codex's
  bare name): “Delegate / Delegating /
  Delegated a child task”, “Get / Getting / Got delegated task status”, and so
  on. While a turn waits on a delegation `wait`, the header's status dot reads
  **Waiting on a child** (tooltip and spoken title).
- **Settings.** **Cross-agent delegation** (default on) lets sessions of every
  harness (OpenCode from 2.0) opened afterwards delegate.
- **Delete.** Deleting a parent removes its children from the companion; native
  histories stay.
- **Changes.** The delegating parent turn folds each child's changed files into
  its summary once the child's turn settles: a branch-icon heading in the accent
  colour, “Title · Harness” (“· worktree” for an isolated child) with line
  counts, then file rows that open diffs and files as usual (a worktree child's
  in its worktree). The collapsed row counts parent and children together. A
  file a shared child made is listed once, under the child. Without a parent
  snapshot the turn shows a card for its children alone. The footer adds “Files
  under a delegated child are its own edits.” Fixture: `changes-delegated`.
