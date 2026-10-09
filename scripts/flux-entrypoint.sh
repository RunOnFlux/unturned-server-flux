#!/bin/bash
# PID 1, and the supervisor of the Unturned server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and becomes a save, and a
# server that ends on its own is followed by the next one in place:
#
#   - every start: SteamCMD update, Commands.dat and the Workshop list from the environment
#     (flux-config.py), then the server, with its console on a FIFO the supervisor holds open
#   - while it runs: `save` every FLUX_AUTOSAVE_MINUTES. Unturned has NO autosave of its own: a
#     server that dies loses everything since its last save
#   - SIGTERM/SIGINT from Docker: `shutdown` on the console, which saves and quits
#   - the server ending on its own (its own scheduled or update shutdown, a crash): a new
#     generation in the same container, updated from Steam first
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42 (FluxOS starts it again on the same node, with a fresh budget)
#   - UNT_ROCKETMOD: Rocket (the RocketMod build the game ships in Extras/) copied into Modules/
#     on every start, or taken out; plugins and their settings live on the data volume
#   - a backup of the world on every start and every FLUX_BACKUP_HOURS, the last FLUX_BACKUP_KEEP
#     kept on the data volume (flux/backups)
#
# Same shape as runonflux/7dtd-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. Docker's own deadline on Flux is
# ten seconds, so this only matters for a restart, where nobody is waiting on us.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-60}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-5}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}" "$(dirname "${FLUX_LOG}")" "${FLUX_GAME_LOG_DIR}"

if ! flux_valid_server_id "${FLUX_SERVER_ID}"; then
  flux_log "ERROR FLUX_SERVER_ID='${FLUX_SERVER_ID}' is not one plain word; refusing to start"
  exit 42
fi
if ! port="$(flux_valid_port "${FLUX_PORT:-27015}")"; then
  flux_log "ERROR FLUX_PORT='${FLUX_PORT:-}' is not a port from 1024 to 65534; refusing to start"
  exit 42
fi
export FLUX_PORT="${port}"
autosave="$(flux_autosave_minutes "${FLUX_AUTOSAVE_MINUTES:-10}")"
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, server ${FLUX_SERVER_ID}, ports ${port}-$((port + 1)), autosave ${autosave} min)"
if [ -z "${UNT_GSLT:-}" ]; then
  flux_log "WARN no UNT_GSLT: the server logs into Steam anonymously, is hidden from the Internet list and cannot be joined over the Internet (create a token for app 304930 at steamcommunity.com/dev/managegameservers)"
fi

game_pid=""
tail_pid=""
saver_pid=""
watch_pid=""
backup_pid=""
# The token actually written into Commands.dat this generation ("" when none or when left out).
gslt_in_use=""
terminating=0
generation=0
restart_history=()

# The console: a FIFO the server reads as its stdin. Held open here, read-write, so the server
# never sees end-of-file when a writer (flux-console) closes it.
rm -f "${FLUX_CONSOLE_FIFO}"
mkfifo -m 600 "${FLUX_CONSOLE_FIFO}"
exec 3<>"${FLUX_CONSOLE_FIFO}"

