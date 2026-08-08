#!/usr/bin/env bash
#
# bmo post-installation / provisioning script.
#
#   ./run.sh --minimal    packages, docker, dirs, secrets, compose
#   ./run.sh --full       the above plus NFS, systemd units, firewall, backups
#   ./run.sh --full --restore
#                         the above, then restore every service's state
#                         from the newest snapshot (bare-metal rebuild)
#
# Every step is idempotent -- re-running is safe and is the intended
# way to apply changes.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE=""
ASSUME_YES=0
RESTORE_REQUESTED=0

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
  sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
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
    --restore) RESTORE_REQUESTED=1 ;;
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
      "$(date -Is)" "${BASH_SOURCE[0]}" "${ORIGINAL_ARGS[*]-}" >> "$LOG_FILE"
    set +e
    bash "${BASH_SOURCE[0]}" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"} 2>&1 | tee -a "$LOG_FILE"
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
# harden_data_mountpoint, one per interrupted run.
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
  for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
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

# The Docker and Tailscale apt repositories publish for debian, ubuntu and
# raspbian only, so derive the archive from $ID (or a derivative's $ID_LIKE)
# and fail here rather than inside `apt-get update`.
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release -- unsupported system"
. /etc/os-release

APT_DISTRO=""
for cand in "${ID:-}" ${ID_LIKE:-}; do
  case $cand in
    debian|ubuntu|raspbian) APT_DISTRO=$cand; break ;;
  esac
done
[[ -n $APT_DISTRO ]] \
  || die "this is ${ID:-unknown}, which is neither Debian, Ubuntu nor Raspbian (nor derived from one) -- the Docker and Tailscale repositories below have nothing to offer it"

# UBUNTU_CODENAME first: a derivative's own VERSION_CODENAME is its own
# invention (Mint ships "wilma") and names no suite either archive publishes.
APT_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n $APT_CODENAME ]] \
  || die "no VERSION_CODENAME in /etc/os-release -- cannot name an apt suite for this release"

if [[ ${ID:-} == "$APT_DISTRO" ]]; then
  ok "${PRETTY_NAME:-$ID} (apt suite: $APT_DISTRO $APT_CODENAME)"
else
  warn "${PRETTY_NAME:-${ID:-unknown}} is not directly packaged for; using its base, $APT_DISTRO $APT_CODENAME"
fi

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

# Checked here rather than at the restore step, which --minimal exits long
# before reaching: --restore would otherwise be silently ignored.
if (( RESTORE_REQUESTED )) && [[ $PROFILE == minimal ]]; then
  die "--restore needs --full (the restic repository is reconnected in the --full-only backup step)"
fi

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

step "APT repositories"

# Both repository blocks fetch a signing key with curl, which a minimal
# Debian install lacks and packages.txt only installs in the next step.
boot_missing=()
for p in curl ca-certificates gnupg; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || boot_missing+=("$p")
done
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

