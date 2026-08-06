# Release & CI/CD Guide

This document covers how Screen Snipe's automated builds work, how the GitHub
secrets are set up, and what to do when Apple certificates expire.

For the release process itself (version bump, changelog, PR, tagging), see the
**Releasing** section in [CLAUDE.md](../CLAUDE.md).

## Overview

Two GitHub Actions workflows live in `.github/workflows/`:

| Workflow | Trigger | What it does |
|---|---|---|
| `build.yml` | Every push and PR to `main` | Unsigned Debug build — verifies the code compiles. No secrets needed. |
| `release.yml` | Every push to `main`, every `vX.Y.Z` tag, manual dispatch | Signed, notarized, App Store builds (see jobs below). |

`release.yml` has two jobs:

- **`notarized-app`** — runs on **every push to `main`** (and tags/dispatch).
  Archives in Release configuration, signs with the **Developer ID Application**
  certificate, notarizes with Apple, staples the ticket, then packs the app two
  ways: `ScreenSnipe.zip` and a signed, notarized, stapled `ScreenSnipe.dmg`
  (the standard macOS download format). Both are uploaded as workflow artifacts
  (kept 30 days); on version tags (`vX.Y.Z`) they're also attached to the
  GitHub Release for that tag (creating the release with auto-generated notes
  if needed). Anyone can download and run these builds.
- **`app-store`** — runs **only on a `vX.Y.Z` tag or manual dispatch**.
  Archives with the **Apple Distribution** certificate, packages the signed
  app into a `.pkg` with `productbuild` (signed with the **Mac Installer
  Distribution** certificate), and uploads it to App Store Connect. You then
  submit for review manually in App Store Connect.

You can watch runs and download artifacts from the repo's **Actions** tab.

## The DMG installer window

The `.dmg` opens to a styled drag-to-install window: the app on the left, the
`/Applications` alias on the right, and an annotated background behind them.

| File | Purpose |
|---|---|
| `scripts/make-dmg.sh` | Builds the DMG from a `.app`. Used by CI and locally. |
| `distribution/dmg/dmgbuild-settings.py` | Window geometry, icon positions, view options. |
| `scripts/dmg-background.swift` | Draws the background artwork. |
| `scripts/build-dmg-background.sh` | Renders the artwork to `distribution/dmg/background.tiff` (committed). |

