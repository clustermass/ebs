# EBS — ESXi Backup Service

> A lightweight, offline ESXi-to-Synology OVF backup service for homelabs and
> small environments.

EBS is a Bash service that exports VMware ESXi virtual machines to SMB/CIFS
storage. It schedules full backups, manages Synology NAS power, safely stops and
restores VMs, and preserves the previous backup until its replacement succeeds.

It is intended for standalone or lightly managed ESXi hosts where temporary VM
downtime is acceptable and a straightforward NAS-backed workflow is preferable
to a larger commercial backup platform.

See [INSTALLATION.md](INSTALLATION.md) for the tested deployment walkthrough and
[DESCRIPTION.md](DESCRIPTION.md) for architecture, file responsibilities, and
review notes.

## Limitations

- Backups require VM downtime; EBS powers down running VMs during export.
- Backups are complete OVF exports, not incremental or snapshot-based backups.
- ESXi and NAS credentials are stored locally in plaintext `config.json`. The
  file is ignored by Git and should remain restricted to mode `600`.
- VM discovery uses command-output parsing and substring matching. Avoid spaces,
  brackets, unusual encodings, and overlapping names such as `Test` and `Test2`.
- The scheduler requires an exact local-time `HH:MM` match. Downtime during that
  minute causes the day's trigger to be missed.
- A failed VM is excluded until an operator investigates and removes its error
  file; there is no automatic retry policy.
- A suspended VM skipped with `suppressErrorIfSuspended: "y"` remains due, but
  it is reconsidered only at the next scheduled trigger—not immediately when
  the VM is resumed.
- `report_error.sh` is a placeholder. There are no built-in email, webhook, or
  centralized monitoring notifications.
- Compatibility has been tested with specific ESXi, DSM, and OVF Tool versions
  documented in `INSTALLATION.md`; other versions require validation.
- Attached CD/DVD or floppy media must remain accessible to ESXi during export.
  Disconnect stale ISO or device mappings that OVF Tool cannot read.
- Restoration must be tested independently. A completed export is not proof of
  a recoverable backup.

## Capabilities

- Schedule backups at a preferred daily start time.
- Run the normal due-VM check immediately with `--run-now`.
- Select specific VMs interactively with `-m` and stream detailed output.
- Give each VM an independent backup interval, in hours.
- Manage multiple ESXi hosts and NAS shares from one configuration.
- Wake and optionally shut down Synology NAS devices.
- Mount CIFS destinations only while they are needed.
- Retry CIFS mounting while a newly started NAS finishes initializing SMB.
- Gracefully stop VMs, with a hard power-off fallback when VMware Tools fails.
- Export complete VMs in OVF format with a locally installed VMware OVF Tool.
- Stage exports locally or directly on the NAS.
- Restore a VM to its original powered-on state.
- Keep the last stable backup if export or VM restart fails.
- Record successful and failed backup history.
- Prevent overlapping scheduled and manual coordinators with an instance lock.

## Backup lifecycle

At the configured start minute, `ebs.sh` finds machines whose `backupPeriod` has
elapsed and processes them sequentially:

1. Confirm that the ESXi host is reachable.
2. Wake the configured NAS when `powerOn` is enabled.
3. Mount its CIFS share at `mount/backupDestination`, retrying up to five times
   at 30-second intervals while SMB becomes ready.
4. Find the VM and record its initial power state.
5. Stop the VM if it is running.
6. Export it to a staging directory named `___VM_NAME`.
7. Move local staging data to the NAS when temporary storage is enabled.
8. Restart the VM if it was originally running.
9. Replace `VM_NAME` with the completed staging directory.
10. Record the result, unmount the share, and continue.

The old stable backup is removed only after the new export exists and a VM that
was originally running has restarted successfully. After the original power
state is known, failures or interruptions in later stages attempt to restore a
VM that began powered on.

## Operational gotchas

- Remove unneeded ISO/floppy backing from virtual CD/DVD and floppy devices
  before export. A device shown as disconnected may still cause OVF Tool to
  retrieve its backing image; an inaccessible image produces errors such as
  `Failed to open file stream: .../VM-0.iso`. Behavior can differ by ESXi
  version.
- A Synology NAS may answer ping before DSM's SMB service is ready. EBS retries
  CIFS mounting five times with a 30-second interval; very slow systems may
  require larger `CIFS_MOUNT_ATTEMPTS` or `CIFS_MOUNT_RETRY_INTERVAL` values in
  `ebs.sh`.
