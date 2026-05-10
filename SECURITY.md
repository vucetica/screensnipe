# Security Policy

## Reporting a vulnerability

If you find a security issue in ScreenSnipe, **please do not open a public GitHub issue**. Email the details to:

**support@screensnipe.app**

Include:
- A description of the issue
- Steps to reproduce
- The macOS and ScreenSnipe versions affected
- Any proof-of-concept code if applicable

You'll get an acknowledgement within a few days. Once a fix is available we'll release a new build to the App Store and credit you (with your permission) in the release notes.

## Supported versions

Only the latest released version on the Mac App Store receives security fixes.

## Scope

ScreenSnipe is a sandboxed macOS app that runs entirely on the user's Mac and makes no network requests. The most relevant areas for security review are:

- Parsing of saved annotation JSON in `~/Pictures/ScreenSnipe/`
- File system access via the user-selected library folder
- Capture and recording flows (Screen Recording / Microphone TCC)

Issues outside this scope (e.g., social engineering of App Store reviews, theoretical macOS-level exploits unrelated to the app's behavior) are out of scope.
