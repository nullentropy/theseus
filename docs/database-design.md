# A database for Theseus apps

Status: decided 2026-10-14 with the recommendations in section 9. All four phases (section 8) are built: see PLAN.md section 7.24 for what they do and how they differ from this document. The main difference in phase 2: the two sides run one after the other, not at once, because two open transactions writing the same row wait on each other; and a replayed insert whose row already exists leaves the row as it is.

## 1. Where things stand

An app's data lives in its server units' memory as plain Elixir data. After a call changes it, the engine writes the unit's whole state, encrypted, to `<ledger>.state`, and restores it at boot.

That is enough for a demo and for thousands of records. It does not hold up past that:

- All data is in RAM.
- Every save rewrites a unit's whole state.
- There are no indexes or queries beyond what unit code does by hand.
- One machine holds the only copy, next to the ledger.

## 2. What has to stay true

Theseus works because units are deterministic and every change is checked against real behaviour before a person approves it. A database must keep these properties:

1. **Same inputs, same result.** Validation replays recorded calls on the current and the proposed code and compares the two. A unit's result may depend only on its arguments and on data it reads through the engine.
2. **Candidates never touch live data.** Validation, shadow runs and previews may read live data. Nothing they do is kept.
3. **People review behaviour.** A reviewer sees what a change reads and writes, as text, not code or SQL.
4. **Rollback stays possible.** A schema change must not leave the app in a state that rolling back a unit cannot recover from.

## 3. The design in brief

The engine owns a Postgres database. Tables are declared in schema units, which live in the ledger like any unit and change through proposals like any unit.

Endpoint units read through `Theseus.Store` calls. A call is a query written as data, not SQL. A unit does not write directly: it returns its writes as data, the way it already returns email messages. The engine runs each request in one transaction, applies the writes and commits. If another request got there first, the engine runs the handler again. Running it again is safe because the handler had no other effects.

Validation runs the current and the proposed code against the same snapshot of the live database, in two transactions that are always rolled back. It then compares their results and the rows each would write.

## 4. The pieces

### 4.1 The database

- One Postgres database, set with `THESEUS_DATABASE_URL`, reached through Postgrex with a connection pool. Each app gets its own Postgres schema.
- Without the variable, the app has no store, and units that use one are refused at validation with that reason.
- Unit code cannot open connections or reach the network. That is unchanged: only engine code talks to Postgres.

### 4.2 Schema units

A schema unit declares tables as data:

```elixir
defmodule App.Schema do
  use Theseus.Schema

  table :requests, key: :id do
    column :domain, :text, null: false
    column :requester, :text, null: false
    column :app_id, :text, null: false
    column :status, :text, null: false, default: "pending"
    column :requested_at, :utc_datetime, null: false
    index [:domain, :status]
  end
end
```

The column types are text, integer, boolean, utc_datetime, map (stored as jsonb) and list of text. Money is stored in integer cents. A schema unit has a spec like any unit. Its rules say what must hold of the data, such as "every request names an application that exists". The engine checks those rules against the live data in the validation snapshot.

### 4.3 Reads

```elixir
Theseus.Store.get(:requests, id)
Theseus.Store.all(:requests, where: [domain: d, status: "pending"], order: [desc: :requested_at], limit: 50)
Theseus.Store.count(:requests, where: [domain: d, status: "pending"])
```

- Queries are data. Table and column names must be literals, so the static check knows which units read which columns (section 4.8 uses this). Values are passed as parameters.
- `where` takes equality, `in`, comparisons and nil checks.
- Every read comes back in a defined order: the `order` given, then the key. Results are then the same on every run against the same data.
- Rows come back as maps with atom keys.
- There are no joins in the first version. A unit reads twice and combines the results.
- Only endpoint units and the engine's callbacks into them (`tick`, `synced`, `sign_in`) may read. Pure units stay pure: they get data passed in. Server units stay in memory, for coordination such as rate limits.

### 4.4 Writes are returned as data

```elixir
{:write,
 [
   {:insert, :requests, %{id: id, domain: d, requester: email, app_id: app, requested_at: now}},
   {:update, :requests, other_id, %{status: "approved"}, if: [status: "pending"]},
   {:delete, :sessions, session_id}
 ], {:redirect, "/requests"}}
```

- This wrapper goes around the result, like `{:send, messages, result}`, and can sit inside or outside the `:send` and `:htmx` wrappers.
- The engine applies the writes after the handler returns, in the request's transaction, then commits. Messages are queued only after the commit.
- An `if:` condition that no longer holds means another request changed the row first. The engine rolls back and runs the handler again, at most three times. The second run sees the new data and answers accordingly, for example "already approved".
- A unit cannot read its own writes within one call. It already has the values it wrote.

Returning writes as data is what makes the rest of this design work. A candidate's writes can be compared without being applied. Review evidence can say "the proposed version also sets decided_by". A retry is safe because nothing else happened.

### 4.5 Ids and time

- Time already comes in as `request.now`.
- Each request also gets an `id`: random, and recorded with the call. `Theseus.Store.id(request, n)` derives the n-th row id from it. Replay uses the recorded request, so the current and proposed code create rows with the same ids, and the comparison shows no spurious differences.
- Postgres sequences are not used. They advance even in rolled-back transactions, so the two sides of a comparison would get different ids.
- `tick` and `synced` get an `id` the same way.

