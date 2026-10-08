#!/bin/bash
# Shared helpers for the Unturned image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes: the install (SteamCMD's, disposable) and the data, which IS the install's
# Servers/ folder (a symlink points there): Commands.dat, Config.txt, the world, the Workshop
# list. The data is the only thing that has to survive.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/unturned/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/unturned/data}"
FLUX_SERVER_ID="${FLUX_SERVER_ID:-Default}"
FLUX_LOG="${FLUX_LOG:-${FLUX_DATA_DIR}/flux/flux.log}"
FLUX_LOG_MAX_LINES="${FLUX_LOG_MAX_LINES:-2000}"
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_DATA_DIR}/flux/logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-Unturned_Headless.x86_64}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-1110390}"
# The server's console is its stdin. The supervisor holds this FIFO open and the server reads it;
# flux-console writes one command into it.
FLUX_CONSOLE_FIFO="${FLUX_CONSOLE_FIFO:-/tmp/flux-console}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# The fingerprint of a login token Steam refused, so the next start leaves it out.
FLUX_GSLT_REFUSED="${FLUX_GSLT_REFUSED:-${FLUX_DATA_DIR}/flux/gslt-refused}"

flux_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_trim_file "${FLUX_LOG}" "${FLUX_LOG_MAX_LINES}"
  fi
}

# Keeps the last $2 lines of $1. Checked cheaply first: most calls change nothing.
flux_trim_file() {
  local file="$1" max="$2" lines
  lines="$(wc -l <"${file}" 2>/dev/null || echo 0)"
  if [ "${lines}" -gt $((max + max / 10)) ]; then
    tail -n "${max}" "${file}" >"${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"
  fi
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Inputs that end up in a path or on the command line.
# ---------------------------------------------------------------------------------------------

# $1 = FLUX_SERVER_ID. The server's folder under Servers/ and its +InternetServer/ argument, so
# one plain word. Returns 1 for anything else.
flux_valid_server_id() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

# $1 = FLUX_PORT. The first of the TWO ports the server uses (the query port; the game is the one
# after it). Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65534 ] || return 1
  printf '%s' "${value}"
}

# $1 = FLUX_AUTOSAVE_MINUTES as given. Prints the minutes between saves, 0 (off) or 1 to 120.
# Unturned has no autosave of its own: what is not saved is lost when the server dies.
flux_autosave_minutes() {
  local value="${1:-10}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=10
  value=$((10#${value}))
  [ "${value}" -gt 120 ] && value=120
  printf '%s' "${value}"
}

# $1 = a Game Server Login Token. Prints a short fingerprint of it, so the supervisor can remember
# that Steam refused THIS token without writing the token itself anywhere.
flux_token_fingerprint() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

# $1 = a line of the game log. True when Steam refused the server's login (a token that is
# invalid, revoked or expired): the server then waits for Steam forever and never loads its map.
# Measured with a made-up token: "Failed to connect to Steam servers because
# k_EResultAccountNotFound, no longer retrying".
flux_login_refused() {
  [[ "$1" == *"Failed to connect to Steam servers because"* ]]
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. A shutdown the server planned itself (its own scheduled
# shutdown, a Workshop or game update it detected) or one asked for through the console is the
# plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Rotation of the game logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

# The game's own log, rewritten by the server on every start.
flux_game_log() {
  printf '%s' "${FLUX_SERVER_DIR}/Logs/Server_${FLUX_SERVER_ID}.log"
}

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# $1 = one console command. Written into the server's stdin; returns 1 when nothing is reading
# it (no server running), without blocking.
flux_console() {
  local cmd="$1"
  [ -p "${FLUX_CONSOLE_FIFO}" ] || return 1
  [ -n "$(flux_game_pid)" ] || return 1
  # One line, no control characters: it is typed into the server's console.
  cmd="${cmd//[$'\r\n']/ }"
  # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
  timeout 2 bash -c 'printf "%s\n" "$1" >"$2"' _ "${cmd}" "${FLUX_CONSOLE_FIFO}"
}
