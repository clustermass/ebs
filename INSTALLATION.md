# EBS installation guide

This guide is written for a fresh Ubuntu installation and is intended to be
followed one verified step at a time. Commands beginning with `$` are entered in
a terminal; do not type the `$` itself.

## Step 1 — Download and unpack EBS in your home directory

Place the repository in a directory named `service` directly under your home
directory. The resulting path should be:

```text
/home/YOUR_USER_NAME/service
```

If you received EBS as an archive, open a terminal, extract it, and move or
rename the extracted directory to `~/service`. If Git is already available, the
equivalent clone command is:

```bash
cd "$HOME"
git clone https://github.com/YOUR_GITHUB_USER/ebs.git service
```

Since the repository has already been copied on this machine, verify its
location and contents:

```bash
cd "$HOME/service"
pwd
ls
```

`pwd` should print `/home/YOUR_USER_NAME/service`. The listing should include
at least `ebs.sh`, `process_machine.sh`, `config.example.json`, and the `bin` and
`setup_utils` directories. The systemd template is stored inside `setup_utils`.

Create the deployment configuration from the tracked example. `config.json` is
ignored by Git because it will contain real credentials:

```bash
cp config.example.json config.json
chmod 600 config.json
```

## Step 2 — Set executable permissions

Run the permission setup script from the EBS directory. Invoke it through Bash
so this step also works when archive extraction did not preserve the executable
bit on the permission script itself:

```bash
cd "$HOME/service"
bash setup_utils/setup_permissions.sh
```

The script should report `+x` for the EBS scripts and `bin/jq-linux64`, followed
by `Done.`

Verify bundled jq:

```bash
"$HOME/service/bin/jq-linux64" --version
```

Expected output includes `jq-1.6`.

### Install VMware OVF Tool

VMware OVF Tool is proprietary software and is not distributed by this GitHub
repository. Obtain the Linux version from the official VMware/Broadcom download
portal and review and accept its license. Either install `ovftool` on the system
`PATH`, or unpack its complete distribution into:

```text
$HOME/service/bin/ovftool
```

For a local installation, the executable is
`$HOME/service/bin/ovftool/ovftool`. Verify whichever installation is used:

```bash
if [ -x "$HOME/service/bin/ovftool/ovftool" ]; then
  "$HOME/service/bin/ovftool/ovftool" --version
else
  ovftool --version
fi
```

The documented deployment was tested with VMware OVF Tool `5.0.0`
(build `24781994`). Do not continue until a version is printed successfully.

### Verify the server's local time

EBS interprets `prefferedBackupStartTime` using the Ubuntu server's configured
local timezone. Check the current time and timezone before choosing the schedule:

```bash
date
date +%R
timedatectl
```

Fresh Ubuntu installations may use `Etc/UTC`. To select another timezone, list
available names with `timedatectl list-timezones`, then set the chosen value. For
example:

```bash
sudo timedatectl set-timezone America/Los_Angeles
```

Verify again with `date` and set `prefferedBackupStartTime` as `HH:MM` in that
local time. The scheduler requires an exact minute match. After EBS has been
started, changes to `config.json` require `sudo systemctl restart ebs.service`.

## Step 3 — Install the SSH host-key tools

The next step discovers the SSH fingerprints of the ESXi hosts already listed
in `config.json`. Install the required OpenSSH client tools:

```bash
sudo apt update
sudo apt install openssh-client
```

Confirm that the configuration is valid JSON and review the ESXi names and
addresses that will be contacted. This command intentionally does not display
credentials:

```bash
cd "$HOME/service"
bin/jq-linux64 '.esxiServers[] | {name, ip}' config.json
```

Correct any missing or incorrect ESXi names and addresses in `config.json`
before continuing.

## Step 4 — Discover and save ESXi SSH fingerprints

ESXi SSH must be enabled and TCP port 22 must be reachable from this machine.
Run the interactive helper:

```bash
cd "$HOME/service"
bash setup_utils/update_esxi_host_keys.sh
```

For each `.esxiServers` entry, the helper displays the server name, address, key
type, and SHA256 fingerprint. Compare the fingerprint with the value shown by
the ESXi console or another trusted source. Type the complete word `yes` only
after it matches. Any other response skips that server without modifying it.
When a host advertises several key types, the helper selects them in Plink's
preferred order: Ed25519, ECDSA, then RSA.

The first accepted key causes the script to create a timestamped backup such as
`config.json.backup.20260818-120000`. Both the updated configuration and backup
are restricted to mode `600`. The helper then writes `esxiHostKey` into the
matching server object without printing its login or password.

