--
-- ASOF JOIN
--
-- An ASOF join matches each left row with the single nearest right row
-- that satisfies the inequality in its ON clause.  With
-- enable_asofjoin_native off, it is rewritten into a LATERAL subquery
-- with ORDER BY ... LIMIT 1; with it on, the planner builds an AsofJoin
-- node over sorted inputs.
--

SET enable_asofjoin_native = off;

CREATE TABLE asof_trades (sym text, ts int, qty int);
CREATE TABLE asof_quotes (sym text, ts int, price int);
INSERT INTO asof_trades VALUES
  ('A', 5, 1), ('A', 10, 2), ('B', 3, 3), ('B', 1, 4), ('C', 7, 5);
INSERT INTO asof_quotes VALUES
  ('A', 1, 100), ('A', 5, 105), ('A', 8, 108), ('B', 2, 200), ('B', 4, 204);
CREATE INDEX ON asof_quotes (sym, ts);

-- most recent quote at or before each trade
SELECT t.*, q.ts AS qts, q.price
FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY t.sym, t.ts;

-- LEFT ASOF keeps trades without a match
SELECT t.*, q.ts AS qts, q.price
FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY t.sym, t.ts;

-- LEFT OUTER ASOF, ASOF LEFT and ASOF INNER spellings are accepted too
SELECT count(*)
FROM asof_trades t LEFT OUTER ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
SELECT count(*)
FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
SELECT count(*)
FROM asof_trades t ASOF INNER JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;

-- strict inequality, written with the right column first
SELECT t.*, q.ts AS qts
FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON q.sym = t.sym AND q.ts < t.ts
ORDER BY t.sym, t.ts;

-- forward-looking: first quote at or after each trade
SELECT t.*, q.ts AS qts
FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts <= q.ts
ORDER BY t.sym, t.ts;

-- forward-looking, strict
SELECT t.*, q.ts AS qts
FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND q.ts > t.ts
ORDER BY t.sym, t.ts;

-- no equality key at all
SELECT t.*, q.sym AS qsym, q.ts AS qts
FROM asof_trades t ASOF JOIN asof_quotes q ON t.ts >= q.ts
ORDER BY t.sym, t.ts;

-- unaliased right table, and SELECT *
SELECT *
FROM asof_trades ASOF JOIN asof_quotes
  ON asof_trades.sym = asof_quotes.sym AND asof_trades.ts >= asof_quotes.ts
ORDER BY 1, 2;

-- aliased subquery on the right, and an expression on the left side
SELECT t.sym, t.ts, q.ts AS qts
FROM asof_trades t ASOF JOIN (SELECT * FROM asof_quotes WHERE price > 100) q
  ON t.sym = q.sym AND t.ts - 1 >= q.ts
ORDER BY t.sym, t.ts;

-- same result as the hand-written LATERAL form
(SELECT t.*, q.*
 FROM asof_trades t LEFT ASOF JOIN asof_quotes q
   ON t.sym = q.sym AND t.ts >= q.ts)
EXCEPT ALL
(SELECT t.*, q.*
 FROM asof_trades t LEFT JOIN LATERAL
   (SELECT * FROM asof_quotes q
    WHERE t.sym = q.sym AND t.ts >= q.ts
    ORDER BY q.ts DESC LIMIT 1) q ON true);

-- chained with an ordinary join
SELECT t.sym, t.ts, q.price, t2.qty
FROM asof_trades t
  ASOF JOIN asof_quotes q ON t.sym = q.sym AND t.ts >= q.ts
  JOIN asof_trades t2 ON t2.sym = t.sym AND t2.ts = t.ts
ORDER BY t.sym, t.ts;

-- an index on (sym, ts) gives one backward index probe per left row
SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT * FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
RESET enable_seqscan;

-- views store the rewritten form
CREATE VIEW asof_view AS
SELECT t.sym, q.price
FROM asof_trades t ASOF JOIN asof_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
SELECT pg_get_viewdef('asof_view'::regclass);
DROP VIEW asof_view;

-- prepared statements can be executed repeatedly
PREPARE asof_prep AS
SELECT count(*) FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
EXECUTE asof_prep;
EXECUTE asof_prep;
DEALLOCATE asof_prep;

