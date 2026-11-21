-- count(q.bid), not count(*), so the planner cannot skip the subquery.
PREPARE bench_q AS
SELECT count(q.bid)
FROM trades t
LEFT JOIN LATERAL (
    SELECT q.bid FROM quotes q
    WHERE q.symbol = t.symbol AND q.ts <= t.ts
    ORDER BY q.ts DESC LIMIT 1
) q ON true;
