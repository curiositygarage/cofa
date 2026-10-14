# Credentials Required — Long-Term Memory

| Key name | What it is for | Optional? | Where to obtain |
|----------|----------------|-----------|-----------------|
| `pg.password` (in config) | PostgreSQL auth for the mem0 database | No, unless your PG trusts local connections | Create via your Postgres installation (`CREATE USER ... WITH PASSWORD`). Must be strong; never use a default or blank password. |
| `pg.host` (in config) | PostgreSQL connection host | No | `127.0.0.1` for a local database, otherwise your database host. In most setups `127.0.0.1` works. |
| `pg.port` (in config) | PostgreSQL connection port | No (defaults to 5432) | Standard PostgreSQL port is `5432`. Only change if your cluster uses a different port. |
| `pg.database` (in config) | mem0 database name | No | Convention: `mem0` or `mem0_<agent>` for namespaced isolation. |
| `pg.username` (in config) | PostgreSQL username for mem0 | No | Convention: `mem0` or a per-agent user created alongside the database. |

**Mechanism note.** These values live in the component's config file
(`${COFA_CONFIG_DIR:-$HOME/.config/cofa}/long-term-memory/config.yaml`) under the `pg:` block.
They are not required as environment variables — a platform that prefers environment variables
may export them and substitute the values at install time, but the file is the contract this
component reads.

## Announcement rule

If any of the above are missing at setup time, print:

```
REQUIREDCHECK <key-name>: required for long-term-memory. Set it before starting.
```

Do not silently fail. The installing agent or human must know exactly what is missing.