-- errors
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q ON t.sym = q.sym;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.ts >= q.ts AND t.qty < q.price;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q ON q.ts >= 3;
SELECT * FROM asof_trades t FULL ASOF JOIN asof_quotes q ON t.ts >= q.ts;
SELECT * FROM asof_trades t RIGHT ASOF JOIN asof_quotes q ON t.ts >= q.ts;
SELECT * FROM asof_trades t ASOF FULL JOIN asof_quotes q ON t.ts >= q.ts;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q USING (sym);
SELECT * FROM asof_trades t ASOF JOIN (SELECT 1 AS ts) ON t.ts >= 1;
SELECT * FROM asof_trades q ASOF JOIN asof_quotes q ON q.ts >= q.ts;

-- the native path checks the transformed ON clause for one match inequality
SET enable_asofjoin_native = on;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q ON t.sym = q.sym;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.ts >= q.ts AND t.qty < q.price;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q ON q.ts >= 3;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q ON t.ts <> q.ts;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.ts >= q.ts + random()::int;
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.ts >= (SELECT max(ts) FROM asof_quotes WHERE sym = q.sym);

-- native plans: both inputs sorted on the equality keys, then the match column
EXPLAIN (COSTS OFF)
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
-- < and <= sort the match column descending
EXPLAIN (COSTS OFF)
SELECT * FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts < q.ts;
-- no equality key
EXPLAIN (COSTS OFF)
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q ON t.ts >= q.ts;
-- match clause written right side first is shown left side first
EXPLAIN (COSTS OFF)
SELECT * FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND q.ts <= t.ts;
-- other ON quals filter candidates (Join Filter), WHERE quals filter results
EXPLAIN (COSTS OFF)
SELECT * FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND t.qty + q.price > 100
WHERE q.price IS NULL;
-- the match column is kept even when it is not selected
EXPLAIN (COSTS OFF)
SELECT t.qty, q.price FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;
EXPLAIN (COSTS OFF, FORMAT JSON)
SELECT * FROM asof_trades t LEFT ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts;

-- views keep the ASOF join and print it back as ASOF syntax
CREATE VIEW asof_view_left AS
SELECT t.sym, t.ts, q.price
FROM asof_trades t LEFT ASOF JOIN asof_quotes q ON t.sym = q.sym AND t.ts >= q.ts;
CREATE VIEW asof_view_inner AS
SELECT t.sym, q.price
FROM asof_trades t ASOF JOIN asof_quotes q ON t.sym = q.sym AND q.ts <= t.ts;
SELECT pg_get_viewdef('asof_view_left'::regclass, true);
SELECT pg_get_viewdef('asof_view_inner'::regclass, true);
SELECT * FROM asof_view_left ORDER BY sym, ts;
DROP VIEW asof_view_left, asof_view_inner;


-- native executor (#11): >=, LEFT join, one equality key
-- (A,5 matches the quote at 5: an exact tie counts for >=)
SELECT * FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY t.sym, t.ts;
-- WHERE quals above the join filter its output
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
WHERE q.price IS NULL
ORDER BY t.sym, t.ts;
-- EXPLAIN ANALYZE counts the rows the WHERE quals removed.  Sort memory
-- differs between platforms, so it is masked.
CREATE FUNCTION asof_explain_analyze(query text) RETURNS SETOF text
LANGUAGE plpgsql AS
$$
DECLARE
    ln text;
BEGIN
    FOR ln IN EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) ' || query
    LOOP
        RETURN NEXT regexp_replace(ln, 'Memory: \d+kB', 'Memory: NkB');
    END LOOP;
END;
$$;
SELECT asof_explain_analyze($$
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
WHERE q.price IS NULL
$$);
DROP FUNCTION asof_explain_analyze(text);

-- NULLs on both sides, duplicate match values, keys present on one side only
CREATE TABLE asof_trades_n (sym text, ts int);
CREATE TABLE asof_quotes_n (sym text, ts int);
INSERT INTO asof_trades_n VALUES
  ('A', 10), ('A', 20), ('A', 25), ('A', NULL), (NULL, 7),
  ('B', 15), ('B', 30), ('D', 1);