Layout is written straight into the volume's `.DS_Store` by
[`dmgbuild`](https://dmgbuild.readthedocs.io/) rather than by driving Finder over
AppleScript. GitHub runners are not authorized to send Apple events to Finder, so
the AppleScript approach fails there with `-1743`; `dmgbuild` has no such
dependency and produces the same result on any machine.

### Testing the installer locally

```bash
pipx install dmgbuild            # one time

xcodegen generate
xcodebuild -project ScreenSnipe.xcodeproj -scheme ScreenSnipe \
  -destination 'platform=macOS' -derivedDataPath build build

scripts/make-dmg.sh "build/Build/Products/Debug/Screen Snipe.app" /tmp/test.dmg
open /tmp/test.dmg
```

The window that opens is exactly what a user downloading the release sees, minus
the signing and notarization. A locally built `.app` is signed for development
only, so dragging it to `/Applications` and launching it will work on your Mac
but is not a test of Gatekeeper — for that, download the CI artifact.

Finder aggressively caches a volume's window settings by name. If a rebuild
appears to show the old layout, eject the volume first, and if it persists run
`rm ~/Library/Preferences/com.apple.finder.plist && killall Finder`.

### Changing the design

Icon positions live in two places that must stay in sync: `icon_locations` in
`distribution/dmg/dmgbuild-settings.py` and the layout constants at the top of
`scripts/dmg-background.swift`. After editing the artwork:

```bash
scripts/build-dmg-background.sh   # regenerates background.tiff + a flat PNG preview
```

Commit the regenerated `distribution/dmg/background.tiff`. CI consumes the
committed artwork and never re-renders it, so releases do not depend on fonts or
rendering behaviour being identical on the runner.

`window_rect` in the settings file is the window *frame*, but Finder anchors the
background picture at the top-left of the *content* view at native size. The
frame is therefore `CONTENT_HEIGHT + TITLE_BAR_HEIGHT` tall; without that the
bottom of the artwork is clipped.

## Required secrets and variables

Configured in **GitHub → repo Settings → Secrets and variables → Actions**.

### Variables (Variables tab)

| Variable | What it is |
|---|---|
| `TEAM_ID` | Apple Developer team ID (e.g. `8594MRU6A8`). The signing certificates must belong to this team — a cert from a different team fails the archive with "No signing certificate ... matching team ID". |

### Shared secrets

| Secret | What it is |
|---|---|
| `KEYCHAIN_PASSWORD` | Any random string — used as the password for the temporary keychain on the CI runner. |
| `ASC_KEY_ID` | App Store Connect API key ID (10 characters). |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID (a UUID). |
| `ASC_KEY_BASE64` | Base64 of the `AuthKey_XXXX.p8` API key file. |

### Developer ID notarized build (`notarized-app` job)

| Secret | What it is |
|---|---|
| `DEVID_CERT_BASE64` | Base64 of the **Developer ID Application** certificate + private key, exported as `.p12`. |
| `DEVID_CERT_PASSWORD` | Password set when exporting that `.p12`. |
| `DEVID_PROFILE_BASE64` | Base64 of the **Developer ID** `.provisionprofile` for `app.screensnipe.app`. Required because the app uses iCloud, an ["advanced capability"](https://developer.apple.com/support/developer-id/) that Developer ID signing only permits with a profile. |

### Mac App Store build (`app-store` job — only needed for tag-triggered uploads)

| Secret | What it is |
|---|---|
| `DIST_CERT_BASE64` | Base64 of the **Apple Distribution** certificate + private key (`.p12`). |
| `DIST_CERT_PASSWORD` | Password for that `.p12`. |
| `INSTALLER_CERT_BASE64` | Base64 of the **Mac Installer Distribution** certificate + private key (`.p12`). |
| `INSTALLER_CERT_PASSWORD` | Password for that `.p12`. |
| `PROVISIONING_PROFILE_BASE64` | Base64 of the Mac App Store `.provisionprofile`. |

## One-time setup

### 1. App Store Connect API key (shared)

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com) →
   **Users and Access** → **Integrations** → **App Store Connect API** →
   **Team Keys**.
2. Click **Generate API Key** (or **+**). Name it (e.g. "GitHub Actions CI")
   and set the role to **App Manager** (Developer is the minimum for uploads).
3. From the generated key, collect:
   - **Key ID** → `ASC_KEY_ID`
   - **Issuer ID** (shown at the top of the Team Keys page) → `ASC_ISSUER_ID`
   - **Download API Key** → saves `AuthKey_XXXX.p8`. **It can only be
     downloaded once** — store it somewhere safe.

   ```bash
   base64 -i ~/Downloads/AuthKey_XXXX.p8 | pbcopy   # paste into ASC_KEY_BASE64
   ```

### 2. Developer ID Application certificate (`DEVID_CERT_*`)

1. Open **Keychain Access** → **login** keychain → **My Certificates** and find
   `Developer ID Application: <Name> (8594MRU6A8)`. If missing, create it via
   **Xcode → Settings → Accounts → <team> → Manage Certificates → + →
   Developer ID Application** (only the Account Holder can create these in an
   organization team).
2. Expand the certificate, select **both** it and its private key (⌘-click),
   right-click → **Export 2 items...** → format **.p12**. Set a password —
   that password becomes `DEVID_CERT_PASSWORD`.
3. Encode and store:
   ```bash
   base64 -i devid.p12 | pbcopy   # paste into DEVID_CERT_BASE64
   ```
4. Delete the `.p12` afterwards — it contains the private key.

### 3. Mac App Store certificates and profile (optional, tag releases only)

Same export procedure as above, for the **Apple Distribution** and
**Mac Installer Distribution** certificates. The provisioning profile is
downloaded from [developer.apple.com → Profiles](https://developer.apple.com/account/resources/profiles/list)
(Mac App Store profile for `app.screensnipe.app`) and encoded the same way:

```bash
base64 -i profile.provisionprofile | pbcopy   # paste into PROVISIONING_PROFILE_BASE64
```

## When certificates expire

Certificate expiry **does not break existing releases** — apps already signed
and notarized keep working, and apps already on the App Store are unaffected
(as long as the Apple Developer Program membership stays active). What stops
working is producing *new* builds: CI jobs will fail at the signing step until
the corresponding secret is updated.

| Item | Validity | What happens on expiry | Fix |
|---|---|---|---|
| Developer ID Application cert | 5 years | Cannot sign new builds; already-signed/notarized apps still run | Create a new cert (Xcode → Manage Certificates), export `.p12`, update `DEVID_CERT_BASE64` + `DEVID_CERT_PASSWORD` |
| Apple Distribution cert | ~1 year | Cannot upload new apps/updates to App Store Connect; existing App Store apps unaffected | Regenerate via Xcode → Manage Certificates, export `.p12`, update `DIST_CERT_BASE64` + `DIST_CERT_PASSWORD` |
| Mac Installer Distribution cert | ~1 year | Same as above | Same as above, for `INSTALLER_CERT_*` |
| Mac App Store provisioning profile | Tied to the distribution cert | App Store export fails | Regenerate the profile in the Developer portal, update `PROVISIONING_PROFILE_BASE64` |
| Developer ID provisioning profile | Tied to the Developer ID cert | `notarized-app` archive fails | Regenerate the profile in the Developer portal, update `DEVID_PROFILE_BASE64` |
| App Store Connect API key | No automatic expiry | Can be revoked/rotated manually | Generate a new Team Key, update `ASC_KEY_*` |
| Apple Developer Program membership | Annual renewal | Certificates become invalid; apps removed from the App Store | Renew membership, then re-issue certs as needed |

Renewal procedure for any certificate:

1. Check expiry dates locally: **Keychain Access → My Certificates**, or
   `security find-identity -v`, or the
   [Developer portal certificates page](https://developer.apple.com/account/resources/certificates/list).
2. Create the replacement certificate (Xcode → Settings → Accounts →
   Manage Certificates → **+**).
3. Export the new cert + private key as `.p12` (see setup steps above).
4. Update the matching `*_BASE64` and `*_PASSWORD` secrets in GitHub.
5. The next push to `main` (or tag) will use the new certificate.
6. Delete the local `.p12`.

## Troubleshooting

- **`release.yml` fails at "Import Developer ID certificate"** — the
  `DEVID_CERT_PASSWORD` doesn't match the `.p12` password, or the base64 is
  truncated. Re-export and re-paste.
- **Notarization fails** — usually the ASC API key role is too low, or
  `ASC_ISSUER_ID` is wrong. Regenerate the key with App Manager role.
- **`app-store` job fails on a tag but `notarized-app` works** — the MAS
  secrets (`DIST_*`, `INSTALLER_*`, `PROVISIONING_PROFILE_BASE64`) are missing
  or expired. The `app-store` job is independent; the notarized artifact is
  unaffected.
- **"Provisioning profile has platforms visionOS, watchOS, and iOS"** — the
  uploaded profile is an iOS App Store profile. Create a **Mac App Store**
  profile (Mac section of the portal's distribution types) instead.
- **`productbuild` can't find the installer identity** — the
  `INSTALLER_CERT_BASE64` secret holds the wrong cert (e.g. the application
  distribution cert). Export the "Mac Installer Distribution" cert + key.
- **Expired certificate mid-cycle** — update the secret; no code or workflow
  changes are needed. CI picks up the new secret on the next run.

References: [Apple — Certificates overview](https://developer.apple.com/help/account/create-certificates/certificates-overview/),
[Apple — Developer ID](https://developer.apple.com/support/developer-id/).
