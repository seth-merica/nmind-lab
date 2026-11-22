# Nmind Lab

Camera prototype for Nmind. It uses the phone's front camera to read the reader's face and eyes, and turns calm, steady focus into something you can see.

## Focus mode (default)

- A focus score builds from how steady your eyes are, how still your head is, how much you stay on the screen, and a calm blink rhythm.
- As focus rises, the gaze ring tightens and steadies, and the geometry grows, gains layers and locks into symmetry.
- As focus drops, the ring widens and the shapes loosen, drift and scatter.

## Gaze ring

- Nine-point calibration, then a short pass where you keep your eyes on the dot and move your head, so the fit learns to cancel head motion.
- Uses iris position between the eye corners, eye-direction scores and head pose, combined with a ridge-regression fit.
- Smoothed with a median filter and a One Euro filter. Higher focus means heavier smoothing.
- Tap anywhere you are looking to fine-tune, or use Re-center while looking at the middle.

Front-camera gaze is approximate: expect a thumb-width area on a phone, not a single word.

## Read mode

Shows short concepts with the shapes. Holding attention for 12 seconds moves to the next one.

## Privacy and safety

Everything runs on the device with MediaPipe Face Landmarker (bundled in `lib/` and `models/`). No video, images or data are saved, uploaded or tracked. Calibration lives in memory and is gone when you close the page.

All visual changes fade over a second or more. Nothing flashes, which keeps the page within the three-flashes-per-second safety limit.

Open the GitHub Pages link in Safari on iPhone, tap Start camera and allow the camera.
