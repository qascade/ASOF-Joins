-- Only the first 1000 trades, so the unindexed run finishes at large scales.
PREPARE bench_q AS
SELECT count(q.bid)
FROM (SELECT symbol, ts FROM trades ORDER BY symbol, ts LIMIT 1000) t
LEFT JOIN LATERAL (
    SELECT q.bid FROM quotes q
    WHERE q.symbol = t.symbol AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1
) q ON true;
