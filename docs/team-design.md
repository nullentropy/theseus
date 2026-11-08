# Working on one Theseus app as a team

Status: decided 2026-10-19 (section 9). All five steps of section 8 are built.

## 1. What exists today

Theseus is built for one person directing agents on one machine.

- One running instance per ledger. The ledger lock refuses a second one.
- The MCP endpoint and the review site listen on 127.0.0.1 only.
- Any number of agents can connect over MCP at once. Each change records the name the agent's client gave itself, which proves nothing about who sent it.
- The review site has one reviewer token, printed at startup. Whoever opens that link may approve anything, and the ledger records only that "a human" did.
- Branches exist. A branch forks the app, takes its own changes, runs as a preview on its own port for 30 minutes, and merges back. A merge finds units changed on both sides and asks for a reconciled version.
- Two pending changes to the same unit on the same branch can both pass validation. Approving one makes the other stale: approving it is refused, and the agent has to propose again on top of the new version.

None of this stops two engineers working on one app. It does leave them unable to tell each other apart, approving their own work with no one else looking, and finding collisions only when an approval fails.

## 2. What a team needs

1. Know who proposed and who approved every change.
2. Work at the same time without waiting for each other.
3. Try work in progress without putting it in front of users.
4. Have someone other than the author approve what goes live.
5. Find out early when two people change the same thing, and settle it without starting over.
6. Keep production safe from work in progress.

People still never read code. Everything below works through intents, specs, evidence and review, as today.

## 3. The model: one app server, a branch per piece of work

The ledger stays the single source of truth, on one server that runs production. Engineers' agents connect to it over the network. Each piece of work happens on its own branch. Work reaches production through a merge that someone else approves.

In git terms: the ledger is both the repository and the deployment, a branch is a feature branch that can run, a merge is a pull request, and approval is the code review. The difference is that every change is validated against production's recorded traffic before anyone looks at it.

A server rather than a copy of the ledger per engineer:
- Validation replays production's recorded calls and, with the store, will read production data in rolled-back transactions. A copy goes stale, and copying production data to laptops is a privacy problem.
- Ledgers are histories of events. Two copies that diverged cannot be merged the way text files can.
- Branches, previews and merges already do the isolation a copy would give.

## 4. A day with two engineers

1. Ann asks her agent for a notes feature. The agent works on a new branch, `ann/notes`, forked from main. Its changes are validated against main's recorded calls.
2. Ann approves her own changes on her branch. Her branch is not production, so this is her fast loop.
3. Her branch has a preview at a fixed address while it is open. She and others can try it there.
4. Meanwhile Bob's agent works on `bob/reports`. The review site shows both branches, who owns each, and which units each one changes.
5. Ann merges into main. The merge becomes a held group. Bob, or the owner of a unit it touches, approves it. Validation runs the merged result against main's traffic first.
6. Bob's branch now shows that main moved. If Bob changed different units, nothing happens. If he changed different functions of one unit, the engine combines the two and validates the result (section 5.5). If he changed the same function, his agent proposes a reconciled version, as merges do today.
7. A crash fix lands on main directly, under the same review rules as today.

## 5. What to build

### 5.1 Who is who

- Engineers sign in to the review site with Google, the same sign-in apps already use. Roles: engineer, reviewer and admin, set by an admin.
- Each engineer creates MCP tokens on the review site, shown once, one per agent or machine. An MCP call without a valid token is refused.
- Every ledger event records the person as well as the actor: who proposed, who approved, who rolled back. The history page and get_change show names.
- The single reviewer token goes. A development instance on a laptop can keep a local mode with no sign-in.

### 5.2 Reaching the server

The MCP endpoint and review site are served over TLS on the server's address, normally behind the same proxy as the app. Tokens and sign-in replace "only from this machine". Previews get addresses of their own, such as `ann-notes.preview.example.com`.

### 5.3 Branches as workspaces

- A branch has an owner and a short description of what it is for.
- An MCP token can be tied to a branch, so an engineer's agent works there unless told otherwise.
- The review site's branch list shows each branch's owner, open changes, the units it changes, and whether main has moved since.
- A branch can be closed. A closed branch keeps its history and stops its preview.

### 5.4 Who may approve what