Review the saved results without displaying credentials:

```bash
bin/jq-linux64 '.esxiServers[] | {name, ip, esxiHostKey}' config.json
```

Stop here if a host is skipped or a fingerprint cannot be independently
verified. Do not accept a fingerprint based only on `ssh-keyscan` output.

## Step 5 — Configure optional local cache storage

This step is required only when one or more machines have
`useTempBackupStorage` set to `"y"`. In that mode, EBS exports the complete VM
to local storage first and then moves it to the Synology share. The cache must
have enough free space for the largest VM export, plus a safe operating margin.

Prepare and mount the cache drive using Ubuntu's normal disk-management tools.
Use a stable mount point and configure it to mount automatically at boot. For
example, if the drive is mounted at `/mnt/ebs-cache`, create a directory owned
by the EBS service account:

```bash
sudo mkdir -p /mnt/ebs-cache/backups
sudo chown ebs:ebs /mnt/ebs-cache/backups
sudo chmod 750 /mnt/ebs-cache/backups
```

Set the absolute cache-directory path in `.commonConfig.tempBackupStoragePath`:

```json
"tempBackupStoragePath": "/mnt/ebs-cache/backups"
```

Confirm the configured value and verify that the directory is writable:

```bash
cd "$HOME/service"
cache_path=$(bin/jq-linux64 -r '.commonConfig.tempBackupStoragePath' config.json)
printf 'Cache path: %s\n' "$cache_path"
test -d "$cache_path" && test -w "$cache_path" && echo "Cache is writable"
df -h "$cache_path"
```

If this is a separately mounted drive, also verify its mount before starting
EBS:

```bash
mountpoint -q /mnt/ebs-cache && echo "Cache drive is mounted"
```

Do not continue if the intended cache drive is absent. Otherwise EBS may write
large exports into the underlying system filesystem. If local caching is not
needed, set `useTempBackupStorage` to `"n"` for every machine; exports will then
be staged directly on the NAS share.

## Step 6 — Configure and test Synology backup shares

Add one object to `.backupServers` in `config.json` for every Synology share EBS
will use. Multiple entries may point to different NAS devices or to different
shares on the same NAS. Each entry needs `name`, `ip`, `login`, `password`, and
`sharePath`. NAS power management additionally uses `mac`, `broadcastIp`,
`powerOn`, and `powerOff`. Machine entries select a destination through the
matching `backupServer` name.

The test below mounts shares but does not wake or shut down a NAS. Power on all
configured NAS devices first. Install CIFS support and refresh sudo credentials:

```bash
sudo apt update
sudo apt install cifs-utils
sudo -v
```

Run the validation helper from the repository:

```bash
cd "$HOME/service"
bash setup_utils/setup_permissions.sh
bash setup_utils/test_backup_servers.sh
```

For each `.backupServers` entry, the helper uses `mount_share.sh` to mount the
configured share in a unique temporary mount point. It creates a uniquely named
probe directory and file, verifies the file, deletes both probe objects, and
uses `unmount_share.sh` to unmount the share. It never prints the configured
password and does not touch existing backup folders.

A successful run ends with output similar to:

```text
Backup-share validation finished: 2 passed, 0 failed.
All configured Synology/CIFS backup shares passed validation.
```

Stop here if any share fails. Check its IP address, share name, credentials,
Synology SMB permissions, and network reachability before trying again.

## Step 7 — Install and verify Ubuntu dependencies

Install the remaining packages used by EBS. Repeating packages installed in
earlier steps is safe; APT will leave current packages unchanged.

```bash
sudo apt update
sudo apt install cifs-utils coreutils iputils-ping openssh-client putty-tools sshpass util-linux vim-common wakeonlan
```

Run the dependency check:

```bash
cd "$HOME/service"
bash setup_utils/setup_permissions.sh
bash setup_utils/check_dependencies.sh
```

Do not continue until it ends with:

```text
All required EBS system dependencies are available.
```

The project uses bundled `jq` and a separately licensed VMware OVF Tool, which
were verified in Step 2 and are therefore not installed through APT.

## Step 8 — Validate ESXi connections

Ensure SSH is enabled on every configured ESXi host, then run:

```bash
cd "$HOME/service"
bash setup_utils/test_esxi_servers.sh
```

