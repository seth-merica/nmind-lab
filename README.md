# Nmind

Calm focus prototype (v6). It reads your eyes, face and pulse with the phone's front camera and turns a soft, mellow calm into travel deeper into a geometric void. Calm held with effort keeps you where you are.

## Install on iPhone

Open https://seth-merica.github.io/nmind-lab/?v=6 in Safari, tap Share, then Add to Home Screen. It opens full screen as Nmind and works offline after the first visit.

## The void

- Seven shape families unlock as you travel: rosettes, seed of life, nested polygons, spirals, lattices, lotus, and fractal recursion.
- Each layer drifts toward you and passes by, so deeper calm feels like a slow zoom inward. Every level has its own color world.
- Focus makes the current layer sharper, more vibrant and more intricate. Only mellow calm moves you deeper. Tense calm stalls travel; restlessness slowly pulls you back.

## What it reads

| Signal | From | Calm reads as |
| --- | --- | --- |
| Steady gaze, eye jumps | iris position, saccade rate | few jumps |
| Head stillness | face position | still |
| Blink rate, blink length | eyelid landmarks and blink scores | 5 to 22 per minute, slow blinks |
| Eyelids | lid gap versus your own resting gap | soft, not squinted or wide |
| Brow, jaw and mouth | face expression scores | relaxed |
| Heart rate | skin color on forehead and cheeks (camera pulse) | slowing, at or below your baseline |
| Heart variability | beat-to-beat timing from the same pulse | rising |
| Breathing | slow head rise and fall | slow, under about 10 per minute |

The first 20 seconds learn your resting face. Each signal carries a confidence and drops out when light or motion makes it unreliable. Camera view shows every signal, its confidence and the verdict.

Pulse, variability and breathing need bright, even light and a still head. Pupil size is not readable from the front camera in normal light; a native iPhone app could read it with the infrared Face ID camera later.

## Tense calm versus mellow calm

- **Tense calm:** steady gaze held with effort, squint or brow tension, suppressed blinks, higher heart rate, low variability. The shapes stay sharp, travel stalls and the app cues release.
- **Mellow calm:** soft lids, a natural slow blink rhythm, relaxed brow and jaw, slowing heart and breath. Only this opens deeper layers.

## Gaze ring

Optional nine-point calibration lets your eyes steer a ring. Front-camera gaze is approximate: expect a thumb-width area on a phone.

## Privacy and safety

Everything runs on the device with MediaPipe Face Landmarker (bundled in `lib/` and `models/`). No video, images or data are saved, uploaded or tracked.

All visual changes fade over a second or more. Nothing flashes, which keeps the page within the three-flashes-per-second safety limit.

This is a prototype, not a medical or wellness device.
