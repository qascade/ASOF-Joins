# Source this from the PostgreSQL source root:   . ./pgenv.sh
# It works out every path from its own location, so it works on any machine
# and in any clone. Add it to ~/.bashrc if you want it in every shell:
#   . /path/to/postgres/pgenv.sh

export POSTGRES_SRCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export POSTGRES_INSTALLDIR="$POSTGRES_SRCDIR/install"
export PGDATA="$POSTGRES_INSTALLDIR/data"
export PATH="$POSTGRES_INSTALLDIR/bin:$PATH"
export LD_LIBRARY_PATH="$POSTGRES_INSTALLDIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The server, psql and createdb all read PGPORT, so you never type -p 9432
# and you don't need to edit postgresql.conf.
export PGPORT=9432

# macOS: Homebrew's bison (3.8+) and m4 are keg-only, so they are not on PATH by
# default. We need bison 3.8 for -Wcounterexamples when working on gram.y, and that
# bison needs a real m4 (the /usr/bin/m4 shim only asks you to install Xcode tools).
# No-ops on Linux, where brew is absent.
if command -v brew >/dev/null 2>&1; then
    for _pg_keg in bison m4; do
        _pg_kegdir="$(brew --prefix "$_pg_keg" 2>/dev/null)/bin"
        [ -d "$_pg_kegdir" ] && export PATH="$_pg_kegdir:$PATH"
    done
    unset _pg_keg _pg_kegdir
fi
