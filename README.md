# Nmind

Focus training prototype. It reads your eyes with the phone's front camera. Hold the ring on the center with your eyes alone and the geometry grows richer, more detailed and more luminous. Let it drift and the shapes loosen and dim.

## Install on iPhone

Open the page in Safari, tap Share, then Add to Home Screen. It opens full screen as Nmind and works offline after the first visit.

## Focus mode (default)

- Focus builds mainly from holding the ring on the center target, plus steady eyes, a still head, staying on screen and a calm blink rhythm.
- As focus rises, the ring tightens, and the geometry grows, gains layers, petals and fine detail, and shifts from deep purple to teal to luminous.
- As focus drops, the ring widens and the shapes loosen, dim and scatter.

## Gaze ring

- Nine-point calibration, then a short pass where you keep your eyes on the dot and move your head, so the fit learns to cancel head motion.
- The eyes drive the ring: iris position inside each eye (between the corners), plus eye-direction scores. Head pose is used only to correct for head turns.
- Camera view shows a live readout of the raw iris offset, so you can see it move when only your eyes move.
- Smoothed with a median filter and a One Euro filter. Higher focus means heavier smoothing.
- Tap anywhere you are looking to fine-tune, or use Re-center while looking at the middle.

Front-camera gaze is approximate: expect a thumb-width area on a phone, not a single word.

## Read mode

Shows short concepts with the shapes. Holding attention for 12 seconds moves to the next one.

## Privacy and safety

Everything runs on the device with MediaPipe Face Landmarker (bundled in `lib/` and `models/`). No video, images or data are saved, uploaded or tracked. Calibration lives in memory and is gone when you close the page.

All visual changes fade over a second or more. Nothing flashes, which keeps the page within the three-flashes-per-second safety limit.

Open the GitHub Pages link in Safari on iPhone, tap Start camera and allow the camera.