INSERT INTO asof_quotes_n VALUES
  ('A', 8), ('A', 12), ('A', 20), ('A', NULL), (NULL, 1),
  ('B', 16), ('B', 16), ('E', 0);
SELECT t.sym, t.ts, q.sym AS qsym, q.ts AS qts
FROM asof_trades_n t ASOF LEFT JOIN asof_quotes_n q
  ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY t.sym, t.ts;
-- empty right side
SELECT t.sym, t.ts, q.ts AS qts
FROM asof_trades_n t ASOF LEFT JOIN (SELECT * FROM asof_quotes_n WHERE false) q
  ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY t.sym, t.ts;

-- same rows as the LATERAL rewrite, on the data above and on generated data
CREATE TABLE asof_trades_g AS
  SELECT (g % 7)::text AS sym, g AS ts FROM generate_series(1, 2000) g;
CREATE TABLE asof_quotes_g AS
  SELECT (g % 9)::text AS sym, g * 3 AS ts FROM generate_series(1, 700) g;
SET enable_asofjoin_native = off;
CREATE TEMP TABLE asof_ref_n AS
  SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_n t ASOF LEFT JOIN asof_quotes_n q
    ON t.sym = q.sym AND t.ts >= q.ts;
CREATE TEMP TABLE asof_ref_g AS
  SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_g t ASOF LEFT JOIN asof_quotes_g q
    ON t.sym = q.sym AND t.ts >= q.ts;
SET enable_asofjoin_native = on;
CREATE TEMP TABLE asof_nat_n AS
  SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_n t ASOF LEFT JOIN asof_quotes_n q
    ON t.sym = q.sym AND t.ts >= q.ts;
CREATE TEMP TABLE asof_nat_g AS
  SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_g t ASOF LEFT JOIN asof_quotes_g q
    ON t.sym = q.sym AND t.ts >= q.ts;
SELECT 'nulls' AS data,
       (SELECT count(*) FROM (TABLE asof_ref_n EXCEPT ALL TABLE asof_nat_n) a) AS missing,
       (SELECT count(*) FROM (TABLE asof_nat_n EXCEPT ALL TABLE asof_ref_n) b) AS extra
UNION ALL
SELECT 'generated',
       (SELECT count(*) FROM (TABLE asof_ref_g EXCEPT ALL TABLE asof_nat_g) a),
       (SELECT count(*) FROM (TABLE asof_nat_g EXCEPT ALL TABLE asof_ref_g) b);

-- inputs already in (key, match column) order from an index need no Sort
CREATE INDEX ON asof_trades_g (sym, ts);
CREATE INDEX ON asof_quotes_g (sym, ts);
SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_g t ASOF LEFT JOIN asof_quotes_g q
  ON t.sym = q.sym AND t.ts >= q.ts;
CREATE TEMP TABLE asof_idx_g AS
  SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_g t ASOF LEFT JOIN asof_quotes_g q
    ON t.sym = q.sym AND t.ts >= q.ts;
SELECT (SELECT count(*) FROM (TABLE asof_ref_g EXCEPT ALL TABLE asof_idx_g) a) AS missing,
       (SELECT count(*) FROM (TABLE asof_idx_g EXCEPT ALL TABLE asof_ref_g) b) AS extra;
-- only the right input has a matching index: the left one is still sorted
DROP INDEX asof_trades_g_sym_ts_idx;
EXPLAIN (COSTS OFF)
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_g t ASOF LEFT JOIN asof_quotes_g q
  ON t.sym = q.sym AND t.ts >= q.ts;
-- < wants the match column descending, which a (sym, ts DESC NULLS LAST) index gives
CREATE INDEX ON asof_trades_g (sym, ts DESC NULLS LAST);
CREATE INDEX ON asof_quotes_g (sym, ts DESC NULLS LAST);
EXPLAIN (COSTS OFF)
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_g t ASOF LEFT JOIN asof_quotes_g q
  ON t.sym = q.sym AND t.ts < q.ts;
