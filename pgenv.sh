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