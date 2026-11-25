-- ASOF JOIN demo. Run with: psql -X -d postgres -f demo.sql
\pset null '(null)'
\set ON_ERROR_STOP off
SET enable_asofjoin_native = on;
DROP TABLE IF EXISTS trades, quotes, big_trades, big_quotes;

\echo '=== 1. Tables ==='
CREATE TABLE trades (sym text, ts int, qty int);
CREATE TABLE quotes (sym text, ts int, price int);
INSERT INTO trades VALUES ('A', 5, 100), ('A', 9, 50), ('B', 3, 70), ('B', 8, 40);
INSERT INTO quotes VALUES ('A', 2, 10), ('A', 4, 11), ('A', 7, 12), ('B', 6, 20), ('B', 10, 21);
TABLE trades;
TABLE quotes;

\echo '=== 2. LEFT ASOF JOIN ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;

\echo '=== 3. INNER ASOF JOIN ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY 1, 2;

\echo '=== 4. Comparisons. Add a quote at exactly 9 to show a tie ==='
INSERT INTO quotes VALUES ('A', 9, 13);
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts > q.ts ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts <= q.ts ORDER BY 1, 2;

\echo '=== 5. WHERE versus ON ==='
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts WHERE q.price > 11 ORDER BY 1, 2;
SELECT t.sym, t.ts, q.ts AS qts, q.price FROM trades t ASOF LEFT JOIN quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND q.price > 11 ORDER BY 1, 2;

\echo '=== 6. Errors ==='
SELECT * FROM trades t ASOF JOIN quotes q ON t.sym = q.sym;
SELECT * FROM trades t RIGHT ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;

\echo '=== 7. Larger tables ==='
CREATE TABLE big_quotes AS
  SELECT 'S' || (g % 50) AS sym, (g * 7919) % 1000000 AS ts, g % 1000 AS price
  FROM generate_series(1, 200000) g;
CREATE TABLE big_trades AS
  SELECT 'S' || (g % 50) AS sym, (g * 7907) % 1000000 AS ts, g % 100 AS qty
  FROM generate_series(1, 200000) g;
ANALYZE big_quotes, big_trades;

\echo '=== 8a. No index: sorts ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;

\echo '=== 8b. Btree (sym, ts) with >= : no sorts ==='
CREATE INDEX bq_i ON big_quotes (sym, ts);
CREATE INDEX bt_i ON big_trades (sym, ts);
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;

\echo '=== 8c. Same index with <= : sorts stay ==='
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 8d. Btree (sym, ts DESC) with <= : NULLs first, sorts stay ==='
CREATE INDEX bq_i ON big_quotes (sym, ts DESC);
CREATE INDEX bt_i ON big_trades (sym, ts DESC);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 8e. Btree (sym, ts DESC NULLS LAST) with <= : no sorts ==='
CREATE INDEX bq_i ON big_quotes (sym, ts DESC NULLS LAST);
CREATE INDEX bt_i ON big_trades (sym, ts DESC NULLS LAST);
EXPLAIN (COSTS OFF)
SELECT * FROM big_trades t ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts <= q.ts;
DROP INDEX bq_i, bt_i;

\echo '=== 9. 200 trades, no index: native, then LATERAL ==='
\timing on
SELECT count(q.price) FROM (SELECT * FROM big_trades LIMIT 200) t
  ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = off;
SELECT count(q.price) FROM (SELECT * FROM big_trades LIMIT 200) t
  ASOF LEFT JOIN big_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;
\timing off

DROP TABLE trades, quotes, big_trades, big_quotes;
