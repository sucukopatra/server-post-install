#!/usr/bin/env bash
#
# bmo backup -- installed as /usr/local/sbin/bmo-backup, driven by
# bmo-backup.timer. Safe to run by hand at any time.
#
# Reads /etc/bmo-backup.env (written by run.sh) and nothing else, so it
# does not need the git checkout it came from.
#
# It never runs `restic init`: init against a live repo orphans every
# existing snapshot. $NAS is not backed up -- it is re-acquirable bulk
# media, on the same box the repository lives on.

set -euo pipefail

ENV_FILE=/etc/bmo-backup.env
LOCK_FILE=/run/bmo-backup.lock

# Persistent across reboots, unlike /run: it records when the last
# repository check passed.
STATE_DIR=/var/lib/bmo-backup
CHECK_STAMP="$STATE_DIR/last-check"
VERIFY_STAMP="$STATE_DIR/last-verify"

log()  { printf '%s  %s\n'     "$(date +%H:%M:%S)" "$*"; }
warn() { printf '%s  WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
# DIE_REASON is what the failure ping reports: by the time the EXIT trap
# runs, the message has gone to stderr and only the exit status is left.
DIE_REASON=""
die()  { DIE_REASON=$*; printf '%s  ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Collected rather than fatal: one broken dump should not cost the whole
# night's backup. They set the exit status at the end, so systemd still
# marks the run failed.
FAILURES=()
fail() { warn "$*"; FAILURES+=("$*"); }

[[ $EUID -eq 0 ]] || die "must run as root (restic reads /root/.ssh and every config dir)"

[[ -r $ENV_FILE ]] || die "$ENV_FILE missing -- run run.sh --full to write it"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

for v in RESTIC_REPOSITORY RESTIC_PASSWORD_FILE CONFIG DATA; do
  [[ -n ${!v:-} ]] || die "$v is unset in $ENV_FILE"
done
[[ -r $RESTIC_PASSWORD_FILE ]] || die "cannot read $RESTIC_PASSWORD_FILE"

# Dead-man's switch: ping on start, success and failure. Not OnFailure=,
# which cannot report a dead host or a disabled timer. Empty disables it;
# a failed ping never fails the backup.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# Bounded: at curl's defaults a blackholed endpoint costs ~46s per ping.
ping_hc() {
  local path=${1:-} body=${2:-} retries=${3:-2}
  [[ -n $HEALTHCHECK_URL ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -m 5 --retry "$retries" --retry-delay 2 --retry-max-time 20 \
       -X POST --data-raw "$body" \
       "${HEALTHCHECK_URL%/}${path}" >/dev/null 2>&1 || true
}

# One EXIT trap for the whole run, installed before anything below can
# fail, so every way out reports itself.
NO_PING=0
on_exit() {
  local rc=$? body
  [[ -n ${EXCLUDES:-} ]] && rm -f "$EXCLUDES"
  # Same trap, not a second one: `trap ... EXIT` installed later would
  # replace this handler outright and the run would stop reporting.
  [[ -n ${VERIFY_TMP:-} ]] && rm -rf "$VERIFY_TMP"
  (( ${MC_SAVE_OFF:-0} )) && { mc_rcon save-on || true; }
  (( NO_PING )) && return
  if (( rc == 0 )); then
    ping_hc "" "${SUMMARY:-backup completed}"
  else
    body="exit status $rc"
    [[ -n $DIE_REASON ]] && body+="
ERROR: $DIE_REASON"
    (( ${#FAILURES[@]} )) && body+="
$(printf -- '- %s\n' "${FAILURES[@]}")"
    body+="

full log: journalctl -u bmo-backup.service -n 200"
    ping_hc /fail "$body"
  fi
}
trap on_exit EXIT

# restic reads these from the environment, so no -r or --password-file
# flags below.
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

# The sftp backend shells out to ssh, which needs root's ~/.ssh/config for
# the `nas` host alias. systemd sets HOME, but a bare `sudo` may not.
export HOME="${HOME:-/root}"

# Scopes `forget` below, so it must stay stable across runs and across a
# reinstall -- a renamed host otherwise starts a second snapshot history
# whose retention never touches the first. run.sh pins it in $ENV_FILE.
BACKUP_HOST="${BACKUP_HOST:-${HOSTNAME%%.*}}"

# Tested on the value: an empty /etc/hostname must not mean --host "".
if [[ -z $BACKUP_HOST ]]; then
  BACKUP_HOST=$(cat /etc/hostname 2>/dev/null || true)
  BACKUP_HOST=${BACKUP_HOST//[[:space:]]/}
fi
[[ -n $BACKUP_HOST ]] || die "cannot determine hostname -- set BACKUP_HOST in $ENV_FILE"
BACKUP_TAG="${BACKUP_TAG:-bmo}"

KEEP_LAST="${KEEP_LAST:-3}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

# How often `restic check` runs, in days. Metadata-only, but it walks the
# whole index over sftp, which grows with the repository. 0 means every
# run; RESTIC_CHECK=0 disables it outright.
CHECK_INTERVAL_DAYS="${CHECK_INTERVAL_DAYS:-7}"

# A dump not refreshed in this many days belongs to a service that no longer
# runs. Generous: a stopped container's dump is the only copy of its database.
DUMP_KEEP_DAYS="${DUMP_KEEP_DAYS:-30}"

# How stale a dump may be before the run reports it, apart from deletion
# above. Two nights, so one failure already made good is not reported.
DUMP_STALE_HOURS="${DUMP_STALE_HOURS:-48}"

# How long to wait for a running database container to answer; on timeout
# the dump is tried anyway.
DB_READY_TIMEOUT="${DB_READY_TIMEOUT:-300}"

# How often the dumps are read back from the repository and validated, in
# days. 0 means every run; VERIFY_DUMPS=0 disables it.
VERIFY_INTERVAL_DAYS="${VERIFY_INTERVAL_DAYS:-7}"

for v in CHECK_INTERVAL_DAYS DUMP_KEEP_DAYS DUMP_STALE_HOURS DB_READY_TIMEOUT \
         VERIFY_INTERVAL_DAYS; do
  [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number, got '${!v}'"
done

command -v restic >/dev/null || die "restic is not installed"

# One run at a time. bmo-restore and docker-update.service take this lock
# too, so a backup cannot snapshot a half-restored host as `latest` and prune.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  # No alarm: whoever holds the lock reports for tonight.
  NO_PING=1
  die "another backup, a restore or an image update is already running (holds $LOCK_FILE)"
fi

# The run really starts here, so the monitor's clock does too.
ping_hc /start "" 0

[[ -d $CONFIG ]] || die "CONFIG=$CONFIG does not exist"
[[ -d $DATA   ]] || die "DATA=$DATA does not exist"

# An unmounted $DATA is an empty directory; backing it up looks like a mass
# deletion and ages the real snapshots out.
if [[ ${DATA_IS_MOUNT:-1} == 1 ]] && ! mountpoint -q "$DATA"; then
  die "$DATA is not a mount point -- data disk missing? (set DATA_IS_MOUNT=0 in $ENV_FILE to allow)"
fi

# Same reasoning, cruder: a wiped or not-yet-populated config tree.
if [[ -z $(find "$CONFIG" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  die "$CONFIG is empty -- refusing to record that as a backup"
fi

# A killed run (reboot, OOM) leaves a lock behind. `unlock` without
# --remove-all only clears locks whose process is gone, so it cannot
# disturb a legitimately running restic elsewhere.
restic unlock >/dev/null 2>&1 || true

if ! restic cat config >/dev/null 2>&1; then
  warn "cannot open $RESTIC_REPOSITORY"
  warn "wrong passphrase, no SSH access as root, or the repo does not exist."
  warn "If it genuinely does not exist yet, create it by hand -- this script"
  warn "will not, because init on a live repo orphans every snapshot:"
  warn "  restic -r $RESTIC_REPOSITORY --password-file $RESTIC_PASSWORD_FILE init"
  exit 1
fi
log "repository open: $RESTIC_REPOSITORY"

# A file copy of a live database is not a backup, so each engine is dumped
# here and its data directory excluded below. Uncompressed, so restic can
# deduplicate and compress it.

DUMP_DIR="$CONFIG/_dumps"
install -d -m 0700 "$DUMP_DIR"

have_docker() { command -v docker >/dev/null; }

running() {
  [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]
}

# Wait until a database container can answer queries: 'running' starts
# before the socket is bound. Health status first, $probe for an image
# without one. A timeout is advisory; callers dump anyway. Duplicated in
# restore.sh on purpose: both are installed standalone.
wait_ready() {
  local c=$1 probe=${2:-} timeout=${3:-$DB_READY_TIMEOUT}
  local waited=0 interval=2 state health inspected

  while (( waited < timeout )); do
    # Status and health in one inspect; the separator cannot appear in either.
    state=missing health=""
    if inspected=$(docker inspect \
         -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
         "$c" 2>/dev/null); then
      state=${inspected%%|*}; health=${inspected#*|}
    fi
    case $state in
      running) ;;
      # Gone or stopped while we watched. Waiting out the timeout would
      # only delay the rest of the backup; the caller reports it.
      missing|exited|dead) return 1 ;;
      *) sleep "$interval"; waited=$(( waited + interval )); continue ;;
    esac

    if [[ -n $health ]]; then
      if [[ $health == healthy ]]; then
        (( waited )) && log "  $c ready after ${waited}s"
        return 0
      fi
    elif [[ -n $probe ]]; then
      if docker exec "$c" sh -c "$probe" >/dev/null 2>&1; then
        (( waited )) && log "  $c answering after ${waited}s"
        return 0
      fi
    else
      # No healthcheck and no probe: dump blind rather than skip.
      return 0
    fi

    sleep "$interval"; waited=$(( waited + interval ))
  done

  return 1
}

# A dump can exit 0 and still be truncated; both engines end a complete dump
# with a fixed trailer. tail -c, not grep, on files of hundreds of MB.
valid_postgres_dump() {
  tail -c 200 | grep -q 'PostgreSQL database cluster dump complete'
}

valid_mariadb_dump() {
  tail -c 200 | grep -q '^-- Dump completed'
}

# Temp file and rename, so a failed or truncated dump keeps yesterday's good
# copy. The staleness check below is what then reports it aging.
dump_to() {
  local out=$1 validate=$2; shift 2
  if "$@" > "$out.tmp" && [[ -s $out.tmp ]] && "$validate" < "$out.tmp"; then
    mv -f "$out.tmp" "$out"
    log "  dumped $(basename "$out") ($(du -h "$out" | cut -f1))"
    return 0
  fi
  rm -f "$out.tmp"
  return 1
}

# The single-quoted sh -c bodies in both dump functions are intentional:
# the variables expand inside the *container*, so no credentials land on
# the host.
# shellcheck disable=SC2016
dump_postgres() {
  local container=$1
  running "$container" || return 0
  wait_ready "$container" 'exec pg_isready -U "${POSTGRES_USER:-postgres}"' \
    || warn "$container not ready after ${DB_READY_TIMEOUT}s -- dumping anyway"
  # The official image trusts local socket connections, so no credentials
  # are needed here.
  dump_to "$DUMP_DIR/$container.sql" valid_postgres_dump \
    docker exec "$container" sh -c 'exec pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' \
    || fail "pg_dumpall failed or produced a truncated dump for $container"
}

# Single-quoted sh -c body again -- see dump_postgres above.
# shellcheck disable=SC2016
dump_mariadb() {
  local container=$1
  running "$container" || return 0
  wait_ready "$container" 'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb-admin -u root ping' \
    || warn "$container not ready after ${DB_READY_TIMEOUT}s -- dumping anyway"
  # MYSQL_PWD rather than -p keeps the password out of the container's
  # process list.
  dump_to "$DUMP_DIR/$container.sql" valid_mariadb_dump \
    docker exec "$container" sh -c '
      export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
      if command -v mariadb-dump >/dev/null; then d=mariadb-dump; else d=mysqldump; fi
      exec "$d" -u root --all-databases --single-transaction --quick --routines --events' \
    || fail "mariadb-dump failed or produced a truncated dump for $container"
}

# Everything else is SQLite. `.backup` is the only correct copy of a database
# open in WAL mode. Databases are discovered, and recorded as exact paths.
SQLITE_DUMPED=()

dump_sqlite() {
  rm -rf "$DUMP_DIR/sqlite"
  if ! command -v sqlite3 >/dev/null; then
    fail "sqlite3 not installed -- SQLite databases copied as live files, may restore torn"
    return 0
  fi

  local db rel out magic n=0
  while IFS= read -r db; do
    # Dot-commands take a single-quoted path, which a quote in the name
    # would break out of.
    [[ $db == *"'"* ]] && { fail "skipping path with a quote: $db"; continue; }

    # *.db is not always SQLite. The builtin read avoids a fork per file.
    magic=""; read -r -N 15 magic < "$db" 2>/dev/null || true
    [[ $magic == "SQLite format 3" ]] || continue

    rel=${db#"$CONFIG"/}
    out="$DUMP_DIR/sqlite/$rel"
    install -d -m 0700 "$(dirname "$out")"

    # integrity_check on the copy: it is about to be the only copy in the backup.
    if sqlite3 "$db" ".backup '$out.tmp'" 2>/dev/null && [[ -s $out.tmp ]] \
       && [[ $(sqlite3 "$out.tmp" 'PRAGMA integrity_check' 2>/dev/null) == ok ]]; then
      # Carry the live file's owner and mode onto the dump (sqlite3 runs as root),
      # so restore.sh's cp -a puts them back.
      chown --reference="$db" "$out.tmp" 2>/dev/null || true
      chmod --reference="$db" "$out.tmp" 2>/dev/null || true
      mv -f "$out.tmp" "$out"
      SQLITE_DUMPED+=("$db")
      (( ++n ))
    else
      rm -f "$out.tmp"
      fail "sqlite3 .backup failed or produced a corrupt copy for $db"
    fi
  done < <(find "$CONFIG" -path "$DUMP_DIR" -prune -o \
                -type f \( -name '*.sqlite3' -o -name '*.sqlite' -o -name '*.db' \) -print)

  log "  dumped $n SQLite database(s)"
}

# Immich's own scheduled dump is version-aware in a way a plain pg_dumpall
# is not (the vectorchord extension needs handling on restore), so let it
# do the job and only check that it still is.
check_immich_dump() {
  local dir="$DATA/photos/backups" newest total
  running immich_postgres || return 0

  # Matched by name: Immich also keeps a zero-byte `.immich` marker here. Strict
  # prefix, loose suffix; an upstream rename reads as 'no dump', a false alarm.
  local pat='immich-db-backup-*.sql*'
  newest=$(find "$dir" -type f -name "$pat" ! -name '*.tmp' -newermt '-48 hours' -print -quit 2>/dev/null || true)
  if [[ -n $newest ]]; then
    log "  immich self-dump is current ($(basename "$newest"))"
  else
    total=$(find "$dir" -type f -name "$pat" ! -name '*.tmp' 2>/dev/null | wc -l || true)
    fail "no immich database dump under $dir in the last 48h ($total dump(s) total) -- check Immich's backup setting"
  fi
}

# The engine databases: container, engine, live data directory. One table for
# the dump loop and the exclusion loop, so a dumped container cannot miss its
# exclusion.
declare -A SQL_ENGINE=(
  [immich_postgres]=postgres      # immich's own dump is the restore path
  [romm-db]=mariadb
)
declare -A SQL_LIVE_DIR=(
  [immich_postgres]="$CONFIG/immich/database"
  [romm-db]="$CONFIG/romm/mysql"
)

log "dumping databases"
if have_docker; then
  # Sorted, so the log reads the same every night.
  for c in $(printf '%s\n' "${!SQL_ENGINE[@]}" | sort); do
    case ${SQL_ENGINE[$c]} in
      postgres) dump_postgres "$c" ;;
      mariadb)  dump_mariadb  "$c" ;;
      *)        fail "no dump method for engine '${SQL_ENGINE[$c]}' ($c)" ;;
    esac
  done
  check_immich_dump
else
  fail "docker not found -- database dumps skipped"
fi
dump_sqlite

# Remove dumps not refreshed in DUMP_KEEP_DAYS (a dropped service). Age, not
# 'written this run': a failed or stopped service's dump is its only copy.
# `|| true` so housekeeping cannot abort the run.
stale=$(find "$DUMP_DIR" -type f ! -newermt "-${DUMP_KEEP_DAYS} days" -print -delete 2>/dev/null | wc -l || true)
if (( stale )); then
  log "  removed $stale dump(s) not refreshed in ${DUMP_KEEP_DAYS} days"
  # -mindepth 1 so $DUMP_DIR itself survives being emptied.
  find "$DUMP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

# Removed by the EXIT trap above; a second EXIT trap would replace it.
EXCLUDES=$(mktemp)

cat > "$EXCLUDES" <<EOF
# Regenerated from the originals on demand; large, and churns every night.
# Immich writes its derivatives under its library root, so there are no
# \$CONFIG/immich equivalents to list here.
$DATA/photos/thumbs
$DATA/photos/encoded-video
$CONFIG/jellyfin/cache
$CONFIG/jellyfin/transcodes
$CONFIG/navidrome/cache
$CONFIG/romm/resources
$CONFIG/romm/redis

# Partial dumps from a run that died midway. Both forms on purpose: '**'
# is not guaranteed to match zero path components.
$DUMP_DIR/*.tmp
$DUMP_DIR/**/*.tmp

# There is deliberately no \$DATA/*.log rule. Every \${DATA} mount in the
# enabled stacks is a subdirectory, so no container can write a file at
# the root of \$DATA. If one ever does, exclude it then, on evidence.
EOF

# Live database directories, excluded ONLY when their dump is on disk, so a
# snapshot can never hold neither.
exclude_sql_dirs() {
  local c live
  for c in "${!SQL_LIVE_DIR[@]}"; do
    live=${SQL_LIVE_DIR[$c]}
    # Not deployed here: nothing to exclude and nothing to warn about.
    [[ -d $live ]] || continue
    if [[ -s $DUMP_DIR/$c.sql ]]; then
      printf '%s\n' "$live" >> "$EXCLUDES"

      # Existence is not freshness: a dump that keeps failing leaves an old copy in
      # place, and this is what says the snapshot no longer has a current one.
      if [[ -z $(find "$DUMP_DIR/$c.sql" -newermt "-${DUMP_STALE_HOURS} hours" -print -quit 2>/dev/null) ]]; then
        fail "$DUMP_DIR/$c.sql has not been refreshed in ${DUMP_STALE_HOURS}h -- the snapshot excludes the live $live in favour of a stale dump"
      fi
    elif have_docker && running "$c"; then
      # Engine up and no dump: the copy going into the snapshot is being
      # written to as it is read. Worth failing the run over.
      fail "no dump at $DUMP_DIR/$c.sql and $c is running -- keeping the live $live in the backup instead, which may restore torn"
    else
      # A stopped engine's data directory copies fine.
      log "  no dump for $c and it is not running -- backing up the live $live (safe: engine stopped)"
    fi
  done
}
exclude_sql_dirs

# Exclude the live SQLite files whose clean copy is in $DUMP_DIR/sqlite, with
# their -wal/-shm/-journal sidecars. A failed dump keeps its live file in.
if (( ${#SQLITE_DUMPED[@]} )); then
  for db in "${SQLITE_DUMPED[@]}"; do
    printf '%s\n%s-wal\n%s-shm\n%s-journal\n' "$db" "$db" "$db" "$db"
  done >> "$EXCLUDES"
  log "  excluding ${#SQLITE_DUMPED[@]} live SQLite file(s) in favour of their dumps"
fi

# $DUMP_DIR is inside $CONFIG, so this travels in the snapshot and lands
# with the files it describes.
cat > "$DUMP_DIR/README" <<EOF
These are database dumps, written by /usr/local/sbin/bmo-backup before
each snapshot. They are not spare copies -- for most of them they are the
ONLY copy in the backup, because the live files are excluded from it.

  sqlite/<path>     A clean copy, via SQLite's online backup API, of the
                    live file at \$CONFIG/<path>. That live file is NOT
                    in the snapshot. Restoring means copying this back
                    over it, with the service stopped.

  <container>.sql   pg_dumpall / mariadb-dump output. The engine's data
                    directory is NOT in the snapshot. Restoring means
                    feeding this to a running, empty engine.

Immich is the exception: it dumps its own database, version-aware, to
\$DATA/photos/backups, and that is the file to restore from.

Anything here not refreshed in ${DUMP_KEEP_DAYS} days is removed as belonging to a
service that no longer exists.
EOF

# Kept on purpose, in case it looks like an omission later:
#   $CONFIG/caddy/data  -- ACME account key and issued certs. Small, and
#                          restoring it avoids re-issuing into a rate limit.
#   $DATA/photos/backups -- Immich's own database dumps (see above).

mc_rcon() { docker exec minecraft-server rcon-cli "$@" >/dev/null 2>&1; }
MC_SAVE_OFF=0
if have_docker && running minecraft-server && mc_rcon save-off; then
  MC_SAVE_OFF=1
  mc_rcon save-all flush || warn "minecraft save-all failed -- the world may be copied mid-save"
fi

log "backing up $CONFIG and $DATA"
if restic backup \
     --host "$BACKUP_HOST" \
     --tag "$BACKUP_TAG" \
     --one-file-system \
     --exclude-caches \
     --exclude-file "$EXCLUDES" \
     --cleanup-cache \
     "$CONFIG" "$DATA"
then
  log "backup complete"
  (( MC_SAVE_OFF )) && mc_rcon save-on && MC_SAVE_OFF=0
else
  # No prune after a failed backup: retention would be applied against an
  # incomplete picture of what exists.
  die "restic backup failed -- not pruning"
fi

# --host and --tag keep this to snapshots this script made: a repo shared
# with another machine holds snapshots that are not ours to age out.
log "applying retention (last=$KEEP_LAST daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
restic forget --prune \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG" \
  --keep-last    "$KEEP_LAST" \
  --keep-daily   "$KEEP_DAILY" \
  --keep-weekly  "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  || fail "restic forget/prune failed"

# Structural check only. The interval runs from a stamp written on success,
# since bmo is not always on; a failing repository is re-checked next run.
if [[ ${RESTIC_CHECK:-1} != 1 ]]; then
  log "repository check disabled (RESTIC_CHECK=0)"
else
  install -d -m 0700 "$STATE_DIR"
  last_check=0
  if [[ -r $CHECK_STAMP ]]; then
    last_check=$(<"$CHECK_STAMP")
    [[ $last_check =~ ^[0-9]+$ ]] || last_check=0
  fi
  since_days=$(( ( $(date +%s) - last_check ) / 86400 ))

  if (( CHECK_INTERVAL_DAYS == 0 || since_days >= CHECK_INTERVAL_DAYS )); then
    log "checking repository"
    if restic check; then
      date +%s > "$CHECK_STAMP"
    else
      fail "restic check reported problems"
    fi
  else
    log "repository checked ${since_days}d ago, next in $(( CHECK_INTERVAL_DAYS - since_days ))d"
  fi
fi

# ------------------------------------------------------- verifying dumps

# `restic check` proves the repository is sound; this proves the dumps can be
# read back and are whole. Streamed where possible, so verifying does not
# fill the disk.

decompress() {
  if [[ $1 == *.gz ]]; then gzip -dc; else cat; fi
}

verify_dumps() {
  local -a filter=( --host "$BACKUP_HOST" --tag "$BACKUP_TAG" )
  local c path tail_out rc gz imm db rel sdump
  local n=0 bad=0 unread=0

  VERIFY_TMP=$(mktemp -d)
  local rcf="$VERIFY_TMP/rc" gzf="$VERIFY_TMP/gz" errf="$VERIFY_TMP/err"

  log "verifying dumps in the latest snapshot"

  # `latest` is resolved by restic against --host/--tag.
  for c in $(printf '%s\n' "${!SQL_ENGINE[@]}" | sort); do
    path="$DUMP_DIR/$c.sql"
    # A dump on disk must be in the snapshot: its live directory was excluded.
    [[ -s $path ]] || continue

    # restic's own status via a file: PIPESTATUS does not cross a command
    # substitution, and 'cannot fetch' must not read as 'corrupt'.
    tail_out=$( { restic "${filter[@]}" dump latest "$path" 2>"$errf"; echo $? >"$rcf"; } \
                | tail -c 200 )
    rc=$(<"$rcf")

    if (( rc != 0 )) && grep -q 'not found in snapshot' "$errf"; then
      fail "$c.sql is on disk but missing from the latest snapshot -- the live database directory was excluded in its favour, so that database is in no copy at all"
      bad=$(( bad + 1 ))
    elif (( rc != 0 )); then
      warn "  $c.sql: could not be read back from the repository"
      unread=1
    elif "valid_${SQL_ENGINE[$c]}_dump" <<< "$tail_out"; then
      log "  $c.sql: complete"
      n=$(( n + 1 ))
    else
      fail "$c.sql in the latest snapshot is truncated -- the live database directory is excluded from that snapshot, so this is its only copy"
      bad=$(( bad + 1 ))
    fi
  done

  # Immich's own dump: decompressing proves the archive, the trailer proves the
  # dump. Matches both the pg_dump and pg_dumpall trailers.
  imm=$(find "$DATA/photos/backups" -type f -name 'immich-db-backup-*.sql*' ! -name '*.tmp' \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [[ -n $imm ]]; then
    tail_out=$( { restic "${filter[@]}" dump latest "$imm" 2>"$errf"; echo $? >"$rcf"; } \
                | { decompress "$imm" 2>/dev/null; echo $? >"$gzf"; cat >/dev/null; } \
                | tail -c 200 )
    rc=$(<"$rcf") gz=$(<"$gzf")

    if (( rc != 0 )) && grep -q 'not found in snapshot' "$errf"; then
      fail "$(basename "$imm") is on disk but missing from the latest snapshot -- this is Immich's restore path"
      bad=$(( bad + 1 ))
    elif (( rc != 0 )); then
      warn "  $(basename "$imm"): could not be read back from the repository"
      unread=1
    elif (( gz == 0 )) && grep -qE 'PostgreSQL database (cluster )?dump complete' <<< "$tail_out"; then
      log "  $(basename "$imm"): archive and dump both complete"
      n=$(( n + 1 ))
    else
      fail "$(basename "$imm") in the latest snapshot is corrupt or truncated -- this is Immich's restore path"
      bad=$(( bad + 1 ))
    fi
  fi

  # One restore of the whole subtree: one repository open instead of ~40.
  if (( ${#SQLITE_DUMPED[@]} )); then
    if ! restic "${filter[@]}" restore latest --target "$VERIFY_TMP/sqlite" \
             --include "$DUMP_DIR/sqlite" >/dev/null 2>&1; then
      warn "  could not read the SQLite dumps back from the repository"
      unread=1
    else
      local sn=0 sbad=0
      for db in "${SQLITE_DUMPED[@]}"; do
        rel=${db#"$CONFIG"/}
        sdump="$VERIFY_TMP/sqlite$DUMP_DIR/sqlite/$rel"
        if [[ ! -s $sdump ]]; then
          fail "the dump of $db is missing from the latest snapshot -- the live file is excluded from it, so that database is in no copy at all"
          sbad=$(( sbad + 1 ))
        elif [[ $(sqlite3 "$sdump" 'PRAGMA integrity_check' 2>/dev/null) != ok ]]; then
          fail "the dump of $db is corrupt in the latest snapshot"
          sbad=$(( sbad + 1 ))
        else
          sn=$(( sn + 1 ))
        fi
      done
      log "  sqlite/: $sn of $(( sn + sbad )) verified"
      n=$(( n + sn )); bad=$(( bad + sbad ))
    fi
  fi

  if (( bad )); then
    # Not stamped, so it re-checks nightly until clean.
    warn "$bad dump(s) in the latest snapshot did not verify"
  elif (( unread )); then
    # An sftp hiccup is not corruption, but must not buy another interval.
    warn "verification incomplete -- retrying on the next run"
  else
    log "verified $n dump(s) in the latest snapshot"
    date +%s > "$VERIFY_STAMP"
  fi
}

# Stamp-file interval, as for the repository check above.
if [[ ${VERIFY_DUMPS:-1} != 1 ]]; then
  log "dump verification disabled (VERIFY_DUMPS=0)"
else
  install -d -m 0700 "$STATE_DIR"
  last_verify=0
  if [[ -r $VERIFY_STAMP ]]; then
    last_verify=$(<"$VERIFY_STAMP")
    [[ $last_verify =~ ^[0-9]+$ ]] || last_verify=0
  fi
  verify_days=$(( ( $(date +%s) - last_verify ) / 86400 ))

  if (( VERIFY_INTERVAL_DAYS == 0 || verify_days >= VERIFY_INTERVAL_DAYS )); then
    verify_dumps
  else
    log "dumps verified ${verify_days}d ago, next in $(( VERIFY_INTERVAL_DAYS - verify_days ))d"
  fi
fi

# Also the success ping's body. `|| true`: a failed read-back here must not
# turn a good backup into a /fail ping.
SUMMARY=$(restic snapshots --host "$BACKUP_HOST" --tag "$BACKUP_TAG" --compact 2>/dev/null | tail -1 || true)
[[ -n $SUMMARY ]] || SUMMARY="backup completed (could not read the snapshot list back)"
log "$SUMMARY"

if (( ${#FAILURES[@]} )); then
  warn "finished with ${#FAILURES[@]} problem(s):"
  printf '  - %s\n' "${FAILURES[@]}" >&2
  exit 1
fi

log "done"
