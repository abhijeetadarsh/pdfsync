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
It needs Docker with the Compose plugin and curl. HTTPS comes from your own
reverse proxy (e.g. Caddy); the script only runs the server.

```sh
scp deploy/deploy.sh user@vm:~/   # from a machine with the repo
ssh user@vm
./deploy.sh --port 9000           # server on 127.0.0.1:9000 (for Caddy on the host)
./deploy.sh                       # later: pull the newest image and restart, same settings
```

Options (remembered in `~/pdfsync/.env`):
- `--port N`: host port to expose the server on (default 8080).
- `--listen ADDR`: `127.0.0.1` (default; only the VM itself can reach it) or
  `0.0.0.0` (reachable directly over plain HTTP).
- `--network NAME`: also join an existing Docker network, so a Caddy
  *container* on it reaches the server as `pdfsync:8080`. `--network none` leaves
  the network again.
- `--tag 1.0.0`, `--max-upload-mb N`, `--dir PATH`.

Caddyfile:
```
sync.example.com {
  reverse_proxy 127.0.0.1:9000   # Caddy on the host
  # reverse_proxy pdfsync:8080   # Caddy in a container on --network
}
```

What the script also does:
- On the first pull, logs in to ghcr.io with a token that has the
  `read:packages` scope. It asks for the token, or reads `GHCR_TOKEN`.
- Replaces a container named `pdfsync` that was started by hand with
  `docker run`.
- Waits until `/healthz` answers.
- Runs the server unprivileged: as the fixed non-root user 65532, with all
  Linux capabilities dropped, `no-new-privileges`, and a read-only root
  filesystem (it writes only to the `/data` volume and an in-memory `/tmp`).
  The script itself runs no root containers. If an old volume is owned by root,
  it prints the one `sudo chown` command to fix it instead of fixing it itself.

The image is a multi-platform image (linux/amd64 and linux/arm64), so Docker
pulls the variant that matches the VM. 32-bit ARM is not built. Data is in the
Docker volume `pdfsync-data` and survives updates. Logs:
`cd ~/pdfsync && docker compose logs -f`.

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