- ESXi exposes separate SSH host keys for different algorithms. After an ESXi
  upgrade, reinstall, SSH change, or configuration replacement, verify keys
  again with `setup_utils/update_esxi_host_keys.sh`, then run
  `setup_utils/test_esxi_servers.sh`.
- Stop `ebs.service` before using `--run-now` or `-m`; the service owns
  `process.lock` while running.
- A failed VM stays excluded until its exact file under `excluded_machines` is
  reviewed and removed.

## Requirements

EBS targets Linux with Bash and systemd. It uses:

- Bundled `jq` (`bin/jq-linux64`)
- VMware OVF Tool, installed separately at `bin/ovftool/ovftool` under
  VMware/Broadcom's license
- `plink` from `putty-tools`
- OpenSSH (`ssh`, `ssh-keyscan`, and `ssh-keygen`)
- `sshpass` and `wakeonlan`
- `mount.cifs`, `mountpoint`, and `umount`
- `ping`, `timeout`, `ex`, `awk`, and standard GNU utilities

The service account must be able to mount and unmount CIFS shares without an
interactive prompt. Grant only narrowly scoped sudo permissions for this.

## Configuration

Copy the tracked, credential-free example to create the active configuration:

```bash
cp config.example.json config.json
chmod 600 config.json
```

Then edit `config.json` for the deployment. Its structure is:

```json
{
  "commonConfig": {
    "prefferedBackupStartTime": "22:35",
    "tempBackupStoragePath": "/srv/ebs-staging"
  },
  "machines": [
    {
      "name": "ExampleVM",
      "backupPeriod": 24,
      "esxiServer": "esxi-1",
      "dataStoreName": "Datastore",
      "backupServer": "nas-share-1",
      "useTempBackupStorage": "y",
      "suppressErrorIfSuspended": "n"
    }
  ],
  "esxiServers": [
    {
      "name": "esxi-1",
      "ip": "192.0.2.10",
      "login": "backup-user",
      "password": "REPLACE_ME",
      "esxiHostKey": "SHA256:REPLACE_ME"
    }
  ],
  "backupServers": [
    {
      "name": "nas-share-1",
      "ip": "192.0.2.20",
      "login": "backup-user",
      "password": "REPLACE_ME",
      "sharePath": "backups",
      "mac": "00:11:22:33:44:55",
      "broadcastIp": "192.0.2.255",
      "powerOff": "y",
      "powerOn": "y"
    }
  ]
}
```

Configuration notes:

- `prefferedBackupStartTime` is intentionally spelled this way in the code. It
  is an `HH:MM` value in the server's local time.
- `backupPeriod` is measured in hours.
- `esxiServer` and `backupServer` refer to matching `name` fields.
- `useTempBackupStorage: "y"` exports locally before moving to the NAS. The
  temporary path needs space for a complete VM.
- `suppressErrorIfSuspended: "y"` skips suspended VMs without changing their
  last successful-backup timestamp or excluding them. They remain due for the
  next scheduled trigger. With `"n"`, suspension is recorded as a failure.
- Multiple logical shares may use one NAS IP; shutdown is deduplicated by IP.
- Generate one `esxiHostKey` with
  `./setup_utils/get_server_signature.sh ESXI_HOST`. Verify the
  fingerprint through a trusted channel before saving it.

`config.json` stores plaintext credentials and is ignored by Git. Restrict it to
the service user (normally mode `600`), never publish it, and rotate exposed
credentials.

## Installation

1. Install the required system packages.
2. Copy EBS into the intended service directory, such as `/home/ebs/service`.
3. Create the `ebs` service user and group if needed.
4. Copy `config.example.json` to `config.json`, then edit and secure it.
5. Make the required files executable:

   ```bash
   bash setup_utils/setup_permissions.sh
   ```

6. Install VMware OVF Tool at `bin/ovftool/ovftool`, and confirm that it runs on
   the target host.
7. Install the path-aware systemd unit and scoped CIFS permissions, then start
   the service:

   ```bash
   bash setup_utils/install_systemd_service.sh
   sudo systemctl start ebs.service
   ```

8. Monitor it:

   ```bash
   systemctl status ebs.service
   journalctl -u ebs.service -f
   tail -f ebs.log
   ```

EBS reads `config.json` relative to its working directory. Bundled executable
paths are resolved from the EBS installation directory.

## Running backups

The systemd service runs `ebs.sh` without options. It remains active, checks the
server's local time, and starts all due VMs at `prefferedBackupStartTime`.

To perform the same due-machine check immediately instead of waiting for that
time, stop the continuously running service, use `--run-now`, and start the
service again:

```bash
sudo systemctl stop ebs.service
./ebs.sh --run-now
sudo systemctl start ebs.service
```

