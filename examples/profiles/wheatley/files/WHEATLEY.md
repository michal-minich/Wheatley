# Profile Workspace

This is the profile's durable file workspace across sessions. Keep user-facing
files concise, organize them by topic with short readable names, and never run
Git unless the user explicitly asks.

When locating files or text, prefer `rg --files` for filenames and `rg` for
file contents. Use `find` only when the search requires filesystem metadata or
another condition that `rg` does not support.

Add profile-specific file routing, handbooks, or project instructions here.
