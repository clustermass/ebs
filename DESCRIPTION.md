EBS PROJECT DESCRIPTION
=======================

Purpose
-------

EBS is a Bash-based ESXi backup automation service. It exports VMware ESXi
virtual machines in OVF format to SMB/CIFS storage, primarily Synology NAS
shares. It coordinates scheduling, NAS power management, share mounting, VM
power-state management, safe staging, result tracking, and cleanup.

High-level lifecycle
--------------------

The long-running ebs.sh process reads config.json and checks the time every five
seconds. At the preferred start minute, it compares each VM's last successful
backup timestamp with its backupPeriod. A per-minute trigger guard prevents a
still-due skipped VM from being requeued repeatedly during that minute. Due VMs
are processed sequentially.

The same coordinator also supports two one-shot modes. --run-now performs the
normal due-VM selection immediately, while -m lists configured VMs and processes
an operator-selected set with detailed terminal output. All modes use
process.lock to prevent overlapping coordinators.

For each VM, the coordinator resolves the configured ESXi host and destination,
checks ESXi reachability, wakes the NAS if configured, mounts its CIFS share,
delegates the export to process_machine.sh, records the outcome, and unmounts
the share. CIFS mounting is retried five times at 30-second intervals because a
NAS can answer ping before SMB is ready. Mount cleanup is idempotent and
distinguishes an ordinary directory from an active mount. Once the queue is
empty, configured NAS devices are shut down. Shutdown is deduplicated by IP for
multiple shares on one physical NAS.

VM backup lifecycle
-------------------

process_machine.sh connects to ESXi through plink using a password and pinned
SSH host-key fingerprint. It uses vim-cmd to locate the VM and inspect its state.

A running VM is shut down gracefully through VMware Tools, with hard power-off
as a fallback. A suspended VM is either treated as an error or skipped,
depending on its configuration. A suppressed skip changes neither success
state nor exclusion state, so the VM remains due at the next scheduled trigger.
Export begins only after ESXi reports that the VM is powered off.

VMware OVF Tool writes to a staging directory such as ___ExampleVM. This may be
on local temporary storage or directly on the NAS. A local export is moved to
NAS staging after completion.

If the VM was originally running, EBS powers it back on and verifies the result.
If restart fails, the new staging export is discarded and the last stable
backup is preserved. Only after export and restoration succeed does EBS remove
the old stable directory and rename staging to the VM's normal name.

Once the original VM power state is known, the worker installs an exit-recovery
handler. Any later failure or interruption—including OVF export, staging, or
promotion failure—attempts to return a VM that started powered on to that state.

Configuration model
-------------------

config.example.json documents the configuration structure. Each deployment
copies it to the Git-ignored config.json, which contains:

- commonConfig: preferred start time and local staging path.
- machines: VM name, interval, ESXi mapping, datastore, destination, staging
  choice, and suspended-VM behavior.
- esxiServers: logical name, address, credentials, and SSH fingerprint.
- backupServers: logical share, NAS address, credentials, share name, MAC,
  broadcast address, and power flags.

Credentials are stored in plaintext. The file must have restrictive permissions
and must not be published or included in support output.

Runtime state
-------------

- processed_machines/<VM>.log stores success history. Its first line is the
  latest success time in epoch seconds and drives scheduling.
- excluded_machines/<VM>.err stores failure details and prevents further
  scheduling until an operator removes it.
- ebs.log stores coordinator events.
- temp_process_machine.log carries worker detail back to the coordinator in
  scheduled and --run-now modes; manual mode streams it to the terminal.
- mount/backupDestination is the transient CIFS mount.
- process.lock stores the active coordinator PID, start epoch, and mode. Shell
  traps and systemd ExecStopPost remove it when the coordinator stops.

File responsibilities
---------------------

- ebs.sh: scheduler, immediate/manual modes, instance lock, CIFS retry, and
  coordinator.
- process_machine.sh: VM discovery, power handling, export, promotion, live
  output, and failure-time power restoration.
- mount_share.sh / unmount_share.sh: idempotent per-backup CIFS handling.
- power_on_synology.sh / power_off_synology.sh: NAS power handling.
- setup_utils/get_server_signature.sh: obtains one SHA256 fingerprint for plink.
- setup_utils/update_esxi_host_keys.sh: interactively verifies and saves keys
  for all ESXi servers in config.json.
- setup_utils/test_backup_servers.sh: validates CIFS mount, write, delete, and
  unmount access for every configured backup share.
- setup_utils/check_dependencies.sh: verifies required Ubuntu commands.
- setup_utils/test_esxi_servers.sh: validates pinned-key ESXi access with a
  read-only VM-list command.
- setup_utils/test_nas_power.sh: interactively validates NAS shutdown and
  Wake-on-LAN recovery once per physical IP.
- report_error.sh: placeholder that currently prints failure information.
- setup_utils/setup_permissions.sh: sets executable permissions on active files.
- setup_utils/ebs.service.template: path-aware systemd unit template.
- setup_utils/install_systemd_service.sh: renders and installs the unit and
  scoped noninteractive CIFS permissions for the current service user.
- config.example.json: credential-free deployment configuration template.
- bin/jq-linux64: active bundled jq executable used independently of PATH.
- bin/ovftool/: Git-ignored required location for a separately licensed local
  VMware OVF Tool installation.

Known constraints and risks
---------------------------

- Deployment ESXi and NAS credentials are plaintext in the Git-ignored
  config.json. Credentials exposed outside the trusted host should be rotated.
- Mounting requires carefully scoped noninteractive service-account privileges.
- A failure excludes a VM indefinitely; retry requires operator intervention.
- A suppressed suspended VM is skipped without changing its last successful
  backup timestamp, so it remains due at the next scheduled trigger.
- The exact-minute scheduler can miss a daily trigger.
- VM lookup uses substring matching and whitespace parsing. Spaces, complex
  characters, and overlapping VM names are unsafe.
- Inaccessible ISO or floppy backing can make OVF Tool fail even when the
  virtual removable-media device appears disconnected. Remove unused backing
  before export and validate behavior on each ESXi version.
- Some variables and paths are not consistently shell-quoted.
- Error reporting has no email, webhook, or monitoring integration.
- Recursive removal is used for staging and old backups; paths require care.

Operational intent
------------------

EBS prioritizes preservation of the last known-good backup when export or VM
restoration fails. It is intended for controlled, sequential offline backups
where temporary VM shutdown is acceptable. It is not snapshot-based,
incremental, encrypted, application-consistent, or centrally monitored.

Before production use, test the complete lifecycle with a disposable VM:
restoration, CIFS permissions, storage capacity, Wake-on-LAN, NAS shutdown, VM
restart, failure cleanup, and preservation of the previous stable backup.
