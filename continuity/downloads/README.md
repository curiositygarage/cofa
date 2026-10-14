# Downloads Directory — continuity

Pinned download scripts and SHA-256 checksums for any dependencies not shipped in-repo.

The continuity component uses shell + JSON for checkpoint files. Dependencies come from:

1. Standard Python stdlib (`json`, `pathlib`) — no downloads.
2. POSIX shell builtins — no downloads.
3. Platform-specific startup hooks (may need a small shim script from the platform ecosystem).

If a platform shim is required:

1. Write a download script here pinning to a specific commit/tag.
2. Verify with SHA-256 before placing it anywhere else.
3. Note the upstream update channel in the component README.

Nothing is downloaded or checked in yet (M1 is skeleton only).
