#!/usr/bin/env bash
#
# bmo post-installation / provisioning script.
#
#   ./run.sh --minimal    packages, docker, dirs, secrets, compose
#   ./run.sh --full       the above plus NFS, systemd units, firewall, backups
#
#   -y, --yes             assume yes at every prompt (non-interactive)
#
# Every step is idempotent -- re-running is safe and is the intended
# way to apply changes.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=""
ASSUME_YES=0

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'
c_blu=$'\033[34m'; c_dim=$'\033[2m';  c_off=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "$c_blu" "$*" "$c_off"; }
ok()   { printf '  %s+%s %s\n'   "$c_grn" "$c_off" "$*"; }
skip() { printf '  %s.%s %s\n'   "$c_dim" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n'   "$c_ylw" "$c_off" "$*"; }

# DYING tells the ERR trap this exit was deliberate and already explained.
DYING=0
die()  { DYING=1; printf '\n%sERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

prompt_yn() {
  (( ASSUME_YES )) && return 0
  local reply
  read -rp "  ? $1 [y/N] " reply
  [[ ${reply,,} == y* ]]
}

usage() {
  # Bounded by the blank line ending the header, not by a line count.
  sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  exit "${1:-0}"
}

# Copied before the loop below shifts "$@" away; the logging re-exec replays
# it. Without the copy, `./run.sh --minimal` re-execs as bare `./run.sh` and
# stops to re-prompt for the profile it was already given.
ORIGINAL_ARGS=("$@")

while (( $# )); do
  case $1 in
    # Refuse rather than let the last flag win: a silent --full to --minimal
    # downgrade skips NFS, units, firewall and backups.
    --minimal|--full)
      want=${1#--}
      [[ -z $PROFILE || $PROFILE == "$want" ]] \
        || die "--minimal and --full are mutually exclusive (got both)"
      PROFILE=$want ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# Re-exec rather than `exec > >(tee ...)`, whose process substitution can
# still be flushing at exit and lose the last lines. Any failure to set this
# up falls through to running unlogged.
LOG_FILE="${BMO_LOG_FILE:-/var/log/bmo-provision.log}"
if [[ ${BMO_LOG:-0} != 1 ]]; then
  export BMO_LOG=1
  if [[ ! -e $LOG_FILE ]]; then
    log_user=${USER:-$(id -un)}
    log_group=adm; getent group adm >/dev/null 2>&1 || log_group=$(id -gn)
    sudo install -m 0640 -o "$log_user" -g "$log_group" /dev/null "$LOG_FILE" 2>/dev/null || true
  fi
  if [[ -w $LOG_FILE ]]; then
    printf '\n===== %s  %s %s =====\n' \
      "$(date -Is)" "${BASH_SOURCE[0]}" "${ORIGINAL_ARGS[*]}" >> "$LOG_FILE"
    set +e
    bash "${BASH_SOURCE[0]}" "${ORIGINAL_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  fi
fi

# -E propagates the ERR trap into functions and subshells, where most of the
# work happens; `set -e` on its own aborts in silence.
set -E

on_err() {
  local rc=$1 line=$2 cmd=$3
  (( DYING )) && return
  printf '\n%sFAILED%s at line %s (exit %s):\n    %s\n' \
    "$c_red" "$c_off" "$line" "$rc" "$cmd" >&2
  if [[ -w ${LOG_FILE:-} ]]; then
    printf '  full output of this run: %s\n' "$LOG_FILE" >&2
  fi
  # In argument position, `printf ... "$(cmd)"`, there is no parent frame at
  # all: printf succeeds, so the run would finish normally while the screen
  # said it crashed.
  (( BASH_SUBSHELL )) && exit "$rc"
  printf '  every step is idempotent -- fix the cause and re-run\n' >&2
  # Not left to set -e, so the trap owns the exit status either way.
  exit "$rc"
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Ctrl-C is the ordinary way out of the secret prompts below, and without
# this it strands 0600 secrets in /tmp and a live `mount --bind /` from
# harden_mountpoint, one per interrupted run.
CLEANUP_PATHS=()
CLEANUP_MOUNT=""

cleanup_add() { CLEANUP_PATHS+=("$1"); }

# Every command here must be incapable of failing: an ERR trap firing from
# inside the EXIT trap reports a line number and a $BASH_COMMAND that belong
# to neither.
cleanup() {
  local p
  # Before the removals, and never with rm: `rm -rf` on a bind of / would
  # walk the root filesystem.
  if [[ -n $CLEANUP_MOUNT ]]; then
    # -n so an expired sudo timestamp cannot hang the exit path on a password
    # prompt, and loud when it fails: a bind of / left mounted is not
    # something to discover later.
    if sudo -n umount "$CLEANUP_MOUNT" 2>/dev/null; then
      rmdir "$CLEANUP_MOUNT" 2>/dev/null || true
    else
      printf '\n  %s!%s a bind mount of / was left at %s -- remove it with:\n' \
        "$c_ylw" "$c_off" "$CLEANUP_MOUNT" >&2
      printf '      sudo umount %s && rmdir %s\n' "$CLEANUP_MOUNT" "$CLEANUP_MOUNT" >&2
    fi
    CLEANUP_MOUNT=""
  fi
  for p in "${CLEANUP_PATHS[@]}"; do
    [[ -n $p ]] || continue
    rm -rf "$p" 2>/dev/null || true
  done
  CLEANUP_PATHS=()
  return 0
}
trap cleanup EXIT

# Exit rather than clean up here, so cleanup runs once, from the EXIT trap,
# whatever ended the run -- and without disturbing the status on_err/die set.
trap 'exit 130' INT
trap 'exit 143' TERM

step "Preflight"

[[ $EUID -ne 0 ]] || die "run as your normal user, not root -- the script calls sudo where needed"
sudo -v || die "sudo access is required"

[[ -r /etc/os-release ]] || die "cannot read /etc/os-release -- unsupported system"
. /etc/os-release
[[ ${ID:-} == debian && -n ${VERSION_CODENAME:-} ]] \
  || die "this is ${PRETTY_NAME:-${ID:-unknown}} -- run.sh supports Debian only"
APT_DISTRO=debian
APT_CODENAME=$VERSION_CODENAME
ok "${PRETTY_NAME:-$ID} (apt suite: $APT_DISTRO $APT_CODENAME)"

# config/site.env is per-host and gitignored; a committed site.env.<hostname>
# is that host's own profile, so a reinstalled machine recovers settings that
# otherwise only existed on the disk being erased.
SITE_ENV="$REPO_DIR/config/site.env"
if [[ ! -f $SITE_ENV ]]; then
  host_profile="$REPO_DIR/config/site.env.$(hostname -s 2>/dev/null || echo _)"
  if [[ -f $host_profile ]]; then
    cp "$host_profile" "$SITE_ENV"
    ok "site.env seeded from $(basename "$host_profile") -- review it before trusting it"
  else
    cp "$REPO_DIR/config/site.env.example" "$SITE_ENV"
    die "created config/site.env from the example -- edit it, then re-run"
  fi
fi

set -a
# shellcheck source=/dev/null
. "$SITE_ENV"
set +a
for v in DOCKER_ROOT CONFIG DATA NAS PUID PGID TZ DOMAIN; do
  [[ -n ${!v:-} ]] || die "$v is unset in config/site.env"
done
ok "site.env loaded (DOCKER_ROOT=$DOCKER_ROOT, NAS=$NAS)"

if [[ -z $PROFILE ]]; then
  echo
  echo "  minimal  packages, docker, directories, secrets, compose files"
  echo "  full     the above plus NFS mount, systemd units, firewall, backups"
  echo
  read -rp "  ? profile [minimal/full]: " PROFILE
fi
[[ $PROFILE == minimal || $PROFILE == full ]] || die "profile must be 'minimal' or 'full'"
ok "profile: $PROFILE"

if [[ $PROFILE == full ]]; then
  for v in NAS_HOST NAS_EXPORT LAN_SUBNET RESTIC_REPO; do
    [[ -n ${!v:-} ]] || die "$v is unset in config/site.env (required by --full)"
  done
fi

TARGET_USER="${SUDO_USER:-$USER}"

# Escape a value for the replacement half of a sed `s|...|...|`: an
# unescaped & is not a syntax error, it silently expands to what was matched.
sed_rhs() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }

# The shipped files hardcode /srv/docker, /srv/data and /srv/nas so they stay
# directly runnable, and systemd cannot expand a variable in
# RequiresMountsFor= or ExecStart= at all. CONFIG has no rule because nothing
# under files/ refers to it -- add one rather than assuming it lives under
# DOCKER_ROOT.
install_templated() {
  local src=$1 dst=$2; shift 2
  # Registered as well as rm'd below: the sudo install can exit through the
  # ERR trap and strand the temp file.
  local tmp; tmp=$(mktemp); cleanup_add "$tmp"
  # Two passes through a \x01 marker, because sed feeds each -e's output to
  # the next: with DOCKER_ROOT=/srv/data/docker a direct substitution would
  # rewrite the /srv/data it had just written.
  sed -e 's|/srv/docker|\x01DOCKER_ROOT\x01|g' \
      -e 's|/srv/data|\x01DATA\x01|g' \
      -e 's|/srv/nas|\x01NAS\x01|g' \
      -e "s|\x01DOCKER_ROOT\x01|$(sed_rhs "$DOCKER_ROOT")|g" \
      -e "s|\x01DATA\x01|$(sed_rhs "$DATA")|g" \
      -e "s|\x01NAS\x01|$(sed_rhs "$NAS")|g" \
      "$src" > "$tmp"
  sudo install "$@" "$tmp" "$dst"
  rm -f "$tmp"
}

# Which of these package names are not installed, one per line. One
# dpkg-query for the whole list; unknown names count as not installed.
missing_pkgs() {
  local p st
  local -A installed=()
  while read -r p st; do
    [[ $st == *"ok installed"* ]] && installed[$p]=1
  done < <(dpkg-query -W -f='${Package} ${Status}\n' "$@" 2>/dev/null || true)
  for p in "$@"; do
    [[ -n ${installed[$p]:-} ]] || printf '%s\n' "$p"
  done
}

step "APT repositories"

# Both repository blocks fetch a signing key with curl, which a minimal
# Debian install lacks and packages.txt only installs in the next step.
mapfile -t boot_missing < <(missing_pkgs curl ca-certificates gnupg)
if (( ${#boot_missing[@]} )); then
  sudo apt-get update -qq
  sudo apt-get install -y "${boot_missing[@]}"
  ok "bootstrapped ${boot_missing[*]}"
else
  skip "curl, ca-certificates, gnupg present"
fi

if ! grep -rqs download.docker.com /etc/apt/sources.list.d/; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL "https://download.docker.com/linux/${APT_DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${APT_DISTRO}
Suites: ${APT_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  ok "Docker repository added ($APT_DISTRO $APT_CODENAME)"
else
  skip "Docker repository already present"
fi

if ! grep -rqsE '^[^#]*non-free([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  sudo tee /etc/apt/sources.list.d/debian-non-free.sources >/dev/null <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${APT_CODENAME} ${APT_CODENAME}-updates
Components: non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${APT_CODENAME}-security
Components: non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  ok "Debian non-free component added ($APT_CODENAME)"
else
  skip "Debian non-free component already enabled"
fi

if ! grep -rqs pkgs.tailscale.com /etc/apt/sources.list.d/; then
  curl -fsSL "https://pkgs.tailscale.com/stable/${APT_DISTRO}/${APT_CODENAME}.noarmor.gpg" \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${APT_DISTRO} ${APT_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  ok "Tailscale repository added ($APT_DISTRO $APT_CODENAME)"
else
  skip "Tailscale repository already present"
fi

if ! grep -rqs "${APT_CODENAME}-backports" /etc/apt/sources.list /etc/apt/sources.list.d/; then
  echo "deb http://deb.debian.org/debian ${APT_CODENAME}-backports main" \
    | sudo tee /etc/apt/sources.list.d/backports.list >/dev/null
  ok "Debian backports added ($APT_CODENAME-backports, for cockpit-files)"
else
  skip "Debian backports already present"
fi

step "Packages"

mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$REPO_DIR/config/packages.txt")
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# Answered from dpkg, so apt-get update runs only when something is missing.
mapfile -t missing < <(missing_pkgs "${PKGS[@]}" "${DOCKER_PKGS[@]}")

if (( ${#missing[@]} )); then
  echo "  ${#missing[@]} to install: ${missing[*]}"
  prompt_yn "proceed?" || die "aborted"
  # After the prompt but before the install, because the Docker and
  # Tailscale repositories may have been added moments ago and apt cannot
  # see their packages until it has read them.
  sudo apt-get update -qq
  sudo apt-get install -y "${missing[@]}"
  ok "${#missing[@]} packages installed"
else
  skip "all packages already installed"
fi

step "Docker post-install"

for grp in docker video render; do
  if getent group "$grp" >/dev/null && ! id -nG "$TARGET_USER" | grep -qw "$grp"; then
    sudo usermod -aG "$grp" "$TARGET_USER"
    ok "added $TARGET_USER to $grp (log out and back in to take effect)"
  else
    skip "$TARGET_USER already in $grp"
  fi
done

DAEMON_JSON='{
  "dns": ["1.1.1.1", "8.8.8.8"]
}'
if [[ $(sudo cat /etc/docker/daemon.json 2>/dev/null) != "$DAEMON_JSON" ]]; then
  sudo install -d /etc/docker
  printf '%s\n' "$DAEMON_JSON" | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
  ok "containers resolve via 1.1.1.1 / 8.8.8.8 (/etc/docker/daemon.json)"
else
  skip "/etc/docker/daemon.json already sets container DNS"
fi

sudo systemctl enable --now docker >/dev/null
ok "docker service enabled"

if ! sudo docker network inspect core >/dev/null 2>&1; then
  sudo docker network create core >/dev/null
  ok "created external network 'core'"
else
  skip "network 'core' exists"
fi

step "Directories"

# Creates the dirs.txt entries whose GROUP: prefix matches $1 ("local" for
# unprefixed lines), so nothing is created before its filesystem is mounted.
# The single quotes around ${...} below are literal match targets.
# shellcheck disable=SC2016
create_dirs() {
  local want=$1 line dir owner cur group created=0 wrong=0
  # Classified in one pass, then acted on in bulk: one sudo per action, not per
  # directory. dirs.txt lists no directory before its parent.
  local -a to_create=() check_dirs=() group_dirs=()
  local -A want_owner=() chown_of=()
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    # No dirs.txt path starts with an uppercase word and a colon (they all
    # start with '${'), so this cannot eat a real one.
    group=local
    if [[ $line =~ ^([A-Z]+):(.*)$ ]]; then
      group=${BASH_REMATCH[1],,}
      line=${BASH_REMATCH[2]}
    fi
    [[ $group == "$want" ]] || continue

    # Optional trailing owner field: "uid:gid" for images running as a fixed
    # uid of their own, "-" for directories the service chowns itself.
    owner="$PUID:$PGID"
    if [[ $line =~ ^(.*[^[:space:]])[[:space:]]+([0-9]+:[0-9]+|-)[[:space:]]*$ ]]; then
      line=${BASH_REMATCH[1]}
      owner=${BASH_REMATCH[2]}
    fi
    line=${line%"${line##*[![:space:]]}"}   # trailing whitespace -> mkdir 'foo '

    # Whitelist expansion rather than eval, so a stray dirs.txt line
    # cannot execute anything.
    dir=$line
    dir=${dir//'${DOCKER_ROOT}'/$DOCKER_ROOT}
    dir=${dir//'${CONFIG}'/$CONFIG}
    dir=${dir//'${DATA}'/$DATA}
    dir=${dir//'${NAS}'/$NAS}

    if [[ $dir == *'${'* ]]; then
      warn "unresolved variable, skipping: $dir"
      continue
    fi
    if [[ $dir != /* ]]; then
      warn "not an absolute path, skipping: $dir"
      continue
    fi

    # Ownership is set on creation only -- re-chowning every run would reset
    # live database directories to $PUID:$PGID under a running engine -- so
    # drift is reported rather than corrected.
    if [[ ! -d $dir ]]; then
      to_create+=("$dir")
      if [[ $owner != - ]]; then
        # One accumulator per distinct owner; there are two or three of
        # them across the whole file, so this is two or three chowns.
        if [[ -n ${chown_of[$owner]:-} ]]; then
          chown_of[$owner]+=$'\n'$dir
        else
          chown_of[$owner]=$dir
        fi
      fi
      (( ++created ))
    elif [[ $owner != - ]]; then
      check_dirs+=("$dir")
      want_owner[$dir]=$owner
    fi
  done < "$REPO_DIR/config/dirs.txt"

  if (( ${#to_create[@]} )); then
    sudo mkdir -p "${to_create[@]}"
    for owner in "${!chown_of[@]}"; do
      mapfile -t group_dirs <<<"${chown_of[$owner]}"
      sudo chown "$owner" "${group_dirs[@]}"
    done
  fi

  # One stat for all existing directories. Split on the LAST space: a path
  # may contain one, '%u:%g' cannot.
  if (( ${#check_dirs[@]} )); then
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      cur=${line##* }; dir=${line% *}
      owner=${want_owner[$dir]:-}
      [[ -n $owner && $cur != "$owner" ]] || continue
      warn "$dir is $cur, expected $owner -- sudo chown $owner $dir"
      (( ++wrong ))
    done < <(sudo stat -c '%n %u:%g' "${check_dirs[@]}" 2>/dev/null || true)
  fi

  ok "$created $want directories created"
  if (( wrong )); then
    warn "$wrong existing directories have unexpected ownership (left alone)"
    # Not every mismatch is a fault: a container that chowned its own
    # directory is working as it should, and the printed chown would break it.
    warn "check what each service actually wrote before acting on those:"
    warn "  find $CONFIG -maxdepth 2 -type d -printf '%U:%G  %p\\n' | sort -k2"
    warn "if a directory is root-owned because the service runs as root, mark"
    warn "its dirs.txt line '-' instead of chowning it"
  fi
}

create_dirs local

if [[ -n ${DATA_UUID:-} ]] && ! findmnt -sn -M "$DATA" >/dev/null; then
  data_fs=$(lsblk -no FSTYPE "/dev/disk/by-uuid/$DATA_UUID" 2>/dev/null || true)
  [[ -n $data_fs ]] || die "no filesystem with UUID $DATA_UUID (DATA_UUID in site.env) -- is the data disk attached?"
  sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  echo "UUID=$DATA_UUID $DATA $data_fs defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
  sudo mkdir -p "$DATA"
  sudo mount "$DATA"
  ok "$DATA added to fstab and mounted ($data_fs, UUID $DATA_UUID)"
fi

# DATA_IS_MOUNT declares whether $DATA is a separate disk, rather than being
# probed from fstab: on a freshly reinstalled host fstab has not been written
# yet, so a probe concludes "single-disk by design" and fills / with media.
if mountpoint -q "$DATA" 2>/dev/null; then
  create_dirs data
elif [[ ${DATA_IS_MOUNT:-1} == 1 ]]; then
  warn "$DATA is not mounted -- data directories not created"
  warn "mount the volume (add it to /etc/fstab) and re-run; creating them"
  warn "now would write media to the root disk, where the mount then hides it"
  warn "if $DATA really is on the root filesystem, set DATA_IS_MOUNT=0 in site.env"
else
  skip "DATA_IS_MOUNT=0 -- creating $DATA on the root filesystem"
  create_dirs data
fi

# dockerd starts every `restart: unless-stopped` container at boot whether or
# not the data disk or NAS arrived, so the immutable bit goes on the *bare*
# mountpoint underneath the mount: inert while the disk is there, EPERM on
# every write when it is not. chattr rather than chmod because Docker creates
# missing bind-mount sources as root. Deliberately not RequiresMountsFor= on
# docker.service, which would stop dockerd outright on a dead data disk.
harden_mountpoint() {
  local mnt=$1
  # Reaching the directory *under* a mount needs a non-recursive bind of /,
  # which shows the root filesystem without the mounts layered on it.
  local view="" target=$mnt
  if mountpoint -q "$mnt" 2>/dev/null; then
    view=$(mktemp -d)
    # Registered before the mount: an umount of a directory that was never
    # mounted fails harmlessly, while the reverse loses the mount.
    CLEANUP_MOUNT=$view
    sudo mount --bind / "$view"
    target="$view$mnt"
    # $mnt under some *other* mount is not visible through a bind of / at
    # all, so bail rather than mkdir an immutable directory nobody asked for.
    if ! sudo test -d "$target"; then
      sudo umount "$view"; rmdir "$view"; CLEANUP_MOUNT=""
      warn "cannot reach the bare $mnt through a bind of / -- mountpoint left unhardened"
      return 0
    fi
  fi

  if sudo lsattr -d "$target" 2>/dev/null | awk '{print $1}' | grep -q i; then
    skip "$mnt mountpoint is already immutable"
  elif [[ -n $(sudo find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    # Contents here are the failure this prevents, already happened, and
    # freezing them in place with +i would only make them harder to clear.
    warn "the bare $mnt mountpoint is not empty -- files were written while nothing was mounted there"
    if [[ -n $view ]]; then
      warn "they are hidden by the mount and consuming the root filesystem. To inspect and clear:"
      warn "  sudo mkdir -p /mnt/rootfs && sudo mount --bind / /mnt/rootfs"
      warn "  sudo du -sh /mnt/rootfs$mnt && sudo rm -rf /mnt/rootfs$mnt/*"
      warn "  sudo umount /mnt/rootfs"
    else
      warn "nothing is mounted there right now, so they are in plain sight. To inspect and clear:"
      warn "  sudo du -sh $mnt && sudo rm -rf $mnt/*"
    fi
    warn "then re-run to set the immutable bit"
  elif sudo chattr +i "$target" 2>/dev/null; then
    ok "$mnt mountpoint made immutable -- writes fail if nothing is mounted there"
  else
    warn "could not set the immutable bit on the $mnt mountpoint (filesystem may not support it)"
  fi

  if [[ -n $view ]]; then
    sudo umount "$view"
    rmdir "$view"
    CLEANUP_MOUNT=""
  fi
}

if [[ ${DATA_IS_MOUNT:-1} == 1 ]]; then
  harden_mountpoint "$DATA"
else
  skip "DATA_IS_MOUNT=0 -- $DATA is not a mountpoint, nothing to harden"
fi

step "Secrets"

if ! command -v sops >/dev/null; then
  latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/getsops/sops/releases/latest) \
    || die "could not reach GitHub to resolve the latest sops release"
  sops_ver="${latest_url##*/tag/v}"
  [[ $sops_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not parse a version from: $latest_url"
  ok "latest sops is $sops_ver"

  # The plain binary, not the .deb: sops-v<ver>.checksums.txt covers only the
  # binaries, so a .deb cannot be verified against it at all.
  arch=$(dpkg --print-architecture)
  case $arch in
    amd64|arm64) ;;
    *) warn "sops publishes linux binaries for amd64 and arm64 only; this host is $arch"
       die  "install sops by hand from https://github.com/getsops/sops/releases and re-run" ;;
  esac

  tmp=$(mktemp -d); cleanup_add "$tmp"
  asset="sops-v${sops_ver}.linux.${arch}"
  base="https://github.com/getsops/sops/releases/download/v${sops_ver}"
  curl -fsSL -o "$tmp/sops" "$base/$asset" \
    || die "download failed: $base/$asset"
  curl -fsSL -o "$tmp/checksums" "$base/sops-v${sops_ver}.checksums.txt" \
    || die "could not fetch checksums for v${sops_ver} -- refusing to install unverified"

  # Not `sha256sum -c`: the checksums file names the release asset and the
  # local file does not. awk on field 2 is exact, where a grep pattern would
  # treat the dots in the asset name as wildcards.
  want=$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/checksums")
  [[ -n $want ]] || die "no checksum published for $asset -- refusing to install"
  have=$(sha256sum "$tmp/sops" | awk '{ print $1 }')
  [[ $want == "$have" ]] \
    || die "sops checksum mismatch for $asset (want $want, got $have) -- refusing to install"
  ok "checksum verified ($asset)"

  sudo install -m 0755 -o root -g root "$tmp/sops" /usr/local/bin/sops
  rm -rf "$tmp"
  ok "sops $sops_ver installed to /usr/local/bin/sops"
else
  skip "sops present ($(sops --version 2>/dev/null | head -1))"
fi

KEY_FILE="$HOME/.config/sops/age/keys.txt"

# Declared before decryption, which names it in a die() message: assigned
# further down it hits `set -u` first.
ENV_TARGET="$DOCKER_ROOT/.env"

# Held in a temp file because piping sops into `tee "$ENV_TARGET"` truncates
# the target as the pipeline starts, so a wrong key would destroy a working
# .env.
DECRYPTED=""

if [[ -f $REPO_DIR/secrets/env.sops ]]; then
  key=$KEY_FILE
  if [[ ! -f $KEY_FILE ]]; then
    echo
    echo "  Paste your age private key -- one line, starts with AGE-SECRET-KEY-1."
    echo "  (age-keygen prints two '#' comment lines above it; skip those.)"
    echo "  Leave blank to skip decryption and write a template .env instead."
    read -rsp "  key: " pasted; echo
    if [[ -n $pasted ]]; then
      # A pasted comment line or public key would otherwise fail later as an
      # unrelated-looking decryption error.
      [[ $pasted == AGE-SECRET-KEY-1* ]] \
        || die "that does not start with AGE-SECRET-KEY-1 -- a comment line or the public key? Re-run and paste the key line"
      key=$(mktemp); chmod 600 "$key"; cleanup_add "$key"
      printf '%s\n' "$pasted" > "$key"
    fi
    unset pasted
  fi

  if [[ -f $key ]]; then
    # --input-type/--output-type are required: sops does not recognise .sops.
    out=$(mktemp); chmod 600 "$out"; cleanup_add "$out"
    SOPS_AGE_KEY_FILE=$key sops -d --input-type dotenv --output-type dotenv \
        "$REPO_DIR/secrets/env.sops" > "$out" \
      || die "could not decrypt secrets/env.sops (sops says why above); $ENV_TARGET left untouched. A wrong $KEY_FILE: move it aside and re-run"
    [[ -s $out ]] || die "sops decrypted secrets/env.sops but produced nothing -- refusing to install an empty .env"
    DECRYPTED=$out
    if [[ $key != "$KEY_FILE" ]]; then
      mkdir -p "$(dirname "$KEY_FILE")"
      install -m 600 "$key" "$KEY_FILE"
      ok "age key stored at $KEY_FILE (0600)"
    else
      skip "age key present and decrypts secrets/env.sops"
    fi
  else
    warn "no key provided -- secrets will not be decrypted"
  fi
fi

# The compose variables that come from site.env rather than sops. run.sh
# provisions with these, so compose must not read a different copy.
SITE_ENV_KEYS=(PUID PGID TZ CONFIG DATA NAS DOMAIN)

if [[ -n $DECRYPTED ]]; then
  sudo install -m 600 -o "$PUID" -g "$PGID" "$DECRYPTED" "$ENV_TARGET"
  rm -f "$DECRYPTED"
  ok "decrypted .env -> $ENV_TARGET"

elif [[ ! -f $ENV_TARGET ]]; then
  # Built from SITE_ENV_KEYS so the two cannot drift: a key seeded with a
  # real value must not also appear among the blanks, where the empty one
  # would win.
  site_keys_re=$(IFS='|'; printf '^(%s)$' "${SITE_ENV_KEYS[*]}")

  # tr strips the literal characters '$' and '{'.
  # shellcheck disable=SC2016
  {
    echo "# TEMPLATE -- fill these in. Nothing will start until you do."
    for v in "${SITE_ENV_KEYS[@]}"; do echo "$v=${!v}"; done
    grep -hoE '\$\{[A-Z_][A-Z0-9_]*' "$REPO_DIR"/compose/stacks/*.yml \
      | tr -d '${' | sort -u \
      | grep -vE "$site_keys_re" \
      | sed 's/$/=/'
  } | sudo tee "$ENV_TARGET" >/dev/null
  sudo chmod 600 "$ENV_TARGET"
  sudo chown "$PUID:$PGID" "$ENV_TARGET"
  warn "wrote a TEMPLATE .env -- fill it in before starting containers"
fi

# site.env wins, applied after both branches: the sops branch rewrites
# $ENV_TARGET on every run, and secrets/env.sops still carries old copies.
env_set() {
  local key=$1 val=$2
  # sed_rhs: an unescaped & in $val would expand to the whole match.
  if sudo grep -qs "^${key}=" "$ENV_TARGET"; then
    sudo sed -i "s|^${key}=.*|${key}=$(sed_rhs "$val")|" "$ENV_TARGET"
  else
    printf '%s=%s\n' "$key" "$val" | sudo tee -a "$ENV_TARGET" >/dev/null
  fi
}

if sudo test -f "$ENV_TARGET"; then
  for v in "${SITE_ENV_KEYS[@]}"; do
    env_set "$v" "${!v}"
  done
  ok "site.env values forced into $ENV_TARGET (${SITE_ENV_KEYS[*]})"
fi

dotenv_get() {
  local v
  v=$(sudo sed -n "s/^$1=//p" "$ENV_TARGET" 2>/dev/null | head -1 || true)
  # Strip one layer of matched quotes, as compose does: KEY="" is empty.
  if (( ${#v} >= 2 )) && [[ $v == \"*\" || $v == \'*\' ]]; then
    v=${v:1:${#v}-2}
  fi
  printf '%s' "$v"
}

# HEALTHCHECK_URL is a capability, so it lives in sops, not in the committed
# site.env.<host>. site.env still wins if set.
if [[ -z ${HEALTHCHECK_URL:-} ]] && sudo test -f "$ENV_TARGET"; then
  HEALTHCHECK_URL=$(dotenv_get HEALTHCHECK_URL)
  [[ -n $HEALTHCHECK_URL ]] && ok "HEALTHCHECK_URL recovered from sops"
fi
export HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

step "Compose files"

sudo rsync -a --chown="$PUID:$PGID" \
  --exclude '.env' \
  "$REPO_DIR/compose/" "$DOCKER_ROOT/"

# --delete over stacks/ only, so a stack removed from the repo stops being
# deployed; $DOCKER_ROOT also holds scripts/.
sudo rsync -a --delete --chown="$PUID:$PGID" \
  --exclude '.env' \
  "$REPO_DIR/compose/stacks/" "$DOCKER_ROOT/stacks/"
ok "compose files synced to $DOCKER_ROOT (stacks/ pruned of removals)"

CADDYFILE="$CONFIG/caddy/Caddyfile"

if [[ -f $CADDYFILE ]]; then
  # Left alone: live, hand-edited configuration.
  skip "Caddyfile exists -- leaving it alone"
else
  # sed_rhs for the same reason env_set uses it: an unescaped & in the
  # replacement expands to the whole match.
  sed "s|{{DOMAIN}}|$(sed_rhs "$DOMAIN")|g" "$REPO_DIR/templates/Caddyfile.tmpl" \
    | sudo tee "$CADDYFILE" >/dev/null
  sudo chown "$PUID:$PGID" "$CADDYFILE"
  ok "rendered Caddyfile for $DOMAIN"
fi

# compose turns an unset variable into an empty string and carries on. Only
# included stacks, and only a bare `${VAR}`: `${VAR:-default}` supplies its
# own value.
if sudo test -f "$ENV_TARGET"; then
  mapfile -t included < <(
    sed -n '/^include:/,/^[^[:space:]#-]/p' "$REPO_DIR/compose/compose.yml" \
      | sed -n 's|^[[:space:]]*-[[:space:]]*stacks/\([A-Za-z0-9._-]*\.yml\).*|\1|p'
  )

  env_required=()
  for f in "${included[@]}"; do
    src="$REPO_DIR/compose/stacks/$f"
    if [[ ! -f $src ]]; then
      warn "compose.yml includes stacks/$f, which does not exist"
      continue
    fi
    # Commented-out YAML is skipped first.
    # tr strips the literal characters '$', '{' and '}'.
    # shellcheck disable=SC2016
    mapfile -t -O "${#env_required[@]}" env_required < <(
      grep -vE '^[[:space:]]*#' "$src" \
        | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | tr -d '${}')
  done

  # `=.+` so a key present but blank counts as missing, which is exactly
  # what the TEMPLATE .env is full of.
  declare -A env_present=()
  while IFS= read -r v; do
    [[ -n $v ]] && env_present[$v]=1
  done < <(sudo grep -oE '^[A-Z_][A-Z0-9_]*=.+' "$ENV_TARGET" | cut -d= -f1)

  env_missing=(); env_checked=0
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    (( ++env_checked ))
    [[ -n ${env_present[$v]:-} ]] || env_missing+=("$v")
  done < <(printf '%s\n' "${env_required[@]}" | sort -u)

  if (( ${#env_missing[@]} )); then
    warn "${#env_missing[@]} variable(s) the enabled stacks reference are empty or absent in $ENV_TARGET:"
    printf '    %s\n' "${env_missing[@]}"
    warn "containers using them will start misconfigured -- fill them in before 'docker compose up -d'"
  else
    # $env_checked, not ${#env_present[@]}: what the stacks actually need
    # and got, not how many keys happen to be sitting in the file.
    ok ".env covers all $env_checked variables the enabled stacks reference"
  fi
fi

# Group membership is fixed at login: this shell may predate the docker
# group added above. `id -nG` with no argument reports this process.
if id -nG 2>/dev/null | grep -qw docker; then
  START_HINT="cd $DOCKER_ROOT && docker compose up -d"
else
  START_HINT="newgrp docker      # this shell predates the group change made above
     cd $DOCKER_ROOT && docker compose up -d"
fi

if [[ $PROFILE == minimal ]]; then
  cat <<EOF

${c_grn}Minimal provisioning complete.${c_off}

Next:
  1. Fill in $ENV_TARGET
  2. Review $DOCKER_ROOT/compose.yml and comment out stacks you don't want
  3. $START_HINT

Skipped (host-specific): NFS mount, systemd units, firewall rules, backups.
EOF
  exit 0
fi

step "NFS mount"

# interface name can change across reinstalls, so discover it
LAN_IF=$(ip -o -4 route show default | awk '{print $5}' | head -1)
LAN_GW=$(ip -o -4 route show default | awk '{print $3}' | head -1)

if [[ $LAN_GW =~ ^[0-9.]+$ ]] && systemctl cat ifupdown-wait-online.service >/dev/null 2>&1; then
  if ! grep -qsxF "WAIT_ONLINE_ADDRESS=$LAN_GW" /etc/default/networking; then
    printf 'WAIT_ONLINE_METHOD=ping\nWAIT_ONLINE_ADDRESS=%s\n' "$LAN_GW" \
      | sudo tee -a /etc/default/networking >/dev/null
  fi
  sudo systemctl enable ifupdown-wait-online.service >/dev/null 2>&1
  ok "network-online.target waits until the gateway $LAN_GW answers (the NAS mount needs IPv4)"
fi

FSTAB_LINE="${NAS_HOST}:${NAS_EXPORT}  ${NAS}  nfs  rw,_netdev,x-systemd.automount,x-systemd.requires=network-online.target,noatime,nofail  0  0"

if ! grep -qs "^${NAS_HOST}:${NAS_EXPORT}[[:space:]]" /etc/fstab; then
  sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  ok "fstab entry added (backup saved)"
else
  skip "fstab entry present"

  # An existing entry is never rewritten, so check it has x-systemd.automount:
  # without it a slow NAS at boot leaves $NAS empty for the whole uptime.
  if ! grep -qs "^${NAS_HOST}:${NAS_EXPORT}[[:space:]].*x-systemd\.automount" /etc/fstab; then
    warn "the fstab entry for $NAS has no x-systemd.automount"
    warn "it will be mounted once at boot and never retried. Replace the line with:"
    warn "  $FSTAB_LINE"
  fi
fi

# The automount unit retries indefinitely if the NAS is slow to boot.
unit_name=$(systemd-escape -p --suffix=mount "$NAS")
for d in "${unit_name%.mount}.mount" "${unit_name%.mount}.automount"; do
  sudo mkdir -p "/etc/systemd/system/${d}.d"
  sudo cp "$REPO_DIR/files/systemd/srv-nas-override.conf" \
    "/etc/systemd/system/${d}.d/override.conf"
done
ok "installed mount retry drop-ins"

sudo systemctl daemon-reload

# Not restarted when it is already active: that pulls the autofs
# mountpoint out from under every container bind-mounting $NAS, to apply a
# setting that only governs restart-rate limiting at the next boot.
automount_unit="${unit_name%.mount}.automount"
if systemctl is-active --quiet "$automount_unit"; then
  skip "$automount_unit already running -- not restarting it under live containers"
else
  sudo systemctl restart "$automount_unit" 2>/dev/null || true
  ok "started $automount_unit"
fi

if timeout 30 ls "$NAS" >/dev/null 2>&1; then
  ok "$NAS responds"
else
  warn "$NAS did not respond within 30s -- check the NAS is up"
fi

harden_mountpoint "$NAS"

# Only safe now the export is mounted: created earlier they land on the
# root filesystem, and the mount then hides them.
if findmnt -rn -t nfs,nfs4 -M "$NAS" >/dev/null 2>&1; then
  create_dirs nas
else
  warn "the NAS export is not mounted at $NAS -- NAS directories not created"
  warn "mount the export and re-run; creating them now would fill the root disk"
fi

step "systemd units"

# Rendered here, not through install_templated: it takes an escaped unit
# name. The .automount unit, not .mount: Wants= on the .mount would force
# the NFS mount at boot and wait out its timeout with the NAS down.
nas_mount_unit=$(systemd-escape -p --suffix=automount "$NAS")
sudo mkdir -p /etc/systemd/system/docker.service.d
sed "s|{{NAS_MOUNT_UNIT}}|$(sed_rhs "$nas_mount_unit")|g" \
  "$REPO_DIR/files/systemd/docker.service.d-override.conf" \
  | sudo tee /etc/systemd/system/docker.service.d/override.conf >/dev/null
sudo chmod 0644 /etc/systemd/system/docker.service.d/override.conf
ok "docker.service Wants/After $nas_mount_unit (ordered, not required)"

install_templated "$REPO_DIR/files/scripts/update.sh" \
  "$DOCKER_ROOT/scripts/update.sh" -m 0755 -o "$PUID" -g "$PGID"
install_templated "$REPO_DIR/files/systemd/docker-update.service" \
  /etc/systemd/system/docker-update.service -m 0644
sudo install -m 0644 "$REPO_DIR/files/systemd/docker-update.timer" \
  /etc/systemd/system/docker-update.timer
sudo systemctl daemon-reload

# Is this host empty enough that a restore is what it wants? Not 'the
# repository has snapshots' (true on every healthy host), but 'no regular
# file under $CONFIG besides the Caddyfile this run renders'.
config_state=""
if sudo test -d "$CONFIG"; then
  config_state=$(sudo find "$CONFIG" -type f ! -path "$CADDYFILE" -print -quit 2>/dev/null || true)
fi

if [[ -z $config_state ]]; then
  skip "docker-update.timer not enabled -- $CONFIG holds no service state, and its boot run would start the stack before a restore"
  skip "re-run run.sh --full once the stack has state to enable it"
elif prompt_yn "enable docker-update.timer (pulls latest images after boot and every Sunday)?"; then
  sudo systemctl enable --now docker-update.timer >/dev/null
  ok "docker-update.timer enabled"
else
  skip "docker-update.timer installed but not enabled"
fi

step "Firewall"

# ufw filters the host's INPUT chain: SSH, cockpit and every network_mode:
# host container, technitium's DNS on 53 above all. Docker's IPv4 published
# ports bypass it; IPv6 ones reach containers through docker-proxy on the
# host (core has no IPv6), so ufw does filter those.

sudo ufw --force default deny incoming >/dev/null
sudo ufw --force default allow outgoing >/dev/null

sudo ufw allow in on tailscale0 >/dev/null
sudo ufw allow from "$LAN_SUBNET" >/dev/null
sudo ufw allow 41641/udp >/dev/null           # tailscale direct
sudo ufw allow 25565/tcp >/dev/null           # minecraft

if cf_v6=$(curl -fsS -m 10 https://www.cloudflare.com/ips-v6); then
  for net in $cf_v6; do
    [[ $net =~ ^[0-9a-f:]+/[0-9]+$ ]] || { warn "skipping odd Cloudflare range: $net"; continue; }
    sudo ufw allow proto tcp from "$net" to any port 443 >/dev/null
  done
  ok "443 open to Cloudflare's IPv6 ranges"
else
  warn "could not fetch Cloudflare's IPv6 ranges -- 443 rules not written, and the"
  warn "public sites need them. Re-run, or see https://www.cloudflare.com/ips-v6"
fi

# syncthing (network_mode: host) serves its GUI on the host. Only caddy
# needs it, from core's subnet rather than Docker's whole 172.16.0.0/12.
# Asked of docker because core pins no --subnet; take the first IPv4 entry.
core_subnet=$(sudo docker network inspect -f \
  '{{range .IPAM.Config}}{{.Subnet}} {{end}}' core 2>/dev/null \
  | tr ' ' '\n' | grep -m1 -E '^[0-9.]+/[0-9]+$' || true)

if [[ $core_subnet =~ ^[0-9.]+/[0-9]+$ ]]; then
  # Sweep 8384 and 53 rules from Docker ranges other than core's current
  # subnet. `show added`, not `status`: an inactive firewall lists no rules
  # in `status`.
  while read -r stale port proto; do
    [[ $stale == "$core_subnet" ]] && continue
    sudo ufw delete allow from "$stale" to any port "$port" ${proto:+proto "$proto"} >/dev/null 2>&1 || true
  done < <(sudo ufw show added 2>/dev/null \
             | awk '$3 == "from" && $4 ~ /^172\./ && $7 == "port" && ($8 == 8384 || $8 == 53) { print $4, $8, $10 }' || true)

  sudo ufw allow from "$core_subnet" to any port 8384 proto tcp >/dev/null
  ok "syncthing GUI restricted to the core network ($core_subnet)"
  sudo ufw allow from "$core_subnet" to any port 53 >/dev/null
  ok "technitium DNS reachable from the core network (uptime-kuma)"
else
  # Fails closed: silently falling back to the /12 because one docker
  # command did not answer is the wrong trade for an admin interface.
  warn "could not read the core network's subnet -- syncthing's GUI rule NOT written"
  warn "sync.$DOMAIN will fail to proxy until it is. Re-run once docker is up, or:"
  warn "  sudo ufw allow from \$(sudo docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' core | tr ' ' '\\n' | grep -m1 -E '^[0-9.]+/[0-9]+$') to any port 8384 proto tcp"
fi

if [[ -n $LAN_IF ]]; then
  sudo ufw allow in on "$LAN_IF" to any port 21027 proto udp >/dev/null  # syncthing discovery
  ok "base rules applied (LAN interface: $LAN_IF)"
else
  warn "could not determine LAN interface -- syncthing discovery rule skipped"
fi

sudo ufw --force enable >/dev/null
ok "ufw enabled"

TS_SYSCTL='net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1'
if [[ $(cat /etc/sysctl.d/99-tailscale.conf 2>/dev/null) != "$TS_SYSCTL" ]]; then
  printf '%s\n' "$TS_SYSCTL" | sudo tee /etc/sysctl.d/99-tailscale.conf >/dev/null
  sudo sysctl -q -p /etc/sysctl.d/99-tailscale.conf
  ok "IP forwarding on for the tailscale exit node and LAN route"
else
  skip "IP forwarding already on (/etc/sysctl.d/99-tailscale.conf)"
fi

# The restic repository lives on the NAS and survives a reformat of this
# host. This step reconnects to it -- it never runs `restic init`, which
# would orphan every existing snapshot.

step "Backups"

RESTIC_PASS_FILE=/root/.restic-pass
NAS_SSH_USER="${NAS_SSH_USER:-root}"

# root's SSH access to the NAS -- restic runs as root.
sudo install -d -m 0700 /root/.ssh

if ! sudo grep -qs '^Host nas$' /root/.ssh/config; then
  sudo tee -a /root/.ssh/config >/dev/null <<EOF
Host nas
    HostName ${NAS_HOST}
    User ${NAS_SSH_USER}
    IdentityFile /root/.ssh/id_nas
EOF
  sudo chmod 600 /root/.ssh/config
  ok "added 'nas' host alias for root"
else
  skip "root ssh config has 'nas'"
fi

# A rebuilt host generates a fresh key; the old one lingers in the NAS's
# authorized_keys as dead weight.
if ! sudo test -f /root/.ssh/id_nas; then
  sudo ssh-keygen -t ed25519 -f /root/.ssh/id_nas -N "" -q
  ok "generated /root/.ssh/id_nas"
else
  skip "root NAS key present"
fi

if sudo ssh -o BatchMode=yes -o ConnectTimeout=5 nas true 2>/dev/null; then
  ok "root can reach the NAS without a password"
else
  warn "root cannot log into the NAS yet"
  if prompt_yn "copy the key over now (asks for the NAS password)?"; then
    sudo ssh-copy-id -i /root/.ssh/id_nas.pub "${NAS_SSH_USER}@${NAS_HOST}" \
      || warn "ssh-copy-id failed -- add /root/.ssh/id_nas.pub to the NAS by hand"
  else
    warn "run later: sudo ssh-copy-id -i /root/.ssh/id_nas.pub ${NAS_SSH_USER}@${NAS_HOST}"
  fi
fi

repo_ok=0

if ! sudo test -f "$RESTIC_PASS_FILE"; then
  echo
  echo "  No restic passphrase for $RESTIC_REPO"
  echo "  Paste it from your paper / password-manager copy."
  echo "  WITHOUT IT THE EXISTING BACKUPS CANNOT BE READ."
  read -rsp "  passphrase (blank to skip backups): " restic_pass; echo
  if [[ -n $restic_pass ]]; then
    # 0600 before the secret is written, not after: /root/.restic-pass is
    # all that stands between a stolen repository and every file here.
    pass_tmp=$(mktemp); chmod 600 "$pass_tmp"; cleanup_add "$pass_tmp"
    printf '%s\n' "$restic_pass" > "$pass_tmp"
    sudo install -m 600 -o root -g root "$pass_tmp" "$RESTIC_PASS_FILE"
    rm -f "$pass_tmp"
    ok "passphrase stored at $RESTIC_PASS_FILE (0600)"
  else
    warn "no passphrase given -- backups not configured"
  fi
  unset restic_pass
fi

if sudo test -f "$RESTIC_PASS_FILE"; then
  if snaps_json=$(sudo restic -r "$RESTIC_REPO" --password-file "$RESTIC_PASS_FILE" snapshots --json 2>/dev/null); then
    # One "short_id" per snapshot; "time" would also match fields restic
    # may add later.
    snap_count=$(grep -o '"short_id"' <<<"$snaps_json" | wc -l || true)
    ok "connected to $RESTIC_REPO ($snap_count snapshots)"
    repo_ok=1
  else
    warn "could not read $RESTIC_REPO with $RESTIC_PASS_FILE:"
    warn "wrong passphrase (sudo rm $RESTIC_PASS_FILE and re-run), no SSH access as root,"
    warn "or the repo does not exist yet. A NEW repo is initialised by hand -- deliberately"
    warn "not automated, because init on a live repo orphans every snapshot:"
    warn "  sudo restic -r $RESTIC_REPO --password-file $RESTIC_PASS_FILE init"
  fi
fi

if sudo test -f "$RESTIC_PASS_FILE"; then

  # Config for the systemd job, independent of this checkout. BACKUP_HOST is
  # pinned so a rename cannot fork the snapshot history; DOCKER_ROOT is stated
  # because CONFIG need not be its child.
  backup_host="${BACKUP_HOST:-$(hostname -s 2>/dev/null || true)}"
  [[ -n $backup_host ]] || die "cannot determine a backup host name -- set BACKUP_HOST in config/site.env"

  # %q because backup.sh and restore.sh source this file (both bash): an
  # unquoted & in HEALTHCHECK_URL would break the assignment.
  env_line() { printf '%s=%q\n' "$1" "$2"; }

  {
    env_line RESTIC_REPOSITORY    "$RESTIC_REPO"
    env_line RESTIC_PASSWORD_FILE "$RESTIC_PASS_FILE"
    env_line DOCKER_ROOT          "$DOCKER_ROOT"
    env_line CONFIG               "$CONFIG"
    env_line DATA                 "$DATA"
    env_line DATA_IS_MOUNT        "${DATA_IS_MOUNT:-1}"
    env_line BACKUP_HOST          "$backup_host"
    env_line HEALTHCHECK_URL      "${HEALTHCHECK_URL:-}"
    env_line OFFSITE_REPOSITORY   "${OFFSITE_REPO:-}"
    env_line AWS_ACCESS_KEY_ID     "$(dotenv_get B2_KEY_ID)"
    env_line AWS_SECRET_ACCESS_KEY "$(dotenv_get B2_APP_KEY)"
  } | sudo tee /etc/bmo-backup.env >/dev/null
  sudo chmod 600 /etc/bmo-backup.env
  ok "wrote /etc/bmo-backup.env (snapshots recorded as host '$backup_host')"
  if [[ -n ${HEALTHCHECK_URL:-} ]]; then
    ok "backup monitoring enabled (pings ${HEALTHCHECK_URL%/*}/...)"
  else
    warn "HEALTHCHECK_URL is set neither in secrets/env.sops nor config/site.env --"
    warn "a backup that fails, or that stops running at all, will do so silently."
    warn "Nothing on this host can report that this host is down; that needs an"
    warn "off-box check. To add one:"
    warn "  sops edit --input-type dotenv --output-type dotenv secrets/env.sops"
  fi

  # --- backup job + timer ---
  sudo install -m 0700 -o root -g root \
    "$REPO_DIR/files/scripts/backup.sh" /usr/local/sbin/bmo-backup

  # Installed for the same reason: a restore is wanted on a host that has
  # just been rebuilt, where the git checkout may not be there. Both read
  # /etc/bmo-backup.env and need nothing else.
  sudo install -m 0700 -o root -g root \
    "$REPO_DIR/files/scripts/restore.sh" /usr/local/sbin/bmo-restore
  ok "installed bmo-backup and bmo-restore in /usr/local/sbin"
  # RequiresMountsFor= in the service has to name $DATA literally --
  # systemd does not expand variables there.
  install_templated "$REPO_DIR/files/systemd/bmo-backup.service" \
    /etc/systemd/system/bmo-backup.service -m 0644
  install_templated "$REPO_DIR/files/systemd/bmo-backup.timer" \
    /etc/systemd/system/bmo-backup.timer -m 0644
  sudo systemctl daemon-reload
  sudo systemctl enable --now bmo-backup.timer >/dev/null
  ok "bmo-backup.timer enabled ($(systemctl show -p TimersCalendar --value bmo-backup.timer 2>/dev/null | head -1))"

  # Installing the backup does not take one. Not offered under --yes, nor on
  # an empty host, which bmo-backup refuses to record.
  if (( repo_ok )) && [[ -n $config_state ]]; then
    if (( ASSUME_YES )); then
      warn "no backup has been taken yet -- run: sudo /usr/local/sbin/bmo-backup"
    elif prompt_yn "run a backup now (can take a long time on the first run)?"; then
      sudo /usr/local/sbin/bmo-backup || warn "backup finished with problems -- see above"
    else
      skip "no backup taken -- run: sudo /usr/local/sbin/bmo-backup"
    fi
  elif (( repo_ok )); then
    skip "not offering a backup yet -- $CONFIG holds no service state"
  fi
fi

step "Verification"

printf '  %-22s %s\n' "NAS mounted:"   "$(findmnt -rn -t nfs,nfs4 -M "$NAS" >/dev/null 2>&1 && echo yes || echo NO)"
printf '  %-22s %s\n' "data disk:"     "$(mountpoint -q "$DATA" && echo yes || echo 'NO (check UUID in fstab)')"
# `|| true`: systemctl is-active exits 3 for inactive, after printing it.
printf '  %-22s %s\n' "docker:"        "$(systemctl is-active docker || true)"
printf '  %-22s %s\n' "core network:"  "$(sudo docker network inspect core >/dev/null 2>&1 && echo yes || echo NO)"
printf '  %-22s %s\n' ".env:"          "$([[ -s $ENV_TARGET ]] && echo present || echo MISSING)"
printf '  %-22s %s\n' "ufw:"           "$(sudo ufw status | head -1 | awk '{print $2}')"
printf '  %-22s %s\n' "backup timer:"  "$(systemctl is-enabled bmo-backup.timer 2>/dev/null || echo 'not installed')"
# The timer being enabled says nothing about whether it can reach the
# repository: under --yes a wrong passphrase only warns and the run
# carries on.
printf '  %-22s %s\n' "restic repo:"   "$( (( repo_ok )) && echo "readable" || echo 'NOT READABLE -- backups will fail')"

cat <<EOF

${c_grn}Provisioning complete.${c_off}

Not done by this script, on purpose:
  - restic init  (a new repo must be created by hand -- see above)
  - sudo tailscale up --advertise-exit-node --advertise-routes=$LAN_SUBNET  (interactive auth;
    on a rebuild, delete the old node in the Tailscale admin console first)
EOF

if [[ -z $config_state ]] && (( ${snap_count:-0} > 0 )); then
  cat <<'HINT'

This host has no service state and the repository has snapshots. If this
is a rebuild, restore BEFORE starting the stack -- once a service starts
on an empty directory it writes a fresh database there, and the next
nightly backup snapshots that over the top:

     sudo /usr/local/sbin/bmo-restore --list
     sudo /usr/local/sbin/bmo-restore --all

Then start the stack and re-run ./run.sh --full, which enables
docker-update.timer now that there is state to protect.
HINT
fi

cat <<EOF

Then:
     $START_HINT
EOF
