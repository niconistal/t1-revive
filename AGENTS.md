# t1-revive — repository rules and design contract

t1-revive regenerates the Apple T1 (iBridge) firmware data of a 2016/2017 Touch Bar
MacBook Pro from Linux alone, when the `EFI/APPLE/EMBEDDEDOS` folder was erased (typically by
a Linux installer). It drives Apple's own EmbeddedOS restore protocol with patched
libimobiledevice tools, stages the result on the EFI System Partition, and hands the booted T1
to [t1bridge](https://github.com/standardagents/t1bridge) for Touch Bar and Touch ID.
Licence: MIT for everything authored here. Patches under `vendor/` keep their upstream
licences (LGPL-2.1 for idevicerestore and libirecovery, GPL for usbmuxd).

`AGENTS.md` is canonical; `CLAUDE.md` is a symlink to it.

## Rules that never bend

1. **Never call the ACPI method `SOCW`.** `FRST` is the only T1 reset. CI greps for the word.
2. **No identifiers anywhere**: no serial numbers, ECIDs, nonces, tickets, FDR contents,
   keybags, MAC addresses, hostnames, tailnet names, usernames, or home-directory paths in
   code, docs, fixtures, tests, logs, or commit messages. Test fixtures use obviously
   synthetic values. `tools/scan-identifiers.sh` runs in CI and as a pre-commit hook.
3. **No Apple binaries or device data in the repo.** Firmware is downloaded from Apple's CDN at
   run time and verified by a pinned checksum. Everything identity-bearing lives under
   `/var/lib/t1-revive` (mode 0700) and is never printed.
4. **No fixed user, no `$HOME`, no fixed device paths.** Everything is discovered (DMI, sysfs,
   partition types, ACPI tables) or configured. The tool runs as root via `sudo`.
5. **Device-touching steps confirm first** unless `--no-confirm`/`--demo`. A step checks the
   T1's USB state before touching it and stops on the first failure with the fallback spelled
   out (full power cycle, then resume with `--from STEP`).
6. **Preserve the proven sequence.** The restore steps (`provision`, `reset`, `personalize`,
   `reset`, `boot`, `stage`, `handover`; the cross-reference table in `docs/how-it-works.md`
   maps them to the original recipe's and idevicerestore's names) are refactored for layout
   and naming only. The commands sent to the device, their order, flags, environment and
   timings stay exactly as in the proven scripts.
7. **Shell is bash**, `set -uo pipefail`, shellcheck-clean, functions sourceable without side
   effects. Python is allowed only for parsers and extractors under `tools/` (ACPI, plist,
   xar/pbzx). No other languages.
8. Logs are redacted at the source (`redact` filter) and diagnostics are emitted as
   structured, identifier-free lines (see Diagnostics).

## Layout

```
bin/t1-revive            dispatcher: resolves T1R_ROOT, sources lib/common.sh, runs cmd_<sub>
lib/common.sh            logging, redaction, confirm, exit codes, dirs, lock, T1 USB state, diag
lib/discover.sh          ESP, DMI model + allowlist, FRST ACPI path, T1 device node
lib/distro.sh            package installs and kernel checks (Arch implemented; others fail clearly)
lib/firmware.sh          fetch + verify + extract Apple's EmbeddedOSFirmware.pkg into the cache
lib/report.sh            cmd_report: redacted, structured diagnostic bundle
lib/cmd-preflight.sh     cmd_preflight
lib/cmd-backup.sh        cmd_backup
lib/cmd-status.sh        cmd_status
lib/cmd-regenerate.sh    cmd_regenerate (provision -> reset-1 -> personalize -> reset-2 -> boot -> stage -> handover)
lib/cmd-stage.sh         cmd_stage (ESP staging, --dry-run)
lib/cmd-handover.sh      cmd_handover (USB re-enumeration to t1bridge)
lib/steps/provision.sh   step_provision     the T1 gets its device-specific FDR identity data from Apple
lib/steps/personalize.sh step_personalize   replay it; capture the personalised boot image + AP ticket
lib/steps/boot.sh        step_boot          boot the T1 from that image in RAM, watch USB for 05ac:8600
lib/steps/reset.sh       step_reset         the T1-only ACPI reset (the FRST method); ids reset-1, reset-2
                         (the older recipe names for these four are in docs/how-it-works.md)
tools/                   scan-identifiers.sh, ACPI/plist/pbzx helpers (python), relocate-prefix.sh (shared by the
                         PKGBUILD and the toolkit), make-toolkit.sh, make-install-stick.sh
vendor/                  build recipes and pinned refs for the patched libimobiledevice stack; build.sh at root
packaging/arch/PKGBUILD  AUR recipe (builds vendor/ from pinned tags; nothing from Apple at build time)
contrib/stick/           install-stick files: README.txt, install-nvram.sh, nvram template
contrib/omarchy/         t1bridge desktop provider for Omarchy (Touch Bar volume, media, OSD); see docs/omarchy.md
skills/t1-revive-tester/SKILL.md   the tester-facing agent skill
test/                    bats tests + fixtures; test/fixtures/** holds synthetic sysfs/lsblk/DMI/ACPI
docs/                    how-it-works, threat-model, troubleshooting, diagnostics, hardware-validation, omarchy, firmware, install-stick, assets/ (README visuals; regenerate with docs/assets/gen.py)
.github/                 issue templates, CI workflow
```

## Paths and environment (all overridable for tests)

| Variable | Default | Meaning |
| --- | --- | --- |
| `T1R_ROOT` | dir containing `lib/` (resolved by `bin/t1-revive`) | code |
| `T1R_PREFIX` | `$T1R_ROOT/prefix`, else `/usr/lib/t1-revive/prefix` | patched idevicerestore/irecovery/usbmuxd/plistutil + libs (`bin/`, `sbin/`, `lib/`, `lib64/`) |
| `T1R_STATE` | `/var/lib/t1-revive` (0700) | private state: `private/` (FDR store, memboot, ticket), `efi-backup-<stamp>/` |
| `T1R_LOG` | `/var/log/t1-revive` (0700) | redacted logs: `<cmd>-<stamp>.log`, `latest.log` symlink |
| `T1R_CACHE` | `/var/cache/t1-revive` | firmware pkg + extracted bundle |
| `T1R_CONF` | `/etc/t1-revive` | optional `t1-revive.conf` (key=value) |
| `T1R_SYSFS` | `/sys` | sysfs root (tests point it at a fixture) |
| `T1R_DMI` | `$T1R_SYSFS/class/dmi/id` | DMI root |
| `T1R_ACPI_TABLES` | `$T1R_SYSFS/firmware/acpi/tables` | ACPI tables |
| `T1R_LSBLK_JSON` | unset | if set, a file with `lsblk -J -o ...` output used instead of running lsblk |
| `T1R_NO_CONFIRM` | `0` | `1` skips confirmations |
| `T1R_DEMO` | `0` | `1` = on-camera mode: generic lines on screen, details to the log |
| `T1R_DRY_RUN` | `0` | `1` = print what would happen; no device, no ESP, no network writes |
| `T1R_STRICT` | `0` | `1` = stricter step gates (exit status of the restore tool, full 30 s boot verdict) |
| `T1R_FIRMWARE` | unset | a local EmbeddedOSFirmware.pkg to use instead of downloading (checksum still verified) |
| `T1R_ESP_DEV` | unset | pin the ESP device when two candidates look alike (conf file) |
| `T1R_ESP_PROBE` | `auto` | unmounted ESPs: `auto` = look inside through a read-only mount as root on a real block device; `0` = never; `1` = always try (tests, stub mount) |
| `T1R_FRST_METHOD` | unset | pin the reset method when the tables define several; must be one of them (conf file) |
| `T1R_UDEV_RULES_DIRS` | `/etc/udev/rules.d /run/udev/rules.d` | admin udev directories `legacy_t1_stack` scans; never the package-provided `/usr/lib/udev/rules.d`, which is t1bridge's own |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | generic failure |
| 2 | usage |
| 3 | preflight failed (fix the NO lines) |
| 4 | refused for safety (unsupported model, confirmation declined, unexpected state) |
| 5 | device in an unexpected state (see message; fallback: full power cycle) |
| 6 | network / Apple service failure |
| 7 | reboot needed (kernel changed) |

## `lib/common.sh` API (implement exactly these names)

```
say MSG            green section header (stderr in demo mode goes to log only)
note MSG           indented informational line
warn MSG           yellow warning
die CODE MSG       print red "STOPPED: MSG", diag result=error, exit CODE
show MSG           a line that is always shown on screen, even in demo mode (generic text only)
confirm PROMPT     ask "[Enter to continue, Ctrl-C to stop]"; no-op when T1R_NO_CONFIRM=1 or T1R_DEMO=1
redact             stdin->stdout filter: hex runs >=16 chars -> <hex>, MAC addresses -> <mac>,
                   ECID=..., serial-looking tokens -> <id>
diag K=V ...       append "t1-revive-diagnostic v=1 component=$T1R_COMPONENT K=V ..." to the log
                   and to the journal via logger -t t1-revive (values: [A-Za-z0-9._:-]+ only)
require_root       die 4 unless EUID=0
ensure_dirs        create T1R_STATE (0700), T1R_LOG (0700), T1R_CACHE (0755)
open_log NAME      start the redacted log for this command (tee through redact); sets T1R_LOGFILE
lock_acquire       flock on $T1R_STATE/lock; die 4 if another run holds it
t1_state           prints one of: recovery (05ac:1281) | booted (05ac:8600) | none
t1_config          prints bConfigurationValue of the 8600 device or empty
t1_sysfs           prints the sysfs path of the T1 usb device or empty
wait_t1 STATE SEC  poll t1_state every 0.5 s; return 0 when reached, 1 on timeout
kver_normalize     stdin filter: pacman "7.2.3.arch1-3" -> uname "7.2.3-arch1-3"
version            prints the tool version (from $T1R_ROOT/VERSION)
```

Functions read only their parameters and `T1R_*` variables, so bats can test them against
`test/fixtures`. A file that defines commands must not execute anything at source time.

## `lib/discover.sh` API

```
model_id                 DMI product_name (e.g. MacBookPro14,3) from $T1R_DMI/product_name
model_status ID          prints: tested | untested | unsupported, from two lists so a model moves
                         when a tester confirms it (the README table is the record)
                         T1R_TESTED_MODELS:   MacBookPro14,3 14,2 13,3 13,2 - every T1 Mac, since issue #9
                         T1R_UNTESTED_MODELS: empty; a model here warns and continues
                         unsupported: anything else (die 4)
legacy_t1_stack          one line per leftover of a pre-t1bridge Touch Bar stack, "KIND DETAIL":
                         module NAME (loaded), dkms NAME (built, so something can insmod it
                         again), udev PATH (an admin rule pinning the T1's USB configuration).
                         Returns 1 when clean. Reads only; lists in T1R_LEGACY_MODULES and
                         T1R_LEGACY_DKMS, directories in T1R_UDEV_RULES_DIRS
esp_candidates           prints "DEVICE MOUNTPOINT HAS_APPLE" per line for partitions with
                         PARTTYPE c12a7328-f81f-11d2-ba4b-00a0c93ec93b (from lsblk -J or T1R_LSBLK_JSON);
                         HAS_APPLE is yes/no when mounted or probed (esp_probe), "?" otherwise
esp_select [--why]       picks the single ESP, in this order: T1R_ESP_DEV; the only ESP; the single
                         non-removable ESP holding EFI/APPLE (Apple's ESP on a dual-boot Mac, unmounted
                         under Linux); only when none is known to hold it, the one mounted at /boot,
                         /efi or /boot/efi. Prints "DEVICE MOUNTPOINT" (--why: one sentence on the
                         choice); returns 1 if none or ambiguous
esp_apple_facts MP       "EFI_APPLE EMBEDDEDOS MEMBOOT FDRDATA VERSION" yes/no for a mounted tree
esp_with_ro_mount DEV CMD [ARG...]
                         mounts an unmounted ESP ro,nosuid,nodev,noexec on a private temp dir, runs
                         CMD ARG... MOUNTPOINT, unmounts and removes the dir; returns 1 without running
                         anything when T1R_ESP_PROBE forbids it or the mount fails
esp_probe DEVICE         esp_apple_facts through esp_with_ro_mount
esp_mount DEVICE [ro]    mounts under $T1R_STATE/esp if not mounted; prints mountpoint. "ro":
                         ro,nosuid,nodev,noexec (backup, preflight); an ESP already mounted is
                         used as it is. esp_release (from log_close) unmounts at exit
frst_method              prints the full ACPI path of the T1 reset method (e.g.
                         \_SB.PCI0.XHC1.RHUB.ASOC.FRST) discovered from the ACPI tables in
                         $T1R_ACPI_TABLES; empty if not found, and empty (refuse, never guess)
                         when several are defined unless exactly one sits under an xHCI node
                         or T1R_FRST_METHOD pins one of them. Never calls it.
```

## Diagnostics

One line per event, no free text, no identifiers:

```
t1-revive-diagnostic v=1 component=regenerate step=provision result=ok elapsed=97
t1-revive-diagnostic v=1 component=regenerate step=reset-1 result=error code=5 t1=none
```

`t1-revive report` prints the redacted bundle testers paste into an issue: tool version,
model_status, kernel, distro, t1bridge version if installed, T1 state and config, ESP
findings (no device names beyond /dev/…), the last 200 diagnostic lines, package versions.

## Source material (read-only, outside this repo)

The tool was derived from the maintainer's private notebook scripts and logs, which are not
published; this repository and its tests are the source of truth. t1bridge's repo layout and
tone is the reference for docs quality.
Never copy from a machine's state directories (`/var/lib/t1bridge`, the tool's own state
directory) or from the ESP into the repo.
