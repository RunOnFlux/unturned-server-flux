# unturned-server-flux

The Unturned dedicated server image the [Flux](https://runonflux.io/) marketplace deploys:
`runonflux/unturned-server-flux`.

It runs the game's native Linux server (Steam app 1110390, "U3DS"), installed and updated with
SteamCMD on every start, under a small supervisor. Written from scratch; same family as
`runonflux/7dtd-server-flux`, `runonflux/vrising-server-flux` and `runonflux/palworld-server-flux`.

## Why it exists

The image the marketplace deployed before (ich777/steamcmd:unturned) could not do what the
marketplace sells:

| | Previous image | This image |
|---|---|---|
| Server name, map, players, password | Only by editing `Commands.dat` by hand: the image passes one launch line, and Unturned takes none of these from the command line | `UNT_*` variables, written into `Commands.dat` every start |
| Game Server Login Token | Nowhere to set it. Without one the server is hidden from the Internet list and **cannot be joined over the Internet** (the server says so at start) | `UNT_GSLT`. A token Steam refuses no longer hangs the server: it restarts without it and says why |
| Port | `GAME_PORT` was appended after the server ID and swallowed into it (folder `Servers/Default -port:27015 -sv`); the server always bound 27015 | `FLUX_PORT`, written as `Port`, so several servers can share an address |
| Saving | None: Unturned has no autosave, and `docker stop` killed the server | `save` every 10 minutes, `shutdown` (save and quit) on stop: 2.4 s, exit 0, measured |
| Console | stdin, which Unturned ignores unless it is a terminal | The server runs in a pseudo-terminal fed by a FIFO; `flux-console <command>` runs a command and prints the answer |
| Workshop | Edit `WorkshopDownloadConfig.json` by hand | `UNT_WORKSHOP_IDS` |
| RocketMod | Downloaded from ci.rocketmod.net on every start, which now serves an HTML page | Not installed |
| Server crashes | The container ends | Restarted in place; the container only ends after 5 crashes in an hour (exit 42) |

## Configuration

| Variable | Default | |
|---|---|---|
| `UNT_NAME` | | `Name`: the name in the server list (50 characters at most) |
| `UNT_MAP` | | `Map`: PEI, Washington, Yukon, Russia, Germany, or a Workshop map by name |
| `UNT_MAX_PLAYERS` | | `MaxPlayers`, 1 to 200 |
| `UNT_PASSWORD` | | `Password`, no spaces. Empty: no password |
| `UNT_GSLT` | | `GSLT`: a Game Server Login Token for **app 304930** from steamcommunity.com/dev/managegameservers. Without one the server cannot be joined over the Internet |
| `UNT_OWNER` | | `Owner`: the SteamID64 that gets admin rights |
| `UNT_PERSPECTIVE` | | `Perspective`: First, Third, Both or Vehicle |
| `UNT_PVE` | | `true`: the `PvE` line (no player damage); `false` removes it |
| `UNT_CHEATS` | | `true`: the `Cheats` line (admins can spawn items); `false` removes it |
| `UNT_WELCOME` | | `Welcome`: the message shown on join |
| `UNT_WORKSHOP_IDS` | | Comma-separated Workshop file IDs, written into `WorkshopDownloadConfig.json`'s `File_IDs`; the server downloads them and their dependencies on start |
| `FLUX_PORT` | `27015` | The FIRST of the two UDP ports the server uses (server list queries); the game uses the next one |
| `FLUX_SERVER_ID` | `Default` | The server's folder under `Servers/` |
| `FLUX_AUTOSAVE_MINUTES` | `10` | Minutes between saves, 0 to turn them off, 120 at most |
| `SKIP_UPDATE` | | `true`: start the installed build without asking Steam |
| `FLUX_STOP_GRACE` | `60` | Seconds a restart may take to save before it is forced |
| `FLUX_RESTART_MAX_ATTEMPTS` / `FLUX_RESTART_WINDOW` | `5` / `3600` | Unplanned restarts allowed per window before the container ends with 42 |

**The environment wins, for the commands it names.** A variable that is set replaces that
command's line in `Commands.dat`; one set to an empty value removes the line; one that is not set
leaves the owner's line alone. Every other line, comments included, is kept.

Everything else (difficulty, loot, the server list's descriptions and icons, scheduled
shutdowns) is the server's own `Config.txt`, which the image never touches.

### The login token

Without `UNT_GSLT` the server logs into Steam anonymously and prints that it "is not visible in
Internet server list" and "cannot be joined over the Internet". Players can still join with the
Server Code it prints, which changes on every start.

A token Steam refuses (mistyped, revoked, expired) makes the real server stop retrying and never
load its map. The supervisor watches for it, remembers the token's fingerprint (never the token)
in `flux/gslt-refused`, and restarts the server without it, with a warning in the log, until
`UNT_GSLT` changes.

## Volumes

| Path | What | On Flux |
|---|---|---|
| `/mnt/unturned/server` | The install, about 2 GB. Disposable: SteamCMD rebuilds it | `ml:` (local, never synced) |
| `/mnt/unturned/data` | The install's `Servers/` folder (a symlink points here): `Default/Server/Commands.dat`, `Default/Config.txt`, the world, `Default/WorkshopDownloadConfig.json`, and `flux/` (our log, a copy of each game log) | primary, `g:` |
| `/mnt/unturned/data/Default/Workshop/Steam` | Workshop downloads. Downloaded again on a new node | `ml:` |

An install that already has servers in its own `Servers/` folder has them moved onto the data
volume once, never over a folder already there.

Ports: `FLUX_PORT` and the one after it, UDP.

## Measured (2026-10-08, Unturned 3.26.3.13, PEI)

- first start on empty volumes: SteamCMD's usual "Missing configuration" on the first attempt,
  installed on the retry; 1.9 GB; map loaded about 90 s after start
- a start with the install present: map loaded in about 20 s; 1.0 to 1.2 GB of memory idle
- `docker stop`: 2.4 s to exit 0, "Saving during server shutdown" in the log
- a fresh node holding only the data volume: up in 94 s, with the world (16 saved vehicles
  loaded), `Commands.dat` and the Workshop item
- `UNT_WORKSHOP_IDS=1753131903` (Hawaii Assets, 73 MB): downloaded and installed on start
- a made-up `UNT_GSLT`: "Successfully set game server login token", then Steam's
  `k_EResultAccountNotFound`; restarted without it and up 31 s after the container started

## Development

```bash
./tests/test-flux.sh
docker build -t unturned-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A push to `main` tests, builds, tests the built image and publishes `:latest`, `:<VERSION>` and
`:<sha>`. A weekly run rebuilds on a patched base. FluxOS's image update service checks every
running app's tag every six hours and soft-redeploys onto a new image (volumes kept), so a
published `:latest` reaches running servers within hours: the image test gate is what stands
between a bad build and every server.

## Versions

- **1.0.0** (2026-10-08): first release.
