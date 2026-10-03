# Claude instructions

## Project Rules

- This is a Flutter project. Application builds are restricted to `debug` and
  `profile` modes.
- Never run or recommend `flutter build ... --release`,
  `flutter build ... --dart-define=...` with a release-only wrapper, or any
  equivalent release build command.
- Never use an install helper or script with a `release` mode. Before installing
  a build, verify the APK exists and use an explicit device id; do not uninstall
  the existing app as a preparation step.
- A normal device verification build is `flutter build apk --debug` or
  `flutter build apk --profile`. Desktop verification may use
  `flutter build windows --debug`, `flutter build windows --profile`,
  `flutter build linux --debug`, or `flutter build linux --profile`.
- If an existing script, CI job, README command, or plan conflicts with these
  rules, stop and update the instructions or ask the user before running it.
- Installing a debug/profile package must preserve user data. Never run
  `adb uninstall`, `flutter install` when its APK path has not been verified, or
  any command that can remove application data without explicit user approval.

- When switching into a worktree, check `git worktree list` first.
- If the target worktree already exists, call `EnterWorktree` with `path` only.
- If creating a new worktree, call `EnterWorktree` with `name` only.
- Never pass both `name` and `path`, and never pass `name: ""`.
- After switching, verify with `git branch --show-current` and `git rev-parse --show-toplevel` before doing anything else.
- Decide path vs name before the first `EnterWorktree` call; do not retry with the other form unless the target changed.
