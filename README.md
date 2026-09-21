# azerothcore-ci

Builds the mod-playerbots server for an arm64 Mac on GitHub Actions, so the
machine that runs the server does not need the build toolchain or the Homebrew
libraries installed.

Nothing here is a fork of anything: the workflow checks out
`mod-playerbots/azerothcore-wotlk` and `mod-playerbots/mod-playerbots` at the
refs you pass, applies the patches in `patches/`, and uploads an installable
payload.

## What comes out

Artifact `server-pb-macos-arm64`, laid out like an AzerothCore install prefix:

- `bin/worldserver`, `bin/authserver`
- `bin/lib/` — every non-system dylib the binaries load (boost, openssl@3,
  readline, the MySQL client), with the load commands repointed at
  `@executable_path/lib` and re-signed ad hoc. The payload does not read
  `/opt/homebrew`.
- `bin/BUILD-MANIFEST.txt` — the two source commits, the patch hashes, the
  runner and the compiler that produced it.
- `etc/*.dist` — the reference configs for that revision.

The MySQL *server* is a separate matter: it still has to be installed and
running on the machine that hosts the databases.

`worldserver.conf` and `authserver.conf` each need `SourceDirectory` pointing at
the installed `sql-source/`: that is where the DB updater reads the SQL at every
startup, and a server that cannot find it shuts itself down. The install script
refuses to finish if either config is missing it.

## Running a build

```sh
gh workflow run build-macos.yml -R mybaixinyu/azerothcore-ci
# optionally pin the sources:
gh workflow run build-macos.yml -R mybaixinyu/azerothcore-ci \
    -f core_ref=Playerbot -f module_ref=master
```

Then install the result on the server machine:

```sh
scripts/install-artifact.sh            # newest successful run
scripts/install-artifact.sh <run-id>   # a specific run
```

`install-artifact.sh` refuses to run while `worldserver` is up, keeps the
previous binaries as `bin/*.bak-<timestamp>`, and only ever writes `*.dist`
files into `etc/` — the live configs are left alone.

## Patches

`patches/` holds the changes that are not upstream yet. Each one is applied with
`git apply` against a fresh checkout, so a patch that stops applying fails the
build instead of being silently skipped.

- `0001-gameeventmgr-27275.patch` — re-resolves each creature by GUID while
  walking the map's object store during a game event, instead of holding
  pointers that a `SMART_EVENT_GAME_EVENT_START` script can invalidate.
  Upstream: azerothcore/azerothcore-wotlk#27291 (issue),
  azerothcore/azerothcore-wotlk#27275 (closed PR).

The patch is deliberately left uncommitted in the build tree, so the revision
banner keeps the `+` suffix that marks a patched build.

## Keeping the workflow honest

The cmake flags in `build-macos.yml` mirror the ones the local build used. If
either side changes, change both — a silent divergence shows up as behaviour
that only reproduces on one of the two builds.
