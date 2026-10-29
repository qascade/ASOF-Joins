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

Five runs of the 50,000 x 200,000 bulk case from `test.sql`, index present on
`(sym, ts)`, results verified identical every run:

| Run | `ASOF JOIN` | hand-written LATERAL |
|---|---|---|
| 1 | 1924.3 ms | 1873.4 ms |
| 2 | 1870.3 ms | 1853.0 ms |
| 3 | 2101.7 ms | 1951.8 ms |
| 4 | 1935.0 ms | 2037.2 ms |
| 5 | 1876.7 ms | 1903.5 ms |
| **median** | **1924.3 ms** | **1903.5 ms** |

The 1% median difference is noise: the spread *within* each column is about 12%, far wider
than the gap between them. That is the expected result, and it is worth stating as the
measurement floor — when benchmarking the native join later, anything under roughly 10% on
a single run means nothing.

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
