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

# A dead-man's switch: ping on start, success and failure, and if the
# success ping does not arrive on schedule the far end raises the alarm.
#
# Deliberately not OnFailure= in the unit, which only fires when the unit
# runs and fails -- nothing on this host can report that the host is dead,
# the timer was disabled, or the disk filled up before systemd started
# anything, which is how a backup actually goes quiet. Here silence is the
# signal, so a broken notifier and a broken backup both reach you.
#
# Empty HEALTHCHECK_URL disables it. Pings are best-effort and never
# affect the exit status: a monitoring endpoint that is down must not be
# able to fail a backup that is otherwise fine.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# Bounded timeouts: at curl's defaults an endpoint that blackholes packets
# costs ~46s per ping, twice a run. --retry-max-time caps the whole
# attempt, not each try.
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

# Tested on the value rather than chained to cat's exit status: an empty
# /etc/hostname leaves cat exiting 0, and every restic call would then run
# with --host "", forking exactly the second snapshot history the note
# above guards against. Whitespace is stripped so " " cannot pass -n.
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

# A live service's dump is rewritten nightly, so one older than this
# belongs to a service that no longer runs. Generous on purpose: it must
# not catch a merely stopped container, whose live data directory is
# excluded from the backup and whose dump is the only copy.
DUMP_KEEP_DAYS="${DUMP_KEEP_DAYS:-30}"

