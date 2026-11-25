# ASOF-Joins
Custom implementation ASOF joins in postgres


# Building and Running PostgreSQL

Steps to build and run PostgreSQL after cloning this repo.

## 1. Install prerequisites

**Linux (Debian/Ubuntu)**

```bash
sudo apt install build-essential gdb bison flex libreadline-dev zlib1g-dev
```

**macOS**

```bash
xcode-select --install          # clang, make, flex, readline
brew install bison m4           # bison 3.8+ and the m4 it needs
```

Apple ships bison 2.3 (from 2006), which builds PostgreSQL but is useless for the grammar
work ahead of us. `pgenv.sh` puts Homebrew's bison and m4 on `PATH` for you, so there is
nothing to add to your shell profile. See [macOS notes](#macos-notes) for why.

In VS Code, install the **C/C++** extension (`ms-vscode.cpptools`).

## 2. Open the repo in VS Code

Open the repo root folder, which is the one containing `.vscode/` and `pgenv.sh`.

## 3. Build (first time)

Run these in order. Run a task with **Ctrl+Shift+P → Tasks: Run Task**.

1. **`pg: configure (one-time)`**
2. **`pg: build`**. Ctrl+Shift+B also runs it. The first build takes a few minutes.
3. **`pg: initdb + createdb test (one-time)`**

Everything is installed into `install/` inside the repo. The database runs on port **9432**.

## 4. Run

**Single-user mode (with debugger)**
Open **Run and Debug (Ctrl+Shift+D)**, select **`pg: single-user (debug)`**, and press **F5**.
This rebuilds, then opens a terminal where you can type SQL. Press **Ctrl+D** to exit.

**Server mode**
1. Run the task **`pg: start server`**.
2. Run the task **`pg: psql`** to open a client.
3. Run the task **`pg: stop server`** when you're done.

After changing code, run **`pg: rebuild + restart server`**.

## Without VS Code

```bash
. ./pgenv.sh
./configure --prefix="$POSTGRES_INSTALLDIR" --enable-debug --enable-cassert --without-icu CFLAGS='-O0 -g3'
make -j$(nproc) && make install          # macOS: make -j$(sysctl -n hw.ncpu)
initdb -D "$PGDATA"
pg_ctl -l "$POSTGRES_INSTALLDIR/logfile" start
createdb test
psql test
```

Run `. ./pgenv.sh` in every new terminal before using any PostgreSQL commands.

## ASOF JOIN

This fork adds an `ASOF JOIN`, which matches each left row to the nearest right row by
time instead of by equality — the latest quote at or before each trade, per symbol.

```sql
SELECT t.sym, t.ts, q.bid
FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
```

The `ON` clause holds the usual equality keys plus **exactly one** inequality
(`>=`, `>`, `<=` or `<`) between a column of the right table and an expression over the
left. That inequality decides which direction "nearest" means. `ASOF LEFT JOIN` keeps left
rows with no match and fills the right columns with NULL; `ASOF JOIN` drops them.

Today it is implemented by rewriting the query into an equivalent
`LEFT JOIN LATERAL (... ORDER BY ts DESC LIMIT 1)` during parse analysis, so it performs
exactly like the hand-written form. Phase 2 adds a native sort-merge join and a setting to
choose between the two. See `docs/lateral-rewrite.pdf` for how the rewrite works, and
`docs/asof-join.pdf` for the operator itself.

### Performance today

Phase 1 is a rewrite, not a new algorithm, so it performs **exactly** like the hand-written
LATERAL query — the planner receives the same tree and produces the same plan. Both forms
of the bulk query produce byte-identical plans:

```
Nested Loop Left Join
  ->  Seq Scan on big_trades t
  ->  Limit
        ->  Index Only Scan Backward using big_quotes_sym_ts on big_quotes q
              Index Cond: ((sym = t.sym) AND (ts <= t.ts))
```

#### What was measured

The same two queries, run against the same data, one after the other:

```sql
-- A: the new syntax
SELECT t.tid, q.ts FROM big_trades t
ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;

-- B: what people write today
SELECT t.tid, q.ts FROM big_trades t
LEFT JOIN LATERAL (
    SELECT q.ts FROM big_quotes q
    WHERE q.sym = t.sym AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1) q ON true;
```

Data is `big_trades` and `big_quotes` from `test.sql`: 50,000 trades and 200,000 quotes
over 55 and 50 symbols respectively, so five symbols have trades but no quotes. Generated
from a fixed seed, so every run uses identical rows. Index on `(sym, ts)` present on both
tables, and `ANALYZE` run before timing.

Each numbered run is one execution of A followed by one of B — the same pair repeated five
times, to see how much the machine alone varies the answer. Row counts matched (50,000) and
the two result sets were compared with `EXCEPT ALL` in both directions after every run;
they were identical every time.

| Run | A: `ASOF JOIN` | B: hand-written LATERAL |
|---|---|---|
| 1 | 1924.3 ms | 1873.4 ms |
| 2 | 1870.3 ms | 1853.0 ms |
| 3 | 2101.7 ms | 1951.8 ms |
| 4 | 1935.0 ms | 2037.2 ms |
| 5 | 1876.7 ms | 1903.5 ms |
| **median** | **1924.3 ms** | **1903.5 ms** |

#### Reading the numbers

A is 21 ms slower than B at the median — about 1%. That difference means nothing, because
the same query varies more than that against itself: A's own runs range from 1870 to 2102
ms, a spread of 232 ms. In run 3 A was slower than B, in run 4 it was faster. The machine
alone moves the number around more than the two queries differ from each other.

That is the expected and desired result: A and B are the same plan, so they should take the
same time. It also sets a floor for later benchmarking — on this machine a single run has to
differ by roughly 10% before it means anything at all.

Measured on macOS 14.5, Apple silicon, PostgreSQL 18.6 built with
`--enable-cassert CFLAGS='-O0 -g3'` and `work_mem = 4MB`. **Assertions make this build
several times slower than a release build**; both sides are affected equally, so the
comparison holds, but the absolute numbers are not representative. Reproduce with
`psql -X -f test.sql`, which prints `debug_assertions` and `work_mem` before the timings for
exactly this reason.

Phase 2 replaces the per-row index search with a single sorted pass over both inputs, which
is where an actual speedup comes from — most of all when no suitable index exists, since
the plan above then degrades to a sort per left row.

### Testing it

`test.sql` is a self-checking harness: it runs each ASOF query alongside an equivalent
hand-written LATERAL query and prints PASS or FAIL per case.

```bash
. ./pgenv.sh
createdb asoftest
psql -d asoftest -X -f test.sql
```

It covers all four inequality directions, left and inner, other key and time types, empty
inputs, and a 50k x 200k bulk case that also reports timings. Data is seeded, so rows and
diffs are identical on every run. Timings are only comparable against runs with the same
build and settings, which is why the script prints `debug_assertions` and `work_mem` first
— an assertions-enabled build is several times slower.

## Demo (about 10 minutes)

### Setup

```bash
cd "<repo>"
. ./pgenv.sh
pg_ctl start -l install/server.log      # skip if already running
psql -X -d postgres
```

Paste the blocks below into `psql` one at a time. To run the whole thing at once
instead, use `psql -X -d postgres -f demo.sql` (about 20 seconds).

The `EXPLAIN` for each step is in the
[Appendix](#appendix-explain-for-each-step) under the same step number.

### 0. Start clean

```sql
\pset null '(null)'
SET enable_asofjoin_native = on;
DROP TABLE IF EXISTS trades, quotes, big_trades, big_quotes;
```

### 1. Tables

```sql
CREATE TABLE trades (sym text, ts int, qty int);
CREATE TABLE quotes (sym text, ts int, price int);
INSERT INTO trades VALUES ('A', 5, 100), ('A', 9, 50), ('B', 3, 70), ('B', 8, 40);
INSERT INTO quotes VALUES ('A', 2, 10), ('A', 4, 11), ('A', 7, 12), ('B', 6, 20), ('B', 10, 21);
TABLE trades;
TABLE quotes;
```

For each trade we want the latest quote of the same symbol at or before the trade
time. Trade (B,3) comes before every B quote. Trade (B,8) sits between the B quotes at 6
and 10.

### 2. LEFT ASOF JOIN

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;
```

| trade | gets quote | why |
|---|---|---|
| (A,5) | 4 | latest A quote at or before 5 |
| (A,9) | 7 | latest A quote at or before 9 |
| (B,3) | NULL | no B quote at or before 3 |
| (B,8) | 6 | quote 10 is later than 8, so it is skipped |

### 3. INNER ASOF JOIN

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;
```

Look for: 3 rows. (B,3) is dropped because it has no match.

### 4. Comparisons

First add a quote at exactly time 9, so trade (A,9) has a tie.

```sql
INSERT INTO quotes VALUES ('A', 9, 13);
```

`>=`: latest quote at or before the trade. (A,9) gets 9, so a tie is allowed.

```sql
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts ORDER BY 1, 2;
```

`>`: latest quote strictly before. (A,9) now gets 7.

```sql
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts > q.ts ORDER BY 1, 2;
```

`<=`: earliest quote at or after, so the join looks forward in time. (B,3) now gets 6,
and (B,8) gets 10.

```sql
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts <= q.ts ORDER BY 1, 2;
```

### 5. WHERE versus ON

`WHERE` finds the latest quote first, then keeps the row only if that quote's price is
above 11. Two rows survive: (A,9) with quote 9 and (B,8) with quote 6.

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts WHERE q.price > 11 ORDER BY 1, 2;
```

In `ON`, the price condition is applied first, so the join finds the latest quote whose
price is above 11. All four trades stay. (A,5) gets NULLs, because its earlier quotes
cost 10 and 11.

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND q.price > 11 ORDER BY 1, 2;
```

### 6. Errors

No inequality in the `ON` clause. The error says so and gives a hint.

```sql
SELECT * FROM trades t ASOF JOIN quotes q ON t.sym = q.sym;
```

RIGHT and FULL ASOF joins are not supported.

```sql
SELECT * FROM trades t RIGHT ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

### 7. Larger tables

200,000 trades and 200,000 quotes over 50 symbols.

```sql
CREATE TABLE big_quotes AS
  SELECT 'S' || (g % 50) AS sym, (g * 7919) % 1000000 AS ts, g % 1000 AS price
  FROM generate_series(1, 200000) g;
CREATE TABLE big_trades AS
  SELECT 'S' || (g % 50) AS sym, (g * 7907) % 1000000 AS ts, g % 100 AS qty
  FROM generate_series(1, 200000) g;
ANALYZE big_quotes, big_trades;
```

### 8. When an index removes the sort, and when it does not

The join needs each input sorted by the key, then the time:

- for `>=` and `>`: `sym ASC, ts ASC NULLS LAST`
- for `<=` and `<`: `sym ASC, ts DESC NULLS LAST`

The planner skips a Sort only when an index already gives exactly that order.

#### 8a. No index: both inputs are sorted

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

Look for: two `Sort` nodes over `Seq Scan`, and the `Execution Time` (about 2 s on our
debug build).

#### 8b. Btree on (sym, ts) with `>=`: no sorts

A plain btree is `ASC NULLS LAST`, which is exactly what `>=` needs.

```sql
CREATE INDEX bq_i ON big_quotes (sym, ts);
CREATE INDEX bt_i ON big_trades (sym, ts);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

Look for: two `Index Scan` nodes, no `Sort`. `Execution Time` drops to about 0.5 s.

#### 8c. Same index with `<=`: the sorts stay

`<=` needs `ts` descending, and this index gives `ts` ascending.

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;
```

Look for: `Sort Key: t.sym, t.ts DESC NULLS LAST`.

#### 8d. Btree on (sym, ts DESC) with `<=`: the sorts stay

`DESC` puts NULLs first by default, but the join needs NULLs last, because NULLs never
match.

```sql
CREATE INDEX bq_i ON big_quotes (sym, ts DESC);
CREATE INDEX bt_i ON big_trades (sym, ts DESC);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;
```

#### 8e. Btree on (sym, ts DESC NULLS LAST) with `<=`: no sorts

This is the exact order `<=` needs.

```sql
CREATE INDEX bq_i ON big_quotes (sym, ts DESC NULLS LAST);
CREATE INDEX bt_i ON big_trades (sym, ts DESC NULLS LAST);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;
```

### 9. Why the native join matters

Only 200 trades, against 200,000 quotes with no index.

```sql
\timing on
SELECT count(q.price) FROM (SELECT * FROM big_trades LIMIT 200) t
  ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

```sql
SET enable_asofjoin_native = off;
SELECT count(q.price) FROM (SELECT * FROM big_trades LIMIT 200) t
  ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;
\timing off
```

Look for: native about 0.5 s, LATERAL about 7 s. The LATERAL query scans all the quotes
once for every trade. The native join sorts once and makes one pass.

### Clean up

```sql
DROP TABLE trades, quotes, big_trades, big_quotes;
```

### Appendix: EXPLAIN for each step

Run these on the small tables at any time after step 1. Step 8 already shows its plans.
`ANALYZE` adds the real row counts next to each node.

#### A2. LEFT ASOF JOIN

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

Look for: `Asof Left Join` with `Merge Cond` (the key) and `Asof Cond` (the match
condition), over two Sorts on `(sym, ts)`. It returns 4 rows, one per trade.

#### A3. INNER ASOF JOIN

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

Look for: the node is `Asof Join`, and it returns 3 rows.

#### A4. Comparisons

The `>=` plan sorts `ts` ascending (same as A2). The `<=` plan sorts it descending:

```sql
EXPLAIN (COSTS OFF)
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts <= q.ts;
```

Look for: `Sort Key: t.sym, t.ts DESC NULLS LAST`. With this direction, one forward scan
handles all four operators.

#### A5. WHERE versus ON

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts WHERE q.price > 11;
```

Look for:
- `Filter: (q.price > 11)` sits on the join node, so it runs after the nearest quote is
  chosen.
- The node says `Asof Join`, not `Asof Left Join`. The filter would remove the NULL rows
  anyway, so the planner turned the left join into an inner one.
- `Rows Removed by Filter` shows how many rows the filter dropped.

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND q.price > 11;
```

Look for: here the filter sits on `Seq Scan on quotes q`, so the cheap quotes are
removed before the join, and it stays an `Asof Left Join`.

#### A6. The same query through the LATERAL rewrite

```sql
SET enable_asofjoin_native = off;
EXPLAIN (COSTS OFF)
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;
```

Look for: a `Nested Loop Left Join` with `Limit` and `Sort` on the quotes. That subquery
runs once for every trade.

### Notes

- Timings are from a debug build with assertions on. They show the difference in plan
  shape, not real benchmark numbers.
- Step 8a may show `Sort Method: external merge  Disk`. The default `work_mem` (4 MB)
  is too small for 200,000 rows, so the sort spills to disk. This is normal.

## Run the tests

```bash
. ./pgenv.sh
make check                               # core regression suite, ~1 minute
```

This starts a temporary server on its own port, runs every test, and shuts it down; it does
not touch the database you created above. It must be green before you open a PR, and the PR
template asks you to paste the summary line. On failure, read
`src/test/regress/regression.diffs` — it shows expected vs actual output per test.

## macOS notes

Verified on macOS 14.5 (Apple clang, SDK 14.4) with Homebrew bison 3.8.2 and m4 1.4.21:
`configure` clean, full build clean, **231 of 231 regression tests passed**.

Differences from the Linux instructions:

| Linux | macOS |
|---|---|
| `sudo apt install ...` | `xcode-select --install` + `brew install bison m4` |
| `make -j$(nproc)` | `make -j$(sysctl -n hw.ncpu)` |
| `gdb` | `lldb` — see the debugger note below |

### Why Homebrew bison, and why m4 comes with it

Apple's `/usr/bin/bison` is **2.3**, which is exactly PostgreSQL's minimum, so `configure`
accepts it and the tree builds. It is still the wrong tool for this project: bison 3.8+
supports `-Wcounterexamples`, which turns an unhelpful

```
gram.y: warning: 1 shift/reduce conflict
```

into a concrete pair of inputs the grammar cannot tell apart. We are adding productions to
`src/backend/parser/gram.y` in Phase 1, so that diagnostic is the difference between a
five-minute fix and an afternoon.

`m4` is needed because Homebrew's bison shells out to it, and macOS does not really ship
one: `/usr/bin/m4` is an `xcode-select` shim that aborts the build with

```
xcode-select: Failed to locate 'm4', requesting installation of command line developer tools.
make[1]: *** [parser/gram.h] Error 2
```

Both formulae are **keg-only** — Homebrew deliberately does not link them into
`/opt/homebrew/bin`, because they shadow Apple's versions. Rather than editing your shell
profile, `pgenv.sh` prepends both to `PATH` when `brew` is present (a no-op on Linux), so
`. ./pgenv.sh` is all you need:

```bash
. ./pgenv.sh
bison --version                 # expect 3.8.x, not 2.3
```

If you had already configured with Apple's bison, re-run `./configure` after sourcing
`pgenv.sh` so it records the new one.

### Checking the grammar for conflicts

`BISONFLAGS` appends `$(YFLAGS)`, so counterexamples can be switched on per build without
editing any makefile:

```bash
touch src/backend/parser/gram.y
make -C src/backend/parser YFLAGS=-Wcounterexamples
```

On an unmodified tree this prints nothing, which is the baseline: `gram.y` has no conflicts,
so **any** conflict your change introduces is yours to fix, not a pre-existing one.

### Other things worth knowing

- **The VS Code debug tasks do not work as-is on macOS.** `.vscode/launch.json` sets
  `"MIMode": "gdb"`, and gdb on Apple silicon needs code signing that nobody wants to set
  up. Either debug from the command line with `lldb -- install/bin/postgres --single -D
  "$PGDATA" test`, or change `MIMode` to `lldb` locally without committing it
  (`git update-index --skip-worktree .vscode/launch.json`). A per-platform launch
  configuration is worth adding later; it is not done here because it would change the
  working setup for the Linux machines.

- **`--without-icu` is deliberate** and works the same on both platforms. Drop it only if
  `make check` reports collation failures, in which case `brew install icu4c` and point
  `PKG_CONFIG_PATH` at it.

- **The port is 9432** (set by `pgenv.sh`), so a Postgres installed from Homebrew or
  Postgres.app on the default 5432 will not collide with this one.

- **`CFLAGS='-O0 -g3'` and `--enable-cassert` are intentional.** Assertions catch malformed
  parse and plan trees at the point they are built rather than as wrong output later, which
  is most of their value on this project. Never benchmark a cassert build — use a separate
  optimised build directory for the Phase 1/Phase 2 timings.
