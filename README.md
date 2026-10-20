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

- `0002-config-and-openssl-paths-relative.patch` — makes the binaries independent
  of where they were built. Module configs are read from `modules/` next to the
  main config file (`-c`), not from the compiled-in `_CONF_DIR`; and on macOS
  OpenSSL's provider search path is set to `<bin>/lib/ossl-modules`, where the
  legacy provider (RC4) is bundled, instead of a Homebrew Cellar path that
  disappears on `brew upgrade openssl@3`. Without this the payload only runs
  when it is installed at exactly the prefix it was built for.
- `0004-desolace-caravan-refollow.patch` — the Gizelton Caravan escorts (quests 5821
  and 5943) failed because the summoned Rigger and kodos stop following Cork after
  they fight: they are plain summons without an owner, so evading sends them to a
  stale home position, and `SummonsFollow()` only ran at the stops. Re-issues the
  follow every 2 s for any summon that is out of combat and not following. Upstream:
  azerothcore/azerothcore-wotlk#6593, #5848, #20626 (all open). Untested in game.
- `0006-outdoorpvp-script-store-full-guid.patch` — shutdown use-after-free in
  `GameObject::RemoveFromWorld` (`m_zoneScript->OnGameObjectRemove`) during
  `MapMgr::UnloadAll`. An OutdoorPvP registers the objects whose zone script it is
  and clears that pointer in its destructor, but it keyed the registry by the
  per-map low counter, which is per HighGuid: a static transport (elevator) and a
  gameobject in the same OutdoorPvP can share it, so one of them is never cleared
  and keeps pointing at the OutdoorPvP that `Die()` freed. Keys the registry by the
  full `ObjectGuid`, and `Die()` now also clears the zone lookup that held the freed
  pointers. Seen once (2026-10-19); no upstream issue yet.
- `module/0003-playerbots-water-breathing.patch` — a bot that is under water without a
  water-breathing aura casts spell 5697 (Unending Breath) on itself, so bots that
  follow their master into deep water no longer drown. Touches the module
  (`src/Bot/PlayerbotAI.cpp`), so it lives in `patches/module/` and is applied
  inside the module checkout, not the core. Upstream
  has no fix; related open issues: mod-playerbots#1771, #1772. Drop this patch if
  the module gains its own handling.
- `module/0005-playerbots-thick-hide-talent.patch` — every bear/cat decision for a
  feral druid (level-up talent rebuild, combat and non-combat strategies, `IsTank`,
  LFG role, druid triggers) asks `HasTalent(16931)` instead of `HasAura(16931)`.
  The aura was missing at some level-ups, so a bear with Thick Hide 3/3 was rebuilt
  from the cat template (5 of 28 observed level-up intervals). The level-up check
  logs `Thick Hide talent ... but aura ...` with the bot's state whenever the two
  disagree, to find out when the aura goes missing. Upstream marks the check
  `@todo: fix cat druid hardcode`; no issue filed yet.
- `module/0008-playerbots-world-thread-packets.patch` — first part of making
  `MapUpdate.Threads > 1` safe for the module without moving the AI off the map threads.
  The core processes every client packet that touches shared state (groups, guilds,
  arena teams, battleground queues, mail, gossip scripts, ready checks, instance resets)
  on the world thread, which never runs while maps update; bot actions called those
  handlers directly on their map thread. They now queue the packet on the bot's session,
  which `HandleBotPackets` drains on the world thread, as upstream already does for loot
  and LFG. Where the action reads the outcome right away (accepting a group invite,
  turning in a guild charter, picking a gossip option) the call and the follow-up run as
  one `BotWorldThreadTask` on `PlayerbotWorldThreadProcessor`. Handlers the core marks
  world-only but which only touch the bot's own map (trade, duel, quest sharing, logout
  cancel, mount animation, next-mail query) are left as they were. Those actions now
  happen up to a tick (queued packets) or about 50 ms (tasks) later, as a client's would.
  Related upstream: mod-playerbots#2474. Inventory of the remaining hazards:
  notes/mt-audit-2026-10-20.md in the server workspace.

The patches are deliberately left uncommitted in the build tree, so the revision
banner keeps the `+` suffix that marks a patched build.

## Keeping the workflow honest

The cmake flags in `build-macos.yml` mirror the ones the local build used. If
either side changes, change both — a silent divergence shows up as behaviour
that only reproduces on one of the two builds.
