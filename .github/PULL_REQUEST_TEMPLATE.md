<!-- Title must be a Conventional Commit: <type>(<scope>): <subject>
     e.g. feat(parser): add ASOF and MATCH_CONDITION keywords
     CI checks this, and because we squash-merge it becomes the commit subject on main. -->

## What this changes

<!-- One or two sentences. Link the issue: Closes #N -->

Closes #

## Layer

<!-- Tick the layers this PR touches. Keep a PR to one layer where possible. -->

- [ ] Parser / grammar (`gram.y`, `kwlist.h`, `primnodes.h`)
- [ ] Analyzer / rewrite (`parse_clause.c`, `parse_asof.c`)
- [ ] Planner (`joinpath.c`, `pathnode.c`, `costsize.c`, `createplan.c`)
- [ ] Executor (`nodeAsofjoin.c`, `execnodes.h`, `execProcnode.c`)
- [ ] EXPLAIN / deparse (`explain.c`, `ruleutils.c`)
- [ ] Tests / benchmark / docs / CI

## Approach

<!-- Why this way? Note anything a reviewer would otherwise have to reconstruct:
     an invariant you rely on, a switch you had to extend, a semantic corner you chose. -->

## Regression output

<!-- Paste the summary line from `make check`. A PR that has not been run is not ready. -->

```
make check: ... of ... tests passed
```

- [ ] `make check` is green locally
- [ ] New or changed behaviour has a test in `src/test/regress/sql/asof_join.sql`
- [ ] `EXPLAIN` output in the tests is stable (no row counts or timings)

## Semantics touched

<!-- Delete if not applicable. Otherwise say what you chose and where it is documented. -->

- [ ] NULL handling
- [ ] Ties on the match column
- [ ] Strict vs non-strict operators (`>` / `>=`)
- [ ] Outer vs inner semantics
- [ ] None of the above

## Review notes

<!-- Reviewer is named on the issue. Point them at the file to read first,
     and anything you are unsure about. -->
