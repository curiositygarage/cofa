# Downloads Directory — long-term-memory

Pinned download scripts and SHA-256 checksums for any dependencies not shipped in-repo.

For mem0 and related packages, prefer standard package managers (pip, apt) over downloading binaries. If a specific pinned version of mem0 or a native extension must be installed from a URL:

1. Document the pinned version and source URL here.
2. Include the expected SHA-256 checksum.
3. Add a "check upstream for newer version" note in the component README.

**Example entry:**
```
# pinned_versions.txt
mem0==0.1.0  https://github.com/mem0ai/mem0/releases/tag/v0.1.0
expected_sha256=<HASH>
```

Nothing is downloaded or checked in yet (M1 is skeleton only).
