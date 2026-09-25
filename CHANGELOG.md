# Changelog

Dates are the days the work was proven on hardware, taken from the maintainer's private
engineering notebook. Everything before the first public version happened on one
MacBookPro14,3.

## Unreleased

- **A desktop provider for Omarchy.** t1bridge's built-in renderer draws volume, mute and media
  buttons only when a desktop provider is configured, and the core package ships none by design,
  so the bar arrived with Escape, the hardware controls and the F-keys and no volume.
  `contrib/omarchy/t1bridge-omarchy-provider.sh` (PR #11, @mbriney) implements desktop provider
  v1 with Omarchy's own tools: the sink Omarchy's volume keys move, resolved through
  `omarchy-audio-output-sink`; Omarchy's OSD for volume and brightness; `omarchy-shell media` for
  previous, play/pause and next, advertised only while an MPRIS player is actually running; and a
  dark bar while Hyprland has the displays off. No `jq`, no `playerctl`, ~33 ms per status poll
  against a 500 ms deadline. Setup is section 5 of `docs/omarchy.md`
- **Review fixes on that provider**, from @wdwy90's review on a MacBookPro14,2 and a run on a
  MacBookPro14,3 against a t1bridge 0.1.9 renderer. `toggle-mute` goes through
  `omarchy-audio-output-volume`, so the Touch Bar shares Omarchy's one 250 ms mute debounce
  window instead of double-firing a tap. `show-display-brightness` asks
  `omarchy-brightness-display` for the focused display instead of taking the first
  `/sys/class/backlight` entry, which with an external monitor focused reported the internal
  panel's 9% where the focused output was at 76%. `hyprctl` is asked through an explicit
  instance, because the instance signature the user service inherits dies when Hyprland restarts
  and the display capability then vanished from a running renderer. The display capability is
  switchable for a renderer that predates it, which 0.1.9 turned out not to need: it accepts the
  bit and ignores it. Sysfs levels are read through `T1R_SYSFS`, behind a readability test so an
  unmatched glob cannot reach the renderer's stderr and a numeric test so a value cannot reach
  arithmetic

## 0.1.3 (2026-09-19)

A second MacBookPro13,2 (issue #10, @ncolina), on a host that had carried an older Touch Bar
stack since before t1bridge existed. The regeneration itself was fine; getting to it was not.

- **`preflight` now refuses when a pre-t1bridge Touch Bar stack is still installed.** The
  out-of-tree drivers that predate t1bridge (`apple-ib-drv` and its forks) bind the T1's HID
  interfaces and their udev rules pin its USB configuration to 1. On that machine the boot
  step reached `05ac:8600` and the post-watch USB walk then wedged against a device something
  else was holding - twice, `result=error code=5` - and the chain only completed once the
  stack was out of the way. `legacy_t1_stack` reports each leftover it finds: a loaded module,
  a DKMS package that is merely built (which counts, because the reported machine had a unit
  that `insmod`s it past the blacklist), and an admin udev rule that pins the configuration.
  Package-provided rules under `/usr/lib/udev/rules.d` are never flagged: those are t1bridge's
  own. `docs/troubleshooting.md` has the entry and the commands to clear it
- `docs/omarchy.md`: the `WorkingDirectory` drop-in does not always clear the
  `t1bridge-import.service` exit 30; importing by hand from the mounted ESP did

## 0.1.2 (2026-09-17)

Six tester reports (issues #4 to #9) on 0.1.0 and 0.1.1, four of them successful regenerations
on models nobody had run before. Every model on the allowlist now has one.

- **Every allowlisted model is a tested model.** MacBookPro14,2 and 13,3 (issues #5 and #4),
  then 13,2 (issue #9, @pmbemax): a wiped-ESP regeneration each, persisting across a full power
  cycle. `model_status` reads two lists, `T1R_TESTED_MODELS` and an empty
  `T1R_UNTESTED_MODELS`, so a new model moves between them in one line; the tool no longer
  tells anyone on these four that they are the first. The README table has the rows
- **`preflight` demanded the stock `linux-headers` by name** (issue #9, @pmbemax): on a kernel
  that is not the `linux` package — Omarchy's `linux-omarchy`, or `linux-lts` — the headers
  live in that kernel's own `-headers` package, so a machine with correct headers and working
  DKMS builds got a NO and exit 3, one line below its own `ok kernel headers for <uname -r>`.
  The kernel package and the headers package are now resolved from the running kernel's module
  directory (`distro_kernel_pkg`, `distro_headers_pkg`), so the check asks for the headers DKMS
  actually builds against and `--install` installs those
- **the bundle named a kernel that was not running** (same cause, visible in issues #7 and #9):
  `kernel-pkg` read the version of the stock, unbooted `linux`, so both reports carried
  `kernel-match: no` on a machine whose kernel was perfectly matched, and
  `pkg.linux-headers: not-installed` next to `kernel-headers: yes`. The bundle now prints
  `kernel-pkg-name` and `kernel-headers-pkg`, takes the match from `distro_kernel_matches`, and
  lists the running kernel's own packages
- **the bundle says which ESP candidates are removable** (`esp[n].removable`, issue #7): a USB
  stick with its own EFI partition is a candidate the selection rule skips, and a bundle that
  did not say so read as if the machine had two internal ESPs
- **`report` counted every diagnostic line twice** (issue #6, reported with the cause and the fix
  by @bleedmonkey): `diag()` writes each line to the per-command log and to the aggregate
  `diagnostics.log`, and the bundle globbed both, so a single regeneration read as two identical
  ones and the merged stream came out in filename order, not in the order the commands ran. The
  bundle now reads the aggregate alone, in order; the per-command logs are the fallback when it
  is absent and the source for `--since`, and the two are never combined. `diag-log-source`
  says which was read
- **`backup` and `preflight` mount an unmounted ESP read-only** (issue #2 follow-up, @bjhinkle):
  with the 0.1.1 selection fix, `backup` on a dual-boot Mac reaches Apple's ESP for the first
  time, and mounted it read-write in order to read it. `esp_mount DEVICE ro` mounts
  `ro,nosuid,nodev,noexec`; `stage` and the regeneration still mount read-write
- as a normal user, `status` and `report` mark the `/boot` fallback as provisional when a
  candidate could not be looked inside, and say to run as root, instead of stating the `/boot`
  reason as a fact
- a read-only probe that will not unmount is detached lazily, and its directory is removed only
  once nothing is mounted on it; `preflight` looks at the candidates once instead of four times
- the reset step's exit 3 names the running kernel and the `dkms` commands: on the 13,3 the chain
  stopped there twice with `elapsed=0` (`acpi_call` not loaded at that moment, on a kernel that
  was not the `linux` package); troubleshooting has the entry, and docs/omarchy.md records the
  `t1bridge-import.service` `ProtectSystem=strict` failure from the same run with its drop-in
- **the offline toolkit ships again** (issue #1): `tools/relocate-prefix.sh` strips the built
  binaries, rewrites their RUNPATH (`$ORIGIN`-relative for the toolkit, the installed path for the
  package), drops the build-time files and refuses to leave a build path behind; the PKGBUILD
  and `make-toolkit.sh` share it. The toolkit's `prefix/` goes from 10 MB to under 2 MB

Open, not fixed here: on one MacBookPro14,3 a fully verified staged set is not loaded at cold
boot (issue #7, @lecstor) while the same image boots the T1 over USB every time. A 13,2 on the
same tool version and the same kernel loaded its staged set at the first cold boot (issue #9),
so the staged files are not the variable. Nothing the T1 does before the kernel starts is
visible from Linux; docs/troubleshooting.md now lists what to separate before adding a report.

A note for anyone who patched 0.1.0 by hand: the two-ESP bugs of 0.1.1 were masking each
other. The wrong selection returned the Linux ESP, which was already mounted, so the leaking
`esp_mount` never ran; a correct selection without the exit-unmount leaves Apple's ESP mounted
read-write after every `backup` or `preflight`. Take the selection fix, the exit-unmount and
the read-only mount together (@bjhinkle's observation on issue #2).

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
- an ESP the tool mounted itself is unmounted at exit again: `esp_mount` runs inside a command
  substitution, so the variable `esp_release` relied on never reached the exiting shell and the
  partition stayed mounted read-write under the state directory (found on a loop-device ESP
  while testing this release; invisible on the tested machine, whose ESP is at `/boot`)
- a dry run of `backup` on an unmounted ESP looks through the read-only probe instead of
  mistaking the empty mount directory for a wiped ESP
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
