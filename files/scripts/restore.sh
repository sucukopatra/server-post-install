#!/usr/bin/env bash
#
# bmo restore -- installed as /usr/local/sbin/bmo-restore by run.sh.
#
#   bmo-restore --list                what the repository holds
#   bmo-restore sonarr radarr         put those services back
#   bmo-restore --all                 every service, for a rebuilt host
#   bmo-restore --undo <timestamp>    put back whatever a restore replaced
#
# Options:
#
#   -n, --dry-run       print every action and change nothing. Use it first.
#   --snapshot <id>     restore from this snapshot rather than the newest.
#                       Ids come from --list.
#   -y, --yes           answer yes to every prompt -- including the one that
#                       replaces live state, and the one that merges into
#                       $DATA, which cannot be undone. Not for routine use.
#   -h, --help          this message.
#
# =========================== everything below is design notes, not usage
#
# This is the other half of bmo-backup, and it exists because a snapshot
# does not map one-to-one onto a working host. Three kinds of state come
# back three different ways:
#
#   plain files   restored as they are
#   SQLite        the live files are NOT in the snapshot. A clean copy of
#                 each, taken through SQLite's online backup API, is under
#                 _dumps/sqlite and has to be put back over the path it
#                 came from
#   postgres      the data directories are NOT in the snapshot either. The
#   mariadb       engine starts on an empty directory, initialises itself,
#                 and is then fed a dump
#
# So a plain `restic restore --target /` leaves every SQLite service
# without a database and both SQL engines empty, and nothing says so --
# the services start, create fresh databases, and look merely "reset".
# That is the failure this script exists to prevent.
#
# It restores STATE only. The shape of the host -- packages, docker,
# directories, systemd units, firewall -- comes from `run.sh --full`,
# which must have been run first. See the README.

set -euo pipefail

# "${arr[@]}" on an empty array is an unbound-variable error before 4.4.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "bash 4.4 or newer is required (this is $BASH_VERSION)" >&2
  exit 1
fi

ENV_FILE=/etc/bmo-backup.env

# ---------------------------------------------------------------- output

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'
c_blu=$'\033[34m'; c_dim=$'\033[2m';  c_off=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "$c_blu" "$*" "$c_off"; }
ok()   { printf '  %s+%s %s\n'   "$c_grn" "$c_off" "$*"; }
skip() { printf '  %s.%s %s\n'   "$c_dim" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n'   "$c_ylw" "$c_off" "$*"; }
# DYING tells the ERR trap this exit was deliberate and already explained.
DYING=0
die()  { DYING=1; printf '\n%sERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ------------------------------------------------------------ error trap
# -E propagates the trap into functions and subshells; `set -e` alone exits
# in silence, and this script runs when the host is already broken.
set -E

on_err() {
  local rc=$1 line=$2 cmd=$3
  (( DYING )) && return
  printf '\n%sFAILED%s at line %s (exit %s):\n    %s\n' \
    "$c_red" "$c_off" "$line" "$rc" "$cmd" >&2
  # In a subshell, report the frame and leave the advice to the parent.
  (( BASH_SUBSHELL )) && exit "$rc"
  printf '  nothing further has been changed. If a rollback was already taken,\n' >&2
  printf '  %s --list will show it and --undo <timestamp> will put it back.\n' \
    "${BASH_SOURCE[0]}" >&2
  exit "$rc"
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

DRY_RUN=0
ASSUME_YES=0

# The dry-run trace goes to a private copy of stderr, so call sites that
# redirect the wrapped command's output cannot swallow it.
exec {TRACE_FD}>&2

# Every mutating action goes through this, so --dry-run is a property of
# one function rather than a flag remembered at thirty call sites.
run() {
  if (( DRY_RUN )); then
    printf '  %s[dry-run]%s %s\n' "$c_dim" "$c_off" "$*" >&"$TRACE_FD"
    return 0
  fi
  "$@"
}

# For the line *after* a `run`, which otherwise states as fact something
# that only happened in a real run.
done_ok() { (( DRY_RUN )) || ok "$@"; }

prompt_yn() {
  (( ASSUME_YES )) && return 0
  local reply
  read -rp "  ? $1 [y/N] " reply
  [[ ${reply,,} == y* ]]
}

# Prints the header up to the divider; `$d` drops the divider itself.
usage() {
  sed -n '3,/^# ===/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \?//'
  exit "${1:-0}"
}

# ------------------------------------------------------------------ args

MODE=""            # list | restore | undo
MODE_SRC=""        # the argument that chose $MODE, so the clash can name both
SNAPSHOT=latest
SNAPSHOT_SET=0    # --snapshot given explicitly, as opposed to the default
UNDO_STAMP=""
SERVICES=()
WANT_ALL=0

# --list, --undo and a restore are different operations. Asking for two on
# one command line is refused rather than guessed: `--list --all` used to
# end as a full restore.
set_mode() {
  local want=$1 src=$2
  if [[ -n $MODE && $MODE != "$want" ]]; then
    die "$MODE_SRC and $src ask for different operations -- run them separately"
  fi
  MODE=$want; MODE_SRC=$src
}

while (( $# )); do
  case $1 in
    --list)      set_mode list "$1" ;;
    # --all next to a named service is caught after the loop.
    --all)       set_mode restore "$1"; WANT_ALL=1 ;;
    # A missing value is refused here: `shift` past the end exits silently.
    --undo)      set_mode undo "$1"
                 [[ ${2:-} && ${2:-} != -* ]] \
                   || die "--undo needs a timestamp (see --list)"
                 UNDO_STAMP=$2; shift ;;
    --snapshot)  [[ ${2:-} && ${2:-} != -* ]] \
                   || die "--snapshot needs a snapshot id, or 'latest' (see --list)"
                 SNAPSHOT=$2; SNAPSHOT_SET=1; shift ;;
    --dry-run|-n) DRY_RUN=1 ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage 0 ;;
    -*)          die "unknown option: $1 (try --help)" ;;
    *)           set_mode restore "$1"; SERVICES+=("$1") ;;
  esac
  shift
