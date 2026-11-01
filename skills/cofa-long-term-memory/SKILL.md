---
name: cofa-long-term-memory
description: Use when an agent needs durable recall across sessions without a cloud memory vendor. Facts live in local PostgreSQL, namespaced per agent.
license: MIT
---

# COFA — Long-Term Memory

A plain local Postgres client for the facts an agent should still know tomorrow: preferences,
decisions, corrections, operational state. Namespaced per agent so several agents can share one
database without colliding. No embeddings, no provider package, no network egress.

Source: https://github.com/curiositygarage/cofa (component: `long-term-memory/`)

## Use this when

- The agent forgets things between sessions and re-derives the same facts every time.
- A vendor-hosted memory service is unacceptable, unavailable, or too expensive.
- Several agents share one host and must not read each other's facts.

## Not this

It is a keyed fact store, not a semantic search engine. There is no embedding and no similarity
query; retrieval is by namespace and term. If you need vector recall, run a memory provider against
the same database and treat this component as the schema and the fallback client.

## Install

Prerequisites: PostgreSQL 14+ running locally, Python 3.9+ standard library. `psycopg2` is used when
present, otherwise the client drives the `psql` client.

```bash
sudo -u postgres createdb <database_name>
sudo -u postgres psql -c "CREATE USER <username> WITH PASSWORD '<PASSWORD>';
  CREATE DATABASE <database_name> OWNER <username>;"
mkdir -p ~/.config/cofa/long-term-memory
cp config.sample.yaml ~/.config/cofa/long-term-memory/config.yaml
```

Fill in `pg.host`, `pg.database`, `pg.username`, `pg.password`, and `namespace` in the config. Keep
that file at mode 600 and out of version control.

## Usage

```bash
python3 lib/memory.py --config ~/.config/cofa/long-term-memory/config.yaml \
  --namespace "<agent_name>" write "a fact worth keeping"
python3 lib/memory.py --config ~/.config/cofa/long-term-memory/config.yaml \
  --namespace "<agent_name>" read "fact"
```

## What belongs in it

Store signal, not transcript. A correction from the user, a decision and its reason, a stable
environment fact, a lesson that cost time. Do not store raw conversation, credentials, or anything
you would not want printed on a screen in public.

## Pitfalls

- **Namespace collision is silent.** Two agents sharing one namespace overwrite each other's
  meaning for a key. One namespace per agent, always.
- **An empty read is not proof of absence.** Check the connection and the namespace before
  concluding the fact was never stored.
- **Writes can fail quietly behind a wrapper.** Verify by reading the row back after a write, at
  least once per deployment.
- **Schema drift breaks recall later, not now.** Pin the database name and the config path, and keep
  a backup before any migration.
- **Do not put the password on a command line.** It lands in shell history and process listings.

## Verify

```bash
./checks/verify.sh
```

Then write one fact, restrict the query to the same namespace, and read it back in a fresh process.

MIT licensed. See `LICENSE`.