- On your own branch, you approve your own changes.
- On main, which is production, a change or merge needs approval from someone other than its proposer.
- Units can have owners, as files have in a CODEOWNERS file. A change to a unit's spec, a schema change, or a merge touching an owned unit also needs one of its owners.
- Automatic crash fixes and consolidations keep today's limits, and are listed for the team to see.
- These rules are settings, so a team of two can start with "someone else approves main" and add owners later.

### 5.5 Two people changing the same unit

Today the second approval is refused as stale. Three improvements:

1. **Combine by function.** A unit is a module of functions. When two changes start from the same version and change different functions, the engine combines them into one version (a three-way merge per function), validates it, and offers it in place of the stale change. The same applies to merges between branches. Only edits to the same function need a person or agent to reconcile them.
2. **Schema units combine as data.** Two branches that each add columns or tables produce a combined schema without anyone reconciling, because a schema is a literal map and only additions are allowed.
3. **Warn early.** list_units and get_unit say when a unit has pending changes or is changed on another open branch, and by whom. An agent can then coordinate, or pick a different unit, before writing anything. This is information, not a lock.

Small units keep collisions rare. The 200-line limit already pushes in that direction.

### 5.6 Trying work before it is live

- Each open branch can keep a preview running, restarted when the branch changes, instead of the 30-minute snapshot.
- Preview data is the open question (section 9). Either previews read production data in transactions that are always rolled back, which store phase 4 already plans, or they use a seeded set of made-up data so engineers do not see real people's records.

### 5.7 Sharing the server's capacity

Each validation starts a sandbox node, and each preview is a node too. With several engineers:
- validations queue, with each engineer getting a fair share so one busy agent cannot hold up everyone else;
- check_change and propose_change say where a change is in the queue;
- the number of running previews is capped, and the oldest idle one stops first.

Later, sandboxes and previews can run on other machines, so production does not share CPU with them.

### 5.8 Knowing what changed

The engine already sends email through the outbox. It can send its own notices too:
- a change is waiting for you to approve;
- your change was refused as stale, or combined (5.5);
- main moved under your branch;
- a crash on production started a repair.

Agents read the same through MCP: list_changes takes the engineer and the branch.

## 6. What does not change

- People review behaviour, specs and evidence, never code.
- Every change is validated before anyone sees it, on whatever branch.
- main is what runs in production, and the ledger records everything that happened to it.

## 7. Alternatives considered

**A ledger per engineer, synced.** Each engineer runs a copy and sends changes to a shared one. Rejected: validation would run against stale traffic and no production data, copies would hold personal data, and diverged event histories cannot be merged.

**A staging server between branches and production.** A second instance on a copy of production's ledger, where merges land first. This may become useful with more engineers, but branch previews already let people try work on production's traffic and data. It can be added later as a branch that follows main.

**Export source to git and review pull requests there.** This contradicts the premise that people review behaviour, not code. It also loses the validation evidence, which lives with the change.

## 8. Build order

1. **Identity and access.** Sign-in on the review site, MCP tokens, names on every event, TLS. Without this nothing else can be trusted. Built (PLAN.md 7.30).
2. **Approval rules.** Someone else approves main, then unit owners. Built (PLAN.md 7.30).
3. **Branch workspaces.** Owners, descriptions, tokens tied to branches, the branch list, and lasting previews. Built (PLAN.md 7.31), with made-up preview data from seed units and previews reached through the admin port.
4. **Collisions.** Combining by function, combining schemas, and early warnings. Built (PLAN.md 7.32).
5. **Capacity and notices.** The fair validation queue, the preview cap and notifications. Built (PLAN.md 7.33).

## 9. Decisions (2026-10-19)

1. One central app server, with a branch per piece of work.
2. Previews use made-up data by default, because production data would show every engineer real people's records. A setting lets a team whose engineers may all see production data preview on it, in transactions that are always rolled back.
3. Engineers approve their own changes on their own branches. Main still needs someone other than the proposer.
4. Unit owners must approve spec changes, schema changes and merges touching their units. An admin may override, as GitHub lets an admin bypass branch protection: the admin gives a reason, and the ledger records the override.
5. The engine combines edits to different functions of one unit, and validates the result. Only edits to the same function go back to a person or agent.