for v in CHECK_INTERVAL_DAYS DUMP_KEEP_DAYS; do
  [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number of days, got '${!v}'"
done

command -v restic >/dev/null || die "restic is not installed"

# Only one run at a time. bmo-restore takes this same lock, and that is
# the more important half: a restore of a rebuilt host runs for hours and
# can span 03:30, and without the lock this run would dump the databases
# of engines the restore has just started on empty data directories,
# snapshot a half-restored $CONFIG, and prune. That snapshot looks healthy
# and is `latest`.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  # No alarm: the run holding the lock will ping when it finishes, and a
  # /fail here would be a false alarm. A restore holding it ends the night
  # with no ping at all, which is correct -- no backup was taken, and the
  # monitor's grace period is what should say so.
  NO_PING=1
  die "another backup or a restore is already running (holds $LOCK_FILE)"
fi

# With the lock held, the run really begins -- so the clock the monitor
# measures against starts here. No retries: losing this ping costs only a
# duration reading, and the pings carrying the outcome do retry.
ping_hc /start "" 0

[[ -d $CONFIG ]] || die "CONFIG=$CONFIG does not exist"
[[ -d $DATA   ]] || die "DATA=$DATA does not exist"

# With the data disk unmounted $DATA is an empty directory on the root
# filesystem, and backing that up looks like "the user deleted
# everything" -- after enough retention cycles the real snapshots age out.
# Same name as DATA_IS_MOUNT in config/site.env, which run.sh copies into
# $ENV_FILE, so the two guards are one switch.
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

# A file-level copy of a database being written to is not a backup -- it
# restores torn, or silently stale. So each live database gets a logical
# dump here and its on-disk directory is excluded from the backup below.
#
# Uncompressed on purpose: restic deduplicates a nightly dump against
# yesterday's and compresses on its own for v2 repositories. Gzipping
# first would defeat both.

DUMP_DIR="$CONFIG/_dumps"
install -d -m 0700 "$DUMP_DIR"

have_docker() { command -v docker >/dev/null; }

running() {
  [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]
}

# Temp file and rename, so an interrupted dump cannot replace a good one
# with a truncated one. stderr is left alone: when a dump fails, the
# engine's own message in the journal is the only useful diagnosis.
dump_to() {
  local out=$1; shift
  if "$@" > "$out.tmp" && [[ -s $out.tmp ]]; then
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
  # The official image trusts local socket connections, so no credentials
  # are needed here.
  dump_to "$DUMP_DIR/$container.sql" \
    docker exec "$container" sh -c 'exec pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' \
    || fail "pg_dumpall failed for $container"
}

# Single-quoted sh -c body again -- see dump_postgres above.
# shellcheck disable=SC2016
dump_mariadb() {
  local container=$1
  running "$container" || return 0
  # MYSQL_PWD rather than -p keeps the password out of the container's
  # process list.
  dump_to "$DUMP_DIR/$container.sql" \
    docker exec "$container" sh -c '
      export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
      if command -v mariadb-dump >/dev/null; then d=mariadb-dump; else d=mysqldump; fi
      exec "$d" -u root --all-databases --single-transaction --quick --routines --events' \
    || fail "mariadb-dump failed for $container"
}

# Everything else here is SQLite. `.backup` uses SQLite's online backup
# API, the only correct way to copy a database open in WAL mode, and
# databases are discovered rather than listed so a new service cannot
# silently go unprotected.
#
# The dumped files are recorded as exact paths, never a glob: `*.db` would
# also match files dump_sqlite skips for failing the SQLite magic check,
# and those would then be in no copy at all.
SQLITE_DUMPED=()

dump_sqlite() {
  if ! command -v sqlite3 >/dev/null; then
    fail "sqlite3 not installed -- SQLite databases copied as live files, may restore torn"
    return 0
  fi

  local db rel out n=0
  while IFS= read -r db; do
    # Dot-commands take a single-quoted path, which a quote in the name
    # would break out of.
    [[ $db == *"'"* ]] && { fail "skipping path with a quote: $db"; continue; }

    # *.db is also used by things that are not SQLite.
    [[ $(head -c 15 "$db" 2>/dev/null) == "SQLite format 3" ]] || continue

    rel=${db#"$CONFIG"/}
    out="$DUMP_DIR/sqlite/$rel"
    install -d -m 0700 "$(dirname "$out")"

    if sqlite3 "$db" ".backup '$out.tmp'" 2>/dev/null && [[ -s $out.tmp ]]; then
      # Carry the live file's ownership and mode onto the dump. sqlite3
      # runs as root, so .backup writes root:root 0644, and restore.sh's
      # `cp -a` preserves exactly that -- every restored database owned by
      # root, for services that run as $PUID. This is the only place the
      # original is still knowable: the live file is excluded from the
      # snapshot. Applied before the rename, so the published dump never
      # exists with the wrong owner even briefly.
      chown --reference="$db" "$out.tmp" 2>/dev/null || true
      chmod --reference="$db" "$out.tmp" 2>/dev/null || true
      mv -f "$out.tmp" "$out"
      SQLITE_DUMPED+=("$db")
      (( ++n ))
    else
      rm -f "$out.tmp"
      fail "sqlite3 .backup failed for $db"
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

  newest=$(find "$dir" -type f -newermt '-48 hours' -print -quit 2>/dev/null || true)
  if [[ -n $newest ]]; then
    log "  immich self-dump is current ($(basename "$newest"))"
  else
    total=$(find "$dir" -type f 2>/dev/null | wc -l || true)
    fail "no immich database dump under $dir in the last 48h ($total file(s) total) -- check Immich's backup setting"
  fi
}

log "dumping databases"
if have_docker; then
  dump_postgres immich_postgres   # excluded below; immich's own dump is the restore path
  dump_postgres synapse-db
  dump_mariadb  romm-db
  check_immich_dump
else
  fail "docker not found -- database dumps skipped"
fi
dump_sqlite

# $DUMP_DIR is inside $CONFIG, so a dropped service's last dump would
# otherwise go into every snapshot from then on, forever.
#
# Age, not "was it written this run": a dump that failed tonight keeps its
# previous good copy (see dump_to) and a stopped container writes nothing,
# and deleting either would throw away the only copy of a database whose
# live directory is excluded from the backup. Nothing legitimate goes
# untouched for DUMP_KEEP_DAYS.
#
# Runs before the backup so a stale dump misses tonight's snapshot.
# `|| true` because pipefail would otherwise turn one unreadable file into
# a failed assignment and abort the run over housekeeping.
stale=$(find "$DUMP_DIR" -type f ! -newermt "-${DUMP_KEEP_DAYS} days" -print -delete 2>/dev/null | wc -l || true)
if (( stale )); then
  log "  removed $stale dump(s) not refreshed in ${DUMP_KEEP_DAYS} days"
  # -mindepth 1 so $DUMP_DIR itself survives being emptied.
  find "$DUMP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

# Removed by the single EXIT trap installed above: a second `trap ... EXIT`
# here would replace it outright, and the run would stop reporting to the
# monitor altogether.
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

# Live database directories, dumped above instead because a file-level
# copy taken while the engine runs does not reliably restore.
#
# Each is excluded ONLY when its dump is actually on disk -- that
# condition is the whole point of this block. Unconditional lines in the
# heredoc above are the one arrangement able to produce a snapshot holding
# neither the dump nor the data it stands for, invisibly until a restore.
#
# Keys are container names, because that is what dump_to writes as
# $DUMP_DIR/<container>.sql. Services absent from this host are skipped,
# so synapse is listed even though it is not deployed: enabling
# stacks/matrix.yml must not quietly reintroduce the hole.
declare -A SQL_LIVE_DIR=(
  [immich_postgres]="$CONFIG/immich/database"
  [synapse-db]="$CONFIG/synapse/db"
  [romm-db]="$CONFIG/romm/mysql"
)

for c in "${!SQL_LIVE_DIR[@]}"; do
  live=${SQL_LIVE_DIR[$c]}
  # Not deployed here: nothing to exclude and nothing to warn about.
  [[ -d $live ]] || continue
  if [[ -s $DUMP_DIR/$c.sql ]]; then
    printf '%s\n' "$live" >> "$EXCLUDES"
  elif have_docker && running "$c"; then
    # Engine up and no dump: the copy going into the snapshot is being
    # written to as it is read. Worth failing the run over.
    fail "no dump at $DUMP_DIR/$c.sql and $c is running -- keeping the live $live in the backup instead, which may restore torn"
  else
    # A stopped engine's data directory copies perfectly well, so this is
    # the arrangement working; calling it a fault nightly would train
    # someone to ignore it.
    log "  no dump for $c and it is not running -- backing up the live $live (safe: engine stopped)"
  fi
done

# The live SQLite files whose clean copy now sits in $DUMP_DIR/sqlite.
# Having both in one snapshot is the thing to avoid: `restic restore
# --target /` would put the live copy back over the real path and leave
# the good one unused in _dumps, silently restoring stale or torn data.
#
# The -wal, -shm and -journal sidecars go too. SQLite pairs them with the
# main file by salt, so a WAL from a different instant either refuses the
# database or replays a checkpoint it never had.
#
# A file whose dump FAILED is deliberately absent, so it stays in the
# backup: fail() has recorded the problem, and a copy that might be torn
# beats none.
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

# Structural check only: indexes and metadata, without pulling every pack
# back over sftp. RESTIC_CHECK=0 skips it.
#
# Driven by a stamp file rather than the day of the week, because this
# host is not guaranteed to be powered on on any given day and "check on
# Sundays" would then never run. The stamp is written only on a check that
# passed, so a failing repository is re-checked on the next run instead of
# going quiet for another week.
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

# Also the body of the success ping, so the monitor's last-received
# message says what was stored rather than just "ok".
#
# `|| true` is not optional: this is a cosmetic read-back after the backup
# has already succeeded, and without it a transient sftp error here would
# end the run and fire a /fail ping at 03:30 about a backup that worked.
SUMMARY=$(restic snapshots --host "$BACKUP_HOST" --tag "$BACKUP_TAG" --compact 2>/dev/null | tail -1 || true)
[[ -n $SUMMARY ]] || SUMMARY="backup completed (could not read the snapshot list back)"
log "$SUMMARY"

if (( ${#FAILURES[@]} )); then
  warn "finished with ${#FAILURES[@]} problem(s):"
  printf '  - %s\n' "${FAILURES[@]}" >&2
  exit 1
fi

log "done"
