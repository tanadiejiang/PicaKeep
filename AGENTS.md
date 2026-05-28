# Codex instructions

- When switching into a worktree, check `git worktree list` first.
- If the target worktree already exists, call `EnterWorktree` with `path` only.
- If creating a new worktree, call `EnterWorktree` with `name` only.
- Never pass both `name` and `path`, and never pass `name: ""`.
- After switching, verify with `git branch --show-current` and `git rev-parse --show-toplevel` before doing anything else.
- Decide path vs name before the first `EnterWorktree` call; do not retry with the other form unless the target changed.
