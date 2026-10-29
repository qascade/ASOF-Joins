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
