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
Use `deploy/docker-compose.yml` with plain Docker Compose; there is no script.
Data goes into `./data` next to the compose file (e.g. `~/pdfsync/data`).

```sh
mkdir -p ~/pdfsync/data            # create it yourself first, so you own it
cp docker-compose.yml ~/pdfsync/
docker login ghcr.io -u abhijeetadarsh   # once; token with read:packages
cd ~/pdfsync && docker compose up -d
docker compose pull && docker compose up -d   # update
```

The server runs as UID/GID 1000 (the default first user on Ubuntu; change
`user:` if `id -u` differs), with no capabilities, `no-new-privileges` and a
read-only root filesystem. It listens on `127.0.0.1:8000` for a reverse proxy
on the host (`reverse_proxy 127.0.0.1:8000` in the Caddyfile). The image is
multi-platform (amd64, arm64).

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
