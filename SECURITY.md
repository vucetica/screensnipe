# Security Policy

## Reporting a vulnerability

If you find a security issue in ScreenSnipe, **please do not open a public GitHub issue**. Report it privately via [GitHub's private vulnerability reporting](https://github.com/vucetica/screensnipe/security/advisories/new) (Security tab → "Report a vulnerability"). The report is visible only to you and the maintainer.

Include:
- A description of the issue
- Steps to reproduce
- The macOS and ScreenSnipe versions affected
- Any proof-of-concept code if applicable

You'll get an acknowledgement within a few days. Once a fix is available we'll release a new build to the App Store and credit you (with your permission) in the release notes.

## Supported versions

Only the latest released version on the Mac App Store receives security fixes.

## Scope

ScreenSnipe is a sandboxed macOS app that runs on the user's Mac. Its only network feature is opt-in iCloud link sharing (CloudKit). The most relevant areas for security review are:

- Parsing of saved annotation JSON in `~/Pictures/ScreenSnipe/`
- File system access via the user-selected library folder
- Capture and recording flows (Screen Recording / Microphone TCC)
- iCloud link sharing (CloudKit records and public download links)

Issues outside this scope (e.g., social engineering of App Store reviews, theoretical macOS-level exploits unrelated to the app's behavior) are out of scope.
