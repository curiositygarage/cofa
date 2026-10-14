# Downloads Directory — policy-cel

Pinned download scripts and SHA-256 checksums for any dependencies not shipped in-repo.

When a component needs an external binary or library that cannot be installed via standard package managers:

1. Use a pinned fetch script here (e.g., `download.sh` referencing exact versions).
2. Include the expected SHA-256 checksum alongside the download URL.
3. Document a "check upstream" pointer in the component README so stale pins are noticed.

**Example entry:**
```
# download.sh
URL="https://example.com/tool/v1.2.3/tool-linux-amd64"
EXPECTED_SHA256="abc123..."
```

Nothing is downloaded or checked in yet (M1 is skeleton only). Placeholders and instructions go here when M2+ components add real download targets.
