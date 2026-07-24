# iCloud Link Sharing

Sharing a capture via a public iCloud download link. Anyone with the link can download the file from icloud.com in any browser; the recipient needs no iCloud account and no app. There is no server component: files live only in the user's own iCloud, and storage counts against their quota. This is a deliberate privacy choice; no third-party infrastructure sees the captures.

Status: implemented and validated end to end on a Debug build. Enabled in Debug; disabled in Release pending distribution provisioning (see "Remaining Manual Steps").

## How It Works

Core API: [`FileManager.url(forPublishingUbiquitousItemAt:expiration:)`](https://developer.apple.com/documentation/foundation/filemanager/url(forpublishingubiquitousitemat:expiration:)) (macOS 10.7+, not deprecated).

Flow when the user picks "Copy iCloud Link":

1. If the capture already has an unexpired link stored, copy it to the clipboard and stop.
2. Produce the final artifact: `ImageExportService.flatten(image:annotations:cropRect:)` rendered to PNG for screenshots (using live editor state for the selected entry, disk state otherwise), or the self-contained `recording.mp4` for videos. The API requires flat files.
3. Copy the file into the app's ubiquity container at `SharedLinks/<entry-id>.<ext>`. The folder sits outside `Documents/` and the app declares no `NSUbiquitousContainers` Info.plist key, so nothing appears in the iCloud Drive UI (Finder, Files, iCloud.com). On disk the container syncs through `~/Library/Mobile Documents/iCloud~app~screensnipe~app/`.
4. Wait until iCloud finishes uploading (the publish call fails otherwise): poll `URLResourceValues.ubiquitousItemIsUploaded` every 500 ms, 10-minute timeout, cancellable.
5. Call the publish API off the main thread (it performs synchronous network I/O). It returns the public URL.
6. Copy the URL to the clipboard and persist it in the capture's `metadata.json`.

Semantics:

- **Snapshot.** The link serves the file contents at publish time; later edits are not reflected. Re-sharing after an edit publishes a fresh snapshot.
- **Expiration is system-determined.** The API's `expiration` parameter is an out-parameter: the system chooses when the snapshot dies and reports the date back. We store it and re-publish automatically when a stored link has expired.
- **Revocation.** Deleting the file from `SharedLinks/` invalidates all published URLs for it. "Stop Sharing" does exactly that and clears the metadata fields. Deleting the app's data in System Settings > Apple ID > iCloud > Manage Account Storage kills all links at once.
- **Preconditions.** The user must be signed into iCloud with iCloud Drive enabled (`FileManager.default.ubiquityIdentityToken != nil`), and the build must carry the iCloud entitlements; distinct error messages cover both.
- **Quota.** Shared files consume the user's iCloud storage until they stop sharing or the link expires.
- **Download only.** The link is a direct download with a long icloud.com URL; there is no preview page. Accepted trade-off of the no-infrastructure design.

## Code Map

- `ScreenSnipe/Services/ICloudShareService.swift`: precondition checks, copy-to-container, upload polling, publish, revoke. `ICloudShareError` provides the user-facing error messages.
- `ScreenSnipe/Models/LibraryEntry.swift`: `CaptureMetadata.shareURL` and `.shareExpiration`, optional so old `metadata.json` files keep decoding.
- `ScreenSnipe/Library/LibraryViewModel.swift`: `copyICloudLink(for:)` (reuse-or-publish logic, clipboard, confirmation), `stopSharing(_:)`, `cancelShareLink()`. After the first-ever publish a one-time alert explains the clipboard and the right-click actions (`icloudLinkInfoShown` UserDefaults key); later shares show an "iCloud link copied" toast parented to the library window.
- UI: "Copy Link" toolbar item in `LibraryToolbarDelegate` (`link.icloud` icon), "Copy iCloud Link" / "Stop Sharing" in the `LibrarySidebar` context menu, `ShareLinkProgressView` sheet with Cancel during upload, and a `link.icloud` badge on shared entries in `LibraryEntryRow`.

## Entitlements and Provisioning

Both `.entitlements` files carry the same keys (container IDs are independent of bundle IDs, so Debug and Release share one container):

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.app.screensnipe.app</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudDocuments</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.app.screensnipe.app</string></array>
```

- **Debug: active and provisioned.** The Debug config uses automatic signing (`project.yml`). Building with `xcodebuild ... -configuration Debug -allowProvisioningUpdates -allowProvisioningDeviceRegistration` had Xcode register the container, enable the capability on `app.screensnipe.app.debug`, and mint a team provisioning profile.
- **Release: keys commented out.** Release uses manual signing; building with the keys active fails with "requires a provisioning profile with the iCloud feature" until the distribution profiles include iCloud (verified empirically). Until then, Release builds show the "container unavailable" error if the feature is used.

## Remaining Manual Steps (Release only)

1. In the developer portal (team `8594MRU6A8`): enable the iCloud capability with container `iCloud.app.screensnipe.app` on the `app.screensnipe.app` App ID (the container itself already exists; Xcode registered it while provisioning Debug).
2. Regenerate the Mac App Store and Developer ID provisioning profiles and update the CI secrets per [RELEASE.md](RELEASE.md). iCloud is an "advanced capability" per [Apple's Developer ID page](https://developer.apple.com/support/developer-id), so the Developer ID job (which currently archives with `PROVISIONING_PROFILE_SPECIFIER=""`) must embed a Developer ID profile.
3. Uncomment the iCloud keys in `ScreenSnipe/ScreenSnipe.entitlements`.

## Known Limitations

- **Upload latency.** Videos can take minutes on slow connections; the progress sheet with Cancel covers this.
- **Expiration is out of our control.** Expired links fail silently for recipients; the app re-publishes on the next "Copy iCloud Link".
- **Quota exhaustion.** Users with full iCloud storage will see upload failures surfaced through `ErrorReporter`; the message does not yet distinguish quota from network errors.
- **API health.** The publishing API is old and rarely discussed. It works on current macOS (validated 2026-07-24), but Apple has shipped iCloud Drive regressions before (the iOS 18.4 `NSMetadataUbiquitousItemDownloadingStatusKey` bug, [FB17662379](https://developer.apple.com/forums/thread/785030)), so re-verify after major OS updates.
