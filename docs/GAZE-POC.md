# Gaze-to-window experiment

This lives on `codex/gaze-window-poc`. It is a feasibility experiment, not a
production gaze tracker. No webcam accuracy has been established by the internal
synthetic tests. Personal calibration and independent validation are required.

## Run it

`./build-gaze-poc.sh -r` builds a release executable, signs a separate
`Zonas Gaze POC.app` with a real identity, installs it, stops the running Zonas
instance (the two share hotkeys), and opens the POC. `-i` installs without opening.
The stable `/Applications/Zonas.app` is untouched. The POC uses bundle identifier
`uy.com.fcstudio.zonas.gaze-poc`, so camera consent and runtime preferences are
separate. Both read the existing layout file; this feature does not edit it.

The controls open on the built-in screen, with capture off. The menu also has
**Window Switcher (⌥Tab) → Gaze Experiment (POC)…** and **Stop Gaze Experiment**.
If opening the installed POC directly from Applications, quit stable Zonas
first: both variants register the same shortcuts. Quit the POC before reopening
stable. The build script does the first handover when launched with `-r`.

1. Choose a camera facing you, ideally close to the display you want to use.
   A laptop camera off to the side was insufficient in the first hands-on try;
   a webcam near the centre of the target monitor is the next setup to measure.
2. Start the camera and grant camera access. Accessibility is separately needed
   for the normal window switcher; grant it to the POC through the existing menu.
3. Choose the test display, then **Calibrate + test**. Look at each dot with your
   normal posture. Nine training targets and six unseen validation targets take
   about 40 seconds; dropped pupil observations can make this longer. Esc cancels.
4. Read the result. A failed test keeps hints disabled. A pass requires at least
   5/6 broad regions correct, 80% prediction coverage, median normalized error
   at most 10% and P90 at most 18%. These are provisional POC gates, not accuracy
   claims. The result reports the measured error in display points as well.
   The calibration overlay shows usable pupil samples and the current camera
   observation at every point. The target remains white until the collection
   requirements are met; elapsed time alone does not turn it green. Each point
   still requires 18 distinct usable samples and stops after seven seconds if
   there are too few. The controls return with the point, sample count and
   camera reason. A green calibration target is not a validated gaze estimate.
5. Watch the live map first. Orange is the current estimate; the mint cross is
   a stable fixation. The dashed rectangle is the independently measured error
   margin, not a live confidence score. A mint window outline is a candidate.
   The headline explains missing eyes, changed posture, moving gaze, stale
   frames, borders, desktop and covered or ineligible windows. Camera status
   includes the delivered frame rate; the progress bar shows fixation dwell.
   **Show gaze on screen** enables a click-through diagnostic dot, error box,
   candidate outline and status badge on the calibrated display. It never
   activates a window. A failed test can still display a diagnostic estimate,
   but cannot suggest a window.
6. Close the controls, look at a large visible window for at least 0.3 seconds,
   then hold ⌥Tab. A small mint dot marks a candidate. Tab, Shift+Tab, pointer and
   clicks choose exactly as before; gaze does not change the selected preview or
   the window receiving focus. A fast tap retains the normal switcher behavior.
   The exact opening decision is frozen while the carousel is visible. Reopen
   the controls from the Zonas menu to read **Last ⌥Tab**, including why no mark
   appeared. The live monitor resumes when the carousel closes. The controls
   themselves really cover windows and therefore block candidates underneath.
7. Use **Test again** after a while or after moving. A failed retest disables
   previously successful hints. Use **Stop** to turn capture off and discard
   calibration. Closing the controls deliberately keeps capture running.

To return to stable, quit the POC and open `/Applications/Zonas.app`. The POC
does not enable a login item. Its defaults and calibration are off after a restart.

## What is running

AVFoundation captures unmirrored 1280×720 frames when available. Apple Vision's
local face-landmark model detects both pupil locations and eye outlines, at most
15 frame analyses per second. Face rectangle revision 3 supplies all three head
angles; its same-frame observation is passed to the landmarks request. The
implicit landmarks detector left pitch unavailable in a real trial, so required
angles are requested explicitly instead of replaced with zero. Eye coordinates
are normalized along each eye's axis;
yaw, pitch, roll and face geometry join them in a small personal ridge-regression
model mapping to one display's normalized coordinates. This baseline uses no
downloaded weights or external inference service. It does not treat head pose
alone as eye gaze: absent pupils, closed eyes, multiple faces and small faces
produce no estimate.

