# ASOF JOIN demo (about 10 minutes)

## Setup

```bash
cd "<repo>"
. ./pgenv.sh
pg_ctl start -l install/server.log      # skip if already running
psql -X -d postgres
```

Paste the blocks below into `psql` one at a time. To run the whole thing at once
instead, use `psql -X -d postgres -f demo.sql` (about 20 seconds).

## 0. Start clean

```sql
\pset null '(null)'
SET enable_asofjoin_native = on;
DROP TABLE IF EXISTS trades, quotes, big_trades, big_quotes;
```

## 1. The tables from the report

```sql
CREATE TABLE trades (sym text, ts int, qty int);
CREATE TABLE quotes (sym text, ts int, price int);
INSERT INTO trades VALUES ('A', 5, 100), ('A', 9, 50), ('B', 3, 70);
INSERT INTO quotes VALUES ('A', 2, 10), ('A', 4, 11), ('A', 7, 12), ('B', 6, 20);
TABLE trades;
TABLE quotes;
```

Say: for each trade we want the latest quote of the same symbol at or before the trade time.
Trade (B,3) has no such quote, because the only B quote comes at time 6.

## 2. An ordinary join is not enough

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2, 3;
```

Point out: 5 rows. Trade (A,5) gets 2 quotes and (A,9) gets 3. We only want the nearest one.

## 3. LEFT ASOF JOIN

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;
```

Point out: one row per trade. (A,5) gets quote 4, (A,9) gets quote 7, (B,3) gets NULLs.

## 4. INNER ASOF JOIN

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;
```

Point out: (B,3) is dropped because it has no match.

## 5. The four comparisons

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

`<=`: earliest quote at or after. (A,5) gets 7, (A,9) gets 9, (B,3) gets 6.

```sql
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts <= q.ts ORDER BY 1, 2;
```

`<`: earliest quote strictly after. (A,9) gets NULL, because there is no quote after 9.

```sql
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts < q.ts ORDER BY 1, 2;
```

## 6. WHERE versus ON

`WHERE` finds the latest quote first, then keeps the row only if that quote's price is
above 11. Only (A,9) survives.

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts WHERE q.price > 11 ORDER BY 1, 2;
```

In `ON`, the condition is applied first, so the join finds the latest quote whose price
is above 11. Every trade stays. (A,5) gets NULLs, because its earlier quotes have prices 10 and 11.

```sql
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND q.price > 11 ORDER BY 1, 2;
```

## 7. The two plans

Native join (Phase 2): an `Asof Left Join` node over two Sorts.

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

The same query with the switch off (Phase 1): the LATERAL rewrite, a Nested Loop with
`Limit` and `Sort` on the quotes for every trade.

```sql
SET enable_asofjoin_native = off;
EXPLAIN (COSTS OFF)
SELECT * FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;
```

## 8. Errors

Each of these fails with an error that names the problem.

```sql
SELECT * FROM trades t ASOF JOIN quotes q ON t.sym = q.sym;
```

```sql
SELECT * FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts <> q.ts;
```

```sql
SELECT * FROM trades t RIGHT ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

1. No inequality: "must contain an inequality", with a hint.
2. `<>` is not an ordering operator: "cannot be used as the ASOF JOIN match condition".
3. "only INNER and LEFT ASOF joins are supported".

## 9. Larger tables

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

## 10. When an index removes the sort, and when it does not

The join needs each input sorted by the key, then the time:

- for `>=` and `>`: `sym ASC, ts ASC NULLS LAST`
- for `<=` and `<`: `sym ASC, ts DESC NULLS LAST`

The planner skips a Sort only when an index already gives exactly that order.

### 10a. No index: both inputs are sorted

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

Point out: two `Sort` nodes over `Seq Scan`, and the `Execution Time` (about 1.7 s on our
debug build).

### 10b. Hash index: the sorts stay

A hash index has no order.

```sql
CREATE INDEX bq_i ON big_quotes USING hash (sym);
CREATE INDEX bt_i ON big_trades USING hash (sym);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
DROP INDEX bq_i, bt_i;
```

### 10c. Btree on (ts, sym): the sorts stay

The column order is wrong. The join needs `sym` first.

```sql
CREATE INDEX bq_i ON big_quotes (ts, sym);
CREATE INDEX bt_i ON big_trades (ts, sym);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
DROP INDEX bq_i, bt_i;
```

### 10d. Btree on (sym, ts) with `>=`: no sorts

A plain btree is `ASC NULLS LAST`, which is exactly what `>=` needs.

```sql
CREATE INDEX bq_i ON big_quotes (sym, ts);
CREATE INDEX bt_i ON big_trades (sym, ts);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
```

Point out: two `Index Scan` nodes, no `Sort`. `Execution Time` drops to about 0.45 s.

### 10e. Same index with `<=`: the sorts stay

`<=` needs `ts` descending, and this index gives `ts` ascending.

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;
```

Point out: `Sort Key: t.sym, t.ts DESC NULLS LAST`.

### 10f. Btree on (sym, ts DESC) with `<=`: the sorts stay

`DESC` puts NULLs first by default, but the join needs NULLs last, because NULLs never
match.

```sql
CREATE INDEX bq_i ON big_quotes (sym, ts DESC);
CREATE INDEX bt_i ON big_trades (sym, ts DESC);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;
```

### 10g. Btree on (sym, ts DESC NULLS LAST) with `<=`: no sorts

This is the exact order `<=` needs.

```sql
CREATE INDEX bq_i ON big_quotes (sym, ts DESC NULLS LAST);
CREATE INDEX bt_i ON big_trades (sym, ts DESC NULLS LAST);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;
```

## 11. Why the native join matters

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

Point out: native about 0.5 s, LATERAL about 6 to 8 s. The LATERAL query scans all the
quotes once for every trade. The native join sorts once and makes one pass.

## Clean up

```sql
DROP TABLE trades, quotes, big_trades, big_quotes;
```

## Notes

- Timings are from a debug build with assertions on. They show the difference in plan
  shape, not real benchmark numbers.
- Step 10a may show `Sort Method: external merge  Disk`. The default `work_mem` (4 MB)
  is too small for 200,000 rows, so the sort spills to disk. This is normal.