RESET enable_seqscan;
DROP TABLE asof_ref_n, asof_ref_g, asof_nat_n, asof_nat_g, asof_idx_g;
DROP TABLE asof_trades_n, asof_quotes_n, asof_trades_g, asof_quotes_g;

-- native executor (#12): all four operators, LEFT and INNER joins
-- (A,5 and A,10 / B,3 show whether an exact tie counts)
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts > q.ts
ORDER BY t.sym, t.ts;
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts <= q.ts
ORDER BY t.sym, t.ts;
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts < q.ts
ORDER BY t.sym, t.ts;
-- match clause written right side first
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON q.sym = t.sym AND q.ts > t.ts
ORDER BY t.sym, t.ts;
-- INNER drops trades without a match
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
ORDER BY t.sym, t.ts;
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF INNER JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts < q.ts
ORDER BY t.sym, t.ts;
-- a strict WHERE qual on the right side reduces LEFT to INNER
EXPLAIN (COSTS OFF)
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
WHERE q.price > 100;
SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts
WHERE q.price > 100
ORDER BY t.sym, t.ts;

-- same rows as the LATERAL rewrite, for every operator and join type, on
-- data with NULLs and duplicates and on generated data
CREATE TABLE asof_trades_n (sym text, ts int);
CREATE TABLE asof_quotes_n (sym text, ts int);
INSERT INTO asof_trades_n VALUES
  ('A', 10), ('A', 20), ('A', 25), ('A', NULL), (NULL, 7),
  ('B', 15), ('B', 16), ('B', 30), ('D', 1);
INSERT INTO asof_quotes_n VALUES
  ('A', 8), ('A', 12), ('A', 20), ('A', NULL), (NULL, 1),
  ('B', 16), ('B', 16), ('E', 0);
CREATE TABLE asof_trades_g AS
  SELECT (g % 7)::text AS sym, g AS ts FROM generate_series(1, 2000) g;
CREATE TABLE asof_quotes_g AS
  SELECT (g % 9)::text AS sym, g * 3 AS ts FROM generate_series(1, 700) g;
CREATE FUNCTION asof_diff(q text) RETURNS TABLE (missing bigint, extra bigint)
LANGUAGE plpgsql AS
$$
BEGIN
    SET LOCAL enable_asofjoin_native = off;
    EXECUTE 'CREATE TEMP TABLE asof_ref AS ' || q;
    SET LOCAL enable_asofjoin_native = on;
    EXECUTE 'CREATE TEMP TABLE asof_nat AS ' || q;
    RETURN QUERY
      SELECT (SELECT count(*) FROM (TABLE asof_ref EXCEPT ALL TABLE asof_nat) a),
             (SELECT count(*) FROM (TABLE asof_nat EXCEPT ALL TABLE asof_ref) b);
    DROP TABLE asof_ref, asof_nat;
END;
$$;
SELECT tbl, jt, op, d.*
FROM (VALUES ('n'), ('g')) AS tb(tbl),
     (VALUES ('LEFT'), ('INNER')) AS j(jt),
     (VALUES ('>='), ('>'), ('<='), ('<')) AS o(op),
     LATERAL asof_diff(format(
       'SELECT t.sym, t.ts, q.ts AS qts FROM asof_trades_%s t ASOF %s JOIN asof_quotes_%s q '
       'ON t.sym = q.sym AND t.ts %s q.ts', tbl, jt, tbl, op)) d
ORDER BY 1 DESC, 2 DESC, 3;
DROP FUNCTION asof_diff(text);
DROP TABLE asof_trades_n, asof_quotes_n, asof_trades_g, asof_quotes_g;

-- extra ON conditions are still left to the rewrite
SELECT * FROM asof_trades t ASOF LEFT JOIN asof_quotes q
  ON t.sym = q.sym AND t.ts >= q.ts AND t.qty + q.price > 100;
SET enable_asofjoin_native = off;

-- asof is a keyword now, but still usable as a quoted name or column label
SELECT 1 AS asof, 2 asof;
CREATE TABLE "asof" (x int);
DROP TABLE "asof";

DROP TABLE asof_trades, asof_quotes;
