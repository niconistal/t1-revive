# Changelog

Dates are the days the work was proven on hardware, taken from the maintainer's private
engineering notebook. Everything before the first public version happened on one
MacBookPro14,3.

## 0.1.1 (2026-09-15)

Two ESPs on one Mac (issue #2, reported by @bjhinkle from a MacBookPro14,2 that dual-boots
macOS, firmware intact). A Linux install next to macOS leaves Apple's ESP unmounted and mounts
its own at `/boot`; the tool preferred the mounted one, so on such a machine:

- `backup` picked the Linux ESP, found no `EFI/APPLE` there, printed "nothing to back up (a
  wiped ESP)" and exited 0 on a machine whose firmware was completely intact; `regenerate`
  and `stage` would have targeted the same wrong partition
- `status` and `report` could not look inside the unmounted Apple ESP, so the bundle of an
  intact machine was indistinguishable from a wiped one

Fixed:

- `esp_select` now prefers the single internal ESP that holds `EFI/APPLE` and falls back to
  the one at `/boot`, `/efi` or `/boot/efi` only when none is known to hold it (the header
  comment already said so; the code did the opposite). A stick with `EFI/APPLE` still never wins
- unmounted ESPs are looked at through a read-only probe mount (`ro,nosuid,nodev,noexec` on a
  private temporary directory, as root, removed afterwards) by `status`, `preflight`, `report`,
  `backup` and the regeneration; `T1R_ESP_PROBE=0` turns it off
- `backup` never exits 0 without a tar: a wiped single ESP exits 1 with "nothing was backed
  up"; an empty ESP next to another internal ESP is refused (exit 4) with the other partition
  named and the `T1R_ESP_DEV` pin explained
- `status` and `preflight` say which ESP was chosen and why, and list the ones not chosen;
  `report` gains `esp[n].note: probed-read-only`, `esp-selected` and `esp-selected-why`
- README: the 14,2 is listed as the intact-ESP control case (status and report only, no
  regeneration); docs cover dual-boot layouts and the pin; how-it-works notes that on the 14,2
  `FRST` lives in an SSDT and the device id appears in no static table, which is why the
  method is found by name under the xHCI path and never by device id

## 0.1.0 (2026-09-14)

First public version.

README visual identity: logo, hero, before/after, feature cards, terminal mockup and flow strip.
The Touch Bar pictures are a real T1Bridge renderer on the tested 14,3, not a mock UI.

First full run of the packaged tool on hardware (2026-09-11, MacBookPro14,3, t1bridge 0.1.9 installed,
EFI/APPLE/EMBEDDEDOS removed beforehand): provision 83 s, personalize 84 s, boot 41 s, stage, handover;
4 min 8 s total, no reboot, t1bridge took the device back and the existing Touch ID enrolment verified
without re-enrolling.

Persistence of that run (checked 2026-09-13, after four full power cycles on 2026-09-12): the T1
enumerates in configuration 2 at boot, `t1bridge status` reports every line ready (keybag, broker,
touchbar), and the regenerated `EMBEDDEDOS` folder compared against the copy set aside before the
run gives `FDRData` and `version.plist` byte-identical and `combined.memboot` different, as expected
from fresh nonces and a fresh ticket.

Hardware-gate day fixes (2026-09-11, found while running the gate checklist on the 14,3):

- `build.sh` reconfigures a vendor checkout whose Makefile targets another prefix instead of
  reusing it (it used to "install" into a vanished directory and exit 0 with an empty `prefix/`)
- the bats suite no longer writes `t1-revive-diagnostic` lines to the system journal
  (`T1R_NO_JOURNAL=1`); `report` and `status` ignore leftover `component=test` lines
- `preflight` greps the idevicerestore binary directly for the T1 marker: `strings | grep -q`
  died of SIGPIPE under `pipefail` on the real binary and reported the patched build as unpatched
- package installs hand pacman only the missing packages (no "is up to date -- skipping" noise)
- confirmations: the plan is printed and confirmed once, the ESP write once more;
  `--confirm-each` restores a question before every device-touching step; the prompt is a
  distinct block with the Enter/Ctrl-C instruction on its own line
- after staging the folder is listed once, and the handover prints the import/enrolment hint only
  when t1bridge reports the keybag as not ready (an existing enrolment survives regeneration)
