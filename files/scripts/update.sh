#!/bin/bash
#
# Rebuild, pull, and recreate whatever changed. Installed by run.sh into
# scripts/ under DOCKER_ROOT, which rewrites the paths below to this host's
# -- the defaults are left here so the script stays runnable as-is.
set -e
cd /srv/docker

HC=$(sed -n 's/^UPDATE_HEALTHCHECK_URL=//p' .env 2>/dev/null | head -1)
HC=${HC//[\"\']/}
hc() { [[ -z $HC ]] || curl -fsS -m 5 --retry 2 --retry-max-time 20 -o /dev/null "${HC%/}$1" || true; }
hc /start
trap 'hc /$?' EXIT

# Refuse to recreate containers onto a data disk that is meant to be there
# and is not. docker-update.service carries RequiresMountsFor for this path;
# this covers a hand-run. No fstab entry genuinely means DATA_IS_MOUNT=0.
DATA=/srv/data
NAS=/srv/nas
if grep -qs "[[:space:]]${DATA}[[:space:]]" /etc/fstab && ! mountpoint -q "$DATA"; then
  echo "ERROR: $DATA has an fstab entry but is not mounted." >&2
  echo "       Refusing to update the stack -- Immich would come up against an" >&2
  echo "       empty library. Mount the disk and re-run." >&2
  exit 1
fi

# Same refusal for the NAS. NOT mountpoint -q: $NAS is an x-systemd.automount,
# which is a mountpoint whether or not the export behind it is attached.
# Stat'ing a path inside the export triggers the mount and reports the truth
# (bounded by DefaultTimeoutStartSec when the NAS is down).
if grep -qs "[[:space:]]${NAS}[[:space:]]" /etc/fstab && [[ ! -d "$NAS/media" ]]; then
  echo "ERROR: $NAS has an fstab entry but $NAS/media is not there." >&2
  echo "       Refusing to update the stack -- the NAS-backed containers bind" >&2
  echo "       paths inside the export and would fail to start. Leaving the" >&2
  echo "       running stack alone. Mount the export and re-run." >&2
  exit 1
fi

# The slow, failure-prone steps run while the stack is still up.
rc=0
echo "==> Rebuilding locally-built images (caddy)..."
docker compose build --pull caddy || rc=$?
echo "==> Pulling latest images..."
docker compose pull --ignore-buildable || rc=$?

echo "==> Recreating changed containers..."
docker compose up -d --remove-orphans

echo "==> Removing unused images..."
docker image prune -f
echo "==> Done."
exit "$rc"
