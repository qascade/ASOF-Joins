-- =====================================================================
-- ASOF JOIN test script for PostgreSQL
--
--   psql -d yourdb -X -f asof_test.sql
--
-- Every test runs your ASOF JOIN and an equivalent LATERAL reference
-- query, then diffs them and prints PASS / FAIL.
--
-- Syntax assumed (DuckDB style):
--     a ASOF JOIN b ON a.key = b.key AND a.ts >= b.ts
--     a ASOF LEFT JOIN b ON ...
-- If yours differs, edit only the lines marked  -- <ASOF>
--
-- Ties (two build rows with the same key and ts) are legitimately
-- ambiguous, so comparisons use the matched ts, not the matched row id.
-- =====================================================================

\set ON_ERROR_STOP on
\pset footer off

-- An assertions build is several times slower; timings only compare
-- against runs with the same settings.
\echo '--- environment'
SELECT version() AS version;
SELECT current_setting('debug_assertions') AS debug_assertions,
       current_setting('work_mem')         AS work_mem;

CREATE TEMP TABLE bench_timings (test text, impl text, ms numeric);

DROP TABLE IF EXISTS trades, quotes, big_trades, big_quotes,
                     sensor_reads, calib, events_tz, rates_tz CASCADE;

-- ---------------------------------------------------------------------
-- 1. Small hand-checkable data (inserted out of time order on purpose)
-- ---------------------------------------------------------------------
CREATE TABLE quotes (qid int PRIMARY KEY, sym text, ts int, bid numeric(8,2));
CREATE TABLE trades (tid int PRIMARY KEY, sym text, ts int, qty int);

INSERT INTO quotes VALUES
    (1,  'AAPL', 30, 101.00),
    (2,  'AAPL', 10, 100.00),
    (3,  'AAPL', 20, 100.50),
    (4,  'AAPL', 50, 102.00),
    (5,  'MSFT', 15, 300.00),
    (6,  'MSFT', 40, 301.00),
    (7,  'GOOG', 10, 140.00),   -- tie with qid 8
    (8,  'GOOG', 10, 140.10),
    (9,  'GOOG', 25, 141.00),
    (10, 'TSLA', 100, 250.00),  -- later than every TSLA trade
    (11, NULL,   10,   1.00),   -- NULL key
    (12, 'AAPL', NULL, 999.00), -- NULL time
    (13, 'NEG',  -5,   5.00),
    (14, 'NEG',   0,   6.00);

INSERT INTO trades VALUES
    (101, 'AAPL', 10,  5),   -- exact match
    (102, 'AAPL', 25,  7),   -- between quotes
    (103, 'AAPL', 5,   1),   -- before first quote
    (104, 'AAPL', 999, 3),   -- after last quote
    (105, 'AAPL', 25,  2),   -- duplicate probe ts
    (106, 'MSFT', 14,  4),
    (107, 'MSFT', 15,  9),
    (108, 'MSFT', 39,  8),
    (109, 'GOOG', 12,  6),   -- hits the tie at ts=10
    (110, 'GOOG', 25,  1),
    (111, 'TSLA', 50,  2),
    (112, 'IBM',  10,  2),   -- key absent on build side
    (113, NULL,   10,  2),   -- NULL key must not match NULL key
    (114, 'AAPL', NULL, 2),  -- NULL time must not match
    (115, 'NEG',  -1,  1),
    (116, 'NEG',  0,   1),
    (117, 'NEG',  -10, 1);

-- ---------------------------------------------------------------------
-- 2. Bulk deterministic data (correctness diff + rough perf)
--    50 quoted symbols, trades also use S50..S54 which have no quotes
-- ---------------------------------------------------------------------
SELECT setseed(0.42) \gset

CREATE TABLE big_quotes AS
SELECT g AS qid,
       'S' || lpad((g % 50)::text, 2, '0') AS sym,
       (random() * 1000000)::int AS ts,
       round((random() * 1000)::numeric, 2) AS bid
