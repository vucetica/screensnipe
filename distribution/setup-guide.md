# Mac App Store Submission Guide

Complete checklist for publishing Screen Snipe to the Mac App Store.

---

## Prerequisites

- [ ] Apple Developer account ($99/year) — [developer.apple.com](https://developer.apple.com)
- [ ] Xcode installed with latest command line tools
- [ ] App Store Connect access

---

## Step 1: Certificates & Profiles

### Create Distribution Certificates
1. Go to [developer.apple.com/account](https://developer.apple.com/account) → Certificates
2. Create **"3rd Party Mac Developer Application"** certificate (for code signing the app)
3. Create **"3rd Party Mac Developer Installer"** certificate (for signing the .pkg)
4. Download both and double-click to install in Keychain

### Create App Store Provisioning Profile
1. Go to Identifiers → confirm `app.screensnipe.app` exists
2. Go to Profiles → click **+**
3. Select **Mac App Store** distribution
4. Select App ID: `app.screensnipe.app`
5. Select your "3rd Party Mac Developer Application" certificate
6. Name it: `Screen Snipe App Store`
7. Download and double-click to install

---

## Step 2: Create App Record in App Store Connect

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → My Apps → **+** → New App
2. Fill in:
   | Field | Value |
   |-------|-------|
   | Platform | macOS |
   | Name | Screen Snipe |
   | Primary Language | English (U.S.) |
   | Bundle ID | `app.screensnipe.app` |
   | SKU | `screensnipe-macos` |
   | User Access | Full Access |
3. Click **Create**

---

## Step 3: Set Up Subscription

Follow the detailed instructions in [`subscription.md`](subscription.md).

---

## Step 4: App Store Metadata

1. In App Store Connect → Your App → macOS → Prepare for Submission
2. Copy the text from [`metadata.md`](metadata.md) into the corresponding fields
3. Upload screenshots (see [`screenshots.md`](screenshots.md))
4. Set **App Rating**:
   - Go to App Information → Age Rating → Edit
   - Answer "None" to all content questions
   - Result: **Rated 4+**

---

## Step 5: Deploy Privacy Policy

The privacy page is at `website/privacy.html`. Deploy it so it's live at:
```
https://screensnipe.app/privacy
```

Enter this URL in App Store Connect → App Information → Privacy Policy URL.

---

## Step 6: Archive & Upload

### Option A: Xcode GUI
1. In Xcode, select **Any Mac** as the build destination
2. Product → Archive
3. In the Organizer, click **Distribute App**
4. Select **App Store Connect**
5. Choose **Upload** (not Export)
6. Sign with your distribution certificate and provisioning profile
7. Click **Upload**

### Option B: Command Line
```bash
# Build the archive
xcodebuild archive \
  -project ScreenSnipe.xcodeproj \
  -scheme ScreenSnipe \
  -configuration Release \
  -archivePath ./build/ScreenSnipe.xcarchive

# Export for App Store
xcodebuild -exportArchive \
  -archivePath ./build/ScreenSnipe.xcarchive \
  -exportPath ./build/export \
  -exportOptionsPlist distribution/ExportOptions.plist

# Upload with altool or Transporter app
xcrun altool --upload-app \
  -f ./build/export/ScreenSnipe.pkg \
  -t macos \
  -u "your@apple.id" \
  -p "@keychain:AC_PASSWORD"
```

---

## Step 7: Submit for Review

1. In App Store Connect, select the build you uploaded
2. Fill in review notes from [`review-notes.md`](review-notes.md)
3. Set **Release**:
   - "Manually release this version" (recommended for first release)
   - Or "Automatically release"
4. Click **Submit for Review**

---

## Step 8: Post-Submission

- [ ] Monitor the review status in App Store Connect (typically 1-3 days)
- [ ] If rejected, read the resolution center notes and fix the issues
- [ ] Once approved, release the app (if set to manual release)
- [ ] Update the website's App Store link to the real URL:
  ```
  https://apps.apple.com/app/id<YOUR_APP_ID>
  ```

---

## Version Bumping (Future Updates)

For each new upload to App Store Connect, increment the build number:

**`ScreenSnipe/Resources/Info.plist`:**
```xml
<key>CFBundleVersion</key>
<string>2</string>  <!-- increment: 1 → 2 → 3 → ... -->
```

For user-visible version changes, also update:
```xml
<key>CFBundleShortVersionString</key>
<string>1.1.0</string>
```

---

## Troubleshooting

### "No accounts with App Store Connect access"
- Ensure your Apple ID is added to the team in App Store Connect → Users & Access

### "Profile doesn't match bundle ID"
- The provisioning profile must be for `app.screensnipe.app` (Release bundle ID), not the `.debug` variant

### "Missing compliance" warning
- `Info.plist` already declares `ITSAppUsesNonExemptEncryption: NO` — this should satisfy the export compliance question automatically

### Upload fails with signing error
- Make sure you're archiving with Release config (uses `ScreenSnipe.entitlements` with sandbox)
- The entitlements file must include `com.apple.security.app-sandbox`