`--run-now` processes only VMs whose `backupPeriod` has elapsed, exactly as the
scheduled trigger does. Normal coordinator and per-machine logs are retained.

For an interactive backup, use manual mode:

```bash
sudo systemctl stop ebs.service
./ebs.sh -m
sudo systemctl start ebs.service
```

Manual mode prints a numbered table of every configured VM. Enter one or more
numbers separated by commas, such as `1,4,5,17`. The selected VMs are processed
immediately regardless of their configured interval or exclusion status.
Coordinator and detailed machine output is streamed to the terminal instead of
`ebs.log` and `temp_process_machine.log`. Successful and failed results still
update `processed_machines` and `excluded_machines`, because those files are
scheduler and safety state.

Only one EBS coordinator may run at a time. Every mode atomically creates
`process.lock` with its PID, start epoch, and mode. A graceful exit or systemd
stop removes it; the unit's `ExecStopPost` also removes a leftover lock after
the service terminates. If EBS finds a lock owned by a live process, it exits
without starting a backup; a lock belonging to a dead PID is identified and
removed as stale. The running systemd service therefore must be stopped before
either one-shot command is used.

## Runtime state and recovery

- `processed_machines/VM_NAME.log` begins with the epoch time of the latest
  successful backup. This timestamp drives scheduling.
- `excluded_machines/VM_NAME.err` records a failure and prevents that VM from
  being scheduled again.
- `ebs.log` contains coordinator activity.
- `temp_process_machine.log` temporarily carries detailed worker output during
  scheduled and `--run-now` processing; `-m` streams that output directly.
- `mount/backupDestination` is the transient CIFS mount point.
- `process.lock` identifies the active EBS coordinator and prevents overlapping
  scheduled or manually initiated backup runs.

After correcting a failure, explicitly re-enable that VM by removing only its
error file:

```bash
rm excluded_machines/VM_NAME.err
```

There is currently no automatic retry or expiry for excluded machines.

## File map

- `ebs.sh` — scheduler, immediate/manual entry points, instance lock, and
  coordinator.
- `process_machine.sh` — VM shutdown, OVF export, restore, promotion, and
  file/console output handling.
- `mount_share.sh` / `unmount_share.sh` — active and idempotent CIFS handling;
  the coordinator retries mounts while DSM finishes starting SMB.
- `power_on_synology.sh` / `power_off_synology.sh` — NAS power management.
- `setup_utils/get_server_signature.sh` — obtains one fingerprint for `plink`.
- `setup_utils/update_esxi_host_keys.sh` — verifies and saves fingerprints for
  all configured ESXi servers.
- `setup_utils/test_backup_servers.sh` — validates mount, write, delete, and
  unmount access for every configured backup share.
- `setup_utils/check_dependencies.sh` — checks commands required by EBS.
- `setup_utils/test_esxi_servers.sh` — performs read-only pinned-key connection
  tests against every configured ESXi host.
- `setup_utils/test_nas_power.sh` — interactively power-cycles each unique NAS
  and attempts Wake-on-LAN recovery if interrupted.
- `report_error.sh` — placeholder error reporter.
- `setup_utils/setup_permissions.sh` — marks active scripts and tools executable.
- `setup_utils/ebs.service.template` — path-aware systemd unit template.
- `setup_utils/install_systemd_service.sh` — installs the rendered unit and
  scoped noninteractive CIFS permissions.
- `config.example.json` — credential-free deployment configuration template.
- `bin/jq-linux64` — active bundled `jq` executable.
- `bin/ovftool/` — ignored location for a locally installed VMware OVF Tool.

## Production validation

Use a disposable VM and share to confirm host-key verification, unattended CIFS
mounting, NAS wake/shutdown, successful OVF restoration, VM restart, available
capacity, failure cleanup, and preservation of the previous stable backup.
Backup promotion recursively removes staging and previous-backup directories,
so review every configured mount and temporary-storage path carefully.

## Publishing safely

Never publish a deployment's `config.json`, configuration backups, logs, runtime
state, or locally installed VMware OVF Tool. They are covered by `.gitignore`.

VMware OVF Tool remains governed by VMware/Broadcom's separate license and must
not be added to this repository.

## License

EBS is licensed under the [GNU General Public License version 3](LICENSE)
(`GPL-3.0-only`). Commercial use is permitted. Anyone who conveys modified or
unmodified covered copies must comply with GPLv3, including its corresponding
source and license requirements. Private use without conveying copies does not
require publication. VMware OVF Tool is not part of EBS and has its own license.
