#!/bin/sh
# Times the LATERAL baseline at each scale, without and then with the index.
# Usage: bench/run.sh [scale ...]. Needs psql on PATH and a server built without assertions.

cd "$(dirname "$0")"
mkdir -p results

for scale in ${*:-100000 1000000 10000000}; do
    psql -X -q -d postgres -c 'DROP DATABASE IF EXISTS asof_bench' -c 'CREATE DATABASE asof_bench'
    psql -X -q -d asof_bench -v scale="$scale" -f gen_data.sql

    for index in noindex index; do
        [ "$index" = index ] && psql -X -q -d asof_bench -f create_index.sql
        for query in baseline_lateral baseline_lateral_sampled; do
            out="results/$query-$scale-$index.txt"
            psql -X -d asof_bench -v query="queries/$query.sql" -f time_query.sql > "$out" 2>&1 ||
                echo 'timed out' >> "$out"
            echo "$out"
            grep -E '^Time:|timed out' "$out"
        done
    done
done

psql -X -q -d postgres -c 'DROP DATABASE IF EXISTS asof_bench'