FROM generate_series(1, 200000) g;

CREATE TABLE big_trades AS
SELECT g AS tid,
       'S' || lpad((g % 55)::text, 2, '0') AS sym,
       (random() * 1000000)::int AS ts,
       (random() * 100)::int + 1 AS qty
FROM generate_series(1, 50000) g;

UPDATE big_trades SET ts  = NULL WHERE tid % 997  = 0;
UPDATE big_trades SET sym = NULL WHERE tid % 1009 = 0;
UPDATE big_quotes SET ts  = NULL WHERE qid % 1999 = 0;
ANALYZE big_quotes; ANALYZE big_trades;

-- ---------------------------------------------------------------------
-- 3. Other types: int key + double precision time; no key + timestamptz
-- ---------------------------------------------------------------------
CREATE TABLE calib (sensor_id int, t double precision, offset_v double precision);
INSERT INTO calib VALUES
    (1, 0.0, 0.10), (1, 10.5, 0.20), (1, 20.25, 0.30),
    (2, 5.0, -0.50), (2, 5.000001, -0.40);

CREATE TABLE sensor_reads (rid int, sensor_id int, t double precision);
INSERT INTO sensor_reads VALUES
    (1, 1, 10.4999), (2, 1, 10.5), (3, 1, 1e9),
    (4, 2, 5.0000005), (5, 2, 4.9), (6, 3, 1.0);

CREATE TABLE rates_tz (valid_from timestamptz, rate numeric);
INSERT INTO rates_tz VALUES
    ('2026-03-29 00:30:00+00', 1.10),
    ('2026-03-29 01:00:00+00', 1.20),
    ('2026-10-25 01:00:00+00', 1.40);

CREATE TABLE events_tz (eid int, at timestamptz);
INSERT INTO events_tz VALUES
    (1, '2026-03-29 00:45:00+00'),
    (2, '2026-03-29 02:00:00 Europe/London'),  -- = 01:00 UTC, exact match
    (3, '2026-01-01 00:00:00+00'),             -- before all rates
    (4, '2027-01-01 00:00:00+00');

-- =====================================================================
-- TESTS
-- =====================================================================

-- T1: inner ASOF, >=, small data. Prints the result for eyeballing.
-- Expected 10 rows:
--   tid  q_ts      tid  q_ts
--   101  10        108  15
--   102  20        109  10 (qid 7 or 8)
--   104  50        110  25
--   105  20        115  -5
--   107  15        116  0
\echo '--- T1: inner ASOF (>=), small data'
SELECT t.tid, t.sym, t.ts, q.qid, q.ts AS q_ts, q.bid
FROM trades t
ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts          -- <ASOF>
ORDER BY t.tid;

CREATE TEMP TABLE r_asof AS
SELECT t.tid, q.ts AS q_ts
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;   -- <ASOF>
CREATE TEMP TABLE r_ref AS
SELECT t.tid, q.ts AS q_ts
FROM trades t CROSS JOIN LATERAL (
    SELECT q.ts FROM quotes q
    WHERE q.sym = t.sym AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1) q;
SELECT 'T1 inner >= small' AS test,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- T2: LEFT ASOF, small data. Expected 17 rows; 103,106,111,112,113,114,117 have NULL q_ts.
\echo '--- T2: LEFT ASOF (>=), small data'
CREATE TEMP TABLE r_asof AS
SELECT t.tid, q.ts AS q_ts
FROM trades t ASOF LEFT JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts;   -- <ASOF>
CREATE TEMP TABLE r_ref AS
SELECT t.tid, q.ts AS q_ts
FROM trades t LEFT JOIN LATERAL (
    SELECT q.ts FROM quotes q
    WHERE q.sym = t.sym AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1) q ON true;
SELECT 'T2 left >= small' AS test,
       (SELECT count(*) FROM r_asof) AS rows,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- T3: strict >  (skip if unsupported). Expected 8 matches: 101 and 107 now
