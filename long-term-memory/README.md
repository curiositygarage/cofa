# Long-Term Memory Component

**Local PostgreSQL, namespaced per agent.** Durable recall that persists across sessions with no cloud dependency.

---

## What it does

Stores structured facts about you — preferences, decisions, corrections, operational state — in a local PostgreSQL database. Queries are namespaced per agent so multiple agents on the same Postgres instance do not collide.

The shipped client is a plain Postgres client: it writes and reads fact rows (`cofa_facts`, keyed by
namespace) and does **no** embedding or semantic search, so it needs no memory-provider package. If
your platform already runs a provider such as mem0 against this database, that provider is your
deployment path — not a dependency of this component.

This is your agent's external memory: what it remembers when it wakes up after a restart or after running for days.

---

## Install

### Prerequisites

- **PostgreSQL** installed and running locally. Version 14+ recommended. Available via OS package manager, Docker, or a managed local service.
- **Python 3.9+** — standard library only. No third-party packages are required; `psycopg2` is used when it happens to be installed, otherwise the client drives the `psql` client as a documented fallback.

### Steps

1. Create the database and user:

```bash
sudo -u postgres createdb <database_name>
sudo -u postgres psql -c "CREATE USER <username> WITH PASSWORD '<PASSWORD>'; CREATE DATABASE <database_name> OWNER <username>; GRANT ALL PRIVILEGES ON DATABASE <database_name> TO <username>;"
```

2. Copy the sample config:

```bash
cp config.sample.yaml ~/.config/cofa/long-term-memory/config.yaml
```

3. Edit `~/.config/cofa/long-term-memory/config.yaml` — replace every `<PLACEHOLDER>` with a real value. At minimum: `pg.host`, `pg.database`, `pg.username`, `pg.password`, and `namespace`. See `KEYS-REQUIRED.md`.

4. **Point your platform at this config, or use the shipped client directly.** If your platform
   has a memory-plugin API, register `lib/memory.py` (or your own wrapper) as the memory layer and
   give it `~/.config/cofa/long-term-memory/config.yaml`. With no plugin API at all the component
   still works: call the client from a shell wrapper or a tool your agent already has.

```bash
python3 lib/memory.py --config ~/.config/cofa/long-term-memory/config.yaml \
  --namespace "<agent_name>" write "a fact worth keeping"
python3 lib/memory.py --config ~/.config/cofa/long-term-memory/config.yaml \
  --namespace "<agent_name>" read "fact"
```

5. Verify the connection:

```bash
./checks/verify.sh
```

### Configuration reference

See `config.sample.yaml` for every supported field. Key fields:

- `provider`: The memory provider your platform runs. Recorded so a platform can pick this component up; the shipped client does not read it
- `pg.host` / `pg.port` / `pg.database` / `pg.username`: Connection details
- `pg.password`: Auth credential
- `namespace`: Agent-specific namespace prefix (e.g., `<agent_name>`) — the isolation boundary: the client only ever sees rows carrying this namespace
- `collections`: Relevant only to a platform provider such as mem0. The shipped client uses one table, `cofa_facts`, keyed by namespace

---

## Configure

1. Set your agent namespace (unique per agent sharing the same Postgres instance).
2. Nothing else is required: the client creates its table on demand. A platform provider such as mem0 keeps its own collections alongside `cofa_facts` without conflict.
3. If you have memory data from a previous installation, configure the migration path before starting — import must be explicit, never automatic.

---

## Verify

Run `./checks/verify.sh`. It writes a fact and reads it back through the shipped client — a
database that merely answers `SELECT 1` is not evidence of memory:

- a backend exists (psycopg2, or the `psql` client as a documented fallback)
- the deployed config is real: `pg.host`, `pg.database` and `namespace` are set, not placeholders
- a fact is written and read back **by content** from the same namespace
- a different namespace sees none of it (namespace isolation)
- the verification rows are removed again by the run itself
- **negative:** an unreachable database exits 3 loudly instead of degrading to a warning
- the verifier leaves the component tree byte-identical (no files written into the checkout)
- the verifier re-runs itself with an empty config dir and requires that run to FAIL

Exit code 0 = memory persists and namespaces are isolated. Non-zero = which check failed is printed.

---

## Rollback

1. Remove the component from your platform configuration (stop the provider pointing at this database, if you wired one).
2. Remove the config file: `rm ~/.config/cofa/long-term-memory/config.yaml`
3. Optionally drop the database if you want a clean slate: `sudo -u postgres dropdb <database_name>`
4. Restart your agent platform.

The component is fully isolated — removing it does not affect other components.
