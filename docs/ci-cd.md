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

## Running the server image
The image is private (it belongs to a private repo). On the host:

```sh
echo <a GitHub token with read:packages> | docker login ghcr.io -u <user> --password-stdin
docker run -d --name pdfsync -p 8080:8080 -v pdfsync-data:/data \
  --restart unless-stopped ghcr.io/<owner>/pdfsync-server:latest
```

The CI only publishes the image; deploying it to a host is manual for now.

## Web client on GitHub Pages

`.github/workflows/web.yml` analyzes and tests the client (including sync
integration tests against a freshly built Go server), builds the release web
bundle, and uploads a `github-pages` artifact. It runs on pull requests targeting
`main`, pushes to `main`, and manual dispatch. Only `main` can deploy; pull
requests validate the build without publishing. Web deployment runs independently
of the native release jobs and needs no Android signing secrets.

### One-time repository setup

GitHub Pages is enabled for this public repository with GitHub Actions as the
publishing source, and HTTPS is enforced. No additional Pages setup is needed here.
For another repository, Pages requires a supported paid plan for private
repositories, or a public repository.

In **Settings → Pages → Build and deployment**, set **Source** to
**GitHub Actions**, or run:

```sh
gh api --method POST repos/abhijeetadarsh/pdfsync/pages -f build_type=workflow
```

Merge the web workflow PR, then its push to `main` publishes the client. If Pages
is enabled after merging, rerun the Web workflow from the Actions tab or run:

```sh
gh workflow run web.yml --ref main
```

The default site URL is `https://abhijeetadarsh.github.io/pdfsync/`. Production
builds read the base path from `actions/configure-pages`, so project paths and
custom domains use the appropriate Flutter base href automatically. The existing
hash-based routing needs no server-side route rewrites. PR builds use the
repository path and do not require Pages to be enabled.

### Backend connection

Pages serves only the Flutter client. Keep the Go server, SQLite database and PDF
files on the existing server host. Users enter that server's **HTTPS** URL on the
login screen; no server credentials or backend URL are embedded in the build.
The TLS reverse proxy must support WebSocket upgrades for `/api/ws` (WSS).

Set `PDFSYNC_CORS=https://abhijeetadarsh.github.io` on the Go server, or use the
equivalent `-cors` flag. The origin has no `/pdfsync/` path or trailing slash. For
a custom Pages domain, use that domain's HTTPS origin instead. Docker Compose
users can add this variable under `services.server.environment`. The default `*`
also works, but an explicit origin restricts browser access to the intended site.

For a local production build matching the project URL:

```sh
cd client
flutter pub get
flutter build web --release --base-href /pdfsync/
```

The published files come from `client/build/web`, including the PDFium WASM assets.
After the first deployment, verify sign-in, PDF opening, annotation sync between
devices and cached PDF access offline in a browser. CI validates compilation and
the existing tests; it does not run these browser interactions.

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