# Asks the running server to save and quit: the console's `shutdown` saves the world first. A
# server that does not honour it is ended by wait_for_generation after FLUX_STOP_GRACE (a signal
# would not save either: Unturned does not save on SIGTERM, measured).
stop_server() {
  [ -n "${game_pid}" ] || return 0
  printf 'shutdown\n' >&3
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: saving the world and shutting down, no restart will follow"
  stop_server
}
trap term_handler TERM INT

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/${FLUX_GAME_PROCESS}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  # No `validate` on the first attempt: it re-hashes the whole install on every start. An install
  # that is actually broken fails the first attempt, and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # shellcheck disable=SC2086  # validate is "" or "validate"
    if steamcmd +force_install_dir "${s}" +login anonymous +app_update "${FLUX_STEAM_APP}" ${validate} +quit; then
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5); retrying in 5s with validate"
    sleep 5
  done
  if [ -x "${s}/${FLUX_GAME_PROCESS}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# The install's Servers/ folder IS the data volume, so the world and the settings live on the one
# volume that survives and is synced, and the install stays disposable.
link_data() {
  local servers="${s}/Servers"
  if [ -L "${servers}" ]; then
    [ "$(readlink "${servers}")" = "${d}" ] && return 0
    rm -f "${servers}"
  elif [ -d "${servers}" ]; then
    # An install that already had servers in it (one that ran before this image): moved onto the
    # data volume once, never overwriting a folder already there.
    local dir
    for dir in "${servers}"/*/; do
      [ -d "${dir}" ] || continue
      if [ ! -e "${d}/$(basename "${dir}")" ] && mv "${dir}" "${d}/"; then
        flux_log "moved $(basename "${dir}") from the install onto the data volume"
      fi
    done
    rm -rf "${servers}"
  fi
  ln -s "${d}" "${servers}"
}

prepare_config() {
  local line dir="${d}/${FLUX_SERVER_ID}" gslt="${UNT_GSLT-}" refused=""
  mkdir -p "${dir}/Server"
  # A token Steam refused on an earlier start is left out (the GSLT line removed) until the owner
  # sets another one: with it, the server would wait for Steam forever and never load.
  [ -f "${FLUX_GSLT_REFUSED}" ] && refused="$(cat "${FLUX_GSLT_REFUSED}" 2>/dev/null)"
  if [ -n "${gslt}" ] && [ "$(flux_token_fingerprint "${gslt}")" = "${refused}" ]; then
    flux_log "WARN Steam refused this UNT_GSLT on an earlier start (invalid, revoked or expired): starting WITHOUT it, so the server runs but is hidden from the Internet list. Set a new token to try again."
    gslt=""
  elif [ -n "${refused}" ]; then
    rm -f "${FLUX_GSLT_REFUSED}"
  fi
  while IFS= read -r line; do
    flux_log "Commands.dat: ${line}"
  done < <(if [ -n "${UNT_GSLT+set}" ]; then export UNT_GSLT="${gslt}"; fi
    python3 /opt/flux/flux-config.py commands "${dir}/Server/Commands.dat" 2>&1)
  gslt_in_use="${gslt}"
  [ -n "${UNT_GSLT+set}" ] || gslt_in_use="$(flux_dat_value "${dir}/Server/Commands.dat" GSLT)"
  while IFS= read -r line; do
    flux_log "Workshop: ${line}"
  done < <(python3 /opt/flux/flux-config.py workshop "${dir}/WorkshopDownloadConfig.json" 2>&1)
  while IFS= read -r line; do
    flux_log "Config.txt: ${line}"
  done < <(python3 /opt/flux/flux-config.py config "${dir}/Config.txt" 2>&1)
  # A file the edit could not parse is still the owner's: the server gets it as it is.
  return 0
}

# ROCKET, the RocketMod build Smartly Dressed Games ships inside the server (Extras/Rocket.Unturned,
# "Legally Distinct Missile"). Unturned loads what is in Modules/, which is in the install (local
# to the node), so it is copied in on every start rather than once: a server moved to a fresh node
# gets it back. Its plugins, their settings and Rocket's own files are in Servers/<id>/Rocket, on
# the data volume. UNT_ROCKETMOD unset leaves Modules/ as it is.
prepare_rocket() {
  local src="${s}/Extras/Rocket.Unturned" dst="${s}/Modules/Rocket.Unturned"
  [ -n "${UNT_ROCKETMOD+set}" ] || return 0
  if flux_truthy "${UNT_ROCKETMOD}"; then
    if [ ! -d "${src}" ]; then
      flux_log "WARN UNT_ROCKETMOD is on but this Unturned build has no Extras/Rocket.Unturned; starting without it"
      return 0
    fi
    mkdir -p "${s}/Modules"
    rm -rf "${dst}.flux-tmp"
    cp -a "${src}" "${dst}.flux-tmp" && rm -rf "${dst}" && mv "${dst}.flux-tmp" "${dst}"
    mkdir -p "${d}/${FLUX_SERVER_ID}/Rocket/Plugins"
    flux_log "Rocket: on (plugins go in Servers/${FLUX_SERVER_ID}/Rocket/Plugins)"
  elif [ -d "${dst}" ]; then
    rm -rf "${dst}"
    flux_log "Rocket: off (removed from Modules/; plugins and their settings are kept on the data volume)"
  fi
}

# A .tar.gz of the server's folder (world, players, settings, Rocket), without the Workshop
# downloads (their own local volume, downloaded again) and without our logs and backups. Written
# beside, then renamed, so a cut-off backup never looks like one. The last FLUX_BACKUP_KEEP are
# kept.
backup_world() {
  local why="$1" dir="${d}/${FLUX_SERVER_ID}" out name
  [ "${FLUX_BACKUP_KEEP}" -gt 0 ] 2>/dev/null || return 0
  [ -d "${dir}" ] || return 0
  [ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 ! -name Workshop -print -quit 2>/dev/null)" ] || return 0
  mkdir -p "${FLUX_BACKUP_DIR}"
  name="$(date -u +%Y%m%d-%H%M%S)-${FLUX_SERVER_ID}.tar.gz"
  out="${FLUX_BACKUP_DIR}/${name}"
  if tar -C "${d}" --exclude="${FLUX_SERVER_ID}/Workshop" -czf "${out}.part" "${FLUX_SERVER_ID}" 2>/dev/null \
    && mv "${out}.part" "${out}"; then
    flux_log "backup (${why}): flux/backups/${name}, $(du -h "${out}" | cut -f1)"
  else
    rm -f "${out}.part"
    flux_log "WARN backup (${why}) failed"
  fi
  flux_prune "${FLUX_BACKUP_DIR}" "*-${FLUX_SERVER_ID}.tar.gz" "${FLUX_BACKUP_KEEP}"
}

# shellcheck disable=SC2329  # run in the background below
# Every FLUX_BACKUP_HOURS: a save first, so the backup holds the world as it is now.
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    flux-console save >/dev/null 2>&1 || continue
    sleep 2
    backup_world "every ${FLUX_BACKUP_HOURS}h"
  done
}

# shellcheck disable=SC2329  # run in the background below
# Watches the game log for Steam refusing the login token. The server never recovers from it on
# its own (it stops retrying and never loads), so the token is remembered as refused and the
# server is restarted without it.
#
# Only the token actually in Commands.dat is watched, only until the map has loaded (a connection
# lost later is the server's to retry), and only a refusal of the TOKEN is remembered: Steam being
# unreachable restarts the server with the token still in place. The server is asked to shut down
# through its console, never signalled: a signal would not save.
login_watch() {
  local line
  [ -n "${gslt_in_use}" ] || exit 0
  while IFS= read -r line; do
    flux_level_loaded "${line}" && exit 0
    if flux_login_refused "${line}"; then
      flux_token_fingerprint "${gslt_in_use}" >"${FLUX_GSLT_REFUSED}"
      printf 'Steam refused the login token (%s)\n' "${line##*because }" >"${FLUX_RESTART_MARKER}"
      flux_log "WARN Steam refused the server's login token: restarting without it until the token changes"
      flux_console shutdown >/dev/null 2>&1
      exit 0
    elif flux_login_gave_up "${line}"; then
      printf 'Steam could not be reached (%s)\n' "${line##*because }" >"${FLUX_RESTART_MARKER}"
      flux_log "WARN the server gave up reaching Steam (not a token problem): restarting it, token kept"
      flux_console shutdown >/dev/null 2>&1
      exit 0
    fi
  done < <(tail -n +1 -F "$(flux_game_log)" 2>/dev/null)
}

# shellcheck disable=SC2329  # run in the background below
autosaver() {
  [ "${autosave}" -gt 0 ] || exit 0
  while true; do
    sleep $((autosave * 60))
    flux-console save >/dev/null 2>&1 && flux_log "autosave: save sent to the console"
  done
}

start_generation() {
  local log_file
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"

  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  link_data
  backup_world "start"
  prepare_config
  prepare_rocket
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  log_file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-server.log"
  : >"${log_file}"
  flux_log "starting the server (generation ${generation}), log ${log_file}"

  # THE GAME'S OWN LOG, Logs/Server_<id>.log in the install: it is where the server writes
  # everything, the answers to console commands included. Followed from its end before the server
  # starts (the server rewrites it), onto the container's output and into a copy on the data
  # volume, which is the one the panel can read and that survives a move.
  mkdir -p "$(dirname "$(flux_game_log)")"
  : >"$(flux_game_log)"
  tail -n 0 -F "$(flux_game_log)" 2>/dev/null | tee -a "${log_file}" &
  tail_pid=$!

  (
    cd "${s}" || exit 1
    # What ServerHelper.sh sets: the bundled 64-bit steamclient.so, and a terminal type.
    export LD_LIBRARY_PATH="${s}/linux64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export TERM=xterm
    # INSIDE A PSEUDO-TERMINAL (`script`). Unturned's console reads from a terminal and silently
    # ignores a stdin that is not one: with the FIFO as plain stdin, `save` and `shutdown` were
    # never run (measured). `script` gives it a terminal and copies the FIFO into it. What the
    # terminal shows is the console's drawing (escape sequences) and goes nowhere: the log
    # above has every line.
    exec script -qfec "./${FLUX_GAME_PROCESS} -batchmode -nographics +InternetServer/${FLUX_SERVER_ID}" /dev/null \
      <"${FLUX_CONSOLE_FIFO}" >/dev/null 2>&1
  ) &
  game_pid=$!

  autosaver &
  saver_pid=$!
  login_watch &
  watch_pid=$!
  backupper &
  backup_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${saver_pid}" "${tail_pid}" "${watch_pid}" "${backup_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  saver_pid="" tail_pid="" watch_pid="" backup_pid=""
  # The tail on the other side of that pipe would otherwise outlive the generation.
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force; the grace runs from when the request was first seen.
wait_for_generation() {
  local asked_at=0 now
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  # Unturned ends with 0 when it shut itself down on purpose (the console's shutdown, its own
  # scheduled shutdown, a Workshop or game update it noticed): that is the plan working.
  if [ -z "${reason}" ] && [ "${rc}" = "0" ]; then
    reason="planned: the server shut itself down (exit 0)"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
