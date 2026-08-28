# Security

Wheatley is pre-release local software. Its current trust model assumes one
user on one trusted computer.

## Network exposure

The server binds to `127.0.0.1:8765` by default. The API has no authentication
or user isolation. CORS configuration controls browser access; it is not an
authentication mechanism.

`scripts/server/lan.sh` deliberately requires
`WHEATLEY_TRUSTED_LAN=yes`. LAN mode can expose:

- profile documents, conversations, memories, and generated artifacts;
- local model and runtime details;
- any tools enabled in the active configuration.

Do not expose the API directly to the public internet. Use LAN mode only on a
network whose users and devices you trust.

## Agent tools

The example configuration disables file writing, editing, shell execution,
camera capture, and Codex delegation. These capabilities are powerful:

- Pi's file and shell tools are not a security sandbox.
- A model may make mistakes or follow malicious instructions found in files or
  web content.
- A configured normal-agent workspace gives that profile's Pi and shell tools
  read/write authority over the external tree; `WHEATLEY.md` routing and
  `--no-context-files` reduce prompt cost, not filesystem authority.
- Camera access can capture sensitive surroundings.
- Codex delegation can modify the explicitly configured workspace.

Enable only the tools you need, use a dedicated profile/workspace, and inspect
the effective configuration before trusting the assistant with important
data.

Codex delegation remains disabled unless `WHEATLEY_CODEX_WORKSPACE_ROOT` is
configured. Its local worker socket defaults inside `WHEATLEY_APP_DATA_ROOT`.

## Local data

Profiles contain private data by design. `app-data/`, `wheatley.local.env`,
`local-data/`, and generated output are ignored by Git. Keep any alternate
profile or configuration directory out of the repository as well.

Before publishing a fork, review both tracked files and commit history. Adding
a secret to `.gitignore` after it was committed does not remove it from
history.

## Reporting a problem

Open a GitHub issue for a security design problem that contains no sensitive
information. Do not publish real credentials, private transcripts, personal
paths, or exploit data belonging to another person. For a sensitive report,
contact the maintainer privately through the contact method on their GitHub
profile.