done

[[ -n $MODE ]] || usage 1

if (( WANT_ALL )) && (( ${#SERVICES[@]} )); then
  die "--all restores every service; naming ${SERVICES[*]} as well asks for two different things"
fi
(( WANT_ALL )) && SERVICES=(--all)

if (( SNAPSHOT_SET )) && [[ $MODE == undo ]]; then
  die "--undo restores from a local rollback, not from a snapshot -- --snapshot has no meaning with it"
fi

# ----------------------------------------------------------- environment

[[ $EUID -eq 0 ]] || die "must run as root (restic reads /root/.ssh, and this writes every config dir)"

[[ -r $ENV_FILE ]] || die "$ENV_FILE missing -- run 'run.sh --full' on this host first"
set -a
# per-host file written by run.sh, so there is nothing to follow
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

for v in RESTIC_REPOSITORY RESTIC_PASSWORD_FILE CONFIG DATA; do
  [[ -n ${!v:-} ]] || die "$v is unset in $ENV_FILE"
done
[[ -r $RESTIC_PASSWORD_FILE ]] || die "cannot read $RESTIC_PASSWORD_FILE"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
export HOME="${HOME:-/root}"

# Where compose.yml and the compose .env live. Falls back to the parent of
# $CONFIG for an $ENV_FILE written by an older run.sh.
DOCKER_ROOT="${DOCKER_ROOT:-$(dirname "$CONFIG")}"

BACKUP_HOST="${BACKUP_HOST:-${HOSTNAME%%.*}}"

# Same guard as backup.sh, for the same reason and then a worse one: with
# the data disk missing, $DATA is an empty directory on the root
# filesystem, and restoring a photo library into it fills / instead.
if [[ ${DATA_IS_MOUNT:-1} == 1 ]] && ! mountpoint -q "$DATA"; then
  die "$DATA is not a mount point -- data disk missing? (set DATA_IS_MOUNT=0 in $ENV_FILE to allow)"
fi

command -v restic >/dev/null || die "restic is not installed"

# ------------------------------------------------------------------ lock
# The lock backup.sh takes. A backup during a long restore would dump
# half-restored engines, snapshot a half-restored $CONFIG as `latest`, and
# prune. --list and --dry-run are read-only and do not take it.
LOCK_FILE=/run/bmo-backup.lock
if [[ $MODE != list ]] && ! (( DRY_RUN )); then
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    die "a backup is running (holds $LOCK_FILE) -- wait for it to finish, or
  stop it with 'systemctl stop bmo-backup.service', then re-run this"
  fi
fi

# Beside $CONFIG, not in it, or a rollback would enter every snapshot; and on
# the same filesystem, so taking a rollback is a rename.
WORK_ROOT="$(dirname "$CONFIG")"
STAGE_ROOT="$WORK_ROOT/.bmo-stage"
ROLLBACK_ROOT="$WORK_ROOT/.bmo-rollback"

# ------------------------------------------------------- service mapping
# A service's state is $CONFIG/<name> and its container <name>; only the
# exceptions are listed. A table here, not parsed from compose, because this
# must work on a rebuilt host with no git checkout.

# Containers to stop, where they are not just <name>. qbittorrent lives in
# gluetun's network namespace and gluetun carries its alias, so stopping
# gluetun alone strands it. Both come back on `docker compose up -d`.
declare -A SVC_CONTAINERS=(
  [immich]="immich_server immich_machine_learning immich_postgres immich_redis"
  [romm]="romm romm-db"
  [minecraft]="minecraft-server"
  [gluetun]="qbittorrent gluetun"
)

# Paths under $DATA that belong to a service. minecraft has no $CONFIG half,
# so --all unions in these keys.
declare -A SVC_DATA=(
  [immich]="photos"
  [syncthing]="sync"
  [minecraft]="games/minecraft"
)

# Services whose database is a SQL engine rather than SQLite.
declare -A SVC_SQL=(
  [immich]=postgres
  [romm]=mariadb
)

svc_containers() { printf '%s' "${SVC_CONTAINERS[$1]:-$1}"; }

# Top-level *.sql names in the snapshot's _dumps, read once.
SNAP_SQL_DUMPS=()

# Engine dumps belonging to $1: <svc>.sql or <svc>[-_]*.sql, as backup.sh
# names them. Globs, not a regex, so a service name cannot become a pattern.
svc_sql_dumps() {
  local svc=$1 d
  for d in "${SNAP_SQL_DUMPS[@]}"; do
    [[ $d == "$svc".sql || $d == "$svc"[-_]*.sql ]] && printf '%s\n' "$d"
  done
  return 0
}

# ------------------------------------------------------ engine readiness

# Wait until a database container can answer queries. On a fresh data
# directory both engines initialise and restart while 'running', so health
# status is what counts; $probe covers an image without a healthcheck.
wait_ready() {
  local c=$1 probe=${2:-} timeout=${3:-300}
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
      missing) warn "$c does not exist"; return 1 ;;
      exited|dead)
        warn "$c is $state -- it failed to start"
        return 1 ;;
      *) sleep "$interval"; waited=$(( waited + interval )); continue ;;
    esac

    if [[ -n $health ]]; then
      if [[ $health == healthy ]]; then
        ok "$c healthy after ${waited}s"
        return 0
      fi
    elif [[ -n $probe ]]; then
      if docker exec "$c" sh -c "$probe" >/dev/null 2>&1; then
        ok "$c answering after ${waited}s"
        return 0
      fi
    else
      warn "$c declares no healthcheck and no probe was given -- proceeding blind"
      return 0
    fi

    sleep "$interval"; waited=$(( waited + interval ))
  done

  warn "$c not ready after ${timeout}s (state=$state health=${health:-none})"
  return 1
}

