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
xcode-select --install          # clang, make, bison, flex, readline — that is all you need
```

Nothing from Homebrew is required: the Command Line Tools ship a new enough bison and flex,
and `configure` finds readline on its own. See [macOS notes](#macos-notes) below for the
differences from the Linux commands and for when you might still want Homebrew's bison.

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

Verified on macOS 14.5 (Apple clang, SDK 14.4) with the stock Command Line Tools:
`configure` clean, full build clean, **231 of 231 regression tests passed**.

Differences from the Linux instructions:

| Linux | macOS |
|---|---|
| `sudo apt install ...` | `xcode-select --install` |
| `make -j$(nproc)` | `make -j$(sysctl -n hw.ncpu)` |
| `gdb` | `lldb` — see the debugger note below |

What `configure` picks up on a stock machine, for reference:

```
checking for bison... /usr/bin/bison
configure: using bison (GNU Bison) 2.3
checking for flex... /usr/bin/flex
configure: using flex 2.6.4 Apple(flex-34)
checking for library containing readline... -lreadline
```

A few things worth knowing:

- **Apple's bison is 2.3, from 2006.** PostgreSQL's minimum is exactly 2.3, so it builds
  fine, and `configure` accepts it without a warning. It is only a problem once you start
  editing `src/backend/parser/gram.y`: bison 3.8+ supports `-Wcounterexamples`, which turns
  an unhelpful "shift/reduce conflict" into a concrete pair of inputs that the grammar cannot
  tell apart. When you get to the grammar work, install the newer one and put it first on
  `PATH` — it is keg-only, so it is not linked into `/opt/homebrew/bin` by default:

  ```bash
  brew install bison
  export PATH="$(brew --prefix bison)/bin:$PATH"
  bison --version                        # expect 3.8.x
  ```

  Re-run `./configure` after changing `PATH` so it records the new bison.

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