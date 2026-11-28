-- ASOF JOIN demo. Run with: psql -X -d postgres -f demo.sql
\pset null '(null)'
\set ON_ERROR_STOP off
SET enable_asofjoin_native = on;
DROP TABLE IF EXISTS trades, quotes, big_trades, big_quotes;

\echo '=== 1. The tables from the report ==='
CREATE TABLE trades (sym text, ts int, qty int);
CREATE TABLE quotes (sym text, ts int, price int);
INSERT INTO trades VALUES ('A', 5, 100), ('A', 9, 50), ('B', 3, 70);
INSERT INTO quotes VALUES ('A', 2, 10), ('A', 4, 11), ('A', 7, 12), ('B', 6, 20);
TABLE trades;
TABLE quotes;

\echo '=== 2. An ordinary join returns every earlier quote ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2, 3;

\echo '=== 3. LEFT ASOF JOIN: one row per trade, with the latest quote at or before it ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;

\echo '=== 4. INNER ASOF JOIN drops the trade that has no quote ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;

\echo '=== 5. The four comparisons. Add a quote at exactly 9 to show ties ==='
INSERT INTO quotes VALUES ('A', 9, 13);
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts > q.ts ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts <= q.ts ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts < q.ts ORDER BY 1, 2;

\echo '=== 6. WHERE is applied after the nearest quote is chosen, ON before ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts WHERE q.price > 11 ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND q.price > 11 ORDER BY 1, 2;

\echo '=== 7. Plans: native ASOF join, then the LATERAL rewrite ==='
EXPLAIN (COSTS OFF)
SELECT * FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = off;
EXPLAIN (COSTS OFF)
SELECT * FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;

\echo '=== 8. Errors for a wrong ON clause ==='
SELECT * FROM trades t ASOF JOIN quotes q ON t.sym = q.sym;
SELECT * FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts <> q.ts;
SELECT * FROM trades t RIGHT ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;

\echo '=== 9. Larger tables: 200,000 trades and 200,000 quotes over 50 symbols ==='
CREATE TABLE big_quotes AS
  SELECT 'S' || (g % 50) AS sym, (g * 7919) % 1000000 AS ts, g % 1000 AS price
  FROM generate_series(1, 200000) g;
CREATE TABLE big_trades AS
  SELECT 'S' || (g % 50) AS sym, (g * 7907) % 1000000 AS ts, g % 100 AS qty
  FROM generate_series(1, 200000) g;
ANALYZE big_quotes, big_trades;

\echo '=== 10a. No index: both inputs are sorted ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;

\echo '=== 10b. Hash index on (sym): no order, the sorts stay ==='
CREATE INDEX bq_i ON big_quotes USING hash (sym);
CREATE INDEX bt_i ON big_trades USING hash (sym);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 10c. Btree on (ts, sym): wrong column order, the sorts stay ==='
CREATE INDEX bq_i ON big_quotes (ts, sym);
CREATE INDEX bt_i ON big_trades (ts, sym);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 10d. Btree on (sym, ts) with >= : the order fits, no sorts ==='
CREATE INDEX bq_i ON big_quotes (sym, ts);
CREATE INDEX bt_i ON big_trades (sym, ts);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;

\echo '=== 10e. Same index with <= : needs ts descending, the sorts stay ==='
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 10f. Btree on (sym, ts DESC) with <= : DESC puts NULLs first, the sorts stay ==='
CREATE INDEX bq_i ON big_quotes (sym, ts DESC);
CREATE INDEX bt_i ON big_trades (sym, ts DESC);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 10g. Btree on (sym, ts DESC NULLS LAST) with <= : the order fits, no sorts ==='
CREATE INDEX bq_i ON big_quotes (sym, ts DESC NULLS LAST);
CREATE INDEX bt_i ON big_trades (sym, ts DESC NULLS LAST);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 11. 200 trades, no index: native, then LATERAL ==='
\timing on
SELECT count(q.price) FROM (SELECT * FROM big_trades LIMIT 200) t
  ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = off;
SELECT count(q.price) FROM (SELECT * FROM big_trades LIMIT 200) t
  ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;
\timing off

DROP TABLE trades, quotes, big_trades, big_quotes;
