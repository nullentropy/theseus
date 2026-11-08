# More than one Theseus node per app

Status: decided 2026-11-05 with the recommendations in section 6 (availability first; the ledger in Postgres when a database is set; Erlang distribution between nodes allowed). All three steps of section 4 are built (PLAN.md 7.2): the ledger in Postgres, a standby that takes over, and followers that serve the app's traffic (`Theseus.Leader`). Differences from this document: a follower forwards its whole admin port (the review page, proposals, approvals and MCP) to the leader's, one request at a time; it also reads the ledger table every 500 ms, to catch a `NOTIFY` missed while reconnecting; shadow runs take every node's live calls; the leader checks the session that holds its lock every second and stops its ledger when the session is gone, and there is no boot checkpoint: a new leader reads every row, which takes 123 ms for an 8.6 MB ledger, and compaction works on the table to keep it bounded.

## 1. Where things stand

One app runs on one node. `Theseus.LedgerLock` refuses a second instance, because two nodes writing one ledger file, outbox or state file would corrupt them.

The app's data is already in Postgres (`Theseus.Store`), and so are the engine's records when a database is set (`Theseus.Records`). What still ties an app to one node:

- **The ledger** is one file on one disk, written by one process.
- **Server units** keep their state in one process. Two copies on two nodes would drift apart.
- **Work that must happen once:** ticks (`Theseus.Ticker`), sending messages (`Theseus.Outbox`), crash repair (`Theseus.Trigger`), rewrites (`Theseus.Consolidate`), combining stale changes (`Theseus.Combine`), the validation queue (`Theseus.Queue`), shadow runs (`Theseus.Shadow`) and previews (`Theseus.Previews`).
- **Recorded calls** (`Theseus.Traces`) are a file per node. Replay uses them.

## 2. What has to stay true

1. **One history.** Every node runs a fold of the same ledger. A version promoted on one node is the version every node runs, within seconds.
2. **Once means once.** A tick, a message or a repair happens on one node only.
3. **Server units have one state.** There is one process per server unit, wherever it runs.
4. **Losing a node loses nothing written.** Another node carries on from the database.

## 3. The design in brief

All nodes serve HTTP. One node, the leader, does everything that must happen once and runs the server units. The others are followers.

- **The ledger moves into Postgres** when a database is set: an append-only table `_theseus_ledger` (`seq`, `payload`) holding the same records as the file. Only the leader appends. Followers read new rows when notified (`LISTEN`/`NOTIFY`), fold them as boot does, and hot-load promoted versions. Beams are rows too. Without a database, the app stays on one node with the file, as now.
- **The leader** holds a Postgres advisory lock for as long as its connection lives. It replaces `Theseus.LedgerLock` when a database is set. If the leader dies, its lock goes with its connection, and the first follower to take the lock becomes the leader. It reads any ledger rows it missed, starts the server units from their saved state (`Theseus.State` already keeps that in Postgres), and starts the once-only work.
- **Followers** run endpoint, store and pure units locally. A call to a server unit goes to the leader over Erlang distribution, by name, through `Theseus.call/3`, which already records calls. Proposals, approvals and MCP requests on a follower go to the leader.
- **Recorded calls** stay per node, and the leader asks followers for theirs when it builds a replay set. A follower that is gone contributes nothing, which only makes the replay set smaller.

## 4. Build order

1. **Ledger in Postgres, one node.** The same fold, read from the table. Import an existing file once, as `Theseus.Records` does. This also bounds boot: the leader can keep a checkpoint row of the folded tables and read only the rows after it.
2. **Leader lock and failover.** A second node waits as a standby and takes over when the leader's lock frees. This gives availability with no change to how calls run.
3. **Followers serve traffic.** Endpoint units on every node, server unit calls routed to the leader, ledger tailing and hot loading on followers, and replay sets gathered from every node.

Each step is useful alone. Step 2 is what most apps need. Step 3 matters only when one node cannot serve the traffic.

## 5. What this costs

- Nodes must reach each other over Erlang distribution, with a shared cookie, and over TLS when they are not on one private network. Today the engine never runs distributed.
- A server unit call from a follower takes a network round trip.
- Hot loading on followers has a window, at most a few seconds, where two nodes run different versions of a unit. A request may see the old version on one node just after another node answered with the new one. Replay and shadow runs already run on the leader, so validation is unaffected.
- A leader change takes as long as reading the ledger rows since the checkpoint and restoring server unit state: seconds for a small app.

## 6. Decisions for you

1. **What do you need: availability or capacity?** I recommend building steps 1 and 2 now (a standby that takes over), and step 3 only when one node is not enough.
2. **When a database is set, does the ledger always live in Postgres** (recommended), or stay a file unless asked? Postgres makes backups and failover one system. A file stays easy to copy and inspect.
3. **May the engine run Erlang distribution between its nodes?** Step 3 needs it. Steps 1 and 2 do not: a standby only watches the lock.
