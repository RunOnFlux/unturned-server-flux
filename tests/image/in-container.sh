#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
set -uo pipefail
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
# Waits up to $2 seconds for the command in $1 to succeed.
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill script mkfifo timeout sha256sum tail tee; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-console is on the PATH" "0" "$(status command -v flux-console)"
check "flux-config.py starts (usage)" "64" "$(status python3 /opt/flux/flux-config.py)"
for script in flux-entrypoint.sh flux-console.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" a server that behaves like Unturned where it matters: it only reads its
# console from a TERMINAL (the reason the image runs it under `script`), answers `save`, and
# saves and quits on `shutdown`; everything goes to Logs/Server_<id>.log. With the GSLT line set
# to the made-up token REFUSED, it logs Steam's refusal and hangs, as the real one does.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/linux64" "${dir}/Extras/Rocket.Unturned"
echo module >"${dir}/Extras/Rocket.Unturned/Rocket.Unturned.module"
cat >"${dir}/Unturned_Headless.x86_64" <<'GAME'
#!/bin/bash
id="${@: -1}"; id="${id#+InternetServer/}"
log="Logs/Server_${id}.log"
mkdir -p Logs
say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"${log}"; }
dat="Servers/${id}/Server/Commands.dat"
say "Commands.dat: $(tr '\n' '|' <"${dat}")"
if grep -qx 'GSLT 0*REFUSED0*' "${dat}" 2>/dev/null || grep -q '^GSLT AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "${dat}"; then
  say "Failed to connect to Steam servers because k_EResultAccountNotFound, no longer retrying"
  sleep 1000 & wait
fi
if grep -q '^GSLT BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' "${dat}"; then
  say "Failed to connect to Steam servers because k_EResultNoConnection, still retrying"
  say "Failed to connect to Steam servers because k_EResultNoConnection, no longer retrying"
  sleep 1000 & wait
fi
if [ ! -t 0 ]; then
  say "console is not a terminal"
  sleep 1000 & wait
fi
say "Loading level: 100%"
trap 'say "SIGTERM without a save"; exit 143' TERM
while IFS= read -r line; do
  case "${line,,}" in
    save) say "Successfully saved the game." ;;
    shutdown) say "Saving during server shutdown"; say "Quit game: server shutdown"; exit 0 ;;
    *) say "Unable to match \"${line}\" with any built-in commands" ;;
  esac
done
GAME
chmod +x "${dir}/Unturned_Headless.x86_64"
STUB
chmod +x /usr/local/bin/steamcmd

export FLUX_SERVER_DIR=/tmp/srv FLUX_DATA_DIR=/tmp/data FLUX_RESTART_BACKOFF=1 FLUX_AUTOSAVE_MINUTES=0 FLUX_STOP_GRACE=3
log="${FLUX_SERVER_DIR}/Logs/Server_Default.log"