The helper connects to each `.esxiServers` entry using its configured login,
password, and pinned `esxiHostKey`. It runs the read-only command
`vim-cmd vmsvc/getallvms`, reports the number of registered VMs, and does not
print credentials or change VM state.

A successful run ends with output similar to:

```text
ESXi validation finished: 2 passed, 0 failed.
All configured ESXi servers passed validation.
```

Stop if any server fails. A failure may indicate disabled ESXi SSH, an incorrect
address or credential, a changed host key, firewall rules, or insufficient ESXi
permissions. Do not bypass host-key verification.

EBS has been tested with:

- VMware ESXi `6.7.0 Update 3` (Build `15160138`) during the documented fresh
  installation and end-to-end backup.
- VMware ESXi `7.0 Update 2`, manually during the original development of EBS.

Other ESXi versions should be validated with this read-only test and a
controlled backup before production use.

## Step 9 — Validate Synology power management

This is a disruptive test: it shuts down and restarts each approved physical
NAS. Stop backup jobs and other NAS activity, unmount its shares on other
clients, and ensure Synology Wake-on-LAN is enabled. Each unique NAS IP is tested
only once even when several configured shares use that device.

Before running the test, configure these DSM prerequisites:

- The NAS account stored in `config.json` must belong to the Synology
  administrators group and be allowed to run `sudo poweroff`. CIFS write access
  alone is not sufficient to shut down the NAS.
- Enable SSH in **DSM → Control Panel → Terminal & SNMP → Terminal → Enable SSH
  service**. The current helper connects on the default SSH port, TCP 22. A
  `Connection refused` error normally means the SSH service is disabled or port
  22 is blocked.
- Enable Wake-on-LAN for the NAS network interface in DSM and confirm that the
  configured `mac` and `broadcastIp` values are correct.

The complete shutdown and Wake-on-LAN sequence has been successfully tested on
Synology DSM `7.4.1-90080`. Other DSM versions may arrange these settings
differently and should be validated with this test before enabling the service.

Run the interactive test:

```bash
cd "$HOME/service"
bash setup_utils/setup_permissions.sh
bash setup_utils/test_nas_power.sh
```

The NAS must be online before its test begins. For each device, review the name
and IP and type the exact phrase `power-cycle` to approve downtime. The helper:

1. Calls `power_off_synology.sh` and waits up to three minutes for ping to stop.
2. Waits 30 seconds after shutdown.
3. Calls `power_on_synology.sh` to send Wake-on-LAN.
4. Waits up to five minutes for ping to return.

If interrupted while a NAS is offline, the helper sends a recovery Wake-on-LAN
packet before exiting. A failed startup also triggers one final recovery packet.
Always verify the NAS manually after an interrupted or failed test.

A successful single-NAS result ends with:

```text
NAS power validation finished: 1 passed, 0 failed, 0 skipped.
All approved physical NAS devices passed power-cycle validation.
```

---

Next checkpoint: register EBS with systemd using `/home/ebs/service`, configure
noninteractive mount permissions, and perform a controlled end-to-end backup.

## Step 10 — Install the systemd service

The final installer renders `setup_utils/ebs.service.template` using the current
repository path and Ubuntu user/group. It also installs validated sudoers rules
for noninteractive CIFS operations beneath this repository's `mount` directory.

Run it as the normal `ebs` user; do not prefix the script itself with `sudo`:

```bash
cd "$HOME/service"
bash setup_utils/setup_permissions.sh
bash setup_utils/install_systemd_service.sh
```

The installer:

- Validates the configuration, executable permissions, access, and paths.
- Restricts `config.json` to mode `600`.
- Adds `RequiresMountsFor` when any VM uses local cache storage.
- Installs `/etc/systemd/system/ebs.service`.
- Installs `/etc/sudoers.d/ebs` after checking it with `visudo`.
- Reloads systemd and enables EBS at boot, but does not start it immediately.

Review the unit and repeat the share test with the installed noninteractive
permissions:

```bash
systemctl cat ebs.service
bash setup_utils/test_backup_servers.sh
```

When both checks succeed, start and monitor EBS:

```bash
sudo systemctl start ebs.service
systemctl status ebs.service
journalctl -u ebs.service -f
```

Press `Ctrl+C` to stop following the journal; this does not stop EBS. Do not
stop or restart the service while a VM export is in progress. Service controls:

```bash
sudo systemctl stop ebs.service
sudo systemctl restart ebs.service
sudo systemctl disable ebs.service
```

Rerun the installer whenever the repository is moved or the service user
changes, so its rendered paths and permissions remain correct.
