#!/bin/bash
# flux-console <command...>: types one command into the running server's console and prints what
# the server wrote in the next moments.
#
#   flux-console save
#   flux-console players
#   flux-console kick SomePlayer Being rude
#
# The console is the server's stdin (a FIFO the supervisor holds open), and its answer goes to the
# server's own log (Logs/Server_<id>.log), so the answer is read back from there: the lines
# written after the command. The server writes them a second or more later (measured), so this
# waits for the log to grow, up to FLUX_CONSOLE_WAIT seconds (default 3), and then half a second
# more for the rest of the answer.
#
# ONE AT A TIME. The answer is "what the log gained", so two commands in flight at once each print
# both answers (measured: players and save run together). The whole send-and-read holds a lock;
# a second caller waits for it (up to FLUX_CONSOLE_LOCK_WAIT seconds, default 15, then exits 75).
# The autosaver and the backups go through this command too, for the same reason.
#
# Exit 1 when no server is running, 64 without a command, 75 when the console stayed busy.
set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source /opt/flux/flux-lib.sh

[ $# -gt 0 ] || { echo "usage: flux-console <command...>" >&2; exit 64; }

exec 9>"${FLUX_CONSOLE_LOCK}"
if ! flock -w "${FLUX_CONSOLE_LOCK_WAIT:-15}" 9; then
  echo "the console is busy with another command; try again" >&2
  exit 75
fi

log="$(flux_game_log)"
before=0
[ -f "${log}" ] && before="$(wc -c <"${log}")"

if ! flux_console "$*"; then
  echo "no server is running" >&2
  exit 1
fi

waited=0
limit=$(( ${FLUX_CONSOLE_WAIT:-3} * 5 ))
while [ "${waited}" -lt "${limit}" ]; do
  sleep 0.2
  waited=$((waited + 1))
  if [ -f "${log}" ] && [ "$(wc -c <"${log}")" -gt "${before}" ]; then
    sleep 0.5
    break
  fi
done
[ -f "${log}" ] && tail -c +$((before + 1)) "${log}"
exit 0