-- lose their exact match; 110 -> 10; 116 -> -5.
\echo '--- T3: inner ASOF (>), small data'
CREATE TEMP TABLE r_asof AS
SELECT t.tid, q.ts AS q_ts
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts > q.ts;   -- <ASOF>
CREATE TEMP TABLE r_ref AS
SELECT t.tid, q.ts AS q_ts
FROM trades t CROSS JOIN LATERAL (
    SELECT q.ts FROM quotes q
    WHERE q.sym = t.sym AND q.ts < t.ts
    ORDER BY q.ts DESC LIMIT 1) q;
SELECT 'T3 inner > small' AS test,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- T4: forward direction <=  (skip if unsupported): nearest quote at or AFTER the trade.
-- e.g. 103 -> 10, 111 -> 100, 104 -> no match.
\echo '--- T4: inner ASOF (<=), small data'
CREATE TEMP TABLE r_asof AS
SELECT t.tid, q.ts AS q_ts
FROM trades t ASOF JOIN quotes q ON t.sym = q.sym AND t.ts <= q.ts;   -- <ASOF>
CREATE TEMP TABLE r_ref AS
SELECT t.tid, q.ts AS q_ts
FROM trades t CROSS JOIN LATERAL (
    SELECT q.ts FROM quotes q
    WHERE q.sym = t.sym AND q.ts >= t.ts
    ORDER BY q.ts ASC LIMIT 1) q;
SELECT 'T4 inner <= small' AS test,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- T5: double precision time, int key.
-- Expected: 1->0.0, 2->10.5, 3->20.25, 4->5.0, 5 none, 6 none
\echo '--- T5: float time'
CREATE TEMP TABLE r_asof AS
SELECT r.rid, c.t AS c_t
FROM sensor_reads r ASOF LEFT JOIN calib c
     ON r.sensor_id = c.sensor_id AND r.t >= c.t;                     -- <ASOF>
CREATE TEMP TABLE r_ref AS
SELECT r.rid, c.t AS c_t
FROM sensor_reads r LEFT JOIN LATERAL (
    SELECT c.t FROM calib c
    WHERE c.sensor_id = r.sensor_id AND c.t <= r.t
    ORDER BY c.t DESC LIMIT 1) c ON true;
SELECT 'T5 float time' AS test,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- T6: timestamptz, time-only condition (no equality key).
-- Expected: 1->1.10, 2->1.20, 3 none, 4->1.40
\echo '--- T6: timestamptz, no equality key'
CREATE TEMP TABLE r_asof AS
SELECT e.eid, r.rate
FROM events_tz e ASOF LEFT JOIN rates_tz r ON e.at >= r.valid_from;   -- <ASOF>
CREATE TEMP TABLE r_ref AS
SELECT e.eid, r.rate
FROM events_tz e LEFT JOIN LATERAL (
    SELECT r.rate FROM rates_tz r
    WHERE r.valid_from <= e.at
    ORDER BY r.valid_from DESC LIMIT 1) r ON true;
SELECT 'T6 timestamptz no key' AS test,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- -- T7: bulk LEFT ASOF, no indexes (50k x 200k). Timing on so you can compare.
-- \echo '--- T7: bulk, no index'
-- \timing on
-- CREATE TEMP TABLE r_asof AS
-- SELECT t.tid, q.ts AS q_ts
-- FROM big_trades t ASOF LEFT JOIN big_quotes q
--      ON t.sym = q.sym AND t.ts >= q.ts;                                -- <ASOF>
-- CREATE TEMP TABLE r_ref AS
-- SELECT t.tid, q.ts AS q_ts
-- FROM big_trades t LEFT JOIN LATERAL (
--     SELECT q.ts FROM big_quotes q
--     WHERE q.sym = t.sym AND q.ts <= t.ts
--     ORDER BY q.ts DESC LIMIT 1) q ON true;
-- \timing off
-- SELECT 'T7 bulk no index' AS test,
--        (SELECT count(*) FROM r_asof) AS rows,
--        (SELECT count(q_ts) FROM r_asof) AS matched,
--        CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
--              AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
--             THEN 'PASS' ELSE 'FAIL' END AS result;
-- DROP TABLE r_asof, r_ref;

