# bmo post-install

Provisions a Debian host into the bmo server: packages, Docker, directories,
sops-encrypted secrets, compose stacks, NFS, systemd units, firewall, restic
backups. Every step is idempotent — re-running is how you apply changes.

Debian is what it is built and run on. Ubuntu and Raspberry Pi OS work too —
the apt archive and suite are derived from `/etc/os-release`, and a derivative
resolves to the base it names in `ID_LIKE`. Anything further afield stops at
preflight rather than failing later inside `apt-get update`.

## Use

```sh
git clone <repo> ~/post-install && cd ~/post-install
./run.sh --full              # creates config/site.env and stops
$EDITOR config/site.env      # paths, PUID/PGID, TZ, DOMAIN, NAS_*, RESTIC_REPO
./run.sh --full
```

`config/site.env` is per-host and not in the repo. The first run creates it
from `config/site.env.example` and stops so you can edit it. The exception is a
host with a committed profile of its own — `config/site.env.<hostname>`, e.g.
`site.env.bmo` — which is seeded automatically, so a reinstalled machine gets
its settings back.

| | |
|---|---|
| `--minimal` | packages, docker, directories, secrets, compose files |
| `--full` | the above plus NFS mount, systemd units, firewall, backups |
| `-y` | skip confirmations (not the two secret prompts) |

It will ask for your **age private key** and your **restic passphrase**, once
each. Both are stored 0600 and skipped on later runs.

Afterwards:

```sh
sudo tailscale up                          # interactive, not automated
cd /srv/docker && docker compose up -d     # rebuilds caddy via xcaddy, minutes
```

## On a freshly installed Debian

A minimal install cannot run this yet. As root:

```sh
apt install sudo git curl && usermod -aG sudo <user>   # then log out and back in
```

Then **mount `$DATA` and add it to `/etc/fstab` before running `run.sh`**.
Unmounted, its directories land on the root disk and the eventual mount hides
them. `run.sh` refuses to create them unless `DATA_IS_MOUNT=0` in `site.env`.

## Backups

`run.sh --full` *installs* the backup and enables the 03:30 timer; it offers to
run one at the end. By hand:

```sh
sudo /usr/local/sbin/bmo-backup
systemctl list-timers bmo-backup.timer
```

It never runs `restic init` — a new repository must be created by hand, because
init against a live one orphans every snapshot.

### What a snapshot contains

`$CONFIG` and `$DATA`, minus the exclusions below.

**Databases are dumped, not copied.** A file-level copy of a database that is
being written to restores as a torn file, or silently as stale data. So each one
is dumped to `$CONFIG/_dumps` first and **the live files are then excluded from
the snapshot** — postgres and mariadb as whole data directories, and the SQLite
files that the \*arr apps, vaultwarden, autobrr, navidrome and jellyfin keep all
their state in, together with their `-wal` and `-shm` sidecars.

For those services `_dumps` holds the *only* copy in the backup. `_dumps/README`
says so and travels inside the snapshot, so it arrives with the files it
describes.

Immich is the exception: it dumps its own database, version-aware, to
`$DATA/photos/backups`, and that is the file to restore from.

### What a snapshot does not contain

| Not backed up | Where it comes back from |
|---|---|
| `$DOCKER_ROOT/.env` | `secrets/env.sops` + your age key, via `run.sh` |
| `compose.yml`, `stacks/`, `build/` | this repo, via `run.sh` |
| `$NAS` | bulk media, re-acquirable — and it is the same box the repository lives on |
| `/etc/bmo-backup.env`, `/root/.ssh/id_nas` | rewritten by `run.sh --full` |
| `/etc/fstab`, packages, firewall, units | `run.sh --full` |
| docker images, the `model-cache` volume | pulled or regenerated |
| thumbnails, transcodes, caches | regenerated on demand |

**The backup alone therefore cannot rebuild bmo.** It restores *state*; the
shape of the host comes from this repository. A recovery needs all three of:
this repo, the age private key, and the restic passphrase.

### Monitoring

Put a [healthchecks.io](https://healthchecks.io) ping URL (or one from your own
Healthchecks instance — anywhere but bmo) into **sops**, not into a committed
`site.env` profile:

```sh
sops edit --input-type dotenv --output-type dotenv secrets/env.sops
#   add: HEALTHCHECK_URL=https://hc-ping.com/<uuid>
```