# ----------------------------------------------------------- repository

snapshot_id() {
  # Resolve 'latest' once, so one run reads one snapshot. `|| true` because
  # grep exits 1 when this host has no snapshot, and the callers report that.
  restic snapshots --host "$BACKUP_HOST" --json "$1" 2>/dev/null \
    | grep -oE '"short_id":"[^"]+"' | tail -1 | cut -d'"' -f4 || true
}

# Service names one level under $CONFIG in snapshot $1, minus _dumps. The
# ^$CONFIG/ anchor matters: `restic ls` always prints a header line, so a
# looser match reports every service as present.
snap_config_svcs() {
  restic ls "$1" "$CONFIG" 2>/dev/null \
    | sed -n "s|^${CONFIG}/\([^/]*\)$|\1|p" | grep -v '^_dumps$' | sort -u || true
}

# The top-level *.sql files under _dumps in snapshot $1.
snap_sql_dumps() {
  restic ls "$1" "$CONFIG/_dumps" 2>/dev/null \
    | sed -n "s|^${CONFIG}/_dumps/||p" | grep -E '\.sql$' | sort || true
}

# What counts as SQLite by name: the same list backup.sh discovers with.
SQLITE_EXT_RE='\.(db|sqlite|sqlite3)$'

# Size of the rollbacks and the free space beside them, tab-separated,
# '?' when unknown.
rollback_usage() {
  local sz avail
  sz=$(du -sh "$ROLLBACK_ROOT" 2>/dev/null | cut -f1 || true)
  avail=$(df -h --output=avail "$ROLLBACK_ROOT" 2>/dev/null | tail -1 | tr -d ' ' || true)
  printf '%s\t%s\n' "${sz:-?}" "${avail:-?}"
}

restic cat config >/dev/null 2>&1 \
  || die "cannot open $RESTIC_REPOSITORY -- wrong passphrase, or no SSH access as root"

# ------------------------------------------------------------- --list

