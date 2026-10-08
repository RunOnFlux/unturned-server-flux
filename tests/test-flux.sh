#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and the Commands.dat / Workshop editor. No
# Docker, no Steam, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# cfg VAR=value... <mode> <file>: the editor with exactly these variables in its environment.
cfg() {
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" "${vars[@]}" python3 scripts/flux-config.py "$@"
}

# --- Inputs ------------------------------------------------------------------------------------
check "Default is a server id" "0" "$(status flux_valid_server_id Default)"
check "a server id with a space is refused" "1" "$(status flux_valid_server_id 'Default -port:27015 -sv')"
check "a server id with a slash is refused" "1" "$(status flux_valid_server_id 'a/b')"
check "27015 is a port" "27015" "$(flux_valid_port 27015)"
check "a leading zero is not octal" "27015" "$(flux_valid_port 027015 2>/dev/null || flux_valid_port 27015)"
check "port 80 is refused" "1" "$(status flux_valid_port 80)"
check "port 65535 is refused (the game port is the next one)" "1" "$(status flux_valid_port 65535)"
check "a word is not a port" "1" "$(status flux_valid_port abc)"
check "autosave defaults to 10" "10" "$(flux_autosave_minutes '')"
check "autosave off" "0" "$(flux_autosave_minutes 0)"
check "autosave capped at 120" "120" "$(flux_autosave_minutes 999)"
check "autosave 08 is not octal" "8" "$(flux_autosave_minutes 08)"
check "autosave junk is 10" "10" "$(flux_autosave_minutes often)"

# --- Restarts ----------------------------------------------------------------------------------
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a planned shutdown is not counted" "1" "$(status flux_restart_counts 'planned: the server shut itself down (exit 0)')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "keeps the newest" $'c\nd' "$(flux_files_to_prune 2 a b c d)"

# --- The login token ---------------------------------------------------------------------------
check "the fingerprint is stable" "$(flux_token_fingerprint ABC)" "$(flux_token_fingerprint ABC)"
check "the fingerprint is not the token" "1" "$(status test "$(flux_token_fingerprint ABC)" = ABC)"
check "a refused login is seen" "0" "$(status flux_login_refused '[2026-10-08 17:47:32] Failed to connect to Steam servers because k_EResultAccountNotFound, no longer retrying')"
check "an anonymous start is not a refusal" "1" "$(status flux_login_refused 'Steam Game Server Login Token (GSLT) not set')"

# --- Commands.dat ------------------------------------------------------------------------------
dat="${tmp}/Commands.dat"
cfg UNT_NAME='My Server' UNT_MAX_PLAYERS=24 UNT_PVE=true FLUX_PORT=27015 commands "${dat}" >/dev/null
check "an empty file gets the commands" $'Name My Server\nMaxPlayers 24\nPort 27015\nPvE' "$(cat "${dat}")"

printf '// my notes\nname Old Name\nCheats\nMap Washington\nWelcome Hi\n' >"${dat}"
out="$(cfg UNT_NAME='New Name' UNT_CHEATS=false UNT_GSLT=0123456789abcdef0123456789ABCDEF commands "${dat}")"
check "set lines replace in place, any case; a false flag is removed; unset ones stay" \
  $'// my notes\nName New Name\nMap Washington\nWelcome Hi\nGSLT 0123456789abcdef0123456789ABCDEF' "$(cat "${dat}")"
check "the token is never printed" "1" "$(status grep -q 0123456789abcdef <<<"${out}")"

cfg UNT_WELCOME= UNT_MAP= commands "${dat}" >/dev/null
check "an empty value removes the line" $'// my notes\nName New Name\nGSLT 0123456789abcdef0123456789ABCDEF' "$(cat "${dat}")"

printf 'MaxPlayers 10\nMaxPlayers 12\n' >"${dat}"
cfg UNT_MAX_PLAYERS=16 commands "${dat}" >/dev/null
check "a duplicate line is dropped" "MaxPlayers 16" "$(cat "${dat}")"

printf 'MaxPlayers 10\n' >"${dat}"
out="$(cfg UNT_MAX_PLAYERS=500 UNT_GSLT=short UNT_OWNER=123 UNT_PERSPECTIVE=Sideways commands "${dat}")"
check "invalid values are not written" "MaxPlayers 10" "$(cat "${dat}")"
check "and each is reported" "4" "$(grep -c '^WARN' <<<"${out}")"

cfg UNT_NAME=$'Two\nLines' commands "${dat}" >/dev/null
check "a value is one line" $'MaxPlayers 10\nName Two Lines' "$(cat "${dat}")"

printf '' >"${dat}"
cfg UNT_MODE=Hard commands "${dat}" >/dev/null
check "the difficulty is the Mode command" "Mode Hard" "$(cat "${dat}")"
out="$(cfg UNT_MODE=Insane commands "${dat}")"
check "an unknown difficulty is not written" "Mode Hard" "$(cat "${dat}")"

check "usage" "64" "$(status python3 scripts/flux-config.py)"

# --- WorkshopDownloadConfig.json ---------------------------------------------------------------
ws="${tmp}/WorkshopDownloadConfig.json"
cp tests/fixtures/WorkshopDownloadConfig.json "${ws}"
cfg UNT_WORKSHOP_IDS=' 1753134636, 1702240229,1753134636 ' workshop "${ws}" >/dev/null
check "ids are written, deduplicated" "[1753134636, 1702240229]" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["File_IDs"])' "${ws}")"
check "the other keys are kept" "600" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Shutdown_Update_Detected_Timer"])' "${ws}")"
before="$(cat "${ws}")"
out="$(cfg UNT_WORKSHOP_IDS='123,abc' workshop "${ws}")"
check "a bad id leaves the file alone" "${before}" "$(cat "${ws}")"
check "and says so" "0" "$(status grep -q WARN <<<"${out}")"
cfg workshop "${ws}" >/dev/null
check "unset leaves the file alone" "${before}" "$(cat "${ws}")"
cfg UNT_WORKSHOP_IDS= workshop "${ws}" >/dev/null
check "empty clears the list" "[]" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["File_IDs"])' "${ws}")"
rm -f "${ws}"
cfg UNT_WORKSHOP_IDS=42 workshop "${ws}" >/dev/null
check "a missing file is created" "[42]" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["File_IDs"])' "${ws}")"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
