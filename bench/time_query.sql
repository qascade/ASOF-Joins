-- Times the bench_q statement in :query. One warmup, then three timed runs.

\set ON_ERROR_STOP on
SET jit = off;
SET track_io_timing = on;
SET statement_timeout = '600s';
SELECT current_setting('debug_assertions') AS debug_assertions;

\i :query
EXPLAIN EXECUTE bench_q;

\timing on
EXECUTE bench_q;
EXECUTE bench_q;
EXECUTE bench_q;
EXECUTE bench_q;
\timing off

EXPLAIN (ANALYZE, BUFFERS) EXECUTE bench_q;
