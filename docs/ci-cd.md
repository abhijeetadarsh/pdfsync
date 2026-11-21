# CI/CD

`.github/workflows/release.yml` runs on **every push to `main`** and only there.
Pull requests and other branches do not trigger it.

| Job | What it does |
|---|---|
| `checks` | `go vet` and `go test` for the server; `flutter analyze` and `flutter test` for the client (the sync integration test runs against a freshly built server). Every other job waits for it. |
| `server` | Builds `server/Dockerfile` for linux/amd64 and arm64 and pushes `ghcr.io/<owner>/pdfsync-server` with the tags `latest`, `<pubspec version>` and `sha-<commit>`. |
| `android` | Builds a release APK signed with the release key from repo secrets. |
| `linux` | `flutter build linux` and packs the bundle as `.tar.gz`. |
| `windows` | `flutter build windows` and packs the bundle as `.zip`. |
| `release` | Creates the GitHub Release `v<version>-build.<run number>` with the APK, Linux and Windows files. |

The version comes from `client/pubspec.yaml` (`version: 1.0.0+1`; the build
number is replaced by the workflow run number). Bump the version there for a new
release line.

## Deploying the server on a VM
`deploy/deploy.sh` is a single self-contained script that runs on the VM.
It needs Docker with the Compose plugin and curl.

```sh
scp deploy/deploy.sh user@vm:~/      # from a machine with the repo
ssh user@vm
./deploy.sh                           # HTTP on :8080
./deploy.sh --domain sync.example.com # or: HTTPS via Caddy (DNS must point at the VM, ports 80/443 open)
./deploy.sh                           # later: pull the newest image and restart, same settings
```

What the script does:
- Writes `~/pdfsync/docker-compose.yml` and `~/pdfsync/.env`. The settings are
  remembered, so later runs need no options.
- On the first pull, logs in to ghcr.io with a GitHub token that has the
  `read:packages` scope. It asks for the token, or reads `GHCR_TOKEN`, because
  the image is private.
- With `--domain`, starts Caddy as an HTTPS reverse proxy with an automatic
  certificate, and binds the server's port 8080 to localhost only.
  `--domain none` switches back to plain HTTP.
- Removes containers named `pdfsync`/`caddy` that were started by hand with
  `docker run`; they would block the ports. Data is kept.
- Waits until `/healthz` answers and prints the server URL to use in the apps.

Data is in the Docker volume `pdfsync-data`, the same name as a manual
`docker run -v pdfsync-data:/data`, so it survives updates and switching to
the script. Other options: `--tag 1.0.0` (pin a version), `--max-upload-mb N`,
`--dir PATH`. Logs: `cd ~/pdfsync && docker compose logs -f`.

## Android signing
The release keystore was generated on 2026-11-21 and lives **outside the repo**
in `~/.config/pdfsync-release/` (`release.jks` and `key.properties` with the
passwords). Back it up somewhere safe: if it is lost, users will have to
uninstall the app before a newly signed APK installs. CI gets the keystore from these repo
secrets:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` |
| `ANDROID_KEY_ALIAS` | `pdfsync` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` |

`client/android/app/build.gradle.kts` signs release builds with
`android/key.properties` when it exists (ignored by git) and otherwise with the
debug key, so local `flutter run --release` keeps working. Don't keep
`key.properties` in place locally: the profile builds installed on the test
devices are debug-signed, and Android refuses to update an app whose signature
changed.

Release builds skip Android's `lintVital` tasks: lint crashes on the
`url_launcher_android` plugin and failed the build (see `android/build.gradle.kts`).

## Known limits
- The release APK only allows HTTPS: cleartext HTTP is allowed only in debug and
  profile builds. Put the server behind HTTPS (reverse proxy) for phones running
  the release APK.
- The Windows build is only built by CI; it has never been run or tested on Windows.