### 4.6 Transactions

- Each request runs in one REPEATABLE READ transaction.
- A serialization failure is retried by running the handler again, like a failed `if:` condition.
- A request does all its reads before its writes, which is the right shape for this isolation level.
- A statement timeout (default 5 s) and a row limit per read (default 1,000; a larger `limit` must be explicit) keep one request from holding the database.

### 4.7 Specs

- Spec rules run without Postgres. The engine evaluates the same data queries over rows held in memory. That is possible because queries are data with a small set of operators.
- A rule seeds the rows it needs, for example `rows: %{requests: [...]}`, and starts from empty tables otherwise, as server units start fresh today.
- Running queries in memory can disagree with Postgres on text ordering and on NULL handling. The operators are chosen to avoid both: ordering is by bytes, and a nil comparison must be written as a nil check. Replay against the real database catches any disagreement that remains.

### 4.8 Validation against real data

**Replay.** The engine exports a snapshot of the live database (`pg_export_snapshot`). It opens two transactions on that snapshot, one for the current code and one for the proposed code. Recorded calls replay in each, applying their writes inside the transaction, so later calls see earlier ones, as with the copied server state today. The engine compares the results and the write sets, then rolls both back.

**Evidence.** Rows show write differences in words, for example "current: approves request req-3; proposed: approves request req-3 and records who decided".

**The sandbox.** Candidates run on the sandbox node. The sandbox gets a database role that can only touch the app's tables, inside transactions the engine code there always rolls back. Unit code on the sandbox still cannot reach the connection.

**Limits.** Validation transactions are kept under a minute, so they do not hold back Postgres's cleanup of old rows.

**Shadow runs.** An endpoint unit that calls only pure units is shadowed: the candidate gets the live request's snapshot, in a read-only transaction that is rolled back. One that calls a server unit is not, because a second handler would call it twice.

**Columns in use.** The static check records which tables and columns each unit version reads and writes. Section 4.9 and rollback use this.

### 4.9 Schema changes

A change to a schema unit is validated by applying its DDL inside both validation transactions, which Postgres allows, and then running specs and replay as usual. On approval, the DDL is applied in one transaction and the ledger records exactly what ran.

Allowed in one step:
- add a table;
- add a column that is nullable or has a default;
- add an index (built concurrently at promotion);
- widen a type.

These need two steps:
- dropping or renaming a table or column;
- narrowing a type;
- adding NOT NULL without a default.

First a change makes every unit stop using the column. The engine knows which units use it, from 4.8. Then the schema change goes through, and it is refused while any unit version a rollback could return to still uses the column. A rollback to such a version is refused too, with the reason.

**Backfills.** A backfill is a pure function over rows, declared in the schema unit. It runs in batches at promotion. Validation runs it on the snapshot and shows how many rows it would change, with samples. It is always held for a person.

### 4.10 Branches and previews

- A branch can have its own schema unit versions.
- A preview runs against live data: each request runs in a transaction with the branch's schema changes applied inside it, and everything is rolled back. A preview shows real data and keeps nothing, and says so on the page.
- Merging carries schema units like other units.

## 5. What this costs

- Postgres must run in development and production. Postgrex becomes a dependency.
- Replay does real database work. Validation time grows with the data each recorded call touches, not with the size of the database.
- The query language is smaller than SQL. Some pages need two reads where SQL would use one join.
- The engine gains a query evaluator for specs that must match Postgres on the operators it supports.

## 6. What this does not do yet

- Stemmed full-text search. Joins to another table's id (from the table or an earlier join), figures per group (count, sum, min, max, over joined rows too), substring conditions and word search ranked by occurrences are built (PLAN.md 7.24).
- Raw SQL from units.
- More than one Theseus node per app. The ledger lock still allows one instance.
- SQLite.

## 7. Alternatives considered

**Units call a store that writes immediately.** This is simpler for agents. But candidates could then write, so every write path would need its own rollback, and a retried request would write twice.

**Raw SQL with parameters.** Agents know SQL well. But the engine could not tell which columns a unit uses without parsing SQL, specs would need Postgres, and ordering would be up to each query.

**Keep server units and swap the snapshot file for a database table per unit.** This fixes durability and backups, but none of the other limits: all data stays in memory, saves still write whole states, and there are still no queries.

**Record each read's result in the trace and replay against those results.** This makes old calls replay exactly. But a proposed version that reads differently has nothing recorded to read. The snapshot approach handles that, and matches how server state is copied for replay today.

## 8. Build order

1. **Store core.** Database connection, schema units, reads, writes as data, request transactions with retry, request ids, specs in memory, static checks.
2. **Validation on real data.** Snapshot replay with two transactions, write-set comparison, write differences on the review page.
3. **Schema evolution.** One-step changes, two-step drops with the columns-in-use check, backfills, rollback refusal.
4. **Previews on live data.**

## 9. Decisions for you

1. Postgres only (recommended), or SQLite as well for development.
2. Queries as data (recommended), or raw SQL with parameters.
3. Writes returned as data, with no reading your own writes within one call (recommended), or writes as immediate calls.
4. Only endpoint units and the engine's callbacks into them use the store, and server units stay for in-memory coordination (recommended).
5. Destructive schema changes take two steps (recommended).
