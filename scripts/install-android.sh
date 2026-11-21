#!/usr/bin/env bash
# Install the APK on every connected device without touching them.
# ColorOS/OxygenOS phones block `adb install` behind a "Continue installation"
# screen; this script finds that button with uiautomator and taps it.
set -u
# Default: the profile build (release speed; the debug build is far too slow
# to judge smoothness). Pass another APK path to install that instead.
APK=${1:-"$(dirname "$0")/../client/build/app/outputs/flutter-apk/app-profile.apk"}
PKG=io.pdfsync.pdfsync
tap_prompt() { # serial
  local d=$1
  for _ in $(seq 1 30); do
    if adb -s "$d" shell dumpsys window | grep -m1 mCurrentFocus | grep -qiE "install"; then
      sleep 1
      adb -s "$d" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
      local b
      b=$(adb -s "$d" exec-out cat /sdcard/ui.xml | grep -oE 'text="(Continue installation|Install|Continue)"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 | grep -oE '[0-9]+' | tail -4)
      if [ -n "$b" ]; then
        set -- $b
        adb -s "$d" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
        return 0
      fi
    fi
    sleep 1
  done
}
for d in $(adb devices | awk 'NR>1 && $2=="device" {print $1}'); do
  adb -s "$d" install -r "$APK" > "/tmp/pdfsync-install-$d.log" 2>&1 &
  pid=$!
  tap_prompt "$d" &
  wait $pid && echo "$d: $(tail -1 "/tmp/pdfsync-install-$d.log")"
  adb -s "$d" reverse tcp:8080 tcp:8080 >/dev/null
  adb -s "$d" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
done