UNT_NAME='Test Server' UNT_MAX_PLAYERS=12 FLUX_PORT=31000 /opt/flux/flux-entrypoint.sh >/tmp/sup.log 2>&1 &
sup=$!
check "the server comes up under a terminal" "0" "$(status wait_for "grep -q 'Loading level: 100%' ${log}" 20)"
check "Commands.dat is written from the environment" "Name Test Server|MaxPlayers 12|Port 31000|" "$(tr '\n' '|' <"${FLUX_DATA_DIR}/Default/Server/Commands.dat")"
check "Servers/ is the data volume" "${FLUX_DATA_DIR}" "$(readlink "${FLUX_SERVER_DIR}/Servers")"
check "flux-console reaches the console and prints the answer" "0" "$(status grep -q 'Successfully saved the game' <<<"$(flux-console save)")"
check "Ctrl-C typed into the console never reaches the server" "0" "$(status grep -q 'Successfully saved the game' <<<"$(flux-console $'sa\x03ve')")"
check "the server is still the same one" "1" "$(status grep -q 'Application quitting' "${log}")"
check "a first start writes Enable_Update_Shutdown" "0" "$(status grep -q 'Enable_Update_Shutdown True' "${FLUX_DATA_DIR}/Default/Config.txt")"
check "the log is copied onto the data volume" "0" "$(status wait_for "grep -qh 'Successfully saved' ${FLUX_DATA_DIR}/flux/logs/*-server.log" 5)"

kill -TERM "${sup}"
wait "${sup}"
check "a stop exits 0" "0" "$?"
check "a stop is a save and a shutdown" "0" "$(status grep -q 'Saving during server shutdown' "${log}")"
check "and never a bare signal" "1" "$(status grep -q 'SIGTERM without a save' "${log}")"
check "nothing is left running" "1" "$(status pgrep -f 'Unturned_Headless|tail -n')"

# Rocket on: copied into Modules/ from the game's Extras/, a Plugins folder on the data volume,
# and a backup of the world from the previous run.
rm -f "${log}"
UNT_ROCKETMOD=true /opt/flux/flux-entrypoint.sh >/tmp/sup3.log 2>&1 &
sup=$!
check "Rocket on comes up" "0" "$(status wait_for "grep -q 'Loading level: 100%' ${log}" 20)"
check "Rocket is in Modules/" "0" "$(status test -f "${FLUX_SERVER_DIR}/Modules/Rocket.Unturned/Rocket.Unturned.module")"
check "plugins go on the data volume" "0" "$(status test -d "${FLUX_DATA_DIR}/Default/Rocket/Plugins")"
check "a start backs the world up" "1" "$(find "${FLUX_DATA_DIR}/flux/backups" -name '*-Default.tar.gz' 2>/dev/null | wc -l)"
check "the backup holds the server's files" "0" "$(status tar -tzf "$(find "${FLUX_DATA_DIR}/flux/backups" -name '*-Default.tar.gz' | head -1)" Default/Server/Commands.dat)"
kill -TERM "${sup}"
wait "${sup}"
rm -f "${log}"
UNT_ROCKETMOD=false FLUX_BACKUP_KEEP=1 /opt/flux/flux-entrypoint.sh >/tmp/sup4.log 2>&1 &
sup=$!
check "Rocket off comes up" "0" "$(status wait_for "grep -q 'Loading level: 100%' ${log}" 20)"
check "Rocket is out of Modules/" "1" "$(status test -e "${FLUX_SERVER_DIR}/Modules/Rocket.Unturned")"
check "the plugins folder is kept" "0" "$(status test -d "${FLUX_DATA_DIR}/Default/Rocket/Plugins")"
check "only FLUX_BACKUP_KEEP backups are kept" "1" "$(find "${FLUX_DATA_DIR}/flux/backups" -name '*-Default.tar.gz' 2>/dev/null | wc -l)"
kill -TERM "${sup}"
wait "${sup}"

# Steam unreachable: the server gives up, so it is restarted, but the token is KEPT (not a refusal).
rm -rf "${FLUX_SERVER_DIR}" "${FLUX_DATA_DIR}"
UNT_GSLT=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB /opt/flux/flux-entrypoint.sh >/tmp/sup5.log 2>&1 &
sup=$!
check "Steam unreachable restarts the server" "0" "$(status wait_for "grep -q 'gave up reaching Steam' /tmp/sup5.log" 30)"
check "the token is not remembered as refused" "1" "$(status test -e "${FLUX_DATA_DIR}/flux/gslt-refused")"
check "the GSLT line stays" "0" "$(status wait_for "grep -q '^GSLT BBBB' ${FLUX_DATA_DIR}/Default/Server/Commands.dat" 5)"
kill -TERM "${sup}"
wait "${sup}"

# A refused login token: the server never loads, so the supervisor restarts it without the token,
# and keeps it out until the token changes.
rm -rf "${FLUX_SERVER_DIR}" "${FLUX_DATA_DIR}"
UNT_GSLT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA /opt/flux/flux-entrypoint.sh >/tmp/sup2.log 2>&1 &
sup=$!
check "after a refused token the server comes up without it" "0" "$(status wait_for "grep -q 'Loading level: 100%' ${log} 2>/dev/null" 30)"
check "the GSLT line is gone" "1" "$(status grep -q '^GSLT' "${FLUX_DATA_DIR}/Default/Server/Commands.dat")"
check "the refusal is remembered, not the token" "1" "$(status grep -rq AAAAAAAA "${FLUX_DATA_DIR}/flux/gslt-refused")"
check "and the log says why" "0" "$(status grep -q 'Steam refused' /tmp/sup2.log)"
kill -TERM "${sup}"
wait "${sup}"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
