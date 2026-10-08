#!/usr/bin/env python3
"""Writes the environment into the Unturned server's own files, every start.

    flux-config.py commands <Commands.dat>
    flux-config.py workshop <WorkshopDownloadConfig.json>

Commands.dat is one console command per line, run when the server starts (`Name My Server`,
`MaxPlayers 24`, `Cheats`). It is where Unturned takes the server's name, map, player limit,
password, owner, port and Game Server Login Token from: the command line takes none of them
(measured with ich777/steamcmd:unturned: `+port/…` and `+gslt/…` were ignored, and the image's own
`-port:` was swallowed into the server ID).

THE ENVIRONMENT WINS, FOR THE COMMANDS IT NAMES. A variable that is set replaces that command's
line (or adds it); one set to an empty value removes the line; one that is not set leaves the
owner's line alone. Every other line, comments included, is kept as it is. Commands are matched
case-insensitively, as the server reads them.

The Workshop list (UNT_WORKSHOP_IDS, comma separated) is written into File_IDs; every other key
of WorkshopDownloadConfig.json is kept.

Prints one line per change. Exit 0 on success (a file that cannot be edited is left as it is and
reported), 64 for a usage error.
"""
import json
import os
import re
import sys

# Variable -> the command it writes. Values go after the command, on one line.
VALUE_COMMANDS = [
    ('UNT_NAME', 'Name'),
    ('UNT_MAP', 'Map'),
    ('UNT_MAX_PLAYERS', 'MaxPlayers'),
    ('UNT_PASSWORD', 'Password'),
    ('UNT_GSLT', 'GSLT'),
    ('UNT_OWNER', 'Owner'),
    ('UNT_PERSPECTIVE', 'Perspective'),
    ('UNT_WELCOME', 'Welcome'),
    ('UNT_MODE', 'Mode'),
    ('FLUX_PORT', 'Port'),
]
# Variable -> a command that is a switch: the line on its own is "on".
FLAG_COMMANDS = [
    ('UNT_CHEATS', 'Cheats'),
    ('UNT_PVE', 'PvE'),
]

# What a value may be, per command. A value outside these is reported and not written: the server
# would start with a broken setting and nothing would say why.
VALID = {
    'MaxPlayers': lambda v: v.isdigit() and 1 <= int(v) <= 200,
    'Port': lambda v: v.isdigit() and 1024 <= int(v) <= 65534,
    'GSLT': lambda v: re.fullmatch(r'[0-9A-Fa-f]{32}', v) is not None,
    'Owner': lambda v: re.fullmatch(r'7656\d{13}', v) is not None,
    'Perspective': lambda v: v.lower() in ('first', 'third', 'both', 'vehicle'),
    # The difficulty: which column of Config.txt's defaults (Easy / Normal / Hard) applies.
    'Mode': lambda v: v.lower() in ('easy', 'normal', 'hard'),
    'Map': lambda v: len(v) <= 64,
    'Name': lambda v: len(v) <= 50,
    'Password': lambda v: ' ' not in v and len(v) <= 64,
    'Welcome': lambda v: len(v) <= 200,
}
# Shown in the log as set, never as their value.
SECRET = {'Password', 'GSLT'}

TRUE = {'1', 'true', 'yes', 'on'}


def one_line(value):
    return ' '.join(str(value).replace('\r', ' ').replace('\n', ' ').split())


def command_of(line):
    """The command a line runs, lower case, or None for a comment or a blank line."""
    text = line.strip()
    if not text or text.startswith('//'):
        return None
    return text.split()[0].lower()


def apply_commands(text, env):
    """Returns (new text, list of change descriptions)."""
    lines = text.splitlines()
    changes = []
    wanted = {}  # command (lower) -> the line to write, or None to remove
    names = {}
    for var, cmd in VALUE_COMMANDS:
        if var not in env:
            continue
        value = one_line(env[var])
        names[cmd.lower()] = cmd
        if value == '':
            wanted[cmd.lower()] = None
            continue
        check = VALID.get(cmd)
        if check and not check(value):
            changes.append(f'WARN {var} is not a valid {cmd}; left as it was')
            continue
        wanted[cmd.lower()] = f'{cmd} {value}'
    for var, cmd in FLAG_COMMANDS:
        if var not in env or env[var].strip() == '':
            continue
        names[cmd.lower()] = cmd
        wanted[cmd.lower()] = cmd if env[var].strip().lower() in TRUE else None

    out = []
    done = set()
    for line in lines:
        cmd = command_of(line)
        if cmd in wanted:
            if cmd in done:
                # A second line for the same command: the server would run both, last one wins.
                changes.append(f'removed a second {names[cmd]} line')
                continue
            done.add(cmd)
            new = wanted[cmd]
            if new is None:
                changes.append(f'{names[cmd]} removed')
                continue
            if line.strip() != new:
                changes.append(f'{names[cmd]} set' if names[cmd] in SECRET else f'{new}')
            out.append(new)
        else:
            out.append(line)
    for cmd, new in wanted.items():
        if cmd in done or new is None:
            continue
        out.append(new)
        changes.append(f'{names[cmd]} set' if names[cmd] in SECRET else f'{new}')
    return '\n'.join(out) + '\n', changes


def parse_ids(value):
    """'1753134636, 1702240229' -> [1753134636, 1702240229]. Raises ValueError on anything else."""
    ids = []
    for part in str(value).split(','):
        part = part.strip()
        if not part:
            continue
        if not re.fullmatch(r'\d{1,20}', part):
            raise ValueError(part)
        if int(part) not in ids:
            ids.append(int(part))
    return ids


def apply_workshop(text, env):
    if 'UNT_WORKSHOP_IDS' not in env:
        return None, []
    try:
        ids = parse_ids(env['UNT_WORKSHOP_IDS'])
    except ValueError as bad:
        return None, [f'WARN UNT_WORKSHOP_IDS has an entry that is not a Workshop ID ({bad}); left as it was']
    try:
        data = json.loads(text.lstrip('﻿')) if text.strip() else {}
        if not isinstance(data, dict):
            raise ValueError('not an object')
    except ValueError:
        return None, ['WARN WorkshopDownloadConfig.json is not valid JSON; left as it was']
    if data.get('File_IDs') == ids:
        return None, []
    data['File_IDs'] = ids
    return json.dumps(data, indent=2) + '\n', [f'Workshop File_IDs: {", ".join(map(str, ids)) or "none"}']


def main(argv):
    if len(argv) != 3 or argv[1] not in ('commands', 'workshop'):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 64
    path = argv[2]
    try:
        with open(path, encoding='utf-8-sig') as f:
            text = f.read()
    except FileNotFoundError:
        text = ''
    if argv[1] == 'commands':
        new, changes = apply_commands(text, os.environ)
    else:
        new, changes = apply_workshop(text, os.environ)
    if new is not None and new != text:
        os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
        tmp = f'{path}.flux-tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(new)
        os.replace(tmp, path)
    for change in changes:
        print(change)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