Calibration excludes the first 0.9 seconds at each dot, waits at least 2.6
seconds, requires 18 valid distinct frames, caps the buffer, and aborts after
7 seconds without enough samples. Each target has equal fitting weight.
Validation uses new spatial targets, not adjacent frames from training dots.
Out-of-domain predictions count as failures rather than disappearing from the
score. The uncertainty box uses independent P90 errors with a 2.5% floor per axis.

The estimator requires a stable, recent fixation. The opening key press takes a
single snapshot of the pre-carousel gaze; looking at carousel icons cannot
redirect it. Mapping uses CoreGraphics global coordinates, the selected display's
full frame, and the visible windows' front-to-back order, including non-switcher
dialogs as blockers. It abstains around borders, empty desktop, occlusions,
off-screen points and hidden/minimized windows. Display reconfiguration, sleep,
capture interruption and a four-second frame outage stop and invalidate capture.
Changes of seating outside the calibration's feature range abstain too, but
subtle camera movement can still require a manual retest.

The live monitor draws at most ten times per second while visible or while its
explicit screen marker is on. WindowServer geometry refreshes on a utility
queue at most once per 0.35 seconds, with one request in flight. Eligibility
uses the switcher's existing cached Accessibility metadata joined by window
number and PID; the monitor makes no Accessibility queries. Geometry older than
one second cannot produce a live candidate. The opening shortcut uses fresh
geometry and the actual switcher entry set. Only the diagnostic marker's own
window number and PID are ignored as occluders. Calibration and the carousel
pause the live geometry reader; closing controls with the marker off stops it.

Raw frames are never saved. Frames, pupil features and calibration stay in memory.
The log records camera state transitions, per-target sample counts, cancellation
or timeout reasons, validation aggregates and candidate window numbers, not
frames or continuous gaze coordinates. There are no new Accessibility writes.

## Internal verification and the human experiment

The current suite passes 406 tests, including 25 gaze tests and a 20-seed noisy
sensor/head-motion stress case. `swift test` exercises fitting, held-out success/failure, leakage, head-only
rejection, sample timing, loss of camera/eyes, timestamp ordering, jitter,
camera-position changes, dropped-frame imbalance, validation coverage, boundary
abstention, negative display origins, vertical coordinates and overlapping or
unlisted blocking windows. Existing switcher tests continue to run.

`zonas gaze-diagnostics /tmp/zonas-gaze-ui` draws controls and a calibration target
off-screen, including synthetic accepted and uncertain live-map fixtures in
light and dark appearance, and enumerates cameras without opening capture. Native off-screen
AppKit control snapshots can omit composited control surfaces; inspect the real
signed application's window for final visual QA. Synthetic data establishes the
decision logic, not a person's gaze accuracy.

A front-facing MacBook trial on 2026-10-07 passed the independent personal
test: 6/6 regions, 97% prediction coverage, 5.4% median error and 9.9% P90.
The measured error box was ±92×105 display points. Subsequent real window trials
were confusing without live feedback; that pass does not establish window
selection accuracy. The monitor exists to make those trials understandable.

For an actual go/no-go, try 20 fresh window trials after calibration: several
window arrangements, left/centre/right on the ultrawide, some large and some
small, two overlapping windows, normal glasses/light and a posture change. Record
correct mark / wrong mark / no mark, plus latency and CPU. A wrong mark is more
costly than abstention. Until that experiment succeeds, keep this advisory-only.
Looking at a fully covered window cannot identify its content from the screen;
the POC only proposes visible windows.

The POC is intentionally not a GitHub release. The existing release script's
zero-entitlement guard rejects this camera-enabled branch. Any eventual merge
must review that policy to allow only the camera entitlement while continuing to
reject debug entitlements, and must complete signed-app camera/TCC testing.

References: [Apple pupil landmarks](https://developer.apple.com/documentation/vision/vnfacelandmarks2d/rightpupil)
and [camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera).
