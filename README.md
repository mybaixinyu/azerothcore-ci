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
- `0016-dismount-indoors-after-map-change.patch` — a player who changes map mounted
  and lands indoors (the Arathi Basin start rooms) stays mounted until the first
  move, because the indoor check that drops outdoor-only auras runs only from
  `Player::UpdatePosition`, which a same-map teleport goes through but
  `HandleMoveWorldportAck` does not (it only relocates). Runs
  `CheckAreaExploreAndOutdoor()` once after the zone update there. Bots take the
  same path. Upstream master and TrinityCore 3.3.5 behave the same; no upstream
  issue yet.
- `0017-create-base-maps-before-map-threads.patch` — `MapMgr` keeps one base map per map ID and
  creates it on first use. `CreateBaseMap` inserts under a mutex, but `FindBaseMap` (behind `FindMap`,
  `GetZoneId`, `GetAreaId`) reads the same `unordered_map` without it, and `MapMgr::Update` walks it on the world
  thread while the workers already update the maps it has handed out. A base map created during a map
  update (bots query zones on maps nobody has entered yet, transports change maps) can rehash the table
  under those readers, even with one map thread, since the updater still runs maps on its own thread.
  When the map updater is active, every map of `Map.dbc` (135: 47 plain, 88 instance parents) is now
  created at startup, so the table is never written after that. Base maps are cheap until a player
  loads a grid; an empty map's update only walks its (empty) player list. No upstream issue yet.
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
- `module/0009-playerbots-gossip-master-locale.patch` — the `talk` command told the
  master the NPC's text and gossip options in English: the bot's gossip menu is built in
  the bot session's locale, and the NPC text read the default fields. Both are now looked
  up in the master's locale, the way the core does for a client (broadcast text first,
  then `npc_text_locale` / `gossip_menu_option_locale`). An option is relocalized only
  when it matches a database option of the menu by id and by its text in the bot's
  locale, so options a script added keep their text; a missing translation falls back
  to the original. The bot's own menu is untouched. The NPC name uses the master's
  locale too, and the codes a client fills in gossip text (`$N`, `$C`, `$R`,
  `$Gmale:female;`, `$B` line breaks) are filled for the bot, each `$B` part told as
  its own line. Like the client, only the NPC text for the bot's gender is told, not
  both.
