# Android device testing (via adb)

All testing is done from the PC; nobody taps the devices by hand.

## Devices
| Serial | Device | Screen (px) | Density |
|---|---|---|---|
| `adea1d8a` | Phone, CPH2661 (ColorOS), Android | 1240×2772 | 560 |
| `HA2891X3` | Tablet, XT2571-1, Android 16 | 1840×2944 | 340 |

## Setup
```bash
cd client
JAVA_HOME=/usr/lib/jvm/java-17-openjdk /home/a8/develop/flutter-stable/bin/flutter build apk --debug
for d in HA2891X3 adea1d8a; do
  adb -s $d install -r build/app/outputs/flutter-apk/app-debug.apk
  adb -s $d reverse tcp:8080 tcp:8080
done
```
- The phone (ColorOS) blocks `adb install` until "Continue installation" is
  tapped on screen. Take a screenshot and tap it with `adb shell input tap`
  (portrait ≈ 622,2354).
- Sign in with server `http://localhost:8080` (works through `adb reverse`).

## Driving the UI
- Screenshot: `adb -s <serial> exec-out screencap -p > shot.png`
- Tap / drag / type: `adb shell input tap X Y`, `input swipe X1 Y1 X2 Y2 ms`,
  `input text 'a%sb'` (`%s` = space), `input keyevent 111` (hide keyboard).
- Rotation: `adb shell settings put system accelerometer_rotation 0` then
  `adb shell wm user-rotation lock 0|1` (0 = portrait, 1 = landscape).
  Both devices normally have auto-rotate **on** – restore it afterwards with
  `settings put system accelerometer_rotation 1` / `wm user-rotation free`.

## Limits
- `adb input` cannot do multi-touch, so two-finger pan/zoom while a drawing
  tool is active has to be checked by hand or with an instrumentation test.
