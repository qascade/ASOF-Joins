# ASOF-Joins
Custom implementation ASOF joins in postgres


# Building and Running PostgreSQL

Steps to build and run PostgreSQL after cloning this repo.

## 1. Install prerequisites

```bash
sudo apt install build-essential gdb bison flex libreadline-dev zlib1g-dev
```

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
make -j$(nproc) && make install
initdb -D "$PGDATA"
pg_ctl -l "$POSTGRES_INSTALLDIR/logfile" start
createdb test
psql test
```

Run `. ./pgenv.sh` in every new terminal before using any PostgreSQL commands.