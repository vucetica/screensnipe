# Contributing to ScreenSnipe

Thanks for your interest! ScreenSnipe is an indie macOS app and contributions of all sizes are welcome — bug reports, fixes, new features, docs.

## Quick start

1. Fork the repo and clone your fork
2. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
4. Open `ScreenSnipe.xcodeproj` in Xcode 16+ and build (⌘B). Run with ⌘R.

The Xcode project is regenerated from `project.yml` — edit `project.yml`, not the `.xcodeproj`.

## Code signing

`project.yml` references the maintainer's signing identity and team. To build locally, either:

- In Xcode → ScreenSnipe target → Signing & Capabilities, enable **Automatically manage signing** and set your own team, or
- Build unsigned for testing:
  ```bash
  xcodebuild -project ScreenSnipe.xcodeproj -scheme ScreenSnipe \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
  ```

Don't commit changes to `project.yml`'s signing fields.

## Pull requests

- Branch from `main`
- Keep PRs focused — one feature or fix per PR
- Run the build before submitting: `xcodegen generate && xcodebuild -project ScreenSnipe.xcodeproj -scheme ScreenSnipe -destination 'platform=macOS' build`
- Match the existing code style (Swift 6 strict concurrency)
- Update `README.md` if you add a user-facing feature

## Reporting bugs

Open an issue on GitHub with:
- macOS version
- Steps to reproduce
- Expected vs actual behavior
- A screenshot or recording if visual

## Security issues

See [SECURITY.md](SECURITY.md) for vulnerability reporting — please don't open public issues for security problems.

## Code of conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold it. Report unacceptable behavior to support@screensnipe.app.