- dry runs: the resets are labelled as steps 2/7 and 4/7, the recovery guard does not repeat the
  reset before every step, the stage preview prints once, the firmware download note prints once

Initial public version, derived from the private notebook scripts (`one-shot.sh`,
`pass-a.sh`, `pass-b.sh`, `phase14.sh`, `stage-esp.sh`, `frst-test.sh`, `regen-preflight.sh`,
the toolkit and install-stick builders) with a clean history:

- pre-hardware review fixes: the reset method is never guessed among several FRST methods
  (`T1R_FRST_METHOD` pins one), the ESP mounted at `/boot` or `/efi` wins over a stick that
  holds `EFI/APPLE`, ESP-selection failures stop the run, the run and the ESP write are confirmed,
  stale step markers are invalidated, contract exit codes survive step failures
- step gates match the proven run by default (artefacts present; `8600` after the boot step's watch);
  `--strict` adds idevicerestore exit-status and full 30 s stability requirements
- one entry point `t1-revive` with `preflight`, `backup`, `regenerate [--from STEP]`,
  `stage`, `handover`, `status`, `report`, `version`, and the global `--no-confirm`,
  `--demo`, `--dry-run`; the regeneration steps are `provision`, `reset-1`, `personalize`,
  `reset-2`, `boot`, `stage`, `handover`;
- model allowlist from DMI (`MacBookPro13,2`, `13,3`, `14,2`, `14,3`; `14,3` tested, the
  others warn and continue, anything else refused);
- the T1 reset method discovered from the ACPI tables instead of assumed;
- ESP discovery by partition type, refusing when ambiguous;
- a recommended backup step before any device-touching step: `regenerate` warns and asks
  for confirmation when no off-disk copy was taken, and `stage` keeps an on-disk copy of any
  existing `EMBEDDEDOS` files under the state directory before overwriting them;
- firmware package fetched from Apple's CDN at run time and verified against a pinned
  checksum; nothing from Apple in the repository;
- state under `/var/lib/t1-revive` (0700), redacted logs under `/var/log/t1-revive`, cache
  under `/var/cache/t1-revive`; no `$HOME`, no fixed user;
- redaction at the source, structured identifier-free diagnostics, a `report` bundle for
  testers;
- documented exit codes; resume at every step;
- the patched libimobiledevice stack as pinned forks built by `build.sh`; AUR recipe;
- the install stick (stock Omarchy ISO plus a `TOOLKIT` partition) and the BCM43602 Wi-Fi
  fixer under `contrib/stick/`;
- tests: shellcheck, bats against synthetic fixtures, the identifier scan and the forbidden-method
  grep in CI;
- documentation: README, how it works, threat model, troubleshooting, FAQ, hardware
  validation, the Omarchy page for t1bridge (firewall rule, PAM lines, known quirks),
  install stick, a tester agent skill;
- t1bridge is installed from its own README, which ships signed packages for Arch and
  Omarchy; t1-revive stops at the handover and does not wrap anyone else's installer.

## Milestones before the public version

- 2026-09-03: first regeneration from Linux on a MacBookPro14,3 whose `EFI/APPLE` had been
  wiped: pass A and pass B, phase 14 boots the T1 (`05ac:8600` stable, full personality,
  bar lit), the three files staged on the ESP and verified. Power cycles between steps.
- 2026-09-06: Touch ID enrolled on the regenerated data with t1bridge 0.1.2, after a fix to
  its property-list decoder (3-byte offset width). sudo, polkit and lock screen by touch;
  persists across reboot.
- 2026-09-07: `FRST`, the T1-only ACPI reset, proven safe (T1 back in recovery in 2.4 s, no
  host side effects). Zero-reboot handover to t1bridge by USB re-enumeration. Full
  regeneration from a wiped state in one shot: 4 min 56 s, no reboot. Wiped machine to sudo
  by touch, t1-revive then t1bridge, about 10 min with zero restarts.
- 2026-09-09: the whole path on camera from a fresh Omarchy install: stock installer wipes
  the T1, regeneration from the install stick, t1bridge, Touch ID, no reboot. The t1bridge
  decoder fix is merged upstream and ships in 0.1.6.
- 2026-09-10: decision to publish as an open-source tool, `t1-revive`, MIT, bash, with a
  tested table, a recommended backup and a model allowlist.