if ! grep -rqs pkgs.tailscale.com /etc/apt/sources.list.d/; then
  curl -fsSL "https://pkgs.tailscale.com/stable/${APT_DISTRO}/${APT_CODENAME}.noarmor.gpg" \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${APT_DISTRO} ${APT_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  ok "Tailscale repository added ($APT_DISTRO $APT_CODENAME)"
else
  skip "Tailscale repository already present"
fi

step "Packages"

mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$REPO_DIR/config/packages.txt")
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

sudo apt-get update -qq
missing=()
for p in "${PKGS[@]}" "${DOCKER_PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
done

if (( ${#missing[@]} )); then
  echo "  ${#missing[@]} to install: ${missing[*]}"
  prompt_yn "proceed?" || die "aborted"
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
# unprefixed lines). The groups exist because a directory created under a
# filesystem that is not mounted yet lands on the root disk, where the
# eventual mount hides it.
#
# The single quotes around ${...} below are literal match targets.
# shellcheck disable=SC2016
create_dirs() {
  local want=$1 line dir owner cur group created=0 wrong=0
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
      sudo mkdir -p "$dir"
      [[ $owner == - ]] || sudo chown "$owner" "$dir"
      (( ++created ))
    elif [[ $owner != - ]]; then
      cur=$(sudo stat -c '%u:%g' "$dir" 2>/dev/null) || cur=""
      if [[ -n $cur && $cur != "$owner" ]]; then
        warn "$dir is $cur, expected $owner -- sudo chown $owner $dir"
        (( ++wrong ))
      fi
    fi
  done < "$REPO_DIR/config/dirs.txt"
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
# not the data disk arrived, so the immutable bit goes on the *bare*
# mountpoint underneath the mount: inert while the disk is there, EPERM on
# every write when it is not. chattr rather than chmod because Docker creates
# missing bind-mount sources as root. Deliberately not RequiresMountsFor= on
# docker.service, which would stop dockerd outright on a dead data disk.
harden_data_mountpoint() {
  if [[ ${DATA_IS_MOUNT:-1} != 1 ]]; then
    skip "DATA_IS_MOUNT=0 -- $DATA is not a mountpoint, nothing to harden"
    return 0
  fi

  # Reaching the directory *under* a mount needs a non-recursive bind of /,
  # which shows the root filesystem without the mounts layered on it.
  local view="" target=$DATA
  if mountpoint -q "$DATA" 2>/dev/null; then
    view=$(mktemp -d)
    # Registered before the mount: an umount of a directory that was never
    # mounted fails harmlessly, while the reverse loses the mount.
    CLEANUP_MOUNT=$view
    sudo mount --bind / "$view"
    target="$view$DATA"
    # $DATA under some *other* mount is not visible through a bind of / at
    # all, so bail rather than mkdir an immutable directory nobody asked for.
    if ! sudo test -d "$target"; then
      sudo umount "$view"; rmdir "$view"; CLEANUP_MOUNT=""
      warn "cannot reach the bare $DATA through a bind of / -- mountpoint left unhardened"
      return 0
    fi
  fi

  if sudo lsattr -d "$target" 2>/dev/null | awk '{print $1}' | grep -q i; then
    skip "$DATA mountpoint is already immutable"
  elif [[ -n $(sudo find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    # Contents here are the failure this prevents, already happened, and
    # freezing them in place with +i would only make them harder to clear.
    warn "the bare $DATA mountpoint is not empty -- files were written while the disk was unmounted"
    if [[ -n $view ]]; then
      warn "they are hidden by the mount and consuming the root filesystem. To inspect and clear:"
      warn "  sudo mkdir -p /mnt/rootfs && sudo mount --bind / /mnt/rootfs"
      warn "  sudo du -sh /mnt/rootfs$DATA && sudo rm -rf /mnt/rootfs$DATA/*"
      warn "  sudo umount /mnt/rootfs"
    else
      warn "the disk is not mounted right now, so they are in plain sight. To inspect and clear:"
      warn "  sudo du -sh $DATA && sudo rm -rf $DATA/*"
    fi
    warn "then re-run to set the immutable bit"
  elif sudo chattr +i "$target" 2>/dev/null; then
    ok "$DATA mountpoint made immutable -- writes fail if the disk is missing"
  else
    warn "could not set the immutable bit on the $DATA mountpoint (filesystem may not support it)"
  fi

  if [[ -n $view ]]; then
    sudo umount "$view"
    rmdir "$view"
    CLEANUP_MOUNT=""
  fi
}

harden_data_mountpoint

step "Secrets"

if ! command -v age >/dev/null; then
  sudo apt-get install -y age
  ok "age installed"
else
  skip "age present"
fi

if ! command -v sops >/dev/null; then
  if [[ -n ${SOPS_VERSION:-} ]]; then
    sops_ver="$SOPS_VERSION"
    ok "using pinned sops $sops_ver"
  else
    latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/getsops/sops/releases/latest) \
      || die "could not reach GitHub to resolve the latest sops release"
    sops_ver="${latest_url##*/tag/v}"
    [[ $sops_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "could not parse a version from: $latest_url"
    ok "latest sops is $sops_ver"
  fi

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

# Declared before the decryption loop, which names it in a die() message:
# assigned further down it hits `set -u` first, and the run reports an
# unbound variable instead of what actually went wrong.
ENV_TARGET="$DOCKER_ROOT/.env"

# Both secret prompts -- this and the restic passphrase below -- verify
# rather than gate on the file existing, so one wrong entry is not permanent
# and a candidate that does not work never overwrites one that might.

# The format check catches a paste of all three lines age-keygen prints:
# `read` takes only the first, a comment, and sops then fails much later
# with an unrelated-looking decryption error.
read_age_key() {
  local dst=$1 key
  echo
  echo "  Paste your age private key -- one line, starts with AGE-SECRET-KEY-1."
  echo "  (age-keygen prints two '#' comment lines above it; skip those.)"
  echo "  Leave blank to skip decryption and write a template .env instead."
  read -rsp "  key: " key; echo
  [[ -n $key ]] || return 1
  if [[ $key != AGE-SECRET-KEY-1* ]]; then
    warn "that does not start with AGE-SECRET-KEY-1 -- looks like a comment line or a public key"
    return 2
  fi
  printf '%s\n' "$key" > "$dst"
  unset key
}

# Held in a temp file because piping sops into `tee "$ENV_TARGET"` truncates
# the target as the pipeline starts, so a wrong key would destroy a working
# .env.
DECRYPTED=""

if [[ -f $REPO_DIR/secrets/env.sops ]]; then
  key_candidate=""; promote=0; attempt=0
  [[ -f $KEY_FILE ]] && key_candidate=$KEY_FILE

  while (( ++attempt <= 3 )); do
    if [[ -z $key_candidate ]]; then
      key_candidate=$(mktemp); chmod 600 "$key_candidate"; cleanup_add "$key_candidate"
      # `|| rc=$?`, not `; rc=$?`. read_age_key returns 1 for blank and 2
      # for a bad format, and under `set -e` a bare call dies through the
      # ERR trap before rc is read -- which made the whole branch below
      # unreachable, including the prompt's own offer to skip decryption.
      # On the left of `||` it is a tested command, the one context set -e
      # leaves alone.
      rc=0; read_age_key "$key_candidate" || rc=$?
      if (( rc == 2 )); then                       # bad format, offer another
        rm -f "$key_candidate"; key_candidate=""
        (( ASSUME_YES )) && { warn "--yes cannot re-prompt -- secrets will not be decrypted"; break; }
        prompt_yn "try again?" && continue
        break
      elif (( rc != 0 )); then                     # blank: deliberate skip
        rm -f "$key_candidate"; key_candidate=""
        warn "no key provided -- secrets will not be decrypted"
        break
      fi
      promote=1
    fi

    # --input-type/--output-type are required: sops infers the format from
    # the extension, does not recognise .sops, and falls back to binary --
    # which means JSON, so it fails to parse the file before it has so
    # much as looked at a key.
    out=$(mktemp); chmod 600 "$out"; cleanup_add "$out"
    sops_err=$(mktemp); cleanup_add "$sops_err"
    if SOPS_AGE_KEY_FILE="$key_candidate" \
       sops -d --input-type dotenv --output-type dotenv \
         "$REPO_DIR/secrets/env.sops" > "$out" 2>"$sops_err"; then
      rm -f "$sops_err"
      if [[ -s $out ]]; then
        DECRYPTED=$out
        if (( promote )); then
          mkdir -p "$(dirname "$KEY_FILE")"
          install -m 600 "$key_candidate" "$KEY_FILE"
          rm -f "$key_candidate"
          ok "age key stored at $KEY_FILE (0600)"
        else
          skip "age key present and decrypts secrets/env.sops"
        fi
        break
      fi
      # Empty after a clean decrypt is a truncated env.sops, not a key
      # problem, so another key cannot help.
      rm -f "$out"
      (( promote )) && rm -f "$key_candidate"
      warn "sops decrypted secrets/env.sops but produced nothing -- refusing to install an empty .env"
      break
    fi

    rm -f "$out"

    # Show what sops actually said -- discarding it makes every failure,
    # the format one above included, look like a wrong key.
    if grep -qiE 'unmarshal|input type|binary store|invalid character' "$sops_err" 2>/dev/null; then
      warn "sops cannot read secrets/env.sops at all:"
      sed 's/^/      /' "$sops_err" >&2
      rm -f "$sops_err"
      (( promote )) && rm -f "$key_candidate"
      die "that is a file format problem, not a key problem -- no other key will help"
    fi

    warn "could not decrypt secrets/env.sops with that key"
    [[ -s $sops_err ]] && sed 's/^/      /' "$sops_err" >&2
    rm -f "$sops_err"
    if (( promote )); then
      rm -f "$key_candidate"                       # ours, and it did not work
    else
      warn "$KEY_FILE is left exactly as it was -- it may unlock something else"
    fi
    key_candidate=""; promote=0

    (( ASSUME_YES )) && die "wrong age key, and --yes cannot prompt for another ($ENV_TARGET left untouched)"
    prompt_yn "enter a different age key?" || break
  done
  (( attempt > 3 )) && warn "giving up after 3 attempts -- secrets will not be decrypted"
fi

# The compose variables that come from site.env rather than from sops.
# run.sh acts on every one of them -- it creates and chowns those
# directories and renders the Caddyfile from $DOMAIN -- so a copy compose
# reads that could disagree would provision the host in one layout and run
# it in another, with nothing to say so.
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

# site.env wins, applied after both branches because the sops branch
# rewrites $ENV_TARGET verbatim on every run and would otherwise put the
# stale copies straight back. secrets/env.sops still carries PUID, PGID,
# TZ, CONFIG, DATA and NAS; overwriting them here is what keeps that
# harmless.
env_set() {
  local key=$1 val=$2
  # sed_rhs because the substitution branch hands $val to sed, where an
  # unescaped & expands to the whole match -- DOMAIN=a&b grew longer on
  # every run. $key is a fixed uppercase name and needs no escaping.
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

# HEALTHCHECK_URL travels the other way. It is not a compose variable, but
# it is a capability -- anyone holding it can send fake success pings and
# silence the backup alarm -- so it lives in sops rather than in the
# committed site.env.<host>, and a rebuilt host recovers its monitoring
# from the same age key as everything else. site.env still wins if set.
if [[ -z ${HEALTHCHECK_URL:-} ]] && sudo test -f "$ENV_TARGET"; then
  HEALTHCHECK_URL=$(sudo sed -n 's/^HEALTHCHECK_URL=//p' "$ENV_TARGET" | head -1)
  # Compose strips one layer of matched quotes from a .env value; sed does
  # not. That mostly washes out, but HEALTHCHECK_URL="" -- how a .env says
  # "no monitoring" -- is two characters rather than an empty string, so
  # the test below would report monitoring enabled while backup.sh pings
  # nothing.
  if (( ${#HEALTHCHECK_URL} >= 2 )) \
     && [[ $HEALTHCHECK_URL == \"*\" || $HEALTHCHECK_URL == \'*\' ]]; then
    HEALTHCHECK_URL=${HEALTHCHECK_URL:1:${#HEALTHCHECK_URL}-2}
  fi
  [[ -n $HEALTHCHECK_URL ]] && ok "HEALTHCHECK_URL recovered from sops"
fi
export HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

step "Compose files"

sudo rsync -a --chown="$PUID:$PGID" \
  --exclude '.env' \
  "$REPO_DIR/compose/" "$DOCKER_ROOT/"

# --delete over stacks/ only, so a stack removed from the repo stops being
# deployed. Not over the whole tree: $DOCKER_ROOT legitimately holds files
# compose/ does not ship -- scripts/update.sh and the Caddyfile symlink.
# .env stays excluded so the block below removes a stale stacks/.env
# visibly rather than silently, in the middle of a sync of eleven others.
sudo rsync -a --delete --chown="$PUID:$PGID" \
  --exclude '.env' \
  "$REPO_DIR/compose/stacks/" "$DOCKER_ROOT/stacks/"
ok "compose files synced to $DOCKER_ROOT (stacks/ pruned of removals)"

# stacks/.env is removed, not merely no longer created: compose
# interpolates included files from the project-level .env, not from one
# beside them (verified on bmo with it absent -- `docker compose config`
# clean across all 31 services). Left in place it is a second path to
# every secret in $ENV_TARGET, and reads as deliberate on a later audit.
if sudo test -e "$DOCKER_ROOT/stacks/.env" || sudo test -L "$DOCKER_ROOT/stacks/.env"; then
  sudo rm -f "$DOCKER_ROOT/stacks/.env"
  ok "removed the obsolete stacks/.env (compose reads $ENV_TARGET directly)"
fi

# network.yml ships an absolute build path; make it match this host
if sudo grep -q 'build: /srv/docker/build/caddy' "$DOCKER_ROOT/stacks/network.yml" 2>/dev/null; then
  sudo sed -i "s|build: /srv/docker/build/caddy|build: ${DOCKER_ROOT}/build/caddy|" \
    "$DOCKER_ROOT/stacks/network.yml"
  ok "patched caddy build path"
fi

# Site addresses from a Caddyfile: the lines opening a block in column 0.
# The global options block is a bare '{' and a site block's contents are
# indented, so neither can match. Comma-separated addresses are split out.
caddy_site_addresses() {
  sudo sed -nE 's/^([A-Za-z0-9_*.,-][A-Za-z0-9_*.,[:space:]-]*)\{[[:space:]]*$/\1/p' "$1" \
    | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -E '\.' \
    | sort -u
}

CADDYFILE="$CONFIG/caddy/Caddyfile"

# Read by the Verification summary. A Caddyfile this script renders itself
# matches $DOMAIN by construction, so 1 is the right starting value.
CADDY_DOMAIN_OK=1

# Does the Caddyfile on disk serve $DOMAIN? Asked twice, because the
# restore step replaces $CONFIG/caddy from a snapshot afterwards: a check
# made only here would pass on the fresh render and miss the old domain's
# file the restore puts back behind it. $1 names where the file came from,
# since the remedy differs.
check_caddy_domain() {
  local origin=$1 addr
  local -a addrs=() stale=()
  [[ -f $CADDYFILE ]] || return 0

  # Matched by suffix rather than by stripping the leftmost label, so an
  # apex block is not reported as the domain "com".
  mapfile -t addrs < <(caddy_site_addresses "$CADDYFILE")
  for addr in "${addrs[@]}"; do
    [[ $addr == "$DOMAIN" || $addr == *".$DOMAIN" ]] || stale+=("$addr")
  done

  if (( ${#stale[@]} )); then
    CADDY_DOMAIN_OK=0
    warn "$CADDYFILE serves ${#stale[@]} address(es) that are not under DOMAIN=$DOMAIN:"
    printf '    %s\n' "${stale[@]:0:6}"
    (( ${#stale[@]} > 6 )) && printf '    ... and %d more\n' "$(( ${#stale[@]} - 6 ))"
    warn "$origin"
    warn ".env, cloudflare-ddns and vaultwarden are all set to $DOMAIN, so nothing"
    warn "agrees with this file. Edit it, or discard it and re-run to render a"
    warn "fresh one from templates/Caddyfile.tmpl:"
    warn "  sudo rm $CADDYFILE"
    return 0
  fi
  CADDY_DOMAIN_OK=1
  return 0
}

if [[ -f $CADDYFILE ]]; then
  # Left alone on purpose: live configuration, hand-edited and restored
  # from backup. Its domain is still checked, because changing DOMAIN in
  # site.env moves .env, cloudflare-ddns and vaultwarden while this file
  # goes on serving -- and renewing certificates for -- the old name,
  # without anything erroring.
  check_caddy_domain "this file was already on the host; nothing here changed it."
  (( CADDY_DOMAIN_OK )) \
    && skip "Caddyfile exists and matches DOMAIN=$DOMAIN -- leaving it alone"
else
  sed "s/{{DOMAIN}}/${DOMAIN}/g" "$REPO_DIR/templates/Caddyfile.tmpl" \
    | sudo tee "$CADDYFILE" >/dev/null
  sudo chown "$PUID:$PGID" "$CADDYFILE"
  ok "rendered Caddyfile for $DOMAIN"
fi

LINK="$DOCKER_ROOT/Caddyfile"
# Nothing reads this link: it exists so the Caddyfile is in reach from
# $DOCKER_ROOT, where every `docker compose` in this repo is run from.
# Flagged as a dead artifact once already, hence the note. Unlike the
# stacks/.env above it cannot become a second source of truth -- a symlink
# cannot drift from its target.
if [[ -L $LINK || ! -e $LINK ]]; then
  sudo ln -sfn "$CONFIG/caddy/Caddyfile" "$LINK"
  sudo chown -h "$PUID:$PGID" "$LINK"
  ok "linked $LINK -> $CONFIG/caddy/Caddyfile"
else
  warn "$LINK exists and is a real file, not a symlink -- left alone"
fi

# compose interpolates an unset variable to the empty string with one
# warning line and carries on. An API key becomes a container that starts
# and misbehaves; `${CONFIG}/prowlarr` becomes `/prowlarr`, which Docker
# then creates at the root of the filesystem.
#
# Only the stacks in compose.yml's include: list are checked, and only a
# bare `${VAR}` -- `${VAR:-default}` supplies its own value, so matching
# it would report IMMICH_VERSION on every run of a correct .env.
if sudo test -f "$ENV_TARGET"; then
  mapfile -t included < <(
    sed -n '/^include:/,/^[^[:space:]#-]/p' "$REPO_DIR/compose/compose.yml" \
      | sed -n 's|^[[:space:]]*-[[:space:]]*stacks/\([A-Za-z0-9._-]*\.yml\).*|\1|p'
  )

  env_required=(); env_paths=()
  for f in "${included[@]}"; do
    src="$REPO_DIR/compose/stacks/$f"
    if [[ ! -f $src ]]; then
      warn "compose.yml includes stacks/$f, which does not exist"
      continue
    fi
    # Commented-out YAML is skipped first: network.yml's disabled
    # cloudflared service needs no ${CLOUDFLARE_TUNNEL_TOKEN}.
    # tr strips the literal characters '$', '{' and '}'.
    # shellcheck disable=SC2016
    mapfile -t -O "${#env_required[@]}" env_required < <(
      grep -vE '^[[:space:]]*#' "$src" \
        | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | tr -d '${}')
    # A variable that opens a bind-mount source. Empty, it does not
    # misconfigure a container -- it relocates the mount to /.
    # shellcheck disable=SC2016
    mapfile -t -O "${#env_paths[@]}" env_paths < <(
      grep -vE '^[[:space:]]*#' "$src" \
        | grep -oE '^[[:space:]]*-[[:space:]]*"?\$\{[A-Z_][A-Z0-9_]*\}[^":]*:' \
        | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | tr -d '${}')
  done

  # `=.+` so a key present but blank counts as missing, which is exactly
  # what the TEMPLATE .env is full of.
  mapfile -t env_present < <(
    sudo grep -oE '^[A-Z_][A-Z0-9_]*=.+' "$ENV_TARGET" | cut -d= -f1 | sort -u)

  env_missing=(); env_missing_paths=(); env_checked=0
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    (( ++env_checked ))
    printf '%s\n' ${env_present[@]+"${env_present[@]}"} | grep -qxF "$v" && continue
    if printf '%s\n' ${env_paths[@]+"${env_paths[@]}"} | grep -qxF "$v"; then
      env_missing_paths+=("$v")
    else
      env_missing+=("$v")
    fi
  done < <(printf '%s\n' ${env_required[@]+"${env_required[@]}"} | sort -u)

  if (( ${#env_missing_paths[@]} )); then
    warn "these open a bind-mount source and are empty or absent in $ENV_TARGET:"
    printf '    %s\n' "${env_missing_paths[@]}"
    die "compose would mount those at the root of the filesystem -- refusing to continue"
  fi

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

# Group membership is fixed at login, so this shell may lack the docker
# group just added above and `docker compose up -d` would fail with a
# socket permission error that reads like a broken installation. `id -nG`
# with no argument reports this process's own credentials, not what
# /etc/group now says.
if id -nG 2>/dev/null | grep -qw docker; then
  START_HINT="cd $DOCKER_ROOT && docker compose up -d"
else
  START_HINT="newgrp docker      # this shell predates the group change made above
     cd $DOCKER_ROOT && docker compose up -d"
fi

if [[ $PROFILE == minimal ]]; then
  cat <<EOF

$(printf '%s' "$c_grn")Minimal provisioning complete.$(printf '%s' "$c_off")

Next:
  1. Fill in $ENV_TARGET
  2. Review $DOCKER_ROOT/compose.yml and comment out stacks you don't want
  3. $START_HINT

Skipped (host-specific): NFS mount, systemd units, firewall rules, backups.
EOF
  exit 0
fi

step "NFS mount"

FSTAB_LINE="${NAS_HOST}:${NAS_EXPORT}  ${NAS}  nfs  rw,_netdev,x-systemd.automount,x-systemd.requires=network-online.target,noatime,nofail  0  0"

if ! grep -qs "^${NAS_HOST}:${NAS_EXPORT}[[:space:]]" /etc/fstab; then
  sudo cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null
  ok "fstab entry added (backup saved)"
else
  skip "fstab entry present"

  # An existing entry is never rewritten, so check its options rather than
  # assume them. Without x-systemd.automount the export is mounted once at
  # boot and, with nofail, never retried -- a slow NAS then leaves $NAS
  # empty for the rest of the uptime, and every container bind-mounting it
  # sees an empty directory rather than an error. The docker.service
  # drop-in depends on this line carrying the option.
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

# Only safe now the export is mounted: created earlier they land on the
# root filesystem, and the mount then hides them.
if mountpoint -q "$NAS" 2>/dev/null; then
  create_dirs nas
else
  warn "$NAS is not a mount point -- NAS directories not created"
  warn "mount the export and re-run; creating them now would fill the root disk"
fi

step "systemd units"

# Rendered here rather than through install_templated: what goes in is an
# escaped unit name, not a path. --suffix=automount, not mount -- naming
# the .mount unit makes Wants= force the real NFS mount at boot and After=
# wait out its timeout with the NAS down, the outage the automount exists
# to prevent. Wants= on an .automount unit that does not exist is only a
# logged warning, so docker still starts. sed_rhs because systemd-escape
# emits backslash escapes, which sed would read as escapes of its own.
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
sudo systemctl daemon-reload

if prompt_yn "enable docker-update.service (pulls latest images on every boot)?"; then
  sudo systemctl enable docker-update.service >/dev/null
  ok "docker-update.service enabled"
else
  skip "docker-update.service installed but not enabled"
fi

step "Firewall"

# Scope: ufw filters the host's INPUT chain, covering SSH, cockpit and
# every network_mode: host container -- technitium's DNS on 53 above all,
# since an open resolver gets conscripted into amplification attacks.
#
# It does NOT cover Docker's published ports, for which Docker inserts its
# own rules ahead of ufw's; restricting those needs DOCKER-USER rules this
# script does not write. Hence no Cloudflare-range rules here: they read
# as though 443 were closed to everyone else and did nothing at all.

sudo ufw --force default deny incoming >/dev/null
sudo ufw --force default allow outgoing >/dev/null

sudo ufw allow in on tailscale0 >/dev/null
sudo ufw allow from "$LAN_SUBNET" >/dev/null
sudo ufw allow 22/tcp >/dev/null
sudo ufw allow 41641/udp >/dev/null           # tailscale direct

# syncthing's admin GUI. syncthing is network_mode: host, so unlike every
# other service here it really is on the host's INPUT chain. Only caddy
# needs to reach it, and the packet arrives from caddy's address on the
# core bridge -- so the source is core's subnet, not Docker's whole
# 172.16.0.0/12 pool, which would expose the admin interface of the
# service holding $DATA/sync to every container on the host.
#
# Asked of docker because `docker network create core` pins no --subnet.
# The trailing space in the template matters: without it a dockerd with
# IPv6 answers `172.20.0.0/16fd00:dead::/64`, one token matching nothing,
# which sends this to the fail-closed branch below. Take the first IPv4
# entry -- the rule is about caddy's v4 address on the bridge.
core_subnet=$(sudo docker network inspect -f \
  '{{range .IPAM.Config}}{{.Subnet}} {{end}}' core 2>/dev/null \
  | tr ' ' '\n' | grep -m1 -E '^[0-9.]+/[0-9]+$' || true)

if [[ $core_subnet =~ ^[0-9.]+/[0-9]+$ ]]; then
  # Sweeps any 8384 rule whose source is not core's current subnet; ufw
  # refusing to delete a rule that is not there is not an error here.
  #
  # `show added`, not `status`: this runs before `ufw --force enable`, and
  # on an inactive firewall `status` prints no rule rows at all -- so the
  # stale /12 would survive in the rule database and come back up with the
  # enable. `show added` reports that database either way.
  while read -r stale; do
    [[ $stale == "$core_subnet" ]] && continue
    sudo ufw delete allow from "$stale" to any port 8384 proto tcp >/dev/null 2>&1 || true
  done < <(sudo ufw show added 2>/dev/null \
             | awk '$3 == "from" && /port 8384 proto tcp/ { print $4 }' || true)

  sudo ufw allow from "$core_subnet" to any port 8384 proto tcp >/dev/null
  ok "syncthing GUI restricted to the core network ($core_subnet)"
else
  # Fails closed: silently falling back to the /12 because one docker
  # command did not answer is the wrong trade for an admin interface.
  warn "could not read the core network's subnet -- syncthing's GUI rule NOT written"
  warn "sync.$DOMAIN will fail to proxy until it is. Re-run once docker is up, or:"
  warn "  sudo ufw allow from \$(sudo docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' core | tr ' ' '\\n' | grep -m1 -E '^[0-9.]+/[0-9]+$') to any port 8384 proto tcp"
fi

# interface name can change across reinstalls, so discover it
LAN_IF=$(ip -o -4 route show default | awk '{print $5}' | head -1)
if [[ -n $LAN_IF ]]; then
  sudo ufw allow in on "$LAN_IF" to any port 21027 proto udp >/dev/null  # syncthing discovery
  ok "base rules applied (LAN interface: $LAN_IF)"
else
  warn "could not determine LAN interface -- syncthing discovery rule skipped"
fi

sudo ufw --force enable >/dev/null
ok "ufw enabled"

# The restic repository lives on the NAS and survives a reformat of this
# host. This step reconnects to it -- it never runs `restic init`, which
# would orphan every existing snapshot.

step "Backups"

RESTIC_PASS_FILE=/root/.restic-pass
NAS_SSH_USER="${NAS_SSH_USER:-root}"

# restic comes from config/packages.txt, so it is already installed here.
command -v restic >/dev/null \
  || die "restic is missing; it should have been installed in step 2"
skip "restic present ($(restic version 2>/dev/null | awk '{print $2}'))"

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

# Repository passphrase, and reconnecting with it -- never init.
#
# Prompt and verification are one loop, for the same reason as the age key
# above: gating on the file existing made a single typo permanent, and the
# nightly timer went on failing against a repository it could not open. A
# passphrase that does not open the repository never overwrites one that
# might.
restic_opens() {   # $1 = password file
  sudo restic -r "$RESTIC_REPO" --password-file "$1" snapshots --latest 1 >/dev/null 2>&1
}

repo_ok=0
pass_candidate=""; promote=0; attempt=0
sudo test -f "$RESTIC_PASS_FILE" && pass_candidate=$RESTIC_PASS_FILE

while (( ++attempt <= 3 )); do
  if [[ -z $pass_candidate ]]; then
    echo
    echo "  No working restic passphrase for $RESTIC_REPO"
    echo "  Paste it from your paper / password-manager copy."
    echo "  WITHOUT IT THE EXISTING BACKUPS CANNOT BE READ."
    read -rsp "  passphrase: " restic_pass; echo
    if [[ -z $restic_pass ]]; then
      warn "no passphrase given -- backups not configured"
      break
    fi
    # 0600 before the secret is written, not after: /root/.restic-pass is
    # all that stands between a stolen repository and every file here.
    pass_candidate=$(mktemp); chmod 600 "$pass_candidate"; cleanup_add "$pass_candidate"
    printf '%s\n' "$restic_pass" > "$pass_candidate"
    unset restic_pass
    promote=1
  fi

  if restic_opens "$pass_candidate"; then
    if (( promote )); then
      sudo install -m 600 -o root -g root "$pass_candidate" "$RESTIC_PASS_FILE"
      rm -f "$pass_candidate"
      ok "passphrase stored at $RESTIC_PASS_FILE (0600)"
    else
      skip "restic passphrase present and opens the repository"
    fi
    # One "short_id" per snapshot; "time" would also match fields restic
    # may add later.
    snap_count=$(sudo restic -r "$RESTIC_REPO" --password-file "$RESTIC_PASS_FILE" \
      snapshots --json 2>/dev/null | grep -c '"short_id"' || true)
    ok "connected to $RESTIC_REPO ($snap_count snapshots)"
    repo_ok=1
    break
  fi

  warn "could not read $RESTIC_REPO"
  warn "wrong passphrase, no SSH access as root, or the repo does not exist yet."

  # A brand-new repository is a real setup rather than a failure, and
  # creating one by hand needs the passphrase on disk first -- so offer to
  # keep an unverified one.
  if (( promote )); then
    if (( ASSUME_YES )); then
      rm -f "$pass_candidate"
      die "restic passphrase does not open $RESTIC_REPO, and --yes cannot prompt for another"
    fi
    if prompt_yn "store it anyway (needed if this repo does not exist yet and you will run restic init)?"; then
      sudo install -m 600 -o root -g root "$pass_candidate" "$RESTIC_PASS_FILE"
      rm -f "$pass_candidate"
      warn "passphrase stored at $RESTIC_PASS_FILE but NOT verified against the repository"
      warn "If this is a NEW repo, initialise it by hand -- deliberately not"
      warn "automated, because init on a live repo orphans every snapshot:"
      warn "  sudo restic -r $RESTIC_REPO --password-file $RESTIC_PASS_FILE init"
      break
    fi
    rm -f "$pass_candidate"
  else
    warn "$RESTIC_PASS_FILE is left exactly as it was"
    (( ASSUME_YES )) && break
  fi
  pass_candidate=""; promote=0

  prompt_yn "try a different passphrase?" || break
done
(( attempt > 3 )) && warn "giving up after 3 attempts -- backups not configured"

# Is this host empty enough that a restore is what it wants?
#
# "The repository has snapshots" is NOT the signal: every run on a healthy
# host satisfies it, and a restore there overwrites 31 running services
# with last night's state. The signal is that this host has no service
# state of its own -- the first regular file under $CONFIG, excluding the
# Caddyfile this run renders, was put there by a container.
snap_count=${snap_count:-0}
config_state=""
if sudo test -d "$CONFIG"; then
  config_state=$(sudo find "$CONFIG" -type f ! -path "$CADDYFILE" -print -quit 2>/dev/null || true)
fi

# Plausible, not decided: this only suppresses the "run a backup now"
# offer and gates the restore step, which still needs an explicit
# --restore or a y at the prompt.
RESTORE_PLAUSIBLE=0
if (( repo_ok && snap_count > 0 )); then
  if (( RESTORE_REQUESTED )) || [[ -z $config_state ]]; then
    RESTORE_PLAUSIBLE=1
  fi
fi

# Fails before the backup offer below rather than at the restore step
# after it: that offer can take an hour on a first run.
if (( RESTORE_REQUESTED )); then
  (( repo_ok )) \
    || die "--restore was asked for but $RESTIC_REPO is not readable (see the errors above)"
  (( snap_count > 0 )) \
    || die "--restore was asked for but $RESTIC_REPO holds no snapshots yet"
fi

if sudo test -f "$RESTIC_PASS_FILE"; then

  # Config for the systemd job, independent of this git checkout.
  #
  # BACKUP_HOST is written as a literal, fixed at whatever this host was
  # called when it was provisioned: reading the live hostname would let a
  # rename start a second snapshot history `forget --host` never prunes.
  # DATA_IS_MOUNT keeps its site.env name so the two guards are one switch
  # rather than two that can disagree. DOCKER_ROOT is stated for
  # restore.sh, which is installed verbatim and would otherwise infer it
  # as $(dirname "$CONFIG") -- site.env sets the two independently, and
  # nothing makes CONFIG a child of DOCKER_ROOT.
  backup_host="${BACKUP_HOST:-$(hostname -s 2>/dev/null || true)}"
  [[ -n $backup_host ]] || die "cannot determine a backup host name -- set BACKUP_HOST in config/site.env"

  # %q because backup.sh and restore.sh both *source* this file: an
  # unquoted value holding a shell metacharacter is code, not data. A
  # HEALTHCHECK_URL query string -- .../ping?rid=a&env=prod -- would end
  # the assignment at the `&`, killing the backup at source time, before
  # it could send the failure ping that lives in the file that just failed
  # to parse.
  #
  # Safe because both consumers are bash. A systemd EnvironmentFile parses
  # quotes but not %q's $'...' form.
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

  # Installing the backup does not take one -- the timer first fires at
  # 03:30, and that gap is how a host gets reformatted on the strength of
  # a backup system that has never written a snapshot.
  #
  # Not under --yes, and not when a restore is on the cards: snapshotting
  # an empty host spends a `forget --keep-last` slot on nothing and puts
  # that snapshot at the top of `--list`, which is the one reached for
  # first.
  if (( repo_ok )) && ! (( RESTORE_PLAUSIBLE )); then
    if (( ASSUME_YES )); then
      warn "no backup has been taken yet -- run: sudo /usr/local/sbin/bmo-backup"
    elif prompt_yn "run a backup now (can take a long time on the first run)?"; then
      sudo /usr/local/sbin/bmo-backup || warn "backup finished with problems -- see above"
    else
      skip "no backup taken -- run: sudo /usr/local/sbin/bmo-backup"
    fi
  elif (( repo_ok )); then
    skip "not offering a backup yet -- restore comes first, see below"
  fi
fi

# Everything above builds the *shape* of the host and restores not one row
# of anybody's database, leaving a rebuilt host one `docker compose up -d`
# away from 31 services initialising fresh empty databases into the
# directories the real ones belong in. Nothing fails; they come up looking
# merely "reset", and the next nightly backup snapshots that over the top.
#
# So the restore belongs here: after the repository is reachable and
# $CONFIG exists, and before the stack is ever started. It is never
# automatic -- see RESTORE_PLAUSIBLE above.

step "Restore"

if (( ! repo_ok )); then
  skip "repository not readable -- nothing to restore from"

elif (( snap_count == 0 )); then
  skip "repository holds no snapshots yet -- nothing to restore from"

else
  do_restore=0
  if (( RESTORE_REQUESTED )); then
    do_restore=1
    ok "--restore given ($snap_count snapshots available)"

  elif [[ -n $config_state ]]; then
    # The normal case: re-running run.sh on a working host. Nothing here
    # should read as an invitation.
    skip "$CONFIG already holds service state -- not touching it"
    skip "to recover individual services: sudo /usr/local/sbin/bmo-restore --list"

  elif (( ASSUME_YES )); then
    # --yes means "do not ask", not "assume yes to replacing the disk".
    warn "$CONFIG is empty and $snap_count snapshots exist, but --yes will not restore on its own"
    warn "re-run with --restore, or: sudo /usr/local/sbin/bmo-restore --all"

  else
    echo
    echo "  $CONFIG holds no service state, and $RESTIC_REPO has $snap_count snapshots."
    echo "  This looks like a rebuilt host. Restoring now -- before the stack is"
    echo "  started for the first time -- is the point at which it is cheapest:"
    echo "  no service has yet written an empty database over its own directory."
    echo
    prompt_yn "restore every service from the newest snapshot?" && do_restore=1
    (( do_restore )) || skip "not restoring -- sudo /usr/local/sbin/bmo-restore --all does it later"
  fi

  if (( do_restore )); then
    # Handed off rather than reimplemented: this is the same code path a
    # hand-run recovery takes, which is the only way it stays tested. Not
    # passing -y, because it prompts before restoring $DATA -- tens of
    # gigabytes of photo library, and the one part worth confirming.
    echo
    sudo /usr/local/sbin/bmo-restore --all \
      || die "restore failed -- do NOT start the stack; investigate, then: sudo /usr/local/sbin/bmo-restore --all"
    ok "restore finished -- review the output above before starting the stack"

    # The restore has just replaced $CONFIG/caddy with the snapshot's
    # copy, which carries whatever domain the host had when it was backed
    # up -- so the earlier check is now about a file that no longer
    # exists. Silent when it passes; the Verification summary reports it.
    check_caddy_domain "that file came from the snapshot, and carries the domain this host had when it was backed up."
  fi
fi

step "Verification"

printf '  %-22s %s\n' "NAS mounted:"   "$(mountpoint -q "$NAS" && echo yes || echo NO)"
printf '  %-22s %s\n' "data disk:"     "$(mountpoint -q "$DATA" && echo yes || echo 'NO (check UUID in fstab)')"
# `|| true` because a non-zero here is the answer, not a fault:
# `systemctl is-active` exits 3 for inactive having already printed the
# word this line reports, and would otherwise reach the ERR trap and print
# a FAILED frame in the middle of the summary.
printf '  %-22s %s\n' "docker:"        "$(systemctl is-active docker || true)"
printf '  %-22s %s\n' "core network:"  "$(sudo docker network inspect core >/dev/null 2>&1 && echo yes || echo NO)"
printf '  %-22s %s\n' ".env:"          "$([[ -s $ENV_TARGET ]] && echo present || echo MISSING)"
# Deliberately repeats the warning above rather than restating it: a restore
# run buries that one, and this is the screen written to be read last.
printf '  %-22s %s\n' "caddy domain:"  "$( (( CADDY_DOMAIN_OK )) && echo "matches $DOMAIN" || echo "STALE -- Caddy will serve the wrong name")"
printf '  %-22s %s\n' "ufw:"           "$(sudo ufw status | head -1 | awk '{print $2}')"
printf '  %-22s %s\n' "backup timer:"  "$(systemctl is-enabled bmo-backup.timer 2>/dev/null || echo 'not installed')"
# The timer being enabled says nothing about whether it can reach the
# repository: under --yes a wrong passphrase only warns and the run
# carries on.
printf '  %-22s %s\n' "restic repo:"   "$( (( repo_ok )) && echo "readable" || echo 'NOT READABLE -- backups will fail')"

cat <<EOF

$(printf '%s' "$c_grn")Provisioning complete.$(printf '%s' "$c_off")

Not done by this script, on purpose:
  - restic init  (a new repo must be created by hand -- see above)
  - tailscale up  (needs interactive auth)
$(if (( RESTORE_PLAUSIBLE )) && (( ! RESTORE_REQUESTED )); then cat <<'HINT'

This host has no service state and the repository has snapshots. If this
is a rebuild, restore BEFORE starting the stack -- once a service starts
on an empty directory it writes a fresh database there, and the next
nightly backup snapshots that over the top:

     sudo /usr/local/sbin/bmo-restore --list
     sudo /usr/local/sbin/bmo-restore --all
HINT
fi)

Then:
     $START_HINT
EOF
