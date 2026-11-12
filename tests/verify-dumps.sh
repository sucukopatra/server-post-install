#!/usr/bin/env bash
set -euo pipefail

src=$(dirname "$0")/../files/scripts/backup.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=/dev/null
source <(sed -n '/^\(decompress\|verify_dumps\|exclude_sql_dirs\|dump_sqlite\|valid_[a-z]*_dump\)() {/,/^}/p' "$src")

log()  { :; }
warn() { WARNS+=("$*"); }
fail() { FAILURES+=("$*"); }

restic() {
  local p=${*: -1}
  [[ -z ${RESTIC_DOWN:-} ]] || { echo 'Fatal: unable to open repository' >&2; return 1; }
  [[ -f $work/snap$p ]] || { echo "cannot dump file: path \"$p\" not found in snapshot" >&2; return 1; }
  cat "$work/snap$p"
}

BACKUP_HOST=bmo BACKUP_TAG=bmo
CONFIG=$work/disk/config DATA=$work/disk/data
DUMP_DIR=$CONFIG/_dumps VERIFY_STAMP=$work/stamp
declare -A SQL_ENGINE=([pg]=postgres [maria]=mariadb)
SQLITE_DUMPED=()
imm=$DATA/photos/backups/immich-db-backup-1.sql.gz

setup() {
  rm -rf "$work/disk" "$work/snap"
  mkdir -p "$DUMP_DIR" "$(dirname "$imm")"
  printf 'x\n--\n-- PostgreSQL database cluster dump complete\n--\n\n' > "$DUMP_DIR/pg.sql"
  printf 'x\n-- Dump completed on 2026-08-09  3:30:01\n' > "$DUMP_DIR/maria.sql"
  printf 'x\n-- PostgreSQL database dump complete\n' | gzip > "$imm"
  touch -d '-1 hour' "$imm"
  : > "$imm.tmp"
  for f in "$DUMP_DIR/pg.sql" "$DUMP_DIR/maria.sql" "$imm"; do
    install -D -m 0600 "$f" "$work/snap$f"
  done
}

rc=0
check() {
  local name=$1 want_fails=$2 want_stamp=$3 got_stamp=0
  FAILURES=() WARNS=() VERIFY_TMP=""
  rm -f "$VERIFY_STAMP"
  verify_dumps
  rm -rf "$VERIFY_TMP"
  [[ -f $VERIFY_STAMP ]] && got_stamp=1
  if (( ${#FAILURES[@]} == want_fails && got_stamp == want_stamp )); then
    echo "ok   $name"
  else
    echo "FAIL $name: ${#FAILURES[@]} failure(s), stamp=$got_stamp"
    printf '     %s\n' "${FAILURES[@]}" "${WARNS[@]}"
    rc=1
  fi
}

setup
check "complete dumps verify and stamp; Immich .tmp ignored" 0 1

setup
printf 'x\nCREATE TABLE half' > "$work/snap$DUMP_DIR/pg.sql"
check "truncated pg dump fails" 1 0

setup
rm "$work/snap$DUMP_DIR/maria.sql"
check "dump missing from snapshot fails" 1 0

setup
{ printf '\x1f\x8b\x08\x00\x00\x00\x00\x00'; head -c 1000000 /dev/urandom; } > "$work/snap$imm"
check "corrupt Immich archive fails without aborting" 1 0

setup
RESTIC_DOWN=1 check "unreachable repository warns, no stamp" 0 0

have_docker() { :; }
running() { [[ $1 == "${RUNNING:-}" ]]; }
DUMP_STALE_HOURS=48
declare -A SQL_LIVE_DIR=([pg]=$CONFIG/pg-live)

check_excl() {
  local name=$1 want_excluded=$2 want_fails=$3 got=0
  FAILURES=() EXCLUDES=$work/excludes
  : > "$EXCLUDES"
  exclude_sql_dirs
  grep -qxF "$CONFIG/pg-live" "$EXCLUDES" && got=1
  if (( got == want_excluded && ${#FAILURES[@]} == want_fails )); then
    echo "ok   $name"
  else
    echo "FAIL $name: excluded=$got, ${#FAILURES[@]} failure(s)"
    rc=1
  fi
}

setup; mkdir "$CONFIG/pg-live"
RUNNING=pg check_excl "fresh dump excludes the live directory" 1 0

setup; mkdir "$CONFIG/pg-live"; touch -d '-3 days' "$DUMP_DIR/pg.sql"
RUNNING=pg check_excl "stale dump still excludes, and fails" 1 1

setup; mkdir "$CONFIG/pg-live"; rm "$DUMP_DIR/pg.sql"
RUNNING=pg check_excl "running engine without a dump stays in, and fails" 0 1

setup; mkdir "$CONFIG/pg-live"; rm "$DUMP_DIR/pg.sql"
check_excl "stopped engine without a dump stays in" 0 0

setup; mkdir -p "$CONFIG/app" "$DUMP_DIR/sqlite/gone"
sqlite3 "$CONFIG/app/live.db" 'CREATE TABLE t(x)'
: > "$DUMP_DIR/sqlite/gone/old.db"
FAILURES=() SQLITE_DUMPED=()
dump_sqlite
if [[ -s $DUMP_DIR/sqlite/app/live.db && ! -e $DUMP_DIR/sqlite/gone/old.db ]] && (( ${#FAILURES[@]} == 0 )); then
  echo "ok   SQLite dump not rewritten tonight is gone, live one dumped"
else
  echo "FAIL SQLite dumps: live dumped=$([[ -s $DUMP_DIR/sqlite/app/live.db ]] && echo y || echo n), stale left=$([[ -e $DUMP_DIR/sqlite/gone/old.db ]] && echo y || echo n), ${#FAILURES[@]} failure(s)"
  rc=1
fi

exit $rc
