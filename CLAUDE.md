# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Unturned dedicated server for Flux,
`runonflux/unturned-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's native Linux server, and a
supervisor in bash. Same family as `~/work/7dtd-server-flux`; read it for the patterns this one
follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the game. The game runs as a child so a stop becomes a save, and a
server that ends on its own is followed by the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t unturned-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, `Servers/` linked to the
  data volume, Commands.dat and the Workshop list, then the server in a pseudo-terminal, the log
  follower, the autosaver and the login-token watcher.
- `scripts/flux-config.py`: writes the `UNT_*` variables into Commands.dat and
  WorkshopDownloadConfig.json. The one place the variable-to-command table lives.
- `scripts/flux-console.sh`: `flux-console <command>` on the PATH; types into the console FIFO
  and prints the server's answer from its log.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly.

## Things that will bite you

- **Unturned ignores a console that is not a terminal.** With the FIFO as plain stdin, `save` and
  `shutdown` were silently never run. The server runs under `script -qfec … /dev/null`, which
  gives it a pty; what the pty prints is escape-sequence drawing and goes to /dev/null.
- **The answers to console commands are in the GAME's log**, `<install>/Logs/Server_<id>.log`,
  written a second or more after the command. The server rewrites that file on every start.
- **Unturned takes nothing useful from the command line** except `+InternetServer/<id>`: name,
  port, players, password and GSLT are Commands.dat only. Anything after the server ID on the
  command line is swallowed into it (the previous image's `Default -port:27015 -sv` folder).
- **There is no autosave in Unturned.** The autosaver and the stop path are the only saves.
- **A refused GSLT hangs the server for good** ("no longer retrying", map never loads). The
  watcher in the entrypoint is what turns that into a restart without the token.
- **Flux stops a container with Docker's default 10 seconds.** Console shutdown measured 2.4 s.
- **The unit tests run with the machine's Python, not the image's.** Anything a script newly needs
  gets a check in `tests/image/in-container.sh`.
