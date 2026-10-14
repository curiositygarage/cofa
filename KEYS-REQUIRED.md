# Credentials Required — COFA

Every credential needed across the entire framework, listed once. Component-level credentials are also documented in each component's `KEYS-REQUIRED.md`.

## Key table

| Component | Key name | What it is for | Optional? | Where to obtain |
|-----------|----------|----------------|-----------|-----------------|
| long-term-memory | `pg.password` (in config) | PostgreSQL auth for the mem0 database | **No** | Create via `pg_createcluster` or your Postgres provider. Must be strong; no defaults. |
| long-term-memory | `pg.host` (in config) | PostgreSQL connection host | No (unless using default) | `127.0.0.1` for a local database, otherwise your database hostname. Do not ship real hostnames; use `<host>` placeholders in repo files. |
| long-term-memory | `pg.port` (in config) | PostgreSQL connection port | No (defaults to 5432) | Standard PostgreSQL port (`5432`). Override only if your cluster uses a non-standard port. |
| long-term-memory | `pg.database` (in config) | mem0 database name | No (unless using default) | Convention: `mem0` or `mem0_<agent>` for namespaced isolation. |
| long-term-memory | `pg.username` (in config) | PostgreSQL username for mem0 | No (unless using default) | Convention: `mem0` or a per-agent user. Created during initial DB setup. |
| policy-cel | *none* | Policy configuration only; no external keys required. The CEL engine evaluates local rule files. | — | — |
| a2a-mesh | `peers.<name>.endpoint` (client config) | Target peer A2A endpoint URLs | Depends on peers you communicate with | Your own peer registry: one entry per sibling agent, e.g. `endpoint: http://<host>:<port>/a2a`. Not a credential — read at runtime by `a2a_client.py resolve <peer>`. Use `<host>` placeholders in repository files. |
| a2a-mesh | `my_agent_id` (client config) | Your own agent identity string sent in A2A messages | No | Your agent handle (e.g., `<your_agent_name>`). Set by the operator in the A2A client config. |
| continuity | *none* | Uses filesystem-based checkpoint files. No external keys needed. | — | — |

## Announcement rule

Any component requiring a key must announce it before failing. Print a clear message such as:

```
REQUIREDCHECK cofa-memory-config: required for long-term-memory. Copy `config.sample.yaml` and set `pg.host`, `pg.database` and `namespace`.
```

Do not silently exit with an opaque error. Always tell the human (or installing agent) what is missing and where to get it.

## Placeholder convention

All example configurations in this repository use angle-bracket placeholders:
- `<YOUR_API_KEY>` — any secret value
- `<host>` — hostname or IP address
- `<port>` — numeric port
- `<username>` — user identifier
- `<database>` — database name

Never replace these with real values in repository files. Real values belong in `.env` files or environment variables outside version control.
