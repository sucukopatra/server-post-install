# Dump validation and read-back verification

Design for two changes to `files/scripts/backup.sh`, agreed 2026-08-09.

## Problem

Everything in this repo is insurance against losing bmo, and nothing in it
has ever checked that a dump can be read back. Three separate bugs found on
2026-08-08 were the same mistake -- a proxy signal standing in for the real
condition:

- `.State.Running` for "the engine accepts connections"
- any-file-in-directory for "an Immich dump exists"
- file-exists for "the dump is current"

`dump_to` makes the same mistake once more: a command that exits 0 and
writes a non-empty file is taken as a good dump. A `docker exec` killed
mid-stream, a disk that fills at 90%, or an engine that errors after
emitting half the schema all satisfy that test.

Nothing checks the property that actually matters, which is not "a dump was
written on bmo" but "a readable, complete dump is inside the snapshot we
would restore from".

## Change 1 -- validate dumps as they are written

`dump_to` gains a validator parameter: the name of a function it calls on
`$out.tmp` after the command exits 0 and the file is non-empty, before the
rename.

| Dump | Validator | Test |
|---|---|---|
| `pg_dumpall` | `valid_pg_dump` | last 200 bytes contain `PostgreSQL database cluster dump complete` |
| `mariadb-dump` | `valid_mariadb_dump` | last 200 bytes contain `-- Dump completed` |
| SQLite `.backup` | inline | `PRAGMA integrity_check` returns exactly `ok` |

On a validation failure the `.tmp` is discarded and the previous good dump
is left in place -- identical to how a non-zero exit is already handled. A
truncated dump is worse than yesterday's complete one.

This depends on the staleness check added the same week: discarding the bad
dump silently ages the surviving one, and the staleness check is what makes
that loud within `DUMP_STALE_HOURS`. The two features cover each other and
neither should be removed alone.

Accepted tradeoff: if an upstream change ever suppresses those trailers,
every dump reads as invalid and is discarded. That costs a night's dump,
corrupts nothing, and the staleness check reports it within two nights.

## Change 2 -- weekly read-back verification

A block after the `restic check` section, driven by its own stamp file
(`$STATE_DIR/last-verify`), for the same reason `restic check` is: bmo is
not guaranteed to be powered on on any given day, so "verify on Sundays"
would never run.

Tunables: `VERIFY_DUMPS` (1, set 0 to disable), `VERIFY_INTERVAL_DAYS` (7,
0 means every run), validated as whole numbers alongside the existing ones.

It resolves the latest snapshot for this host and tag -- as the literal
`latest` with `--host`/`--tag`, so no JSON parsing and no dependency on
`jq` -- and validates what it finds there:

- **`<container>.sql`** -- streamed with `restic dump ... | tail -c 200`,
  checked for the engine's trailer. Never staged to disk: the Immich
  cluster dump is the largest file in `$DUMP_DIR` and is already on the
  root filesystem once.
- **Immich's own dump** -- newest `immich-db-backup-*.sql*` by mtime,
  streamed through `gzip -dc | tail -c 200`, matched against
  `PostgreSQL database (cluster )?dump complete`. One pass proves gzip
  integrity and completeness together. The alternation covers both
  `pg_dump` and `pg_dumpall`, which Immich has used at different versions.
- **`sqlite/`** -- one `restic restore --include` of the whole subtree into
  a temp dir, then `PRAGMA integrity_check` locally on each file. These
  need a real file, and 37 individual `restic dump` calls would be 37
  repository opens over sftp.

Whole pass is 4-5 repository opens. Temp dir is removed by the existing
EXIT trap, not a second one -- a second `trap ... EXIT` would replace the
first and the run would stop reporting to the monitor.

The set of dumps to look for comes from what is on disk in `$DUMP_DIR`, not
from `restic ls`. That is deliberately a stronger test: a dump present
locally must be in the snapshot, so `restic dump` failing to find it means
the exclusion logic is broken, which is exactly the class of bug this
exists to catch.

## Change 3 -- failure is not the same as skip

Two outcomes, deliberately distinct:

- **Validation failure** (bad trailer, gzip error, `integrity_check` not
  `ok`, file missing from the snapshot) -> `fail`. Run exits 1, `/fail`
  ping fires. The dump is genuinely bad.
- **restic-level error** (sftp dropped, repository unreachable) -> `warn`,
  and the stamp is *not* written, so it retries the next night instead of
  waiting out the interval.

"Could not fetch it" is not "it is corrupt". Conflating them is how a
monitor earns the right to be ignored.

`sqlite3` missing is a skip, not a failure, matching how `dump_sqlite`
already treats it.

## Testing

Extends the harness that already extracts real functions out of
`backup.sh` and runs them against stubs, now including `restic` and
`sqlite3`:

- valid trailer passes; truncated dump fails **and preserves the previous
  file** (the property that makes discarding safe)
- gzip corruption fails
- `integrity_check` returning anything but `ok` fails
- an sftp error warns, does not fail, and does not write the stamp
- a missing-from-snapshot dump fails

## Non-goals

- No VM. Restoring into a throwaway host is the real drill and remains
  worth doing; this is the cheap 80% that runs unattended.
- No verification that the restored dump *loads*. That needs an engine and
  is the VM drill's job.
- No coverage target. Ten tests on the dump/exclude/verify logic is where
  the value is, because that is the code whose failure is invisible until
  it is needed.
