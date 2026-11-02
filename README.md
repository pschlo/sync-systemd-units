# sync-systemd-units

Keep a machine's own systemd units in one folder, ideally a Git repository, and let one script make systemd match it. Each unit appears in `/etc/systemd/system` as a symlink back to its file, so editing a file edits the live unit, and a plain-text list decides which units start at boot.

## Setup

Clone this repository once per machine, then link the script into a folder that holds your units:

```bash
git clone https://github.com/pschlo/sync-systemd-units.git /opt/sync-systemd-units
ln -s /opt/sync-systemd-units/sync-units.sh /path/to/your/systemd/sync-units.sh
```

The script works on the folder it is called from by path, so `./sync-units.sh` in your folder uses that folder's units. Update the script on a machine with `git -C /opt/sync-systemd-units pull`.

## Layout

```
your-systemd-folder/
├── sync-units.sh        symlink to the clone
├── enabled              which units start at boot
└── units/
    ├── backup/          group folders, named however you like
    │   ├── backup.service
    │   ├── backup.timer
    │   └── backup-run   helper scripts may sit next to their units
    └── web/
        ├── web.target
        ├── web-api.service
        └── web-worker.service
```

- `units/<group>/`: unit files plus any helper scripts they run. Unit names must be unique across groups and must not reuse a packaged unit's name; use a drop-in for those instead.
- `enabled`: one line per unit that can be enabled, active to start at boot or commented out to stay off, optionally with a note. It doubles as the overview of what runs on the machine. The script names units that have no line yet.

```
backup.timer           # nightly backup
web.target             # API and worker
# debug-shell.service  # off unless needed
```

Only entry points can be enabled, and only they go in `enabled`: a timer, not the service it triggers; a target, not the services it pulls in. Units without an `[Install]` section cannot be enabled and never appear there. A target groups services: list them in its `Requires=` or `Wants=` and give each `PartOf=` the target, and starting, stopping or restarting the target does the same to all of them. Template instances such as `worker@1.service` can be listed too.

## What sync-units.sh does

1. Checks names, the `enabled` list and the unit files (`systemd-analyze verify`). It refuses to take over a name in `/etc/systemd/system` that it does not manage, or one that would hide a packaged unit.
2. Removes the links of units deleted from `units/`, stopping them first.
3. Disables and stops units removed from `enabled`.
4. Links every unit file into `/etc/systemd/system` and reloads systemd.
5. Enables and starts units added to `enabled`. Units that were already enabled keep their current running state.

It never restarts a running unit; after editing one, restart it yourself, and the script names the units whose files changed. `--dry-run` prints the plan, or `Already in sync` when there is nothing to do. It needs root, bash and systemd.

## Everyday use

Run the script after every change; nothing runs it automatically. The links stay across reboots, so boot already uses the last synced state, and a timer or file watcher would apply half-finished edits. `--dry-run` doubles as a check that nobody forgot.

- Edit a unit: change the file, run `./sync-units.sh`, then `systemctl restart <unit>` if it is running.
- Add a unit: put the file in a group, add it to `enabled` (commented out if it should stay off), run `./sync-units.sh`.
- Switch a unit off for a while: comment out its line in `enabled`, run `./sync-units.sh`. Uncomment and run again to bring it back.
- Pause until the next reboot: `systemctl stop <unit>`. Re-running the script leaves it stopped.
- Remove a unit: delete its file and its `enabled` line, run `./sync-units.sh`.

Do not run `systemctl disable`, `systemctl mask` or `systemctl edit` on these units. `disable` also deletes the unit's link, so systemd forgets the unit until the next sync re-links it (and re-enables it if it is still listed). `mask` refuses to work on a linked unit, and `edit` writes drop-ins outside your folder, which the script warns about.

## Moving from the earlier copying version

The first version of this script copied units into `/etc/systemd/system` and recorded them in `units.log`. The current version refuses to replace those copies. Delete each file named in `units.log` from `/etc/systemd/system`, move your units into group folders under `units/`, write `enabled`, and run `./sync-units.sh --dry-run` before the real run.
