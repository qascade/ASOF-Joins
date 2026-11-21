-- Trades and quotes with :scale rows each over 50 symbols. No random(), so every machine gets the same data.

DROP TABLE IF EXISTS trades, quotes;

CREATE TABLE quotes (symbol text, ts timestamptz, bid numeric(12,4), ask numeric(12,4));
CREATE TABLE trades (symbol text, ts timestamptz, price numeric(12,4), size int);

-- g * 7919 % scale is a permutation, so quote timestamps are distinct per symbol.
INSERT INTO quotes
SELECT 'S' || lpad((g % 50)::text, 2, '0'),
       TIMESTAMPTZ '2024-01-02 09:30:00+00' + (g::bigint * 7919 % :scale) * INTERVAL '1 millisecond',
       100 + (g % 500000) / 10000.0,
       100 + (g % 500000) / 10000.0 + 0.01
FROM generate_series(1, :scale) g;

INSERT INTO trades
SELECT 'S' || lpad((g % 50)::text, 2, '0'),
       TIMESTAMPTZ '2024-01-02 09:30:00+00' + (g::bigint * 7907 % :scale) * INTERVAL '1 millisecond',
       100 + (g % 400000) / 10000.0,
       1 + (g % 1000)
FROM generate_series(1, :scale) g;

VACUUM (FREEZE, ANALYZE) quotes;
VACUUM (FREEZE, ANALYZE) trades;
