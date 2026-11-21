CREATE INDEX quotes_symbol_ts_desc_idx ON quotes (symbol, ts DESC);
ANALYZE quotes;
