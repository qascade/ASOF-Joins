# ASOF JOIN for PostgreSQL — Phase 1 & Phase 2 Work Plan

## Context

`CS631 Project Proposal.pdf` proposes adding **ASOF JOIN** to PostgreSQL. An ASOF join
matches each left row to the nearest right row by time (the latest quote at or before
each trade), optionally partitioned by an equality key. DuckDB, ClickHouse, Snowflake,
kdb+ and QuestDB support it; PostgreSQL does not. Today users hand-write
`LEFT JOIN LATERAL (... ORDER BY t DESC LIMIT 1) ON true`, which is verbose and slow
without a well-chosen index.

Target syntax:

```sql
SELECT ...
FROM trades t
ASOF LEFT JOIN quotes q
  MATCH_CONDITION (t.ts >= q.ts)
  ON t.symbol = q.symbol;
```

Two phases:

- **Phase 1 (MVP)** — parse the syntax, validate it, and rewrite it into an equivalent
  LATERAL join so the existing engine executes it unchanged.
- **Phase 2 (Native)** — make ASOF a real `JoinType` the planner understands, add a
  merge-based executor node that sorts both inputs once and walks them together, and
  surface it in `EXPLAIN`.

Decisions already made:

- Branch: **`REL_18_STABLE`** (PostgreSQL 18.6). The team settled on 18 rather than 17; the
  source is imported into this repo at upstream commit `1735ad5` (commit `ab480d4`).
- Split: **rotate layers across phases** — each person does parser-level work in one
  phase and planner/executor work in the other. Conflicts are concentrated in a few
  shared files and resolved by rebasing (AI assistance is fine for that).
- **ON-clause equality keys are in scope for both phases.** Phase 1 carries them as
  predicates inside the LATERAL subquery; Phase 2 uses them as the leading sort/merge
  columns.

Phase 0 is largely done: the PostgreSQL source is in the repo, the build is scripted
(`pgenv.sh`, `.vscode/tasks.json`) and `README.md` documents the Linux path. What remains
is continuous integration, a macOS build path, and the benchmark baseline. This file is the
source for the GitHub issues.

---

## People

| Tag | Name | Roll |
|-----|------|------|
| **A** | Deepjyoti Kakoti | 26M0774 |
| **B** | Debasish Bordoloi | 26M0776 |
| **C** | Shubh Karman Singh | 26M0843 |

Rotation:

| | Phase 1 | Phase 2 |
|---|---|---|
| **A** | Grammar & parse nodes | Executor node |
| **B** | Analyzer & LATERAL rewrite | Planner, paths & costing |
| **C** | Errors, tests, benchmark harness | EXPLAIN, node support, correctness suite |

Every PR gets one reviewer from the other two people. Reviewer is named per issue below.

---

## Repository & workflow

The PostgreSQL source tree **is** this repository --- it was imported at the root, not
vendored in a subdirectory and not kept as a fork:

```
ASOF-Joins/              # = the PostgreSQL 18.6 source tree
  src/ contrib/ doc/     # upstream, where our patches land
  docs/                  # proposal, study guide, design notes, measurements
  bench/                 # data generators, queries, results        (to be added, P0-3)
  .github/               # PR + issue templates, title-convention CI (build CI: P0-4)
  pgenv.sh               # per-clone env: PATH, PGDATA, PGPORT=9432
  .vscode/               # configure / build / initdb / psql tasks
  plan.md                # this file
  install/               # build output (gitignored)
```

Consequences of the monorepo choice:

- No fork to keep in sync, and no patch files: changes are ordinary commits on
  feature branches off `main`, merged by PR. Current branches: `main`, `add-docs`,
  `setup-github-ci`, `deepjyoti`, `debasish`, `feat/lateral_join_impl`.
- Upstream's own CI config (`.cirrus.yml`, `.cirrus.tasks.yml`) ships in the tree but needs
  a Cirrus CI account and GCP images, so we add GitHub Actions instead (P0-4) and leave the
  Cirrus files untouched.
- `git log` mixes upstream history with ours. Use `git log ab480d4..` to see only our work.
- **Titles follow Conventional Commits** --- `<type>(<scope>): <subject>`, e.g.
  `feat(parser): add ASOF and MATCH_CONDITION keywords`. Enforced on PR titles by
  `.github/workflows/conventional-title.yml` (blocking) and nudged on issue titles
  (advisory). We squash-merge, so the PR title becomes the commit subject on `main`.
  Types: `feat fix docs test perf refactor build ci chore revert`; scopes:
  `parser analyzer planner executor explain nodes bench docs ci build regress`.
