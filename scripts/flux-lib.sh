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
# Held by flux-console for a whole command and its answer, so two answers never mix.
FLUX_CONSOLE_LOCK="${FLUX_CONSOLE_LOCK:-/tmp/flux-console.lock}"
# The fingerprint of a login token Steam refused, so the next start leaves it out.
FLUX_GSLT_REFUSED="${FLUX_GSLT_REFUSED:-${FLUX_DATA_DIR}/flux/gslt-refused}"
# The world backups (flux-entrypoint.sh backup_world).
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_DATA_DIR}/flux/backups}"

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

# Steam results that say "could not reach Steam", not "Steam refused the token". The server logs
# them with "still retrying" while it keeps trying (measured with --network none:
# "k_EResultNoConnection, still retrying"); if it ever gives up on one, the token is still good.
FLUX_STEAM_TRANSIENT='NoConnection|ServiceUnavailable|Timeout|TryAnotherCM|Busy|Pending|RateLimitExceeded|ConnectFailed|IOFailure|RemoteDisconnect|Fail'

# $1 = a line of the game log. True when Steam REFUSED the server's login token (invalid, revoked,
# expired): the server stops retrying and never loads its map. Measured with a made-up token:
# "Failed to connect to Steam servers because k_EResultAccountNotFound, no longer retrying".
# A line that is still retrying, or names a result that only means Steam was unreachable, is not
# a refusal: remembering the token as refused then would hide a server with a valid token.
flux_login_refused() {
  [[ "$1" == *"Failed to connect to Steam servers because"*"no longer retrying"* ]] || return 1
  ! [[ "$1" =~ k_EResult(${FLUX_STEAM_TRANSIENT}), ]]
}

# $1 = a line of the game log. True when the server gave up on Steam for a reason that is NOT the
# token (Steam unreachable): worth a restart, never worth dropping the token.
flux_login_gave_up() {
  [[ "$1" == *"Failed to connect to Steam servers because"*"no longer retrying"* ]] && ! flux_login_refused "$1"
}

# $1 = a line of the game log. True once the map has loaded: from then on the login is done, and a
# Steam connection lost later is the server's to retry, never a reason to restart it.
flux_level_loaded() {
  [[ "$1" == *"Loading level: 100%"* ]]
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

# $1 = Commands.dat, $2 = a command. Prints that command's value (the rest of its line), or
# nothing. Matched case-insensitively, as the server reads it.
flux_dat_value() {
  [ -f "$1" ] || return 0
  awk -v want="${2,,}" 'tolower($1) == want { sub(/^[ \t]*[^ \t]+[ \t]*/, ""); sub(/\r$/, ""); print; exit }' "$1"
}

# The game's own log, rewritten by the server on every start.
flux_game_log() {
  printf '%s' "${FLUX_SERVER_DIR}/Logs/Server_${FLUX_SERVER_ID}.log"
}

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# $1 = a console command as given. Prints it as one line with no control characters: it is typed
# into a terminal, where Ctrl-C (\x03) quits the server and Ctrl-\\ (\x1c) kills it without a save
# (both measured). Line breaks become spaces, every other control character is dropped.
flux_console_line() {
  local cmd="${1//[$'\r\n']/ }"
  printf '%s' "${cmd}" | LC_ALL=C tr -d '\000-\037\177'
}

# $1 = one console command. Written into the server's stdin; returns 1 when nothing is reading
# it (no server running), without blocking.
flux_console() {
  local cmd="$1"
  [ -p "${FLUX_CONSOLE_FIFO}" ] || return 1
  [ -n "$(flux_game_pid)" ] || return 1
  cmd="$(flux_console_line "${cmd}")"
  # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
  timeout 2 bash -c 'printf "%s\n" "$1" >"$2"' _ "${cmd}" "${FLUX_CONSOLE_FIFO}"
}