-- T8: same as T7 but with indexes, so the planner may choose differently.
\echo '--- T8: bulk, with index'
CREATE INDEX big_quotes_sym_ts ON big_quotes (sym, ts);
CREATE INDEX big_trades_sym_ts ON big_trades (sym, ts);
ANALYZE big_quotes; ANALYZE big_trades;
-- warm the cache; the first run measures disk, not the join
CREATE TEMP TABLE r_warm AS
SELECT t.tid FROM big_trades t ASOF LEFT JOIN big_quotes q
     ON t.sym = q.sym AND t.ts >= q.ts;                                -- <ASOF>
DROP TABLE r_warm;

SELECT clock_timestamp() AS t0 \gset
CREATE TEMP TABLE r_asof AS
SELECT t.tid, q.ts AS q_ts
FROM big_trades t ASOF LEFT JOIN big_quotes q
     ON t.sym = q.sym AND t.ts >= q.ts;                                -- <ASOF>
INSERT INTO bench_timings
SELECT 'T8 bulk with index', 'asof',
       round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000, 1);

SELECT clock_timestamp() AS t0 \gset
CREATE TEMP TABLE r_ref AS
SELECT t.tid, q.ts AS q_ts
FROM big_trades t LEFT JOIN LATERAL (
    SELECT q.ts FROM big_quotes q
    WHERE q.sym = t.sym AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1) q ON true;
INSERT INTO bench_timings
SELECT 'T8 bulk with index', 'lateral',
       round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz) * 1000, 1);
SELECT 'T8 bulk with index' AS test,
       CASE WHEN (SELECT count(*) FROM (TABLE r_asof EXCEPT ALL TABLE r_ref) a) = 0
             AND (SELECT count(*) FROM (TABLE r_ref EXCEPT ALL TABLE r_asof) b) = 0
            THEN 'PASS' ELSE 'FAIL' END AS result;
DROP TABLE r_asof, r_ref;

-- T9: empty inputs. Inner -> 0 rows; LEFT -> 17 rows, all NULL.
\echo '--- T9: empty build side'
SELECT 'T9 empty build, inner' AS test,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM trades t ASOF JOIN (SELECT * FROM quotes WHERE false) q           -- <ASOF>
     ON t.sym = q.sym AND t.ts >= q.ts;
SELECT 'T9 empty build, left' AS test,
       CASE WHEN count(*) = 17 AND count(q.qid) = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM trades t ASOF LEFT JOIN (SELECT * FROM quotes WHERE false) q      -- <ASOF>
     ON t.sym = q.sym AND t.ts >= q.ts;

-- T10: ASOF result feeding other operators (subquery, aggregate, extra WHERE).
-- Expected: AAPL 17 qty, GOOG 7, MSFT 17, NEG 2
\echo '--- T10: ASOF inside a larger query'
SELECT q.sym, sum(t.qty) AS qty
FROM trades t
ASOF JOIN quotes q ON t.sym = q.sym AND t.ts >= q.ts                   -- <ASOF>
WHERE t.qty > 0
GROUP BY q.sym ORDER BY q.sym;

\echo '--- EXPLAIN for the bulk query (check your plan node shows up)'
EXPLAIN (COSTS OFF)
SELECT t.tid, q.bid
FROM big_trades t ASOF LEFT JOIN big_quotes q
     ON t.sym = q.sym AND t.ts >= q.ts;                                -- <ASOF>

\echo '--- timings (same build and settings only)'
SELECT test, impl, ms FROM bench_timings ORDER BY test, impl;
