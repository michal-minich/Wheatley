# Chat Branching

Wheatley can turn any finished Pi-backed user, thinking/tool-activity, assistant,
or generated-image bubble into an independent chat. The bubble itself is
included. Later content is not. Creating a branch never starts another model
turn automatically and never changes the source chat.

The existing bubble mini-toolbar exposes `Branch chat here`. Active user
submissions and unfinished thinking, tools, images, or assistant output do not
offer the action. Clicking it creates the branch on the server, loads it, and
changes the browser route to the new session.

## Storage contract

- The branch has a new session ID, new branch-local turn IDs, a new Pi session
  identity, its own presentation history, and `codex: null`.
- `session.json` records the source session, source turn, bubble kind, and item
  ID under `branch`.
- Pi ancestry is truncated at the exact durable user/content/tool-result entry.
  The selected turn's Markdown, tool sidecar, generated images, errors, and
  timing metadata are pruned to that same boundary.
- Earlier turn directories and their voice recordings, uploaded images, and
  generated artifacts are copied. Media URLs and stored turn/session references
  are rewritten to the new identity.
- Copied turns are marked `branch_inherited`. They remain normal model context
  inside the branch but are excluded from automatic-memory input and recent-turn
  context aggregation, preventing the same history from being learned twice.
- The Pi working directory is rebound to the current profile workspace. A
  continuation cannot retain a stale path to another profile-store clone.

Branching copies conversation state, not the outside world. Tool effects that
already changed files or external services are not rolled back or duplicated.
Codex presentation bubbles intentionally do not expose branching because a new
Wheatley chat cannot share the source's one-to-one native Codex thread.

## API

`POST /api/profiles/:profile_id/branches` accepts `session_id`, `turn_id`,
`kind` (`user`, `reasoning`, `assistant`, or `artifact`), and `item_id` (empty
only for a user bubble). The server resolves those stable IDs against Pi JSONL;
client DOM/message IDs are never trusted as the branch boundary.