- `module/0010-playerbots-cross-thread-hooks.patch` — second part, the hooks and threads
  that reach a bot from outside its map. The three packet queues fed by `OnPacketSent`
  and the master's packets get a lock; handling order is unchanged. Chat from a bot on
  another map is copied into the receiving bot's queue and decided on its own next
  update, but only when `MapUpdate.Threads > 1` and the sender is not the world thread,
  so a single map thread behaves as before. `LogoutPlayerBot` called off the world
  thread (timed logout in the AI, `hire`) queues a `LogoutPlayerBotOperation` instead
  of deleting the bot inside `Map::Update`, which goes on to use the player
  (`MarkNearbyCellsOf`) and lets other maps read the bot lists mid-erase; this applies
  with one map thread too. The group strategy save it used to queue ran after the bot
  was gone and never saved anything; it now runs inline before the logout. The arena
  join that logs offline team members in uses the existing `AddPlayerBotOperation`, and
  the command server port answers each request on the world thread (5 s timeout)
  instead of reading bots from its own thread. The world thread is recorded in the
  world update hook. Not covered: the whisper `logout` hotfix (mod-playerbots#1838) is a
  re-entrancy problem on the world thread, not a threading one, and the level-reset hook
  is disabled in this realm's config.
- `module/0011-playerbots-shared-tables.patch` — third part, the module's own static tables
  that bots on different map threads write at the same time. Tables filled the first time
  a bot needs them (chat prefixes, unsecured commands, emotes, suggestion factions and
  dungeons, inventory error texts, mail commands, craft skill spells, passive-mode
  allow lists) are filled under `std::call_once`, or built at static initialization where
  the table has no duplicate keys; the per-class trainer cache is filled and copied under
  a mutex, so it still keeps the trainers of the first bot of each class. Lookups that used
  `operator[]` on a shared table and so inserted every missing key (bot texts and their
  chances, class and spec names, mail commands, craft spells, inventory errors, the
  custom-strategy cache) use `find` and take the existing not-found branch. The
  crafting-material cache `IsUsedBySkill` grows at runtime and gets a `std::shared_mutex`,
  and the bot-text locale counters, reset from map threads, become atomics. Table contents
  and lookup results are unchanged. Not covered: `IsUsedBySkill` caches by item only, so
  an item used by any profession counts as used by all of them; that is not a threading
  problem and is left as it is.
- `module/0012-playerbots-shared-runtime-state.patch` — fourth part, the random-bot
  manager state that bot actions write from their map threads. The per-bot event cache
  (spec, price multipliers, trade discounts, randomize/teleport/revive timers), read and
  written by item usage, loot, trade, talent and maintenance actions, gets a mutex; values
  are copied out under it and the database writes stay outside. The battleground queue
  counters the join actions read and increment get a mutex of their own (the world-thread
  `CheckBgQueue` needs none). Battle-master, LFG-dungeon and addclass lookups use `find`
  instead of `operator[]`, which inserted missing keys. The guild cache is written by
  randomization on map threads and is left to the randomization change.
- `module/0013-playerbots-raid-state-lock.patch` — fifth part, the encounter helpers of
  Karazhan, Hyjal, Magtheridon, Tempest Keep, Black Temple, Zul'Aman, Ulduar and Ruby
  Sanctum, which keep per-instance state in 38 unlocked tables shared by every instance
  of the raid. Each of those raids gets a recursive mutex, held for a bot's whole AI update
  on that raid's map and by the three spell listener scripts that write the tables, so
  the 189 places that use them are unchanged. Two instances of the same raid now take
  turns; nothing else ever waits. ICC, SSC, Naxxramas and the Ruby Sanctum instance state
  already had locks and are untouched.
- `module/0014-playerbots-world-thread-group-state.patch` — sixth part, the group, guild and mail
  changes the AI made directly on its map thread rather than through a packet. Raid target icons (96 calls in the
  raid and dungeon strategies), the Razorscale main-tank flags, loot roll votes, guild bank deposits, gathering a
  rated arena team (which regroups, resets and teleports members on other maps) and the mail a bot sends or returns
  to a player go through `PlayerbotWorldThread`, which makes the change right away when no other map can be
  updating, so one map thread behaves as before, and otherwise on the world thread, where the core makes it for a
  client, about 50 ms later. A queued change is applied only if the bot is still in the same group; a queued vote
  is counted only if the bot has not voted on that roll yet, since the bot may decide again before it is counted
  and the core counts every call. Mail is delivered even if the bot logs out first, because the money or items have
  already left it. Channel and guild chat only read the member lists, and leaving a group already queues
  `CMSG_GROUP_DISBAND`, so they are unchanged.
- `module/0015-playerbots-randomize-world-state.patch` — seventh part, the two steps of bot randomization
  that change state shared by every map: unbinding the bot's instances and putting it in a guild (which also fills
  the bot guild cache). Randomizing is reached from the random-bot update on the world thread, from the bot's own
  AI, from the level-up hook and from GM commands; when it runs on a map thread while other maps may be updating,
  those two steps go to the world thread, a moment after the rest. The rest of randomization, refreshing, reviving
  and the random teleports only touch the bot itself, or queue packets and take locks already. Arena teams were
  already assigned on the world thread.
- `module/0018-playerbots-base-map-lookups.patch` — eighth part, the module's own map lookups.
  `FindMap(id, 0)` on an instanceable map looks instance 0 up in that map's instance table, which a
  map thread erases from when an instance unloads, without a lock. Instance IDs start at 1, so the
  lookup always came back empty; `FindBaseNonInstanceMap` returns the same results without reading
  that table. Used for `WorldPosition::getMap` and the four direct lookups. `getMap` passed
  `getInstanceId()`, which is the base map's ID 0, so it never reached an instance either.

The patches are deliberately left uncommitted in the build tree, so the revision
banner keeps the `+` suffix that marks a patched build.

## Keeping the workflow honest

The cmake flags in `build-macos.yml` mirror the ones the local build used. If
either side changes, change both — a silent divergence shows up as behaviour
that only reproduces on one of the two builds.
