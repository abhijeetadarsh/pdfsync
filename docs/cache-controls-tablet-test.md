# Cache controls: tablet verification, 2026-11-24

The initial pass below used the older main base. The follow-up at the end
records verification after pulling the approved UI redesign from main.

Device: Motorola XT2571-1 (`HA2891X3`), Android 16, 1840×2944,
340 dpi. Tested the native profile APK from `fix/issue-8`, version code 12.

The installed version 11 used the project's release certificate, while the
normal profile build used the debug certificate. The first update was rejected
with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Re-signed the profile APK using the
existing local release key, verified its certificate matched the installed APK,
and installed through `scripts/install-android.sh`. No uninstall or data clear
was used.

The tablet was signed out initially, with an existing account database and five
cached PDFs. Saved its session database byte-for-byte and used a temporary
session against a local server via `adb reverse`. All test documents, uploads,
and annotations belonged to a disposable local test account. No production
account or production server was used.

| Check | Result |
| --- | --- |
| Remote PDF initially uncached | Cloud-download placeholder; absent from offline filter |
| Open remote PDF | Downloaded and resumed saved page 2 |
| Shared content hash | Both library entries showed the same offline availability |
| Remove from this device | PDF file disappeared from native blob directory; both shared entries disappeared from offline filter |
| Metadata preservation | Both document records, the saved note, and page-2 progress remained |
| Open removed PDF with server stopped | Clear offline-unavailable error and Try again button |
| Restart server and press Try again | Re-downloaded correct PDF and resumed page 2; offline indicators returned |
| Import PDF with server stopped | PDF readable immediately from local cache |
| Remove unsynced import | Action disabled, labeled Waiting for upload; tapping it did not remove the file |
| Sync imported PDF | Document became clean, upload marker set, removal action enabled when reopened |
| Layouts | Portrait and landscape; dark and light themes; normal and 1.3× text size; no visible clipping or overflow |

Screenshots are direct `adb exec-out screencap` captures:

- [Removal in portrait](screenshots/issue-8-tablet/remove-portrait.png)
- [Empty offline filter after shared-file removal](screenshots/issue-8-tablet/empty-offline-filter.png)
- [Uncached PDF while offline](screenshots/issue-8-tablet/offline-error.png)
- [Upload protection in landscape with larger text](screenshots/issue-8-tablet/protected-landscape-large.png)
- [Retry succeeds and resumes page 2](screenshots/issue-8-tablet/retry-success-page2.png)
- [Removal enabled after upload, light theme](screenshots/issue-8-tablet/remove-landscape-light.png)

Disconnect testing exposed an existing sync bug: failed WebSocket handshakes
reported a stream error and also rejected `channel.ready`, whose error was
unhandled. Added a regression test that fails on the original behavior, then
consumed the readiness failure while leaving reconnect scheduling with the
stream listener. All 22 Flutter tests and static analysis pass after the fix.

Rebuilt and reinstalled the fixed profile APK in place, then launched it with
the test server stopped. Retried with the server running, removed the cached
PDF again, and re-downloaded it. The bytes matched the expected SHA-256. The
final app process had zero unhandled exceptions, fatal exceptions, RenderFlex
overflows, or disposed-image errors in logcat during this pass.

Cleanup: restored the original session database byte-for-byte, verified the
original account database SHA-256 was unchanged and the cached-file list
matched its starting state, and removed the disposable test account database,
two test blobs, the Downloads fixture, and the file-picker copy. Restored dark
mode, font scale 1.0, user rotation 0 with automatic rotation enabled, removed
the test adb reverse mapping, and stopped the local server. The updated version
12 remains installed, displaying the original signed-out state. Phone hardware
was not connected during this verification.

## Follow-up after pulling main

Updated main and fix/issue-8 to `02a15a4` (PR #14, approved UI and Android
branding), then reapplied the cache changes against that implementation.
Version code 13 retains the approved theme, list/grid layouts, sidebar,
details pane, reader sizing and annotation panel. Offline appears in expanded
navigation; compact navigation uses Available offline with the cached count.

Rebuilt and reinstalled the updated profile APK without clearing app data.
Repeated download/resume, shared-file cache removal, empty offline filtering,
and re-download. The downloaded PDF matched its SHA-256; page 2 and the note
remained intact, and the note appeared in the redesigned annotation panel.
Checked portrait and landscape with 1.3× text scale. No runtime exceptions,
RenderFlex overflows, or disposed-image errors were recorded for the final
app process. All 25 automated tests (including the approved UI tests), static
analysis, the native build, and the web build pass on the updated base.

Current native captures, superseding the earlier layout screenshots:

- [Portrait at 1.3× text scale](screenshots/issue-8-tablet/current-portrait-large.png)
- [Landscape offline filter at 1.3× text scale](screenshots/issue-8-tablet/current-landscape-large.png)
- [Re-downloaded PDF on page 2 with its saved note](screenshots/issue-8-tablet/current-reader-note.png)

Restored the original signed-out session byte-for-byte and verified the
original account database checksum and cached-file list remained unchanged.
Removed the disposable account database and test blobs, stopped the local
server, removed its adb reverse mapping, and restored automatic rotation,
font scale 1.0, and dark mode. Version 13 remains installed.
