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
mkdir -p "${dir}/linux64"
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

export FLUX_SERVER_DIR=/tmp/srv FLUX_DATA_DIR=/tmp/data FLUX_RESTART_BACKOFF=1 FLUX_AUTOSAVE_MINUTES=0
log="${FLUX_SERVER_DIR}/Logs/Server_Default.log"

UNT_NAME='Test Server' UNT_MAX_PLAYERS=12 FLUX_PORT=31000 /opt/flux/flux-entrypoint.sh >/tmp/sup.log 2>&1 &
sup=$!
check "the server comes up under a terminal" "0" "$(status wait_for "grep -q 'Loading level: 100%' ${log}" 20)"
check "Commands.dat is written from the environment" "Name Test Server|MaxPlayers 12|Port 31000|" "$(tr '\n' '|' <"${FLUX_DATA_DIR}/Default/Server/Commands.dat")"
check "Servers/ is the data volume" "${FLUX_DATA_DIR}" "$(readlink "${FLUX_SERVER_DIR}/Servers")"
check "flux-console reaches the console and prints the answer" "0" "$(status grep -q 'Successfully saved the game' <<<"$(flux-console save)")"
check "the log is copied onto the data volume" "0" "$(status wait_for "grep -qh 'Successfully saved' ${FLUX_DATA_DIR}/flux/logs/*-server.log" 5)"

kill -TERM "${sup}"
wait "${sup}"
check "a stop exits 0" "0" "$?"
check "a stop is a save and a shutdown" "0" "$(status grep -q 'Saving during server shutdown' "${log}")"
check "and never a bare signal" "1" "$(status grep -q 'SIGTERM without a save' "${log}")"
check "nothing is left running" "1" "$(status pgrep -f 'Unturned_Headless|tail -n')"

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
