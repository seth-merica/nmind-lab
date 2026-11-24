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

## Native iPhone app (ios/)

A SwiftUI version of Nmind that tracks your face with ARKit on the Face ID (TrueDepth) camera. It has the same calm reading, the same tense versus mellow verdict and the same seven-family void as the web prototype. It is a prototype and is not on the App Store.

**What the native app gains**

- Tracking in the dark. The Face ID camera projects its own infrared dots, so face, eye and expression tracking keep working with the lights off.
- Steadier eye direction from ARKit's eye transforms and look-at point.
- More precise expression scores: all 52 of ARKit's face scores (blinks, squint, wide eyes, brow, jaw, mouth) from a depth map instead of a flat picture.
- Breathing from head motion measured in millimeters.

**What it still can't do**

- Pupil size. iOS does not give apps the raw infrared image, only the finished face model, so pupils can't be measured here either.
- The pulse still comes from skin color on the front color camera. It is a hint and needs light on your face.

Everything runs on the phone. No frames, images or numbers are saved or sent.

### Install on your iPhone from a Mac (free Apple ID)

You need: a Mac on macOS Sequoia 15.6 or newer (an M1 MacBook is fine), Xcode 26 or newer from the Mac App Store, a USB-C cable, and your Apple ID. A free Apple ID is enough. Apps installed this way stop opening after 7 days; plug in and press Run again to renew.

1. Install Xcode from the Mac App Store. Open it once, accept the terms, and let it install the iOS components when it asks.
2. In Xcode, open Xcode menu > Settings > Accounts, click +, choose Apple Account, and sign in.
3. Open Terminal and paste:

   ```
   cd ~/Documents
   git clone https://github.com/seth-merica/nmind-lab.git
   open nmind-lab/ios/Nmind.xcodeproj
   ```

   If the Mac offers to install command line developer tools, click Install, then paste the lines again.
4. In Xcode's left sidebar, click the blue Nmind project icon. Under Targets, click Nmind, then the Signing & Capabilities tab. Tick Automatically manage signing and set Team to your name (Personal Team).
   If Xcode shows a red error about the bundle identifier, change Bundle Identifier to something unique, for example `lab.nmind.seth`.
5. Plug the iPhone into the Mac. Unlock it, tap Trust, and enter your passcode.
6. Turn on Developer Mode on the iPhone: Settings > Privacy & Security > Developer Mode (near the bottom) > switch it on > Restart. After the restart, tap Turn On and enter your passcode.
7. In Xcode's top bar, open the device menu next to Nmind and pick your iPhone. Press the Run button (the triangle) or Command-R. The first time, Xcode spends a few minutes preparing the phone. If the Mac asks for your login password for the keychain, enter it and click Always Allow.
8. The first launch is blocked as an untrusted developer. On the iPhone: Settings > General > VPN & Device Management > under Developer App, tap your Apple ID > Trust > Trust.
9. Open Nmind on the iPhone and allow the camera.

To get updates later, paste in Terminal:

```
cd ~/Documents/nmind-lab && git pull
```

then press Run in Xcode again. The version shows under the Nmind title on the phone, so you can check the new build is on it.

Updates leave the Xcode project file alone, because that file holds your Team and Bundle Identifier. If `git pull` ever says your local changes would be overwritten, run

```
cd ~/Documents/nmind-lab && git checkout -- ios/Nmind.xcodeproj && git pull
```

then set Team and Bundle Identifier again (step 4) and press Run.

The paid Apple Developer Program ($99 a year) removes the 7-day limit and allows TestFlight installs without a cable. It isn't needed to try the prototype.

### Build check

`.github/workflows/ios-build.yml` compiles the app unsigned on a GitHub Mac runner on every change to `ios/`. It uses no signing and no Apple account.