if [[ $MODE == list ]]; then
  step "Snapshots in $RESTIC_REPOSITORY"
  restic snapshots --host "$BACKUP_HOST" --compact

  # $SNAPSHOT, so --list --snapshot <id> lists that snapshot.
  snap=$(snapshot_id "$SNAPSHOT")
  [[ -n $snap ]] || die "no snapshot matching '$SNAPSHOT' for host '$BACKUP_HOST'"

  step "Services in snapshot $snap"
  snap_config_svcs "$snap" | sed 's/^/  /'

  step "Database dumps in snapshot $snap"
  sql_dumps=$(snap_sql_dumps "$snap")
  if [[ -n $sql_dumps ]]; then
    echo "  SQL engines:"
    printf '%s\n' "$sql_dumps" | sed 's/^/    /'
  else
    warn "no SQL engine dumps in this snapshot -- immich and romm cannot be restored from it"
  fi

  # Counted, not listed. --recursive: the dumps sit under sqlite/<service>/.
  n_sqlite=$(restic ls --recursive "$snap" "$CONFIG/_dumps/sqlite" 2>/dev/null \
    | grep -cE "$SQLITE_EXT_RE" || true)
  echo "  SQLite: ${n_sqlite:-0} database(s)"

  # The header only when a rollback exists.
  rollbacks=$(find "$ROLLBACK_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    2>/dev/null | sort || true)
  if [[ -n $rollbacks ]]; then
    step "Rollbacks available on this host (bmo-restore --undo <timestamp>)"
    # With sizes: nothing on this host ever deletes these.
    while read -r r; do
      rb_sz=$(du -sh "$ROLLBACK_ROOT/$r" 2>/dev/null | cut -f1 || true)
      printf '  %-22s %s\n' "$r" "${rb_sz:-?}"
    done <<<"$rollbacks"
    IFS=$'\t' read -r rb_sz rb_avail < <(rollback_usage)
    printf '  %-22s %s\n' "total" "$rb_sz"
    printf '\n  %s free on the filesystem holding them. Delete one with:\n' "$rb_avail"
    printf '    rm -rf %s/<timestamp>\n' "$ROLLBACK_ROOT"
  fi
  exit 0
fi

# ------------------------------------------------------------- --undo

if [[ $MODE == undo ]]; then
  src="$ROLLBACK_ROOT/$UNDO_STAMP"
  [[ -d $src ]] || die "no rollback at $src (see --list)"
  [[ -r $src/manifest ]] || die "$src has no manifest -- refusing to guess where its contents belong"

  step "Undoing the restore of $UNDO_STAMP"
  warn "this replaces the CURRENT state of those services with what was there before"
  prompt_yn "continue?" || die "aborted"

  while IFS=$'\t' read -r saved original; do
    [[ -n ${saved:-} && -n ${original:-} ]] || continue
    for c in $(svc_containers "$(basename "$original")"); do
      run docker stop "$c" >/dev/null 2>&1 || true
    done
    run rm -rf "$original"
    run mv "$src/$saved" "$original"
    done_ok "restored $original from the rollback"
  done < "$src/manifest"

  run rm -rf "$src"
  done_ok "undo complete -- start the services with: docker compose up -d"
  exit 0
fi

# ------------------------------------------------------------- restore

SNAP=$(snapshot_id "$SNAPSHOT")
[[ -n $SNAP ]] || die "no snapshot matching '$SNAPSHOT' for host '$BACKUP_HOST'"

# --all is the snapshot's $CONFIG children plus SVC_DATA's keys, for
# services whose whole state is under $DATA. Read once: also used to tell
# whether a service has a $CONFIG half.
mapfile -t SNAP_CONFIG_SVCS < <(snap_config_svcs "$SNAP")

in_snap_config() {
  local want=$1 d
  for d in "${SNAP_CONFIG_SVCS[@]}"; do
    [[ $d == "$want" ]] && return 0
  done
  return 1
}

if [[ ${SERVICES[0]:-} == --all ]]; then
  mapfile -t SERVICES < <(
    { printf '%s\n' "${SNAP_CONFIG_SVCS[@]}"
      printf '%s\n' "${!SVC_DATA[@]}"
    } | grep -v '^$' | sort -u)
  (( ${#SERVICES[@]} )) || die "snapshot $SNAP contains nothing under $CONFIG"
fi

step "Restoring from snapshot $SNAP"
printf '  %-14s %s\n' "repository:" "$RESTIC_REPOSITORY"
printf '  %-14s %s\n' "services:"   "${SERVICES[*]}"
(( DRY_RUN )) && warn "dry run -- nothing will be changed"

# Rollbacks are never deleted automatically; say how much they already use.
old_rb=$(find "$ROLLBACK_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)
if (( ${old_rb:-0} )); then
  IFS=$'\t' read -r rb_sz rb_avail < <(rollback_usage)
  warn "$old_rb rollback(s) already here, using $rb_sz in $ROLLBACK_ROOT"
  warn "$rb_avail free -- 'bmo-restore --list' itemises them"
  (( DRY_RUN )) || warn "this run adds another, and deletes none of them"
fi

# Confirm before touching anything, listing what will be replaced. The
# rollback below makes this reversible, but a restore of the wrong
# snapshot onto a live host is still an outage nobody asked for.
if ! (( DRY_RUN )); then
  warn "this replaces the live state of: ${SERVICES[*]}"
  prompt_yn "continue?" || die "aborted"
fi

STAMP=$(date +%Y-%m-%dT%H-%M-%S)
ROLLBACK="$ROLLBACK_ROOT/$STAMP"
STAGE="$STAGE_ROOT/$STAMP"
run install -d -m 0700 "$ROLLBACK" "$STAGE"
MANIFEST="$ROLLBACK/manifest"
(( DRY_RUN )) || : > "$MANIFEST"

# rmdir, not rm -rf, on the parent: a concurrent restore may still use it.
# Nothing here may fail: it runs from the EXIT trap.
cleanup() {
  [[ -d ${STAGE:-} ]] && rm -rf "$STAGE"
  rmdir "$STAGE_ROOT" 2>/dev/null || true
  # psql's stderr, held while the SQL branches below read it.
  [[ -n ${PSQL_ERR:-} ]] && rm -f "$PSQL_ERR"
  return 0
}
trap cleanup EXIT

mapfile -t SNAP_SQL_DUMPS < <(snap_sql_dumps "$SNAP")

restored=(); sql_pending=()

for svc in "${SERVICES[@]}"; do
  step "$svc"
  src="$CONFIG/$svc"

  # ---- stop only this service's containers ----
  for c in $(svc_containers "$svc"); do
    if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]]; then
      run docker stop "$c" >/dev/null
      done_ok "stopped $c"
    else
      skip "$c is not running"
    fi
  done

  # ---- restore this service's files into the staging area ----
  # Staged first, so a restic failure cannot leave a half-replaced directory.
  if ! run restic restore "$SNAP" --target "$STAGE" \
         --include "$src" \
         --include "$CONFIG/_dumps/sqlite/$svc" >/dev/null 2>&1; then
    warn "restic could not restore $src from $SNAP -- skipping $svc"
    continue
  fi

  # No $CONFIG directory is fine for a $DATA-only service (minecraft). Under
  # --dry-run nothing is staged, so ask the snapshot.
  have_config=1
  if (( DRY_RUN )); then
    in_snap_config "$svc" || have_config=0
  elif [[ ! -d $STAGE$src ]]; then
    have_config=0
  fi

  if ! (( have_config )); then
    if [[ -z ${SVC_DATA[$svc]:-} ]]; then
      warn "$src is not in snapshot $SNAP -- skipping"
      continue
    fi
    skip "$svc keeps nothing under \$CONFIG -- all of its state is in \$DATA"
  fi

  # Whether this service actually got anything back, not merely visited.
  did_restore=$(( have_config ))

  # ---- move the live copy aside, then put the restored one in place ----
  if (( have_config )); then
    if [[ -e $src ]]; then
      run mkdir -p "$ROLLBACK/config"
      run mv "$src" "$ROLLBACK/config/$svc"
      (( DRY_RUN )) || printf '%s\t%s\n' "config/$svc" "$src" >> "$MANIFEST"
      done_ok "previous $svc saved to $ROLLBACK/config/$svc"
    fi
    run mv "$STAGE$src" "$src"
    done_ok "restored $src"
  fi

  # ---- put the SQLite databases back over the paths they came from ----
  # backup.sh excluded these files, so the restored tree has a hole for each.
  dumps="$STAGE$CONFIG/_dumps/sqlite/$svc"
  if ! (( have_config )); then
    # No $CONFIG tree, so no SQLite databases either.
    :
  elif (( DRY_RUN )); then
    # Nothing is staged, so ask the snapshot. --recursive and filtered to database
    # extensions: most dumps sit below the top, e.g. jellyfin's data/jellyfin.db.
    mapfile -t would < <(
      restic ls --recursive "$SNAP" "$CONFIG/_dumps/sqlite/$svc" 2>/dev/null \
        | sed -n "s|^${CONFIG}/_dumps/sqlite/${svc}/||p" \
        | grep -E "$SQLITE_EXT_RE" || true)
    if (( ${#would[@]} )); then
      for r in "${would[@]}"; do
        printf '  %s[dry-run]%s put %s back from _dumps, dropping any -wal/-shm\n' \
          "$c_dim" "$c_off" "$src/$r"
      done
    else
      skip "no SQLite dumps for $svc in $SNAP"
    fi
  elif [[ -d $dumps ]]; then
    n=0
    while IFS= read -r d; do
      rel=${d#"$dumps"/}
      dest="$src/$rel"
      # Only when missing: GNU install -d also re-modes an existing directory.
      dest_dir=$(dirname "$dest")
      [[ -d $dest_dir ]] || run install -d "$dest_dir"
      # -a keeps the owner and mode backup.sh stamped on the dump.
      run cp -a "$d" "$dest"
      # A -wal/-shm from a different instant would make SQLite reject the database
      # or replay a checkpoint this copy never had.
      run rm -f "$dest-wal" "$dest-shm" "$dest-journal"
      (( ++n ))
    done < <(find "$dumps" -type f 2>/dev/null)
    (( n )) && ok "restored $n SQLite database(s) from _dumps"
  elif [[ -z ${SVC_SQL[$svc]:-} ]]; then
    # Not necessarily wrong: plenty of services keep no database.
    skip "no SQLite dumps for $svc in $SNAP (it may not have a database)"
  fi

  # ---- a SQL engine dump nothing here knows how to load ----
  # A dump named after this service means its engine's data directory was
  # excluded from the snapshot, so without an SVC_SQL arm it comes back empty.
  if [[ -z ${SVC_SQL[$svc]:-} ]]; then
    mapfile -t orphan_dumps < <(svc_sql_dumps "$svc")
    if (( ${#orphan_dumps[@]} )); then
      warn "snapshot $SNAP holds a SQL engine dump for $svc:"
      printf '      %s\n' "${orphan_dumps[@]}"
      warn "nothing here knows how to load it -- $svc has no SVC_SQL entry, and its"
      warn "engine's data directory is excluded from the backup. $svc WILL START EMPTY."
      # Not 'add it to SVC_SQL': the engine arms below are Immich's and RomM's only.
      warn "Load it by hand before starting $svc -- this script only knows how to"
      warn "load Immich's and RomM's engines, not this one."
    fi
  fi

  # ---- $DATA, where the service has any ----
  # In place with no rollback (too large to duplicate), so it asks first.
  if [[ -n ${SVC_DATA[$svc]:-} ]]; then
    dpath="$DATA/${SVC_DATA[$svc]}"
    warn "$svc also owns $dpath"
    warn "that is restored IN PLACE with no rollback copy -- too large to duplicate"
    if (( DRY_RUN )) || prompt_yn "restore $dpath as well?"; then
      run restic restore "$SNAP" --target / --include "$dpath" >/dev/null
      done_ok "restored $dpath"
      did_restore=1
    else
      skip "left $dpath alone"
    fi
  fi

  if ! (( did_restore )); then
    warn "$svc: nothing was restored -- it has no \$CONFIG state in the snapshot"
    warn "and its \$DATA restore was declined. Re-run 'bmo-restore $svc' to retry."
    continue
  fi

  [[ -n ${SVC_SQL[$svc]:-} ]] && sql_pending+=("$svc")
  restored+=("$svc")
done

# ------------------------------------------------- SQL engines, in order
# After the files: restoring files needs the container stopped, loading a
# dump needs it running on its fresh, empty data directory.

pg_major() { grep -oE 'database version [0-9]+' | grep -oE '[0-9]+' | head -1; }

# Write a dump to stdout, decompressing if needed. An if, not `a && b || c`:
# a failing gunzip would also run cat and append raw gzip bytes.
dump_stream() {
  if [[ $1 == *.gz ]]; then gunzip -c "$1"; else cat "$1"; fi
}

# One key from the compose .env, read rather than sourcing every secret.
# Strips one layer of matched quotes, as compose does.
env_value() {
  local key=$1 file="$DOCKER_ROOT/.env" val
  [[ -r $file ]] || return 0
  val=$(sed -n "s/^${key}=//p" "$file" | head -1)
  if (( ${#val} >= 2 )) && [[ $val == \"*\" || $val == \'*\' ]]; then
    val=${val:1:${#val}-2}
  fi
  printf '%s\n' "$val"
}

for svc in "${sql_pending[@]}"; do
  step "$svc database"

  case ${SVC_SQL[$svc]} in
    postgres)
      # This arm is Immich's end to end and never reads $svc, so any other
      # service mapped to postgres is refused rather than loaded wrong.
      if [[ $svc != immich ]]; then
        warn "$svc is mapped to postgres in SVC_SQL, but this branch only knows Immich"
        warn "-- it would load Immich's dump into Immich's engine, not $svc's."
        warn "Refusing that. Load $svc's dump by hand from the snapshot's _dumps/,"
        warn "then remove the SVC_SQL entry or teach this branch about $svc."
        continue
      fi

      # Immich's own scheduled dump handles the vectorchord extension; it is the
      # one to restore from. `|| true`: find exits 1 on a missing directory.
      backup_dir="$DATA/photos/backups"
      newest=$(find "$backup_dir" -type f \( -name '*.sql' -o -name '*.sql.gz' \) \
                 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
      if [[ -z $newest ]]; then
        if [[ -d $backup_dir ]]; then
          warn "no Immich self-dump under $backup_dir"
        else
          warn "$backup_dir does not exist"
          warn "\$DATA/photos was not restored -- either it was declined at the prompt"
          warn "above, or this is a fresh disk. Re-run 'bmo-restore immich' and accept"
          warn "the \$DATA restore, then this dump will be there to load."
        fi
        warn "the fallback is _dumps/immich_postgres.sql from the same snapshot,"
        warn "but it does not carry Immich's extension handling. Load it by hand"
        warn "only if you understand what that means for the vectorchord index."
        continue
      fi
      ok "newest Immich dump: $(basename "$newest") ($(date -d "@$(stat -c %Y "$newest")" +%F))"

      run docker compose -f "$DOCKER_ROOT/compose.yml" up -d database >/dev/null 2>&1 \
        || warn "could not start the database container automatically"

      # shellcheck disable=SC2016
      if (( DRY_RUN )); then
        skip "would wait for immich_postgres to report healthy"
      elif ! wait_ready immich_postgres \
             'exec pg_isready -U "${POSTGRES_USER:-postgres}"'; then
        warn "immich_postgres never became ready -- NOT loading the dump into it"
        warn "the database is left empty; $newest is untouched. Retry with:"
        warn "  bmo-restore immich"
        continue
      fi

      # Only the PostgreSQL major version is checkable: a newer dump does not
      # reliably load into an older server. The Immich version is shown for a
      # human to judge. dump_is_cluster is set once the header has been read.
      dump_is_cluster=0

      if (( DRY_RUN )); then
        skip "would compare the dump's PostgreSQL major version against the running server,"
        skip "and probe psql for \\restrict support if the dump's header uses it"
      else
        # The header, read once into a variable. `head` on a live pipe kills gunzip
        # with SIGPIPE, which pipefail turns into a failed test.
        dump_head=$(dump_stream "$newest" 2>/dev/null | head -200 || true)
        dump_major=$(pg_major <<<"$dump_head" || true)
        live_ver_raw=$(docker exec immich_postgres postgres --version 2>/dev/null || true)
        live_major=$(grep -oE '[0-9]+' <<<"$live_ver_raw" | head -1 || true)
        live_full=$(grep -oE '[0-9]+\.[0-9]+' <<<"$live_ver_raw" | head -1 || true)
        if [[ -n $dump_major && -n $live_major ]]; then
          if (( dump_major > live_major )); then
            warn "the dump was written by PostgreSQL $dump_major; this server is $live_major"
            warn "if you pin the image back, pin it to the NEWEST $dump_major.x, not to $dump_major itself --"
            warn "see the \\restrict check below for what an old patch release costs you."
            die "refusing to load a newer dump into an older server -- pin the image back to $dump_major"
          fi
          ok "dump PostgreSQL $dump_major into server $live_major -- compatible"
        else
          warn "could not read a version from the dump or the server (dump='$dump_major' server='$live_major')"
          prompt_yn "load it anyway?" || { skip "left the Immich database empty"; continue; }
        fi

        # Dumps from the August 2025 minor releases on open with \restrict
        # (CVE-2025-8714); an older psql aborts on it under ON_ERROR_STOP. Ask psql
        # rather than keep a table of minimum versions. Not fatal: romm may follow.
        if grep -q '^\\restrict' <<<"$dump_head"; then
          # shellcheck disable=SC2016
          if docker exec immich_postgres sh -c \
               'exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
                  -c "\restrict bmoprobe" -c "\unrestrict bmoprobe"' \
               >/dev/null 2>&1; then
            ok "psql understands \\restrict -- this dump's header will load"
          else
            warn "this dump opens with \\restrict, and the psql in immich_postgres"
            warn "(PostgreSQL ${live_full:-$live_major}) does not understand it."
            warn "ON_ERROR_STOP=1 would abort on that line, before any data loads."
            warn "\\restrict arrived in the August 2025 minor releases -- pin the"
            warn "postgres image forward to the newest ${live_major}.x and re-run:"
            warn "  bmo-restore immich"
            skip "left the Immich database empty; $newest is untouched"
            continue
          fi
        fi

        # A pg_dumpall (cluster) must load via the `postgres` database, a pg_dump
        # into the target database itself. Immich writes a pg_dump today; read the
        # first lines of the header rather than assume.
        if grep -q 'database cluster dump' <<<"$(head -5 <<<"$dump_head")"; then
          dump_is_cluster=1
          ok "dump is a cluster dump (pg_dumpall) -- loading via the postgres database"
        else
          dump_is_cluster=0
          ok "dump is a single-database dump (pg_dump) -- loading into \$POSTGRES_DB"
        fi

        # From $DOCKER_ROOT/.env, where compose gets it.
        immich_ver=$(env_value IMMICH_VERSION)
        warn "IMMICH_VERSION pinned in $DOCKER_ROOT/.env: ${immich_ver:-<unset>}"
        warn "-- check the release notes if that is far from the version that wrote this dump."
      fi

      if (( DRY_RUN )); then
        skip "would load $(basename "$newest") into immich_postgres"
      elif prompt_yn "load $(basename "$newest") into immich_postgres now?"; then
        # Role and database names expand inside the container, from its own
        # environment. ON_ERROR_STOP only for a single-database dump: a pg_dumpall
        # --clean load always fails to drop and recreate the connected role, so the
        # cluster path is judged on psql's errors minus those two.
        PSQL_ERR=$(mktemp)
        psql_rc=0
        # shellcheck disable=SC2016
        dump_stream "$newest" \
          | docker exec -i immich_postgres sh -c \
              'if [ "$1" = 1 ]; then
                 exec psql -U "$POSTGRES_USER" -d postgres
               fi
               exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
              sh "$dump_is_cluster" \
          >/dev/null 2>"$PSQL_ERR" || psql_rc=$?

        if (( ! dump_is_cluster )); then
          # ON_ERROR_STOP was in force, so $? is authoritative.
          if (( psql_rc == 0 )); then
            ok "Immich database loaded"
          else
            # ON_ERROR_STOP stops at the first error; everything before it committed.
            warn "loading the Immich database stopped at the first error"
            warn "psql had already committed everything before that point, so the"
            warn "database may be partly populated -- check it before reloading."
            [[ -s $PSQL_ERR ]] && sed 's/^/      /' "$PSQL_ERR" >&2
            warn "The dump itself is untouched, at $newest"
          fi
        elif (( psql_rc != 0 )); then
          # Without ON_ERROR_STOP, non-zero means psql could not run the dump at all.
          warn "psql could not run the dump at all (exit $psql_rc)"
          [[ -s $PSQL_ERR ]] && sed 's/^/      /' "$PSQL_ERR" >&2
          warn "The dump itself is untouched, at $newest"
        else
          # Minus the two errors every pg_dumpall --clean load produces.
          real_errors=$(grep -E 'ERROR:' "$PSQL_ERR" 2>/dev/null \
            | grep -vE 'current user cannot be dropped|role ".*" already exists' \
            || true)
          n_errors=$(grep -c . <<<"$real_errors" || true)
          if (( n_errors == 0 )); then
            ok "Immich database loaded"
          else
            warn "psql ran the whole dump but $n_errors statement(s) failed:"
            head -20 <<<"$real_errors" | sed 's/^/      /' >&2 || true
            warn "the database is partly populated -- check it before reloading."
            warn "The dump itself is untouched, at $newest"
          fi
        fi
        rm -f "$PSQL_ERR"; PSQL_ERR=""
      else
        skip "Immich database left empty"
      fi
      ;;

    mariadb)
      # RomM's arm, as the postgres arm is Immich's.
      if [[ $svc != romm ]]; then
        warn "$svc is mapped to mariadb in SVC_SQL, but this branch only knows RomM"
        warn "-- it would load romm-db.sql into romm-db, not $svc's database."
        warn "Refusing that. Load $svc's dump by hand from the snapshot's _dumps/,"
        warn "then remove the SVC_SQL entry or teach this branch about $svc."
        continue
      fi

      dump="$STAGE$CONFIG/_dumps/romm-db.sql"
      if [[ ! -f $dump ]] && ! (( DRY_RUN )); then
        # The per-service restore above only pulled _dumps/sqlite/<svc>.
        run restic restore "$SNAP" --target "$STAGE" \
          --include "$CONFIG/_dumps/romm-db.sql" >/dev/null 2>&1 || true
      fi
      if [[ ! -f $dump ]] && ! (( DRY_RUN )); then
        warn "no romm-db.sql in snapshot $SNAP -- RomM's database is left empty"
        continue
      fi
      run docker compose -f "$DOCKER_ROOT/compose.yml" up -d romm-db >/dev/null 2>&1 \
        || warn "could not start romm-db automatically"

      # shellcheck disable=SC2016
      if (( DRY_RUN )); then
        skip "would wait for romm-db to report healthy"
      elif ! wait_ready romm-db \
             'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb-admin -u root ping'; then
        warn "romm-db never became ready -- NOT loading the dump into it"
        warn "the database is left empty and the dump is still in the snapshot."
        warn "Once the engine is up, load it with:"
        warn "  bmo-restore romm"
        continue
      fi
      # MYSQL_PWD expands inside the container, out of the host's process list.
      # shellcheck disable=SC2016
      if (( DRY_RUN )); then
        skip "would load romm-db.sql into romm-db"
      elif docker exec -i romm-db sh -c \
             'export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"; exec mariadb -u root' < "$dump"; then
        ok "RomM database loaded"
      else
        warn "loading the RomM database failed -- it is left empty"
      fi
      ;;
  esac
done

# -----------------------------------------------------------
step "Done"

if (( DRY_RUN )); then
  warn "dry run -- nothing was changed"
  exit 0
fi

# $ROLLBACK and its manifest are created up front; drop them when nothing
# was moved aside, so --list does not offer an empty undo.
discard_empty_rollback() {
  rm -f "$MANIFEST"
  rmdir "$ROLLBACK" 2>/dev/null && skip "$1"
  return 0
}

if (( ${#restored[@]} )); then
  ok "restored: ${restored[*]}"
else
  warn "nothing was restored"
  # A run that replaced nothing has nothing to roll back to.
  discard_empty_rollback "removed the empty rollback directory"
  exit 1
fi

if [[ -s ${MANIFEST:-/dev/null} ]]; then
  cat <<EOF

  The previous state of those services is at:
    $ROLLBACK

  To put it back:
    bmo-restore --undo $STAMP

  Delete it once you are satisfied -- it is outside \$CONFIG so it is not
  in any snapshot, but it is still using disk:
    rm -rf $ROLLBACK
EOF
else
  # Restored into empty space, as every bare-metal restore is: nothing to undo.
  discard_empty_rollback "nothing was overwritten, so there is no rollback to keep"
fi

cat <<EOF

  Start everything:
    cd $DOCKER_ROOT && docker compose up -d

  Then check the services you restored actually came up with their data,
  before deleting the rollback.
EOF
