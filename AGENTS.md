# Agents instructions

## Session start

- Read `docs/guides/Coding Guide.md` before coding or coding discussion. It is
  optional for documentation-only work.
- Inspect the relevant source and documentation trees before changing them.

## Task end

## Project context

## Project rules

- This project is pre-release alpha:
    - Change behaviors freely during features/refactors
    - Fix inconsistencies on sight
    - Do not maintain compatibility for storage
    - Do not add unnecessary boundary checks, validation and verification - architecture is still in flux and can be refactored so we do not need to "close" or "seal" the boundaries or ownership yet.
    - No fallbacks. Do not have two way to do things if one fails or arrives later. There should be only one way and it should fail fast. Keep it simple and straightforward.

- In conversation, it is good to answer with numbered list with title and short text. the text length can be sometimes slightly or use code/interface example.

- Never stage or unstage, and never `git commit` unless explicitly asked. User uses it to follow up, typically staged means reviewed and accepted.
- If there is no commit message, prefill one short one after a task
- Tests are not main deliverable, write them mainly for complex behavioral verification, integration with external system and as and additional too that allow to write complicated and high quality software. I'm fine also for writing ad-hoc one time tests or verification tools for implementation that are then deleted so we don't need to maintain a lot, only small good parts of system and tests brittle parts
- Never run browser UI checks unless explicitly asked
- Occasionally more agents work on parallel on some hopefully unrelated features, you should do best effort to adapt to changes and continue your task.
