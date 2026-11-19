# PDF Sync – working rules

## Rules
- **Document everything you do in `docs/`.** Every work session adds or updates a
  dated log entry in `docs/worklog.md` (what was tested, what broke, what was
  changed and why, what is still open). Larger topics (testing setup, design
  decisions) get their own file in `docs/` and are linked from the log.
- **Drive the devices yourself.** The user will not tap anything on the phone or
  tablet. Install, launch, sign in, accept on-device prompts (e.g. ColorOS
  "Continue installation") and test entirely via `adb` (input tap/swipe/text,
  screencap). See `docs/android-testing.md`.
- Test UI changes on both the phone and the tablet, in portrait and landscape.

## Layout
- `server/` – Go sync server (SQLite). `go test ./...`
- `client/` – Flutter app (Android, iOS, desktop, web).

## Build / run (this machine)
- Flutter: use `/home/a8/develop/flutter-stable/bin/flutter` (3.50). The default
  `flutter` on PATH (3.44, locally patched) is too old for this project.
- Android builds need JDK 17: `JAVA_HOME=/usr/lib/jvm/java-17-openjdk`.
- Server: `cd server && go run . -addr :8080 -data ./data`
- Devices reach the server via `adb reverse tcp:8080 tcp:8080` → `http://localhost:8080`.
