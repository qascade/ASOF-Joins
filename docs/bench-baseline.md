# Baseline: the hand-written LATERAL query

Phase 1 rewrites `ASOF JOIN` into this query, and Phase 2's native join has to beat it:

```sql
SELECT count(q.bid)
FROM trades t
LEFT JOIN LATERAL (
    SELECT q.bid FROM quotes q
    WHERE q.symbol = t.symbol AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1
) q ON true;
```

Without an index every trade scans all of `quotes`, `O(n·m)`. With an index on
`quotes (symbol, ts DESC)` it is one index probe per trade, `O(n log m)`.

## How to reproduce

Build without assertions (`./configure --without-icu CFLAGS='-O2'`), start that server,
put its `psql` on `PATH`, keep the machine awake (`caffeinate -dims` on macOS), then:

```sh
bench/run.sh 100000 1000000 10000000
```

Raw output goes to `bench/results/`.

## Setup

Apple M3, 8 cores, 16 GB, macOS 14.5. PostgreSQL 18.6 at `8711aa4`, `-O2`, no
assertions, default `shared_buffers` (128MB), `jit = off`. Warm cache, median of three
runs after one warmup, 600 s statement timeout.

## Results: full join

| scale | no index | `(symbol, ts DESC)` |
|---|---|---|
| 1e5 | 411.5 s | 688 ms |
| 1e6 | > 600 s (timeout) | 6.99 s |
| 1e7 | > 600 s (timeout) | 137.0 s |

## Results: first 1000 trades, no index

| scale | median | per trade |
|---|---|---|
| 1e5 | 3.18 s | 3.2 ms |
| 1e6 | 30.8 s | 31 ms |
| 1e7 | 355.5 s | 356 ms |

The per-trade cost grows 10× for every 10× of `quotes`, a full scan per trade.

## Caveats

- At 1e7 the index and table (876 MB) do not fit in `shared_buffers`, and about 45% of
  the indexed run is page reads. That is why the cost per trade doubles from 1e6.
- Rows are stored out of `(symbol, ts)` order. That hurts the indexed nested loop and
  not a sort-merge join, so it favours Phase 2. #22 should say so.
- Cold cache was not measured.
