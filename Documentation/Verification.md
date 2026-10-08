# Verification record — October 8, 2026

## Automated and environment checks

- Xcode 27.0 / Apple Swift 6.4, Apple Silicon Mac.
- Release deployment target: macOS 15.6. Swift language mode: 6.0, strict concurrency: complete.
- Debug `xcodebuild … CODE_SIGNING_ALLOWED=NO build`: successful.
- Official Google ADB 37.0.1 universal binary: `adb version` successful.
- Shared ADB server startup and `devices -l`: successful, no headset attached at the time of that check.
- Real `track-devices` initial empty frame confirmed as `0000`.
- Native application launched; the disconnected window and expanded transfer history were inspected.
- Core Swift tests: **23 tests in 7 suites passed**, including parameterized conflict and download cases.
- Final Debug and universal Release builds: **BUILD SUCCEEDED**. No Swift compiler warnings; Xcode emitted only its informational App Intents metadata warning (this app has no App Intents dependency).
- `git diff --check`: clean.

## Release preparation

- Version 1.0.0, build 1; bundle identifier `io.github.mingistech.QuestBridge`.
- Universal app executable includes `arm64` and `x86_64`.
- App and bundled Platform Tools signed with Developer ID and hardened runtime.
- Deep, strict signature verification passed.
- Apple notarization: **Accepted**, October 8, 2026. Submission `5a49942b-c33d-40c4-b73c-30eade7c3c7d`.
- Notarization ticket stapled and validated.
- Gatekeeper assessment: **accepted**, source **Notarized Developer ID**.
- Final distribution ZIP regenerated after stapling; SHA-256 provided with the release.

## Hardware evidence

The developer confirmed successful transfers of multiple files to a physical headset.

The running application's history showed four **Completed · Verified and completed** uploads and one **Skipped · existing item preserved** result. This supports the basic real-device upload flow, multiple uploads, verification completion, and a skipped conflict. It does not establish file sizes, every format, the specific headset model, or every remaining test below. Additional destructive hardware tests have not been performed.

## Manual acceptance checklist

| Scenario | Status |
| --- | --- |
| Basic real-headset uploads | User confirmed successful |
| Multiple uploads | Supported by observed completed history and user report |
| Skip an existing filename | Observed skipped result in running app |
| Initial USB authorization guidance | Implemented; full headset onboarding not independently verified |
| Reconnect with persistent authorization / no MTP prompt | Requires explicit hardware validation |
| Browse Movies, breadcrumbs, sort, multi-selection | Implemented; complete interaction coverage not independently verified |
| Folder upload and nested verification | Automated mock tests; hardware check pending |
| MP4 / MKV over 10 GB and files over 20 GB | Hardware check pending; no size claim from user report |
| Downloads | Automated tests; hardware check pending |
| Rename files and folders | Implemented; destructive hardware checks pending |
| Delete with confirmation | Implemented; hardware checks pending |
| Disconnect during upload / retry after reconnect | Automated queue and process tests; hardware check pending |
| Insufficient headset storage | Automated test; hardware check pending |
| Replace / Keep Both / apply to batch | Automated conflict tests; hardware interaction coverage pending |
| Open uploaded media in HereSphere | User confirmation still needed |
| Notification delivery | Permission-dependent manual check pending |
| Relaunch and preference persistence | Implemented; full manual check pending |
| macOS 15 and Intel runtime | Deployment/build support; runtime checks pending |

## Automated coverage

- Directory parsing: ordinary names, spaces, Unicode, quotes, parentheses, embedded/trailing newlines, empty listings, large sizes, missing metadata, malformed output.
- Remote paths: boundaries, parent navigation, traversal rejection, trailing slashes, filename validation, POSIX shell escaping round trips.
- Devices: empty lists, authorized/unauthorized/offline states, multiple devices, verified Quest identification, unknown Android exclusion, disconnect snapshots, malformed output, chunked tracking frames.
- Transfers: successful upload, original preservation on failure/corruption, insufficient space, Skip/Keep Both/Replace/Cancel, recursive folders, successful/replacement/failed/corrupt downloads.
- Queue: serialization, active cancellation without false success, next-item continuation, failed-item retry, disconnect failing active and pending requests.
- Processes: simultaneous stdout/stderr draining, bounded streaming memory, exit failures, timeout, cancellation and reaping even when SIGTERM is ignored.
