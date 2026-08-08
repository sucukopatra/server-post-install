#!/bin/bash
#
# Rebuild, pull, and restart the whole stack. Installed by run.sh into
# scripts/ under DOCKER_ROOT, which also rewrites the cd path below to
# this host's DOCKER_ROOT -- the default is left here so the script stays
# runnable as-is.
set -e
cd /srv/docker

# Refuse to restart the stack onto a data disk that is meant to be there
# and is not. docker-update.service already carries RequiresMountsFor for
# this path, so systemd covers the boot run -- this covers a hand-run,
# where nothing else would.
#
# The fstab probe is the one run.sh deliberately does *not* use, and the
# reason it rejected it does not apply here. run.sh can meet a freshly
# reinstalled host whose fstab has not been written yet, where "no entry"
# wrongly reads as "single-disk by design"; update.sh only ever runs on a
# host that run.sh has already provisioned. No entry here genuinely means
# DATA_IS_MOUNT=0, and the safe direction is the one it fails towards.
#
# Paths rewritten to this host's DATA and NAS by run.sh at install time.
DATA=/srv/data
NAS=/srv/nas
if grep -qs "[[:space:]]${DATA}[[:space:]]" /etc/fstab && ! mountpoint -q "$DATA"; then
  echo "ERROR: $DATA has an fstab entry but is not mounted." >&2
  echo "       Refusing to restart the stack -- Immich would come up against an" >&2
  echo "       empty library. Mount the disk and re-run." >&2
  exit 1
fi

# Same refusal for the NAS, and here nothing else covers it: the docker
# drop-in only orders docker.service after the export, and
# docker-update.service carries RequiresMountsFor for $DATA alone. This
# check is the boot run's guard as well as the hand-run's.
#
# It matters because of what `down` followed by a failing `up -d` leaves
# behind. The stacks bind paths inside the export with
# bind.create_host_path: false, so with the NAS gone `up -d` does not
# start jellyfin against an empty directory -- it fails. Good on its own,
# fatal in this order: `down` has already stopped everything, set -e
# aborts the script, and every NAS-backed service stays explicitly
# stopped with nothing to bring it back. Before the guards existed those
# containers at least came up degraded. Refusing before the `down` is
# what makes the two changes safe together.
#
# NOT mountpoint -q. $NAS is mounted with x-systemd.automount, and an
# automount point is itself a mountpoint (autofs) whether or not the
# export behind it is attached -- the probe would pass with the NAS
# switched off. Stat'ing a path *inside* the export is what triggers the
# automount and reports the truth, which is exactly what the compose
# guards do. media/ is the directory all four NAS-backed stacks bind.
#
# With the NAS down that stat blocks while the automount tries the mount,
# bounded by DefaultTimeoutStartSec (90s), and then fails. Worth paying:
# it is the same 90s the docker drop-in was just changed to stop spending
# at boot, but spent here it costs nothing that was running -- dockerd
# and every container are already up, and this exits before the `down`.
# At boot that makes docker-update.service fail loudly on a dead NAS
# instead of emptying the host, which is what the $DATA guard above
# already does.
if grep -qs "[[:space:]]${NAS}[[:space:]]" /etc/fstab && [[ ! -d "$NAS/media" ]]; then
  echo "ERROR: $NAS has an fstab entry but $NAS/media is not there." >&2
  echo "       Refusing to restart the stack -- the NAS-backed containers bind" >&2
  echo "       paths inside the export and would fail to start, after this script" >&2
  echo "       had already stopped them. Leaving the running stack alone." >&2
  echo "       Mount the export and re-run." >&2
  exit 1
fi

# Everything slow and failure-prone happens while the stack is still up:
# the xcaddy build takes minutes and the pull depends on the network, and
# either can fail. Only once both have succeeded do we take anything
# down, which shrinks the window where bmo is serving nothing from
# minutes to seconds. Do not move `down` back above these.
echo "==> Rebuilding locally-built images (caddy)..."
docker compose build --pull caddy
echo "==> Pulling latest images..."
docker compose pull --ignore-buildable

echo "==> Restarting containers..."
docker compose down
docker compose up -d --remove-orphans

echo "==> Removing unused images..."
docker image prune -f
echo "==> Done."
