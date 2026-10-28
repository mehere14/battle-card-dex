# Repository privacy

The shared project uses example app and CloudKit identifiers. Actual signing and backend identifiers belong in ignored `Configuration/Local.xcconfig`; the loader reads its container from ignored `.env.local`. Never add the downloaded Firebase `GoogleService-Info.plist`, App Check debug tokens, private keys, credential files, local reports, or Xcode `xcuserdata` to Git.

The Firebase file is still bundled by Xcode when present locally. A fresh checkout requires its own downloaded configuration before live recognition can work. The recognition prompt and matching behavior are independent of these local settings.

Before committing, run `python3 Scripts/check_repository_privacy.py --staged`. It checks the complete staged versions, including binaries, for credential patterns and local identifiers. It reports filenames and issue categories without printing matched values. This is a defensive check, not a guarantee that every possible secret format can be recognized.

Historical Git commits and author/committer metadata are separate from the current file tree. Removing a file now does not remove earlier copies from history. Do not publish the history as a sanitized export without separately reviewing and sanitizing it. Rewriting existing history is not performed by the check.

For privacy-sensitive commits, use a repository-specific display name and a Git-hosting no-reply address or a nonpersonal placeholder. Do not change global Git identity as part of project setup.