- Issue forms live in `.github/ISSUE_TEMPLATE/` (`task.yml` for plan work, `bug.yml` for
  wrong results or crashes); the PR template asks for the layer, the approach and the
  `make check` summary.

Build (per `README.md`):

```sh
. ./pgenv.sh
./configure --prefix="$POSTGRES_INSTALLDIR" --enable-debug --enable-cassert \
            --without-icu CFLAGS='-O0 -g3'
make -j"$(nproc)" && make install
make check                       # must be green before any ASOF work starts
```

`--enable-cassert` is non-negotiable: it catches malformed parse/plan trees early.
`--without-icu` avoids an extra dependency; drop it if `make check` complains about
collations. The server runs on port **9432** so it never collides with a system PostgreSQL.

---

## Shared / hot files

These are the files more than one person touches. Owner listed is who merges first in
each phase; others rebase on top.

| File | Phase 1 owner | Phase 2 owner |
|---|---|---|
| `src/backend/parser/gram.y` | A | A |
| `src/include/parser/kwlist.h` | A | — |
| `src/include/nodes/primnodes.h` (`JoinExpr`) | A | A |
| `src/include/nodes/nodes.h` (`JoinType`) | — | B |
| `src/backend/parser/parse_clause.c` | B | B |
| `src/backend/optimizer/path/joinpath.c` | — | B |
| `src/test/regress/{sql,expected}/asof_join.sql/.out` | C | C |

---

# Phase 0 — Environment (5 issues)

P0-1 and P0-2 are **done**; they are recorded here for completeness. P0-3 to P0-5 are the
remaining setup work.

### P0-1 — Import PostgreSQL 18, build and run it locally · **A** · ✅ done (#1, #2)
- Source imported at `REL_18_STABLE` / `1735ad5`; `pgenv.sh` and `.vscode/tasks.json` added;
  `README.md` documents configure → build → `initdb` → server → `psql` on Linux.

### P0-2 — Study guide · **C** · ✅ done (#3)
- `docs/asof-join.tex` / `.pdf`: the operator, both phases, proofs, cost model, file map.

### P0-2b — PR/issue templates and title-convention CI · **C** · ✅ done
- `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/{task,bug,config}.yml`, and
  `.github/workflows/conventional-title.yml`.

### P0-3 — Benchmark dataset generator and baseline · **C** · review: A (issue #6)
- `bench/gen_data.sql` (or Python): `trades(symbol, ts, price, size)` and
  `quotes(symbol, ts, bid, ask)` generators at 1e5 / 1e6 / 1e7 rows, ~50 symbols,
  deterministic seed.
- `bench/baseline_lateral.sql`: the hand-written `LEFT JOIN LATERAL ... LIMIT 1` query,
  timed with and without `(symbol, ts DESC)` indexes.
- Record timings in `docs/bench-baseline.md` — this is the number Phase 1 and Phase 2
  are measured against.
- **Done when:** `make -C bench baseline` reproduces timings on a fresh checkout.

### P0-4 — GitHub Actions: build + `make check` on every PR · **C** · review: A (issue #4)
- `.github/workflows/ci.yml`: on `pull_request` and pushes to `main`, on `ubuntu-latest`,
  install build deps, `./configure --enable-debug --enable-cassert --without-icu`,
  `make -j$(nproc)`, `make check`.
- Upload `src/test/regress/regression.diffs` and `regression.out` as artifacts on failure —
  without them a red build says nothing.
- Cache the build (`ccache`) so PR feedback stays in single-digit minutes.
- Do not touch `.cirrus.*`; upstream's CI stays as it is.
- **Done when:** a PR shows a green check, and a deliberately broken test shows red with
  the diff downloadable.

