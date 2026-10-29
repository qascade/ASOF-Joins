--
-- ASOF JOIN
--
-- An ASOF join matches each left row with the single nearest right row
-- that satisfies the inequality in its ON clause.  It is implemented by
-- rewriting it into a LATERAL subquery with ORDER BY ... LIMIT 1.
--

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

-- asof is a keyword now, but still usable as a quoted name or column label
SELECT 1 AS asof, 2 asof;
CREATE TABLE "asof" (x int);
DROP TABLE "asof";

DROP TABLE asof_trades, asof_quotes;
