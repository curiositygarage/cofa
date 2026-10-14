# Credentials Required — Continuity

| Key name | What it is for | Optional? | Where to obtain |
|----------|----------------|-----------|-----------------|
| *none* | This component uses filesystem-based checkpoint and resume files. No external keys, credentials, or tokens are needed. | — | — |

## Permissions note

Ensure the agent's process can read and write to the configured `checkpoints_dir` and `resume_file` paths. On Unix systems this means the home directory (or chosen path) must have appropriate ownership and permissions.