### P0-5 — macOS build path in README · **A** · review: C (issue #5)
- The README covers Ubuntu (`apt`, `nproc`) only. Add a macOS section: Homebrew deps
  (`readline`, `bison`, `flex` — note Apple's bundled bison is too old for `gram.y`),
  `PATH` ordering for the keg-only tools, `sysctl -n hw.ncpu` in place of `nproc`, and any
  SDK/`CFLAGS` fixes needed.
- Verify end to end on a MacBook: configure → build → `initdb` → server → `psql` →
  `make check` green.
- **Done when:** a MacBook user can follow the README top to bottom without improvising.

---

# Phase 1 — MVP by query rewrite (9 issues, 3 each)

Goal: `ASOF [LEFT] JOIN ... MATCH_CONDITION (...) ON ...` parses, validates, and executes
with correct left-outer semantics by being rewritten to a LATERAL join. No planner or
executor changes.

## A — Grammar & parse nodes

### P1-A1 — Add `ASOF` and `MATCH_CONDITION` keywords · review: C
- Add both to `src/include/parser/kwlist.h` as **unreserved** keywords, and to the
  `unreserved_keyword:` production in `src/backend/parser/gram.y`.
- Verify no conflicts: `make -C src/backend/parser` must not emit new shift/reduce or
  reduce/reduce warnings (`gram.y` must stay at its baseline conflict count).
- Add a trivial test that `CREATE TABLE asof (match_condition int);` still works —
  unreserved means they remain legal identifiers.
- **Done when:** grammar builds clean and the identifier test passes.

### P1-A2 — `joined_table` productions for ASOF JOIN · review: B
- In `gram.y`, extend `joined_table` with `ASOF` variants:
  `table_ref ASOF opt_outer JOIN table_ref MATCH_CONDITION '(' a_expr ')' join_qual_opt`.
- Accept `ASOF JOIN` and `ASOF LEFT [OUTER] JOIN`; `ASOF RIGHT/FULL/CROSS` must be a
  parse error (handled in P1-C1, grammar just must not silently accept them).
- `MATCH_CONDITION` is mandatory in the grammar; `ON` is optional.
- **Done when:** the queries parse into a `JoinExpr` and `pg_parse_query` does not error
  on the four accepted shapes.

### P1-A3 — Extend `JoinExpr` with ASOF fields + node support · review: C
- In `src/include/nodes/primnodes.h` add to `JoinExpr`:
  `bool isAsof;` and `Node *matchCondition;` (the raw `MATCH_CONDITION` expression,
  later the transformed one).
- Regenerate node support: `src/backend/nodes/gen_node_support.pl` picks the fields up
  automatically for `copyfuncs`/`equalfuncs`/`outfuncs`/`readfuncs` — confirm the
  generated files under `src/backend/nodes/` include them.
- Deparse in `src/backend/utils/adt/ruleutils.c` `get_from_clause_item()` so a view
  defined over an ASOF join round-trips through `pg_get_viewdef`.
- **Done when:** `SELECT * FROM pg_get_viewdef('v')` reproduces the ASOF syntax, and
  `make check` on `rules`/`create_view` passes.

## B — Analyzer & LATERAL rewrite

### P1-B1 — Transform and validate the MATCH_CONDITION in the analyzer · review: A
- In `src/backend/parser/parse_clause.c`, in `transformFromClauseItem()` for `JoinExpr`,
  transform `matchCondition` with `transformExpr(..., EXPR_KIND_JOIN_ON)`.
- Enforce shape: exactly one top-level `OpExpr` whose operator is one of `>=`, `>`,
  `<=`, `<`; left operand must reference only the left relation, right operand only the
  right relation (use `pull_varnos` against the respective `nsitems`).
- Require the operand types be comparable with a btree opfamily for that operator
  (`get_ordering_op_properties` / `op_mergejoinable`-style lookup) — Phase 2 needs it,
  so reject early.
- **Done when:** valid conditions transform; the invalid shapes listed in P1-C1 reach the
  error paths with the right `errcode`.

### P1-B2 — Rewrite ASOF JoinExpr into a LATERAL join · review: C
- New file `src/backend/parser/parse_asof.c` (+ `parse_asof.h`), called from
  `transformFromClauseItem()`, that rewrites

  ```sql
  left ASOF LEFT JOIN right MATCH_CONDITION (l.ts >= r.ts) ON l.k = r.k
  ```
  into the equivalent of
  ```sql
  left LEFT JOIN LATERAL (
      SELECT * FROM right
      WHERE right.ts <= left.ts AND right.k = left.k
      ORDER BY right.ts DESC
      LIMIT 1
  ) ON true
  ```
- Build it as a parse-tree rewrite (`RangeSubselect` over the right `table_ref` with
  `lateral = true`), *before* transformation, so the existing analyzer handles the rest.
  This keeps the change small and reuses all existing LATERAL machinery.
- Sort direction and the `WHERE` comparison flip with the operator:
  `>=`/`>` → `ORDER BY r.ts DESC`, `<=`/`<` → `ORDER BY r.ts ASC`; strict operators drop
  the equality case.
- Equality keys from `ON` move into the subquery `WHERE`; anything in `ON` that is not a
  plain left/right equality is an error (P1-C1).
- **Done when:** the four operators × {with keys, without keys} all return the same rows
  as the hand-written baseline query.

### P1-B3 — Left-outer vs inner semantics and NULL handling · review: A
- `ASOF LEFT JOIN`: left rows with no match emit NULL-extended right columns — falls out
  of `LEFT JOIN LATERAL`.
- `ASOF JOIN` (inner): drop unmatched left rows — `JOIN LATERAL ... ON true`.
- NULLs in the match column: a NULL `ts` on either side never matches (the comparison is
  NULL → row filtered). Document and test that NULL equality keys likewise never match,
  matching `=` semantics.
- Verify behaviour when the right side has **ties** on `ts`: `LIMIT 1` picks an arbitrary
  one; document this as implementation-defined and keep Phase 2 consistent with it.
- **Done when:** `docs/semantics.md` states the rules and each has a regression test.

## C — Errors, tests, benchmark

### P1-C1 — Clear error messages for invalid ASOF queries · review: B
- `ereport(ERROR, ...)` with `ERRCODE_SYNTAX_ERROR` / `ERRCODE_FEATURE_NOT_SUPPORTED`
  and a `parser_errposition()` for each of:
  - missing `MATCH_CONDITION`
  - match condition that is not a single `>=`/`>`/`<=`/`<` comparison
  - match condition referencing both sides on one operand, or neither side
  - non-comparable / non-btree-orderable operand types
  - `ON` clause containing anything other than left-to-right equalities
  - `ASOF RIGHT/FULL/CROSS JOIN`
  - `ASOF ... USING (...)`
- Each message needs a `errhint()` where there is an obvious fix.
- **Done when:** every case above has a regression test with stable `expected` output.

### P1-C2 — Regression suite `asof_join` · review: A
- `src/test/regress/sql/asof_join.sql` + `expected/asof_join.out`, registered in
  `src/test/regress/parallel_schedule`.
- Coverage: all four operators; inner vs left; with/without equality keys; empty right
  side; all-NULL match column; duplicate timestamps; multi-key `ON`; ASOF under a CTE,
  a subquery and a view; `pg_get_viewdef` round-trip.
- Every test asserts equality against the hand-written LATERAL form, so the suite stays
  valid for Phase 2 (`EXCEPT`-based equivalence checks, not hard-coded row dumps, where
  practical).
- **Done when:** `make check` green with the new suite in the schedule.

### P1-C3 — Phase 1 benchmark vs baseline + docs · review: B
- Run `bench/` queries against the MVP; compare to the P0-3 hand-written baseline
  (expectation: parity, since it is the same plan — any gap is a rewrite bug).
- Confirm the rewrite benefits from a `(symbol, ts DESC)` index exactly as the manual
  form does; capture `EXPLAIN (ANALYZE, BUFFERS)` for both.
- Write `doc/src/sgml/ref/select.sgml` documentation for the new syntax, and
  `docs/phase1-report.md` with numbers and plan output.
- **Done when:** report committed and `make docs` builds.

---

# Phase 2 — Native ASOF join (9 issues, 3 each)

Goal: ASOF is a real join type with its own path, plan and executor node; both inputs are
sorted once and merged in a single pass; `EXPLAIN` shows it. The Phase 1 rewrite stays in
the tree behind a GUC so we can benchmark one against the other.

## B — Planner, paths & costing

### P2-B1 — `JOIN_ASOF` join type and parse/plan plumbing · review: A
- Add `JOIN_ASOF` (and `JOIN_ASOF_LEFT`, or carry outer-ness in a flag — pick one and
  document it) to `JoinType` in `src/include/nodes/nodes.h`.
- Stop rewriting to LATERAL when the new GUC `enable_asofjoin` is on; instead produce a
  `JoinExpr` with `jointype = JOIN_ASOF` and a transformed `matchCondition` that reaches
  the planner.
- Touch every `switch (jointype)` the compiler flags — `parse_clause.c`,
  `prepjointree.c`, `joinrels.c`, `analyzejoins.c`, `costsize.c`, `explain.c`,
  `ruleutils.c`. Build with `-Wswitch` to find them all.
- Join legality: ASOF is order-sensitive, so it must not be commuted or reassociated —
  handle it in `join_is_legal()` / `make_join_rel()` the way `JOIN_LEFT` restrictions are
  handled, and add it to `have_join_order_restriction()`.
- **Done when:** a planner-reachable ASOF query reaches `add_paths_to_joinrel` with the
  new jointype and asserts stay quiet under `--enable-cassert`.

### P2-B2 — `AsofPath` generation in `joinpath.c` · review: C
- In `src/backend/optimizer/path/joinpath.c`, add an `asof_path` branch to
  `add_paths_to_joinrel()` that is the *only* path type offered for `JOIN_ASOF`
  (no hash, no nestloop).
- Required pathkeys: equality keys first, match column last — build them with
  `build_join_pathkeys` / `make_pathkeys_for_sortclauses`-style helpers, then wrap each
  input in `create_sort_path()` when the child path is not already sorted that way.
- Prefer an existing index ordering: if the inner rel has a path whose pathkeys match the
  required prefix, use it and skip the sort. This is where the native join beats the MVP.
- New `create_asofjoin_path()` in `src/backend/optimizer/util/pathnode.c`, modelled on
  `create_mergejoin_path()`.
- **Done when:** `EXPLAIN` shows the ASOF path chosen, with sorts only where needed.

### P2-B3 — Cost model and `enable_asofjoin` GUC · review: A
- `initial_cost_asofjoin` / `final_cost_asofjoin` in
  `src/backend/optimizer/path/costsize.c`: single pass over both inputs, so
  `startup = sort costs`, `total ≈ startup + (outer_rows + inner_rows) * cpu_tuple_cost`
  plus requal/match-condition evaluation. No rescan term — unlike merge join there is no
  mark/restore backtracking for non-unique keys unless we support ties.
- Selectivity: ASOF LEFT produces exactly `outer_rows`; ASOF inner produces
  `outer_rows * (fraction with a match)` — estimate from the match column's histogram
  overlap between the two relations.
- Add `enable_asofjoin` (default `on`) in `src/backend/utils/misc/guc_tables.c` and
  `postgresql.conf.sample`; `off` falls back to the Phase 1 LATERAL rewrite. This is the
  switch the final benchmark flips.
- **Done when:** costs are sane on the 1e6-row dataset (native < MVP) and the GUC
  toggles cleanly in one session.

## A — Executor

### P2-A1 — `AsofJoin` plan node and plan creation · review: C
- Add `AsofJoin` to `src/include/nodes/plannodes.h` (embedding `Join`, plus
  `matchCondition` and the ordering operator/collation/`nullsFirst` arrays, mirroring
  `MergeJoin`'s `mergeFamilies`/`mergeStrategies` fields).
- `create_asofjoin_plan()` in `src/backend/optimizer/plan/createplan.c`, modelled on
  `create_mergejoin_plan()`: resolve the sort operators for the equality keys and the
  match column, and set `outersortkeys`/`innersortkeys`.
- Register the tag in `src/backend/executor/execProcnode.c`,
  `src/backend/executor/execAmi.c` (`ExecReScan`), and `nodeTag` dispatch in
  `src/backend/nodes/`; regenerate node support.
- **Done when:** the plan tree builds and `EXPLAIN` prints the node (label comes from
  P2-C1) without crashing at executor startup.

### P2-A2 — `nodeAsofjoin.c` — the merge-based executor · review: B
- New `src/backend/executor/nodeAsofjoin.c` + `src/include/executor/nodeAsofjoin.h`,
  starting from `nodeMergejoin.c`'s state-machine shape.
- Algorithm, both inputs sorted on `(keys..., match_col)`:
  1. Advance inner while `inner.key < outer.key`, or while keys are equal and
     `inner.ts` still satisfies the match condition — remembering the **last** tuple that
     satisfied it in a dedicated `candidateSlot` (an `ExecCopySlot`, not a pointer, since
     the inner slot is overwritten).
  2. When the inner tuple passes the boundary, emit `outer ⋈ candidate` if a candidate
     exists for the current key, else NULL-extend (left) or skip (inner).
  3. On key change, reset the candidate. One pass, O(n + m) after sorting.
- Mark/restore is not needed — the candidate buffer replaces it — but reverse the
  comparison direction for `<=`/`<` so ascending-ordered inputs work for both families.
- `AsofJoinState` in `src/include/nodes/execnodes.h`: candidate slot, per-key compare
  `FmgrInfo`s / `SortSupport`, match-condition `ExprState`, matched flag.
- **Done when:** the Phase 1 regression suite passes with `enable_asofjoin = on`,
  producing byte-identical output to the MVP.

### P2-A3 — Executor hardening: rescan, memory, parallel safety · review: C
- `ExecReScanAsofJoin()` resets the candidate slot and both child scans; test under a
  nested loop / correlated subquery and a `LATERAL` outer reference.
- Candidate tuple lives in its own `ExprContext` / tuple slot that is reset per key group
  — verify with `valgrind` or at least a long-running 1e7-row query that memory is flat.
- Mark the node parallel-unsafe initially (ordered single-pass over a shared inner is not
  trivially parallelisable) and assert that in the planner; note the follow-up in docs.
- Stress: 1e7 rows, 50 keys, inner much larger than outer and vice versa, inner empty,
  outer empty, all keys matching one group.
- **Done when:** no leaks, no crashes under `cassert`, rescan tests in the suite.

## C — EXPLAIN, node support, correctness

### P2-C1 — `EXPLAIN` output for ASOF joins · review: B
- `src/backend/commands/explain.c`: add the `JOIN_ASOF` arm to the join-type label
  switch so plans read `Asof Join` / `Asof Left Join`.
- Print the match condition as its own line (`Match Condition: (t.ts >= q.ts)`) and the
  equality keys as `Asof Keys:`, following how `Merge Cond:` is emitted; wire the
  corresponding `TEXT`/`JSON`/`YAML`/`XML` output paths.
- Under `ANALYZE`, report rows matched vs NULL-extended (useful for the report, and cheap
  to count in the executor).
- **Done when:** `explain` regression tests cover text and JSON formats.

### P2-C2 — Node-support, serialization and deparse round-trips · review: A
- Confirm `gen_node_support.pl` output covers `JOIN_ASOF`, `AsofJoin` and the extended
  `JoinExpr` — `copyObject`, `equal`, `outNode`/`readNode` must all round-trip.
- Test the paths that actually serialize plans: prepared statements + `plan_cache_mode =
  force_generic_plan`, `pg_stat_statements` normalisation, and a view/rule containing an
  ASOF join.
- Verify `pg_get_viewdef` still emits ASOF syntax now that the rewrite no longer happens
  in the parser.
- **Done when:** `make check-world` passes, including `rules`, `create_view` and
  `pg_stat_statements` contrib tests.

### P2-C3 — Native-vs-MVP correctness and benchmark report · review: B
- Differential test harness: run the whole `bench/` and regression query corpus twice,
  with `enable_asofjoin` `on` and `off`, and diff the results. Any difference is a bug.
- Add randomized comparison: generated tables, random operator/key/NULL-density, compare
  native output against the LATERAL baseline (a small `pg_regress`-driven or TAP test
  under `src/test/modules/`).
- Final benchmark at 1e5 / 1e6 / 1e7 rows: native vs MVP vs hand-written LATERAL, with
  and without indexes; plot and write `docs/phase2-report.md` with `EXPLAIN (ANALYZE)`
  for each.
- **Done when:** zero diffs across the corpus and the report is committed — this is the
  deliverable the proposal's goal 5 asks for.

---

## Issue summary (for GitHub)

| ID | Title | Owner | Reviewer | Labels |
|---|---|---|---|---|
| P0-1 | Import PostgreSQL 18, build and run it locally | A | B | ✅ done (#1, #2) |
| P0-2 | Study guide (`docs/asof-join.tex`) | C | A | ✅ done (#3) |
| P0-2b | PR/issue templates + title-convention CI | C | — | ✅ done |
| P0-3 | `perf(bench)`: dataset generator and baseline (#6) | C | A | `phase-0`, `benchmark` |
| P0-4 | `ci`: build + `make check` on every PR (#4) | C | A | `phase-0`, `ci` |
| P0-5 | `docs`: macOS build path in README (#5) | A | C | `phase-0`, `documentation` |
| P1-A1 | Add `ASOF`/`MATCH_CONDITION` keywords | A | C | `phase-1`, `parser` |
| P1-A2 | `joined_table` productions for ASOF JOIN | A | B | `phase-1`, `parser` |
| P1-A3 | Extend `JoinExpr` + node support + deparse | A | C | `phase-1`, `parser`, `nodes` |
| P1-B1 | Transform and validate MATCH_CONDITION | B | A | `phase-1`, `analyzer` |
| P1-B2 | Rewrite ASOF JoinExpr into a LATERAL join | B | C | `phase-1`, `analyzer` |
| P1-B3 | Left-outer semantics and NULL handling | B | A | `phase-1`, `analyzer` |
| P1-C1 | Clear errors for invalid ASOF queries | C | B | `phase-1`, `errors` |
| P1-C2 | Regression suite `asof_join` | C | A | `phase-1`, `tests` |
| P1-C3 | Phase 1 benchmark + SGML docs | C | B | `phase-1`, `benchmark`, `docs` |
| P2-B1 | `JOIN_ASOF` join type and plan plumbing | B | A | `phase-2`, `planner` |
| P2-B2 | `AsofPath` generation in `joinpath.c` | B | C | `phase-2`, `planner` |
| P2-B3 | Cost model and `enable_asofjoin` GUC | B | A | `phase-2`, `planner` |
| P2-A1 | `AsofJoin` plan node and plan creation | A | C | `phase-2`, `executor` |
| P2-A2 | `nodeAsofjoin.c` merge-based executor | A | B | `phase-2`, `executor` |
| P2-A3 | Executor hardening: rescan, memory, parallel | A | C | `phase-2`, `executor` |
| P2-C1 | `EXPLAIN` output for ASOF joins | C | B | `phase-2`, `explain` |
| P2-C2 | Node-support and deparse round-trips | C | A | `phase-2`, `nodes`, `tests` |
| P2-C3 | Native-vs-MVP correctness and final report | C | B | `phase-2`, `benchmark`, `docs` |

Totals: 7--8 issues per person (Phase 0 setup, 3 in Phase 1, 3 in Phase 2), and every person
writes parser-layer code in one phase and planner-or-executor code in the other.

## Dependencies

```
P0-1 ✅─┬─> P1-A1 ──> P1-A2 ──> P1-A3
        │                 └────> P1-B1 ──> P1-B2 ──> P1-B3
P0-4 ───┘                             └──> P1-C1 ──> P1-C2 ──> P1-C3
P0-3, P0-5 ────────────────────────────────────────────────────┘

P1-* ──> P2-B1 ──> P2-B2 ──> P2-B3
              └──> P2-A1 ──> P2-A2 ──> P2-A3
                        └──> P2-C1
         P2-A2, P2-B2 ──> P2-C2 ──> P2-C3
```

Critical path: P1-A2 → P1-B2 → P2-B1 → P2-A1 → P2-A2 → P2-C3. P2-A1 is the hand-off
point where A picks up the executor, so B should land P2-B1 before the Phase 2 midpoint.

---

## Verification

Per-PR, before review:

```sh
cd postgres
make -j8 && make install
make check                              # core regression, includes asof_join
make -C src/test/regress check          # if iterating on just the suite
```

Phase gates:

- **Phase 1 done:** `make check-world` green; every query in `bench/` returns rows
  identical to the hand-written LATERAL baseline; errors from P1-C1 all covered;
  `make docs` builds the new `select.sgml` text.
- **Phase 2 done:** `make check-world` green with `enable_asofjoin` both `on` and `off`;
  the differential harness (P2-C3) reports zero diffs across the full corpus;
  `EXPLAIN (ANALYZE)` shows `Asof Join` with sorts eliminated where an index supplies the
  ordering; native beats the MVP measurably at 1e6 and 1e7 rows, documented in
  `docs/phase2-report.md`.

Manual smoke test for any ASOF change:

```sql
SET enable_asofjoin = on;
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.symbol, t.ts, t.price, q.bid, q.ask
FROM trades t
ASOF LEFT JOIN quotes q MATCH_CONDITION (t.ts >= q.ts) ON t.symbol = q.symbol
ORDER BY t.ts
LIMIT 20;
```
