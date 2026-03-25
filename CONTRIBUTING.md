# Contributing to Spotlight Off

## Commit messages

Write for a human reading the GitHub commit list, not for a developer reading a diff.

**Subject line** — one sentence, plain English, no technical shorthand:
- ✅ `Version 1.1.5 — Light mode fixes and stability improvements`
- ✅ `Fix welcome screen not gaining focus on first launch`
- ❌ `Refine ephemeral mount guard: use mountedPaths instead of fileExists`
- ❌ `Bump build number to 6 (v1.1.4)`

**Body** — group changes under short plain-English headings. Explain what changed and why it matters to the user, not how it was implemented:

```
Light mode
- The welcome window no longer shows a dark titlebar strip in light mode
- Welcome screen and Settings window now follow the system appearance automatically

Stability
- Fixed a bug where Time Machine snapshot mounts were briefly picked up
  and processed, causing harmless errors in the log
```

---

## Release notes

Same principle — written for someone who just downloaded the app, not a developer.

- Lead with what the user will notice or benefit from
- Avoid internal variable names, class names, or file paths
- Group under `### What's new`, `### Fixed`, `### Improved` as appropriate

---

## Versioning

- **Patch** (1.1.x) — bug fixes, visual polish, no new features
- **Minor** (1.x.0) — new user-facing features
- Always bump both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj`
- Update the README download badge and link to match the new version
- Never reference `Co-Authored-By` or AI tooling in commit messages

---

## Before pushing

1. Build and archive in Xcode to confirm the app compiles cleanly
2. Confirm version number shows correctly in the General settings tab
3. Push commits, then create a GitHub release with the zip named `Spotlight-Off.zip`
