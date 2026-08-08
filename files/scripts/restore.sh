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

# Before 4.4, "${arr[@]}" on an empty array is an "unbound variable" error
# under `set -u`, and several arrays here are legitimately empty -- a
# snapshot with no SQL dumps, no services pending a database load. Stated
# and checked rather than worked around at each use site.
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
# DYING tells the ERR trap below that this exit was deliberate and has
# already been explained, so a die() is not also reported as a crash with
# a line number nobody needs.
DYING=0
die()  { DYING=1; printf '\n%sERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ------------------------------------------------------------ error trap
#
# The same arrangement run.sh has, and this script needed it more: it is
# the one that runs when a host is already broken, and `set -e` on its own
# exits in silence. Every unguarded failure here used to surface as a bare
# `exit 1` with no output at all -- which is how a missing `|| true` on a
# command substitution could end a restore between moving a service's live
# directory aside and putting the replacement in place, and say nothing.
#
# -E propagates the trap into functions and subshells, which is where most
# of the work happens.
#
# die() is the deliberate path and prints its own message, so the trap has
# nothing to add for it.
set -E

on_err() {
  local rc=$1 line=$2 cmd=$3
  (( DYING )) && return
  printf '\n%sFAILED%s at line %s (exit %s):\n    %s\n' \
    "$c_red" "$c_off" "$line" "$rc" "$cmd" >&2
  # A failure inside a command substitution fires this twice: once in the
  # subshell, naming the command that actually failed, and again in the
  # parent, naming the assignment that swallowed it. Both lines are worth
  # having -- together they say what broke and where it was being read --
  # but the advice below belongs to the run, not to each frame of it.
  (( BASH_SUBSHELL )) && exit "$rc"
  printf '  nothing further has been changed. If a rollback was already taken,\n' >&2
  printf '  %s --list will show it and --undo <timestamp> will put it back.\n' \
    "${BASH_SOURCE[0]}" >&2
  # Exit here rather than leaving it to set -e, so the trap decides what a
  # failure does regardless of what the shell options are doing.
  exit "$rc"
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

DRY_RUN=0
ASSUME_YES=0

# The dry-run trace goes to a private duplicate of stderr, taken here
# before any redirection can exist.
#
# It used to go to stdout, and several call sites redirect the command
# they wrap -- `run restic restore ... >/dev/null 2>&1` to keep restic
# quiet, `run docker stop ... >/dev/null` to swallow its echo of the
# container name. A redirection on a function call applies to everything
# the function writes, so it swallowed the trace as well: --dry-run
# printed not one line for stopping containers or for running restic,
# the two steps a dry run exists to show you, while the `ok` lines after
# them still reported both as done.
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

# Printed from this file's own header, bounded by the divider rather than
# by a line count.
#
# It was `sed -n '3,17p'`, and a line count is a thing that goes stale
# silently: it ran seven lines past the synopsis into the design notes and
# stopped mid-clause, on "SQLite  the live files are NOT in the snapshot.
# A clean copy of". --snapshot, -y and -h were working options that it
# never mentioned at all. The range now ends where the usage text ends, so
# editing either one cannot desynchronise them.
#
# `$d` drops the divider itself, which is matched and therefore printed.
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

# --list, --undo and a restore are three different operations, and $MODE
# was last-writer-wins between them with nothing downstream able to tell
# that two had been asked for. Silent in every case, and destructive in
# two:
#
#   bmo-restore --list --all     ended as MODE=restore -- a full restore of
#                                every service, from a command whose first
#                                word asked to be shown a list
#   bmo-restore sonarr --all     SERVICES=(--all) was an assignment, not an
#                                append, so the named service was dropped
#                                and everything was restored instead
#   bmo-restore --list sonarr    sonarr collected and then ignored, since
#                                the list branch never reads SERVICES
#   bmo-restore sonarr --undo X  turned a restore into an undo
#
# Refusing costs nothing -- these are all typos or half-edited command
# lines, and none of them has a reading worth guessing at.
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
    # SERVICES is not set here any more. --all and a named service are both
    # "restore", so set_mode cannot tell them apart; the contradiction is
    # caught after the loop, where the whole command line is known.
    --all)       set_mode restore "$1"; WANT_ALL=1 ;;
    # Both of these take a value, and both used to take it with
    # `X="${2:-}"; shift`. Given as the last word on the line -- `--undo`
    # with the timestamp forgotten, which is the way it gets typed -- that
    # shift emptied "$@", the loop's own shift at the bottom then had
    # nothing left to shift, and its non-zero status ended the script
    # under `set -e` with no output whatsoever. The `die` below that names
    # the missing argument could not run. Refuse here instead, where the
    # argument is in hand and the message can say which one it was.
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

# --all and a named service are the one clash set_mode cannot see, both
# being "restore". Naming services alongside it is not a narrowing -- the
# sentinel is read as SERVICES[0] below, so whichever way round they were
# typed the names were dropped and everything was restored.
if (( WANT_ALL )) && (( ${#SERVICES[@]} )); then
  die "--all restores every service; naming ${SERVICES[*]} as well asks for two different things"
fi
(( WANT_ALL )) && SERVICES=(--all)

# --snapshot is the last argument that could still be collected and then
# ignored. --list and a restore both resolve it; the undo branch exits
# without ever reading it, so `bmo-restore --undo <ts> --snapshot 3f2a`
# quietly puts back whatever that rollback holds -- a rollback is a
# directory on this disk, not a snapshot, and no snapshot id can change
# which one it is. Refuse rather than ignore, for the same reason as the
# clashes above.
if (( SNAPSHOT_SET )) && [[ $MODE == undo ]]; then
  die "--undo restores from a local rollback, not from a snapshot -- --snapshot has no meaning with it"
fi

# The check that stood here -- [[ $MODE != undo || -n $UNDO_STAMP ]] -- was
# unreachable. MODE only becomes undo in the --undo arm, and that arm dies
# on a missing or option-shaped timestamp before it can set it, so there is
# no path to undo-without-a-stamp for this to catch. Removed rather than
# left as belt-and-braces: an unreachable guard reads on a later audit like
# a case someone confirmed was possible.

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

# Where compose.yml and the compose .env live.
#
# This script used to spell it $(dirname "$CONFIG") at every use -- the
# compose.yml it starts engines with, the .env it reads pinned versions
# from, and the "cd ... && docker compose up -d" it closes with. site.env
# sets DOCKER_ROOT and CONFIG as two independent values and nothing
# anywhere makes the second a child of the first; CONFIG=/srv/config alone
# would have pointed all three at /srv, which holds no compose.yml and no
# .env. run.sh now writes DOCKER_ROOT into $ENV_FILE.
#
# Not added to the required-variable loop above, and the old expression
# kept as the fallback: this script's whole purpose is a host that has
# just been rebuilt, and refusing to run against an $ENV_FILE written by
# an earlier run.sh would be a refusal at the worst possible moment. On
# every host where the assumption held -- which is every host it has run
# on -- the fallback is the same path it used before.
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
#
# The same lock backup.sh takes, for the case neither of them could see on
# its own: bmo-backup.timer fires at 03:30 (and, with Persistent=true,
# shortly after any boot that missed it), and a `bmo-restore --all` on a
# rebuilt host is measured in hours. Nothing stopped the two overlapping.
#
# What that costs is not a crash. backup.sh would take the lock
# uncontested, dump the databases of engines this restore has just started
# on empty data directories, snapshot a $CONFIG that is neither the old
# state nor the new one, and then forget --prune. The result is a snapshot
# that looks entirely healthy -- recent, complete, dumps present -- and
# restores a host to nothing. It also becomes `latest`, which is exactly
# what $SNAPSHOT defaults to and what the operator reaches for when the
# interrupted restore is retried.
#
# Retention keeps the good snapshots (keep-daily 7), so this is a trap for
# the next restore rather than a loss of the repository. Taking the lock
# closes it, and leaves nothing behind to remember to undo -- unlike
# stopping the timer for the duration, which is a state a failed restore
# would leave stopped.
#
# Held for the whole run, and only for the runs that change something.
# --list and --dry-run are read-only, restic handles concurrent readers
# itself, and the header tells you to reach for --dry-run first: making
# that fail because a two-hour prune is running would train you not to.
LOCK_FILE=/run/bmo-backup.lock
if [[ $MODE != list ]] && ! (( DRY_RUN )); then
  # A named descriptor rather than a literal 9: $TRACE_FD above is already
  # allocated this way, and two hardcoded numbers in one script is how one
  # of them quietly closes the other.
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    die "a backup is running (holds $LOCK_FILE) -- wait for it to finish, or
  stop it with 'systemctl stop bmo-backup.service', then re-run this"
  fi
fi

# Siblings of $CONFIG rather than children, deliberately. Anything under
# $CONFIG is inside the backup, so a rollback copy kept there would be
# swept into the next snapshot -- doubling every config directory in the
# repository, permanently, as a side effect of one restore.
#
# Still $(dirname "$CONFIG") and not $DOCKER_ROOT, unlike the uses above.
# This one genuinely asks "somewhere beside $CONFIG": outside it, and on
# the same filesystem, because the rollback is taken by moving a service's
# live directory here and that has to be a rename rather than a copy.
# $DOCKER_ROOT satisfies the first only by coincidence and the second not
# necessarily at all.
WORK_ROOT="$(dirname "$CONFIG")"
STAGE_ROOT="$WORK_ROOT/.bmo-stage"
ROLLBACK_ROOT="$WORK_ROOT/.bmo-rollback"

# ------------------------------------------------------- service mapping
#
# Two defaults hold for almost every service: its state is $CONFIG/<name>,
# and its container is called <name>. Only the exceptions are listed here.
#
# Deliberately a table in this file rather than something parsed out of
# the compose stacks: this script has to work on a freshly rebuilt host
# from /etc/bmo-backup.env alone, with no git checkout to read.

# Containers to stop, where they are not just <name>.
#
# gluetun is not an extra container for one service; it is the one whose
# network namespace another container lives in. qbittorrent declares
# `network_mode: "service:gluetun"` (downloads.yml:102) and so has no
# network of its own -- stopping gluetun takes the namespace out from
# under it. It does not stop, and nothing marks it: docker reports it
# Running, its WebUI answers on the shared port that no longer exists,
# and the closing `docker compose up -d` will not recreate it either,
# because its own definition has not changed. It sits there with no
# connectivity until someone restarts it by hand.
#
# gluetun also carries the `qbittorrent` alias on the core network
# (downloads.yml:84-87), which is how sonarr, radarr and cross-seed
# resolve the name at all -- qbittorrent has no attachment to publish one.
# So a stopped gluetun takes the name down with it, and the *arr apps
# report a download client that has vanished rather than one that is
# merely unreachable.
#
# Listed qbittorrent first so it is stopped before the namespace it
# depends on goes away. Both then come back on the same `docker compose
# up -d`, and qbittorrent joins the fresh namespace at start.
declare -A SVC_CONTAINERS=(
  [immich]="immich_server immich_machine_learning immich_postgres immich_redis"
  [romm]="romm romm-db"
  [minecraft]="minecraft-server"
  [gluetun]="qbittorrent gluetun"
)

# Paths under $DATA that belong to a service, where it has any.
#
# minecraft appears here and in no other table, and that is the whole
# problem it used to cause: its state is $DATA/games/minecraft and it
# mounts nothing under $CONFIG at all. --all enumerates services from the
# snapshot's $CONFIG children, so minecraft was never in the list -- the
# world went into every snapshot and came back out of none of them, with
# nothing said about it, and the first `docker compose up -d` after a
# rebuild generated a fresh one over the top. See the --all expansion
# below, which now unions in these keys, and the have_config handling in
# the restore loop, which lets a service have no $CONFIG half.
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

# Top-level *.sql names in the snapshot's _dumps, filled in once below and
# consulted per service. A restic call inside the loop would be twenty
# round trips to the NAS for something that cannot change mid-run.
SNAP_SQL_DUMPS=()

# The engine dumps in the snapshot that belong to $1, matched on the
# container-name convention backup.sh writes them under:
# $DUMP_DIR/<container>.sql, where <container> is the service name or the
# service name plus a suffix -- immich_postgres, synapse-db, romm-db.
#
# Glob patterns rather than a regex, so a service name containing a
# regex metacharacter cannot turn into a wildcard.
svc_sql_dumps() {
  local svc=$1 d
  for d in "${SNAP_SQL_DUMPS[@]}"; do
    [[ $d == "$svc".sql || $d == "$svc"[-_]*.sql ]] && printf '%s\n' "$d"
  done
  return 0
}

# ------------------------------------------------------ engine readiness

# Wait for a database container to be able to answer queries.
#
# This replaced a fixed `sleep`, which was wrong in both directions: too
# short whenever an engine is initialising an empty data directory on a
# slow disk -- and that is the only situation this code ever runs in,
# because the restore has just given it one -- and pure delay when the
# engine is ready in two seconds. It "worked" on the host it was written
# for, which is the worst kind of passing.
#
# The trap it has to avoid: on a fresh data directory both engines start,
# initialise, and then restart themselves. The container is "running" the
# whole time, so container state alone means nothing. Docker health
# status does mean something, and both images here define one --
# romm-db's is `healthcheck.sh --connect --innodb_initialized`, which is
# exactly the condition worth waiting for. $probe is the fallback for an
# image that declares no healthcheck, so this does not quietly degrade to
# "it exists" if one is ever removed.
wait_ready() {
  local c=$1 probe=${2:-} timeout=${3:-300}
  local waited=0 interval=2 state health inspected

  while (( waited < timeout )); do
    # Status and health in one inspect, not two. This polls every 2s for
    # up to five minutes, and asking the daemon twice per tick for two
    # fields of the same object is 150 round trips nobody needs. The
    # separator cannot appear in either value.
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
  # Resolve "latest" once, so every step of one run reads the same
  # snapshot even if a backup lands in the middle of a long restore.
  #
  # The trailing `|| true` covers the empty case, and it matters more than
  # it looks. grep exits 1 when the repository holds no snapshot for this
  # host; pipefail promotes that to the pipeline's status; `set -e` then
  # killed the script at the caller's `snap=$(snapshot_id ...)` assignment
  # -- before the `[[ -n $snap ]] || die` on the very next line. Both
  # callers test for an empty result and neither could ever reach that
  # test, so the two messages that name the host and the snapshot were
  # unreachable and the command simply exited 1 in silence.
  #
  # That is precisely the "reinstalled host came up under a different
  # name" case BACKUP_HOST exists to guard against, and the guard's own
  # error message was the thing that could not print.
  restic snapshots --host "$BACKUP_HOST" --json "$1" 2>/dev/null \
    | grep -oE '"short_id":"[^"]+"' | tail -1 | cut -d'"' -f4 || true
}

# One level under $CONFIG in snapshot $1: the services that keep
# configuration on disk, which is the same unit this script restores.
# _dumps is not a service; it is where the databases of all the others
# are.
#
# The sed anchor on ^$CONFIG/ is doing real work, and every `restic ls`
# parse in this file has one for the same reason: `restic ls` prints a
# header line -- "snapshot abc1234 of [...] filtered by [...] at ...:" --
# before any paths, and prints it whether or not anything matched. A test
# as loose as `| grep -q .` therefore always succeeds, and a membership
# check built on one would report every service as present.
#
# A function rather than a pipeline written out at each call site: that
# reasoning has to hold everywhere it is used, and a copy edited without
# it fails silently and in the direction of "everything is fine".
snap_config_svcs() {
  restic ls "$1" "$CONFIG" 2>/dev/null \
    | sed -n "s|^${CONFIG}/\([^/]*\)$|\1|p" | grep -v '^_dumps$' | sort -u || true
}

# The top-level *.sql files under _dumps in snapshot $1 -- the engine
# dumps and nothing else. An unfiltered listing put "README" (backup.sh
# writes one there every run) and "sqlite" (the directory holding the
# other 40) in among the database names, on the one screen someone reads
# while actually recovering a host.
snap_sql_dumps() {
  restic ls "$1" "$CONFIG/_dumps" 2>/dev/null \
    | sed -n "s|^${CONFIG}/_dumps/||p" | grep -E '\.sql$' | sort || true
}

# What counts as a SQLite database by name. The same list backup.sh's
# dump_sqlite discovers with, so the two stay in step -- and one spelling
# within this file rather than one per call site.
SQLITE_EXT_RE='\.(db|sqlite|sqlite3)$'

# How much the rollbacks already on this host use, and what is left on the
# filesystem holding them, tab-separated. Reported in two places -- the
# --list inventory and the warning shown as another one is about to be
# added -- and the two must not be able to disagree.
#
# Both halves fall back to "?" rather than to an empty column: a listing
# that reads "total   " is a broken listing, and a restore is not the
# moment to start wondering whether the tool is working.
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

  # "$SNAPSHOT", not a hardcoded `latest`. --snapshot does not call
  # set_mode, so `bmo-restore --list --snapshot 3f2a1b` parses cleanly --
  # and used to print the inventory of the *latest* snapshot under a
  # header naming it, which is the reading someone does immediately
  # before choosing what to restore. Same silently-ignored-argument class
  # as `bmo-restore --list sonarr`, which set_mode now refuses.
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

  # Counted, not listed: 40 paths would bury the two lines above, and the
  # per-service detail belongs to `bmo-restore <service> --dry-run`.
  #
  # --recursive is required. `restic ls <snap> <dir>` lists that
  # directory's immediate children only, so without it the dumps sit one
  # level down under sqlite/<service>/ and the count came out 0 -- while
  # the SQL listing above, which wants top-level *.sql and nothing else,
  # worked fine and gave no hint anything was wrong.
  n_sqlite=$(restic ls --recursive "$snap" "$CONFIG/_dumps/sqlite" 2>/dev/null \
    | grep -cE "$SQLITE_EXT_RE" || true)
  echo "  SQLite: ${n_sqlite:-0} database(s)"

  # Collected first, and the header printed only if there is something
  # under it: the directory existing is not the same as a rollback being
  # available, and a bare heading reads as one that is.
  rollbacks=$(find "$ROLLBACK_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    2>/dev/null | sort || true)
  if [[ -n $rollbacks ]]; then
    step "Rollbacks available on this host (bmo-restore --undo <timestamp>)"
    # With sizes, and with what is left on the filesystem holding them.
    # These are whole $CONFIG trees -- immich's postgres cluster among
    # them -- sitting on the root disk until somebody removes them by
    # hand. Nothing on this host deletes them: not this script, not
    # run.sh, not the backup timer. A bare list of timestamps gave no
    # hint of that, and this listing is the only place they are ever
    # mentioned again after the run that created them.
    #
    # Sizes fall back to "?" rather than to an empty column: a listing
    # that reads "total   " is a broken listing, and a restore is not
    # the moment to start wondering whether the tool is working.
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

# Expand --all into the actual service list, read from the snapshot so it
# cannot go stale against a service added or removed since this was
# written.
#
# Two sources, unioned. The snapshot's $CONFIG children cover everything
# that keeps configuration on disk, which is almost every service -- but
# "almost" is what made this quietly wrong. A service whose entire state
# lives under $DATA has no $CONFIG directory to be discovered by, so it
# was absent from every --all restore while the nightly backup went on
# storing it faithfully. SVC_DATA is the list of exactly those paths, so
# its keys are the missing half of the enumeration.

# Read once and used twice -- to expand --all, and to decide per service
# whether it has a $CONFIG half at all.
mapfile -t SNAP_CONFIG_SVCS < <(snap_config_svcs "$SNAP")

# Exact string membership, not a pattern match: a service name is a
# directory name and has no business being interpreted as a regex.
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

# What is already on the disk this restore is about to add to.
#
# A rollback is a rename, so making one costs nothing at the time -- but
# the restore then writes a fresh copy of the same service beside it, and
# the host ends up holding two. Nothing ever removes the old one, so the
# cost of a restore is paid until someone notices, and $ROLLBACK_ROOT is
# next to $CONFIG on the root filesystem, where running out is not a
# service being degraded but the whole box stopping.
#
# Reported here as well as in --list because this is the moment another
# one is added, and the operator is being asked to approve it anyway.
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

# rmdir, not rm -rf, on the parent: it removes $STAGE_ROOT only when this
# was the last staging directory in it, and quietly does nothing while a
# concurrent restore still has one. Without it every run leaves an empty
# .bmo-stage next to $CONFIG.
#
# Every command here has to be incapable of failing. It runs from the EXIT
# trap, including on the way out of a failure, and an ERR trap firing from
# inside an EXIT trap reports a line number and a $BASH_COMMAND that belong
# to neither -- it printed "FAILED at line 473: exit 0" after a clean dry
# run. The rmdir failing IS the intended behaviour, so it says so.
cleanup() {
  [[ -d ${STAGE:-} ]] && rm -rf "$STAGE"
  rmdir "$STAGE_ROOT" 2>/dev/null || true
  # psql's stderr, held in a temp file while the SQL branches below decide
  # what it means. Loading a dump is the longest single operation in this
  # script and the one most likely to be interrupted, and its own `rm -f`
  # is at the end of a path a Ctrl-C does not reach.
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
  #
  # Staged rather than written straight over the live path, so a restic
  # failure halfway through cannot leave a half-replaced config directory
  # behind. The live directory is only moved aside once there is a
  # complete replacement to put in its place.
  if ! run restic restore "$SNAP" --target "$STAGE" \
         --include "$src" \
         --include "$CONFIG/_dumps/sqlite/$svc" >/dev/null 2>&1; then
    warn "restic could not restore $src from $SNAP -- skipping $svc"
    continue
  fi

  # Having no $CONFIG directory is not by itself an error. minecraft keeps
  # its whole world in $DATA/games/minecraft and mounts nothing under
  # $CONFIG, so "not in the snapshot" is the normal and correct answer for
  # it. Give up only when there is no $DATA half either -- that is the
  # case where the snapshot genuinely holds nothing under this name.
  #
  # Asked of the snapshot rather than of $STAGE under --dry-run, because
  # nothing has been staged there to look at, and a dry run that announced
  # "mv $CONFIG/minecraft into place" would be describing something that
  # cannot happen.
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

  # Whether this service actually got anything back, as opposed to merely
  # being visited. For a service with a $CONFIG half, reaching here means
  # yes. For a $DATA-only one it stays 0 until the $DATA restore below is
  # accepted -- decline that prompt and nothing whatsoever has happened,
  # and "restored: minecraft" in the summary would be a plain untruth.
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
  #
  # These are the files backup.sh excluded from the snapshot, so what was
  # just restored above has a hole exactly where each database belongs.
  dumps="$STAGE$CONFIG/_dumps/sqlite/$svc"
  if ! (( have_config )); then
    # No $CONFIG tree for this service, so there is nowhere under $CONFIG
    # for a SQLite database to have lived and nothing for _dumps to hold.
    # Saying "no SQLite dumps (it may not have a database)" here would be
    # true and useless -- it reads as a finding rather than as the shape
    # of the service.
    :
  elif (( DRY_RUN )); then
    # Nothing has been staged, so there is no directory to look in. Ask
    # the snapshot instead -- otherwise the most consequential step of
    # the whole restore is the one the dry run says nothing about, and
    # the dry run exists precisely to be trusted about that.
    #
    # --recursive, and filtered to database extensions, because the
    # dumps mirror each database's path under $CONFIG and most are not
    # at the top: jellyfin's is data/jellyfin.db, syncthing's is
    # config/index-v2/main.db. A non-recursive listing returned the
    # intermediate directory instead, so the dry run announced "put
    # /srv/docker/config/jellyfin/data back" -- naming a directory where
    # a database belongs, and hiding that there were two of them.
    # cross-seed.db sits at the top level and looked correct throughout.
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
      # Only when it is genuinely missing. This was an unconditional
      # `install -d -m 0755`, and GNU install applies the mode to a
      # directory that already EXISTS -- so every parent of a restored
      # database was forced to 0755, widening whatever mode the snapshot
      # had faithfully recorded, on a restore that is supposed to put
      # things back as they were. It is almost always already there:
      # backup.sh excludes the database files, not the directories holding
      # them, so the tree restored above has a hole only where each file
      # belongs.
      dest_dir=$(dirname "$dest")
      [[ -d $dest_dir ]] || run install -d "$dest_dir"
      # -a is correct now that backup.sh stamps each dump with the live
      # file's ownership and mode. Before that it faithfully preserved
      # root:root 0644, which is only what sqlite3 happened to run as.
      run cp -a "$d" "$dest"
      # Any -wal/-shm that survived is from a different instant than this
      # database file. SQLite pairs them by salt: at best it refuses the
      # database, at worst the salts match and it replays a checkpoint
      # this copy never had.
      run rm -f "$dest-wal" "$dest-shm" "$dest-journal"
      (( ++n ))
    done < <(find "$dumps" -type f 2>/dev/null)
    (( n )) && ok "restored $n SQLite database(s) from _dumps"
  elif [[ -z ${SVC_SQL[$svc]:-} ]]; then
    # Not necessarily wrong -- plenty of services keep no database at all
    # -- but worth saying, because for one that does this is the symptom
    # of a backup that never dumped it.
    skip "no SQLite dumps for $svc in $SNAP (it may not have a database)"
  fi

  # ---- a SQL engine dump nothing here knows how to load ----
  #
  # Deliberately outside the chain above, and outside the --dry-run split
  # inside it: this has to be reported whether or not the service has
  # SQLite dumps, and a dry run is precisely when you want to learn that a
  # service is going to come back empty -- while it is still a dry run.
  #
  # A dump named after this service means backup.sh dumped a SQL engine
  # for it, and therefore excluded that engine's live data directory from
  # the snapshot. With no SVC_SQL entry nothing below will ever load it,
  # so the service is about to come back with all of its files and an
  # empty database, looking merely "reset" -- the exact failure this whole
  # script exists to prevent.
  #
  # synapse was in that state: dumped by backup.sh, its $CONFIG/synapse/db
  # excluded from the snapshot, absent from SVC_SQL, and reported by the
  # line above with the reassuring "it may not have a database".
  if [[ -z ${SVC_SQL[$svc]:-} ]]; then
    mapfile -t orphan_dumps < <(svc_sql_dumps "$svc")
    if (( ${#orphan_dumps[@]} )); then
      warn "snapshot $SNAP holds a SQL engine dump for $svc:"
      printf '      %s\n' "${orphan_dumps[@]}"
      warn "nothing here knows how to load it -- $svc has no SVC_SQL entry, and its"
      warn "engine's data directory is excluded from the backup. $svc WILL START EMPTY."
      # Deliberately NOT "add $svc to SVC_SQL", which is what this said and
      # was advice that made things worse. The engine arms below are not
      # generic loaders selected by that table: `postgres)` is Immich end to
      # end (its self-dump under $DATA/photos/backups, the `database`
      # compose service, the immich_postgres container) and `mariadb)` is
      # RomM's. Neither one so much as reads $svc. Mapping synapse to
      # postgres would therefore start Immich's engine and load Immich's
      # dump into it under a step header reading "synapse database", while
      # the synapse dump this warning is about stayed exactly where it is.
      # The guards at the head of each arm now refuse that, so the advice
      # and the code agree.
      warn "Load it by hand before starting $svc -- this script only knows how to"
      warn "load Immich's and RomM's engines, not this one."
    fi
  fi

  # ---- $DATA, where the service has any ----
  #
  # Restored in place, with no rollback copy. These are media libraries:
  # $DATA/photos alone is hundreds of gigabytes, and moving it aside
  # before restoring would need twice that free before it could start.
  # restic writes only what differs, so this is a merge rather than a
  # replacement -- which is also why it cannot be undone, and why it asks.
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
#
# This has to come after the file restore, and the two want opposite
# things: restoring files needs the container stopped, loading a dump
# needs it running. So the engines are started here, on the empty data
# directories the snapshot deliberately does not contain, and initialise
# themselves before being fed.

pg_major() { grep -oE 'database version [0-9]+' | grep -oE '[0-9]+' | head -1; }

# Write a dump to stdout, decompressing it if it is compressed.
#
# Spelled as an if rather than the shorter
#   [[ $f == *.gz ]] && gunzip -c "$f" || cat "$f"
# which is the classic a && b || c trap. When the file IS a .gz and gunzip
# fails -- a truncated or corrupt dump, which is precisely the case worth
# handling -- the || arm fires as well, and cat appends the raw gzip bytes
# to whatever gunzip had already decompressed. Downstream of the pipe that
# is a partial SQL load followed by binary garbage: psql commits
# everything before the garbage, then aborts on it, and the caller reports
# a failure while the database is in fact half full.
dump_stream() {
  if [[ $1 == *.gz ]]; then gunzip -c "$1"; else cat "$1"; fi
}

# Values that live in the compose .env rather than in $ENV_FILE.
#
# $ENV_FILE is written by run.sh and deliberately holds only what both
# scripts need in order to find the repository and the compose project.
# Anything compose interpolates -- credentials, pinned image tags -- lives
# in $DOCKER_ROOT/.env, the same file the `docker compose` calls below
# already read.
#
# Read one key rather than sourced: that file holds every secret on this
# host, and pulling all of it into this shell's environment to display a
# version string is not a trade worth making.
#
# Compose strips one layer of matched quotes, so IMMICH_VERSION="v1.119.0"
# and IMMICH_VERSION=v1.119.0 pin the same image. Read with sed the quotes
# stay on, and the only caller prints the result during a recovery -- the
# one moment where "is that the version that wrote this dump?" is being
# answered by eye. Stripping them keeps the answer comparable to what
# `docker compose config` or the release notes would show.
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
      # This arm is Immich's, end to end: the dump it looks for is Immich's
      # scheduled self-dump under $DATA/photos, the container it starts and
      # feeds is immich_postgres, the version it reports is IMMICH_VERSION.
      # It never reads $svc. So a second service mapped to `postgres` here
      # would not be restored by it -- it would silently re-load IMMICH's
      # dump into IMMICH's engine, print "Immich database loaded", and leave
      # its own dump untouched, all under a step header carrying its name.
      #
      # Generalising this is a real change and not a small one (the
      # self-dump preference, the vectorchord handling, the per-service
      # container and compose-service names), so until it is made, the
      # mapping is refused rather than misread.
      if [[ $svc != immich ]]; then
        warn "$svc is mapped to postgres in SVC_SQL, but this branch only knows Immich"
        warn "-- it would load Immich's dump into Immich's engine, not $svc's."
        warn "Refusing that. Load $svc's dump by hand from the snapshot's _dumps/,"
        warn "then remove the SVC_SQL entry or teach this branch about $svc."
        continue
      fi

      # Immich dumps its own database on a schedule, and that dump is
      # version-aware in ways a plain pg_dumpall is not -- the vectorchord
      # extension in particular. backup.sh takes a pg_dumpall too, but
      # Immich's own file is the one to restore from.
      # The `|| true` is load-bearing, not decoration. find exits 1 when
      # $DATA/photos/backups does not exist -- a replacement data disk, or
      # a restore where the operator declined the $DATA half at the prompt
      # above -- and 2>/dev/null hides the reason. Under pipefail that
      # failed the assignment, and `set -e` ended the whole script right
      # here: no message at all, the four warn lines below unreachable in
      # exactly the case they were written for, the rollback instructions
      # at the end never printed, and romm -- which sorts after immich in
      # sql_pending -- never restored either. A missing directory is
      # something to report, not to die of.
      backup_dir="$DATA/photos/backups"
      newest=$(find "$backup_dir" -type f \( -name '*.sql' -o -name '*.sql.gz' \) \
                 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
      if [[ -z $newest ]]; then
        # The two cases look identical from here but mean different
        # things, and the second one has an obvious next move.
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

      # "Verify version first": what is actually checkable here is the
      # PostgreSQL major version. A dump taken from a newer server does
      # not reliably load into an older one, and that failure is the one
      # that corrupts quietly rather than erroring. The Immich
      # application version is NOT recorded in the dump in any stable
      # form, so it is reported for a human to judge, not asserted.

      # The dump's shape, and the only record of it. It decides both the
      # database psql connects to and how the outcome is judged, and those
      # two must not be able to drift apart -- so the target database is
      # derived from this inside the container at the point of use rather
      # than carried alongside it in a second variable that could
      # disagree. Set for real below, once the header has been read.
      dump_is_cluster=0

      if (( DRY_RUN )); then
        skip "would compare the dump's PostgreSQL major version against the running server,"
        skip "and probe psql for \\restrict support if the dump's header uses it"
      else
        # The header, read ONCE into a variable, because both questions
        # below are asked of it and a live pipeline cannot be asked either
        # one safely.
        #
        # This was two separate `dump_stream ... | head -N | <test>`
        # pipelines. `head` exits the moment it has its N lines, gunzip is
        # killed by SIGPIPE, and `pipefail` (set at the top of this script)
        # promotes that 141 to the status of the whole pipeline -- so the
        # shape test, which ran as an `if` condition with nothing to absorb
        # it, was false for every dump longer than five lines. That is every
        # real dump: verified 10/10 against a dump-shaped file, plain and
        # gzipped alike. Only a file of five lines or fewer, where head
        # reaches EOF before it reaches its count, ever said "cluster".
        #
        # The cluster branch below was therefore unreachable, whatever the
        # file actually was. It did not misfire on bmo's dumps, because
        # Immich writes a pg_dump and "single-database" is the right answer
        # for one -- but it was being reached by accident rather than by the
        # test, and would have stayed wrong if the format ever changed.
        #
        # A command substitution collects the whole of head's output before
        # anything is tested, and `|| true` absorbs the SIGPIPE that is
        # expected rather than exceptional. The tests downstream read a
        # string, and a here-string cannot deliver a broken pipe.
        #
        # 200 lines rather than 50 for headroom, not because 50 is known to
        # be too few: in the dump on bmo `-- Dumped from database version`
        # is line 7. In a pg_dumpall it sits in the first embedded pg_dump
        # header, after however many roles and tablespaces the cluster has,
        # and that distance is not something this script gets to bound.
        dump_head=$(dump_stream "$newest" 2>/dev/null | head -200 || true)
        dump_major=$(pg_major <<<"$dump_head" || true)
        # Read once and picked apart here rather than in two pipelines, so
        # the major and the full version cannot come from different reads.
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

        # The major version is not the whole compatibility story, and the
        # check above says "compatible" in a case where the load cannot
        # work at all.
        #
        # Dumps written by a pg_dump from the August 2025 minor releases
        # open with `\restrict <key>` -- a psql meta-command added there to
        # mitigate CVE-2025-8714. bmo's dump carries it on line 5, before
        # any data. A psql that predates its own branch's minimum does not
        # know the command, and ON_ERROR_STOP=1 -- correctly in force for a
        # single-database dump -- aborts on it, loading nothing.
        #
        # 14 vs 14 passes the gate above, so pinning the postgres image
        # anywhere inside 14.x passes it too, and the advice that gate gives
        # under pressure is "pin the image back". bmo runs 14.19, which is
        # the first 14.x with \restrict: there is no margin below it.
        #
        # Probed rather than compared against a table of branch minimums,
        # because the minimums are a thing to be remembered wrong and psql
        # is right here and can simply be asked. \unrestrict takes the same
        # key back off, so the probe leaves the session as it found it.
        # Confirmed on bmo: exit 0 when the commands exist, exit 1 for an
        # unknown meta-command under ON_ERROR_STOP=1.
        #
        # Not fatal, and deliberately not `die`: romm's dump is still to
        # come in this same loop, and dying here would take it down over a
        # problem that belongs to Immich alone.
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

        # A cluster dump and a single-database dump want opposite targets,
        # and picking the wrong one is not a warning -- it is a load that
        # stores nothing.
        #
        # pg_dumpall writes the whole cluster: DROP DATABASE, CREATE
        # DATABASE and \connect for each database in it. Handed the target
        # database directly, its first statement is
        # `DROP DATABASE IF EXISTS "immich"` against the database psql is
        # connected to, which postgres refuses outright -- and
        # ON_ERROR_STOP=1 aborts the whole load there, before a single row
        # lands. It has to go to a maintenance database instead; initdb
        # always creates `postgres`, whatever POSTGRES_DB is set to.
        #
        # pg_dump writes one database, with no \connect and no CREATE
        # DATABASE, and needs exactly the opposite: the target database
        # itself, or the schema is restored into the wrong one.
        #
        # Immich's own scheduled backup is a pg_dump -- checked on bmo,
        # Immich v3.1.0, dump header "PostgreSQL database dump", no role
        # section at all. backup.sh's fallback at _dumps/immich_postgres.sql
        # IS a pg_dumpall (backup.sh:272), and it is the reason the cluster
        # branch exists rather than being deleted: it is loaded by hand
        # today, per the warn above, but nothing stops the shapes swapping
        # under us on an Immich upgrade. So read the header rather
        # than hardcode it. The two differ on the first line.
        #
        # Matched against the first few lines of $dump_head, not against the
        # whole of it: "PostgreSQL database cluster dump" is pg_dumpall's
        # second line and belongs to the file as a whole, so a match further
        # down would be a coincidence -- a table holding that text, say --
        # and would send a single-database dump to the wrong target.
        if grep -q 'database cluster dump' <<<"$(head -5 <<<"$dump_head")"; then
          dump_is_cluster=1
          ok "dump is a cluster dump (pg_dumpall) -- loading via the postgres database"
        else
          dump_is_cluster=0
          ok "dump is a single-database dump (pg_dump) -- loading into \$POSTGRES_DB"
        fi

        # Read from $DOCKER_ROOT/.env, where compose actually gets it.
        # This used to print ${IMMICH_VERSION:-<unset>}, and IMMICH_VERSION
        # is not one of the seven keys run.sh writes into $ENV_FILE -- so
        # the one piece of version guidance offered during a recovery said
        # "<unset>" on every run, whatever was pinned.
        immich_ver=$(env_value IMMICH_VERSION)
        warn "IMMICH_VERSION pinned in $DOCKER_ROOT/.env: ${immich_ver:-<unset>}"
        warn "-- check the release notes if that is far from the version that wrote this dump."
      fi

      if (( DRY_RUN )); then
        skip "would load $(basename "$newest") into immich_postgres"
      elif prompt_yn "load $(basename "$newest") into immich_postgres now?"; then
        # The single-quoted body is the point, exactly as in the mariadb
        # branch below and in the pg_isready probe above: the role and
        # database names are expanded INSIDE the container, from the
        # environment compose gave it.
        #
        # They used to be read on the host as ${DB_USERNAME:-postgres} and
        # ${DB_DATABASE_NAME:-immich}. Neither variable is ever set here --
        # this script sources only /etc/bmo-backup.env, which run.sh writes
        # with seven keys, none of them these; the real values live in
        # secrets/env.sops and reach the engine through $DOCKER_ROOT/.env.
        # So both defaults always applied, and the fresh cluster this
        # restore has just initialised has exactly one superuser, named
        # $DB_USERNAME. Unless that happened to be the literal "postgres",
        # psql died with `FATAL: role "postgres" does not exist` before
        # reading a byte of the dump, and the only clue was the generic
        # "loading the Immich database failed" below.
        #
        # POSTGRES_USER / POSTGRES_DB are what photos.yml sets from those
        # same values, so inside the container they are always right and
        # cannot drift from what the engine was actually initialised with.
        #
        # ON_ERROR_STOP is applied to a single-database dump and withheld
        # from a cluster dump, and that asymmetry is the whole point.
        #
        # `pg_dumpall --clean` emits, at the very top, a DROP ROLE for every
        # role in the cluster -- including the one psql is connected as.
        # PostgreSQL always refuses that with `ERROR: current user cannot be
        # dropped`, and the CREATE ROLE on the next line then fails with
        # `role already exists`. pg_dumpall's own source says as much: it
        # emits CREATE ROLE unconditionally because "even with --clean we
        # will have failed to drop it". Both errors are expected, harmless
        # and unavoidable, which is exactly why Immich's documented restore
        # command does not set ON_ERROR_STOP. This is the failure the
        # hand-loaded _dumps/immich_postgres.sql would hit, not one Immich's
        # own dump produces. With it set, psql aborts on
        # the first of them -- at the top of the file, before a single row
        # of anybody's photo library had been read.
        #
        # A pg_dump of one database has no role section and no such
        # problem, so it keeps the strict setting.
        #
        # Dropping ON_ERROR_STOP costs the exit status its meaning: psql
        # returns 0 for a run in which hundreds of statements failed. So the
        # cluster path is judged on what psql actually complained about,
        # with the two known-harmless errors subtracted, rather than on $?.
        # The uppercase name throughout, because that is the one the EXIT
        # trap knows: a lowercase alias of it is a second handle on the
        # same file that the trap cannot see being reassigned.
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
            # Deliberately not "it is left empty", which is what this said
            # before and was a guess dressed as a fact. ON_ERROR_STOP=1 stops
            # at the FIRST error, so everything before it has already
            # committed -- the database can hold most of the dump, none of
            # it, or anything between. Someone told "it is left empty" will
            # re-run the load into a database that is not.
            warn "loading the Immich database stopped at the first error"
            warn "psql had already committed everything before that point, so the"
            warn "database may be partly populated -- check it before reloading."
            [[ -s $PSQL_ERR ]] && sed 's/^/      /' "$PSQL_ERR" >&2
            warn "The dump itself is untouched, at $newest"
          fi
        elif (( psql_rc != 0 )); then
          # Without ON_ERROR_STOP psql exits non-zero only for something it
          # could not work around at all: no connection, a FATAL, a broken
          # stream. None of those are "some statements failed".
          warn "psql could not run the dump at all (exit $psql_rc)"
          [[ -s $PSQL_ERR ]] && sed 's/^/      /' "$PSQL_ERR" >&2
          warn "The dump itself is untouched, at $newest"
        else
          # The two errors every pg_dumpall --clean restore produces against
          # the role it is connected as. Anchored to the message text rather
          # than to a role name, because the role is $DB_USERNAME and this
          # script deliberately never learns what that is.
          # Filtered once and held, rather than run again to print: the
          # exclusion list is the whole point of this block, and two
          # copies of it can report a count and then show a different set.
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
      # RomM's, for the same reason the postgres arm above is Immich's: the
      # dump name, the compose service and the container are all literal
      # romm-db, and $svc is never consulted.
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
      # The single-quoted sh -c body is the point: MYSQL_PWD is expanded
      # inside the container from its own environment, so the password
      # never appears in this host's process list.
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

# $ROLLBACK is created up front, before it is known whether anything will
# go into it, so a run that moved nothing aside leaves an empty directory
# behind -- and --list advertises those under "Rollbacks available on this
# host", offering an undo that would restore nothing.
#
# The manifest is created up front and is still empty, so it has to go
# before the directory will; that ordering is why the two are one function
# rather than two lines written out at each of the call sites below.
#
# `return 0` because a rollback that is NOT empty is the ordinary outcome,
# and a failing rmdir at the tail of a function is exactly what `set -e`
# would take for a fault.
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
  # Everything restored into empty space, so nothing was moved aside and
  # there is nothing to undo.
  #
  # Not an edge case: this is the shape of every bare-metal restore, where
  # each service lands in a $CONFIG that run.sh has just created empty.
  discard_empty_rollback "nothing was overwritten, so there is no rollback to keep"
fi

cat <<EOF

  Start everything:
    cd $DOCKER_ROOT && docker compose up -d

  Then check the services you restored actually came up with their data,
  before deleting the rollback.
EOF