Both `--*-type` flags are required for `secrets/env.sops`, and for every other
sops command against it. sops infers the format from the file extension, knows
`.yaml`/`.json`/`.env`/`.ini`, and falls back to *binary* for anything else — so
without them it tries to JSON-parse a dotenv file and fails before it reaches
the key.

The URL is a capability — anyone holding it can send fake success pings and
silence the alarm — so it does not belong in a file the repo commits. `run.sh`
reads it back out of the decrypted `.env`, which means a rebuilt host recovers
its monitoring from the same age key as everything else instead of coming up
silently unmonitored. `HEALTHCHECK_URL` in `config/site.env` overrides it, for a
host that should report somewhere else.

`backup.sh` then pings on start, success and failure, and the far end alerts you
if the success ping does not arrive.

This is deliberately not a systemd `OnFailure=`. That only fires when the unit
runs and fails, and nothing running on bmo can tell you that bmo is off, that
the timer got disabled, or that the disk filled up before systemd could start
anything — which is how a backup actually goes quiet. Here silence is the
signal, so the arrangement checks itself.

Left empty, there is no alerting at all and `run.sh` says so on every `--full`
run.

## Restore

`run.sh --full` installs `/usr/local/sbin/bmo-restore` next to `bmo-backup`.
Like it, it reads `/etc/bmo-backup.env` and needs no git checkout.

```sh
sudo bmo-restore --list                  # snapshots, services, dumps, rollbacks
sudo bmo-restore --dry-run sonarr        # print every action, change nothing
sudo bmo-restore sonarr radarr           # put those services back
sudo bmo-restore --all                   # every service, for a rebuilt host
sudo bmo-restore --undo <timestamp>      # put back what a restore replaced
```

**Do not use a plain `restic restore --target /`.** It gives you every service
without its database: the live SQLite files are not in the snapshot, and the
SQL engines' data directories are not either. Nothing errors — the services
start, create empty databases, and merely look reset. Reassembling that is what
`bmo-restore` is for.

It stops only the containers belonging to the services named, so restoring one
service leaves the other thirty running. Before replacing a config directory it
moves the current one to `$DOCKER_ROOT/.bmo-rollback/<timestamp>/`, which is
outside `$CONFIG` and so never enters a snapshot. Delete it once you are happy.

Two things it deliberately does not do:

- **`$DATA` is restored in place, with no rollback copy, and it asks first.**
  `$DATA/photos` is hundreds of gigabytes; moving it aside would need twice
  that free before the restore could start. That half is not undoable.
- **The Immich database is checked before it is loaded.** The script compares
  the PostgreSQL major version recorded in the dump against the running server
  and refuses to load a newer dump into an older one. It also prints the pinned
  `IMMICH_VERSION` for you to sanity-check, because the Immich *application*
  version is not recorded in the dump in any stable form — that part is a
  judgement, not an assertion.

After a full rebuild the order is: `run.sh --full` first (it makes the host),
then `bmo-restore --all` (it makes the state). `run.sh` will offer to do the
second step for you — see below.

### Restoring as part of provisioning

`run.sh --full` has a **Restore** phase between backups and verification. It
sits there because that is the last moment a restore is cheap: the repository is
reachable, `$CONFIG` exists with the right ownership, and no container has
started yet. Start the stack first and every service initialises itself, writing
an empty database into the directory its real one belongs in — nothing fails,
they simply come up looking reset, and the next nightly backup snapshots that
over the top.

```sh
./run.sh --full --restore     # provision, then restore everything
```

Without `--restore` it decides by looking at the host, and **not** at whether
snapshots exist — snapshots existing describes the repository, not this machine.
If `$CONFIG` already holds service state it says so and does nothing, on every
run, for ever. If `$CONFIG` is empty and the repository has snapshots, it
explains the situation and asks, defaulting to no.

`--yes` will not restore on its own. It means "do not ask me", which is not the
same as "yes, replace the disk".

### Rollbacks

Restoring over an existing directory saves the old one first; restoring into
empty space does not, and no rollback directory is left behind in that case —
which is the normal shape of a bare-metal rebuild.

Use `--dry-run` first. It prints every action, including which SQLite databases
it would put back over which paths, and changes nothing.

## Do not lose these

Nothing here can recover them, and neither can the backup:

- age private key — `~/.config/sops/age/keys.txt`, else `secrets/env.sops` is dead
- restic passphrase — `/root/.restic-pass`, else every snapshot is unreadable
