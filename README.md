# Nmind Lab

Camera prototype for Nmind. It uses the phone's front camera to find the reader's face and eyes, then drives the geometry from what it sees:

- Face present or not, and whether the reader is looking at the screen
- A second face pauses the session
- Blink rate
- A rough gaze point after a five-point calibration

Everything runs on the device with MediaPipe Face Landmarker (bundled in `lib/` and `models/`). No video, images or data are saved, uploaded or tracked.

State changes fade smoothly. Nothing flashes, which keeps the page within the three-flashes-per-second safety limit.

Open the GitHub Pages link in Safari on iPhone, tap Start camera and allow the camera.
