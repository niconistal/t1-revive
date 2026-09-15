<div align="center">

<img src="docs/assets/hero.svg" alt="t1-revive: Touch Bar, camera and Touch ID back on a 2016 or 2017 MacBook Pro, from Linux alone" width="100%">

**Regenerates the Apple T1 firmware data of a 2016 or 2017 Touch Bar MacBook Pro, from Linux alone.**

[![ci](https://github.com/niconistal/t1-revive/actions/workflows/ci.yml/badge.svg)](https://github.com/niconistal/t1-revive/actions/workflows/ci.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-3b82f6.svg?logo=opensourceinitiative&logoColor=white)](LICENSE)
[![Arch Linux](https://img.shields.io/badge/Arch_Linux-based-1793d1.svg?logo=archlinux&logoColor=white)](#-requirements)
[![tested: MacBookPro14,3](https://img.shields.io/badge/tested_on-MacBookPro14%2C3-22c55e.svg?logo=apple&logoColor=white)](#-tested)
[![shell: bash](https://img.shields.io/badge/bash-shellcheck_%2B_bats-4EAA25.svg?logo=gnubash&logoColor=white)](#-upstream-status)
[![companion: t1bridge](https://img.shields.io/badge/companion-t1bridge-a855f7.svg?logo=fingerprint&logoColor=white)](https://github.com/standardagents/t1bridge)
[![no macOS](https://img.shields.io/badge/macOS-not_required-3ee8a8.svg)](#-install)

[Requirements](#-requirements) ·
[Install](#-install) ·
[The flow](#-the-flow) ·
[Apple and your disk](#-what-talks-to-apple-and-what-is-stored-where) ·
[After it works](#-after-it-works) ·
[Testing](#-testing-and-reporting) ·
[Credits](#-credits)

</div>

---

`t1-revive` is for the machine whose Linux installer recreated the EFI System Partition and
erased `EFI/APPLE/EMBEDDEDOS`, which leaves the T1 in USB recovery mode with a dark Touch
Bar, no camera and no Touch ID. The tool drives Apple's own EmbeddedOS restore protocol with
patched libimobiledevice tools, lets the chip fetch its own Apple-signed factory data and a
personalised boot image from Apple's servers, boots the T1 with them, and stages the three
resulting files on the ESP so the Mac's firmware loads them at every boot. No macOS install
is needed and no file from another Mac is used. Afterwards,
[t1bridge](https://github.com/standardagents/t1bridge) provides the Touch Bar, the camera and
Touch ID.

> [!CAUTION]
> **Read this before running anything.**
>
> - This tool talks to the T1 over Apple's restore protocol and writes new factory data into
>   the chip. That is a firmware recovery operation, not a driver install. Once a
>   regeneration has run, the chip carries the new data; there is no "undo" other than
>   restoring a previous copy of `EFI/APPLE` if you have one.
> - It depends on Apple's servers. The T1 authenticates to Apple's signing service and
>   fetches its factory data from Apple's FDR service. If Apple stops signing this firmware,
>   regeneration stops working for everyone, macOS reinstalls included. That is the one
>   permanent scenario, and the reason an off-disk copy of `EFI/APPLE` is worth taking while
>   the folder still exists.
> - Never run it unattended. Every device-touching step asks before it proceeds. Stay at
>   the keyboard, on mains power, and do not let the machine sleep.
> - Run it only on `MacBookPro13,2`, `13,3`, `14,2` or `14,3`. Anything else is refused.
>   Only the `14,3` has been tested. On the other three models the tool warns and continues;
>   you are the first, so read [docs/hardware-validation.md](docs/hardware-validation.md) and
>   report.
> - One machine so far. Everything below was proven on one MacBookPro14,3, several times,
>   including from a fresh install. That is evidence, not coverage.
> - Linux next to macOS means two EFI system partitions, Apple's unmounted. Run `status`,
>   `backup` and `preflight` with `sudo` so the tool can look inside it; `backup` exits 0
>   only when it wrote and checked a copy. Versions before 0.1.1 chose the Linux one and
>   reported "nothing to back up" on intact machines: do not trust that message from 0.1.0.
> - The tool never calls the ACPI method `SOCW`. The only T1 reset it uses is `FRST`.

<img src="docs/assets/hardware.jpg" alt="The real T1Bridge Touch Bar after regenerate: Escape, brightness, keyboard backlight, and media keys" width="100%">

<p align="center"><sub>T1Bridge’s built-in renderer on this MacBookPro14,3, after <code>t1-revive regenerate</code>.</sub></p>

<img src="docs/assets/before-after.jpg" alt="Dark Touch Bar in recovery, then the same machine with T1Bridge’s built-in renderer lit" width="100%">

<img src="docs/assets/features.svg" alt="What comes back: Touch Bar, camera, and Touch ID" width="100%">

## ✅ Tested

| Model | Date | Restore | Touch ID | Tester |
| :--- | :--- | :---: | :---: | :--- |
| **MacBookPro14,3** | 2026-09-03 restore · 2026-09-06 Touch ID · 2026-09-07 rehearsals · 2026-09-09 fresh install · 2026-09-11 `t1-revive regenerate` 4 min 8 s, no reboot · 2026-09-12 four power cycles later: still ready, FDRData byte-identical to the pre-run copy · 2026-09-14 two more runs from a removed EMBEDDEDOS, 4 min 2 s each, enrolment kept | 🟢 | 🟢 persists across reboot; existing enrolment survives regeneration | @niconistal (maintainer) |
| MacBookPro14,2 | 2026-09-15 intact-ESP control: `status` and `report` on a Mac that dual-boots macOS, firmware intact, T1 booted; found the two-ESP defects fixed in 0.1.1 (issue #2). Regeneration deliberately not run | ⚪ untested | ⚪ untested (Touch ID via t1bridge 0.1.9 confirmed on that machine, independently of this tool) | @bjhinkle |
| MacBookPro13,3 | | ⚪ untested | ⚪ untested | *your report here* |
| MacBookPro13,2 | | ⚪ untested | ⚪ untested | *your report here* |

A confirmed run on any model becomes a row here with your
handle if you want it there. See [Testing and reporting](#-testing-and-reporting).

## 📋 Requirements

- **A T1 MacBook Pro** from the list above, with the T1 in recovery mode: `lsusb` shows
  `05ac:1281 Apple, Inc. Mobile Device (Recovery Mode)` instead of `05ac:8600`.
- **An Arch-based x86_64 Linux.** Tested on Omarchy 4.0.2 with kernel 7.1.9. Other
  distributions fail clearly at preflight; the restore itself is distribution-neutral and
  packaging help is welcome.
- **Root through `sudo`, mains power, and a network path to Apple:** `gs.apple.com` and
  `swcdn.apple.com` over HTTPS. A fresh install on the 2017 15-inch can come up with no
  Wi-Fi at all; see the [appendix](#-appendix-installing-with-no-network) at the end of this
  page.
- **Kernel headers** for the running kernel and `acpi_call-dkms`. Preflight installs them and
  tells you to reboot if the kernel changed (exit code 7).
- **No system `usbmuxd` running.** Preflight checks.

## 📦 Install

<table>
<tr>
<th align="left">From the AUR, once published</th>
<th align="left">From source</th>
</tr>
<tr>
<td>

```sh
yay -S t1-revive
```

</td>
<td>

```sh
git clone https://github.com/niconistal/t1-revive && cd t1-revive
bash build.sh          # builds the pinned libimobiledevice forks into prefix/
sudo bin/t1-revive version
```

</td>
</tr>
</table>

Those two are the install path. Nothing from Apple is in the repository or the package.
The firmware package `EmbeddedOSFirmware.pkg` is downloaded from Apple's CDN at run time
and checked against a pinned checksum.

## 🚀 The flow

```sh
sudo t1-revive preflight                    # 1. read-only checks; installs the few packages
sudo t1-revive backup --to PATH             # 2. recommended; copies EFI/APPLE off this disk (exit 0 only with a checked copy)
sudo t1-revive regenerate                   # 3. provision, reset, personalize, reset, boot, stage, handover
```

<img src="docs/assets/terminal.svg" alt="t1-revive regenerate: from a wiped ESP to a booted T1 in about five minutes" width="100%">

<img src="docs/assets/flow.svg" alt="provision, reset, personalize, reset, boot, stage, handover" width="100%">

**1. Preflight** runs read-only checks and installs the few packages the restore needs.

**2. Backup** is recommended, not required. If any of `EFI/APPLE` still exists, copy it
somewhere that is not this disk: another machine over `scp`, a phone, a cloud folder, an
external drive. Any destination the tool can write to works. Regeneration produces the
data again whenever it is needed, as long as Apple still signs it, and `stage` keeps an
on-disk copy of whatever `EMBEDDEDOS` files it is about to overwrite. An off-disk copy
covers the one scenario neither of those covers: Apple withdrawing the signing. If the
folder is already gone there is nothing to copy, and `regenerate` warns and asks you to
confirm before it continues.

**3. Regenerate** prints its plan and asks once before it starts, then once more before it
writes the ESP. Timings from the rehearsal: about five minutes from a wiped machine to a
verified ESP, with zero reboots. [docs/how-it-works.md](docs/how-it-works.md) has the steps.

| Flag | Effect |
| :--- | :--- |
| `--confirm-each` | also ask before every step that touches the device |
| `--no-confirm` | skip the questions |
| `--dry-run` | print what would happen without touching the device, the ESP or the network |
| `--demo` | generic on-screen lines, with details in the log |

The other subcommands are `stage` and `handover` (the last two steps on their own),
`status`, `report` and `version`.

**4. Then install t1bridge**, from
[its own README](https://github.com/standardagents/t1bridge). It ships signed packages for
Arch and Omarchy. On Omarchy, three things its README does not cover are written up in
[docs/omarchy.md](docs/omarchy.md): the firewall rule, the PAM lines, and the known quirks.
If t1bridge is already installed when `regenerate` finishes, the last step hands the booted
T1 to it without a reboot. If it is not, install it and do one full power cycle; the
firmware loads the staged files on its own.

### If it stops

The tool stops at the first failure, names the step, and prints the fallback. The fallback is
always the same: full shutdown, wait 20 seconds, power on, then resume from where it stopped:

```sh
sudo t1-revive regenerate --from STEP
# STEP: provision | reset-1 | personalize | reset-2 | boot | stage | handover
```

The provisioned data survives in the state directory, so a failure in `personalize` or
later does not repeat the provision step. The T1 cannot end up worse than recovery mode,
which is where it started. [docs/troubleshooting.md](docs/troubleshooting.md) is organised
by symptom and exit code.

## 🔐 What talks to Apple, and what is stored where

### Network

| Endpoint | When | What for |
| :--- | :--- | :--- |
| `swcdn.apple.com` | before `provision` | download of Apple's public `EmbeddedOSFirmware.pkg` |
| `gs.apple.com` | `provision` and `personalize` | TSS, the signing service: the chip's identity and nonces go up, signed tickets come back |
| Apple's FDR service, reached through the restore protocol | `provision` and `personalize` | the chip's factory data record, signed for this chip |

Booting the T1, staging and handover use no network. What Apple's servers see is what any T1 or
iPhone restore sends: the chip's identity and nonces. Nothing about your files or your
fingerprints. Fingerprints never leave the Secure Enclave.

### On disk

| Path | Mode | Contents |
| :--- | :--- | :--- |
| `/var/lib/t1-revive/private/` | `0700`, files `0600` | the FDR store, the personalised boot image, the AP ticket, unredacted restore logs |
| `/var/lib/t1-revive/efi-backup-<stamp>/` | `0700` | any `EFI/APPLE` files that existed before staging |
| `/var/log/t1-revive/` | `0700` | redacted logs, one per command, `latest.log` symlink |
| `/var/cache/t1-revive/` | `0755` | the firmware package and its extracted bundle; no device data |
| ESP `EFI/APPLE/EMBEDDEDOS/` | | `combined.memboot`, `FDRData`, `version.plist`: what the firmware loads at boot |

Nothing identity-bearing is ever printed. Logs are redacted at the source.
[docs/threat-model.md](docs/threat-model.md) covers what the host sees, what it never sees,
and what someone with the state directory could do.

> [!IMPORTANT]
> After it works, copy the new `EFI/APPLE` folder off this disk, encrypted, and keep it. A
> reinstall is exactly the event that destroys it.

## ✨ After it works

- **[t1bridge](https://github.com/standardagents/t1bridge)** by Andrew Boyd: Touch Bar,
  camera, Touch ID, with the Secure Enclave doing the matching. Touch ID enrolls on
  regenerated data and persists across reboot; t1bridge 0.1.6 or later reads the T1's
  FDRData directly.
- **[docs/omarchy.md](docs/omarchy.md)**: what t1bridge's README leaves out on Omarchy. The
  ufw rule for the T1's private link, Omarchy's own PAM lines for sudo, polkit and the lock
  screen with the password fallback kept, and the quirks with their fixes.

> [!NOTE]
> **Known gaps, ours and upstream's:** system suspend and resume do not work with the T1
> stack; the ambient light sensor is not available under t1bridge; the camera under t1bridge
> has not been tested by us; one machine.

## 🧪 Testing and reporting

Read [TESTING.md](TESTING.md) and the checklist in
[docs/hardware-validation.md](docs/hardware-validation.md). If you work with an agent,
point it at [skills/t1-revive-tester/SKILL.md](skills/t1-revive-tester/SKILL.md); it guides
a run without skipping the confirmations. When something fails, or works on a new model,
open an issue with the output of:

```sh
sudo t1-revive report
```

That bundle is redacted and structured: model status, kernel, distro, t1bridge version, T1
state, ESP findings, the last diagnostic lines, package versions. It is the only thing we ask
you to paste.

> [!WARNING]
> Never paste serial numbers, ECIDs, nonces, tickets, MAC addresses, restore logs from the
> private directory, or the contents of anything under `EFI/APPLE`.

## 🔀 Upstream status

t1-revive builds three patched libimobiledevice components because upstream has no
iBridge1,1 (Apple T1) restore support yet. The patches are exact diffs against pinned
upstream commits and keep their upstream licences. They live as one commit each on a `t1`
branch of the maintainer's copies, and `build.sh` can build from upstream plus patch or
from those branches. When upstream merges them, the package moves its dependencies back
to the original repositories and the copies go away.

| Component | Upstream base | Patched copy | Upstream status |
| :--- | :---: | :--- | :--- |
| idevicerestore | `540c352` | [niconistal/idevicerestore-t1](https://github.com/niconistal/idevicerestore-t1) branch `t1` | offered in [idevicerestore#800](https://github.com/libimobiledevice/idevicerestore/issues/800) (ticket first, per their contributing guide) |
| libirecovery | `95dec3a` | [niconistal/libirecovery-t1](https://github.com/niconistal/libirecovery-t1) branch `t1` | PR [libirecovery#167](https://github.com/libimobiledevice/libirecovery/pull/167) open |
| usbmuxd | `3ded00c` | [niconistal/usbmuxd-t1](https://github.com/niconistal/usbmuxd-t1) branch `t1` | PR [usbmuxd#284](https://github.com/libimobiledevice/usbmuxd/pull/284) open |

Related contributions to the projects around this tool:

| Project | Change | Status |
| :--- | :--- | :--- |
| omacom/omarchy-iso | preserve `EFI/APPLE` across the installer's disk wipe (the root fix for basecamp/omarchy#8271) | [omarchy-iso#174](https://github.com/omacom/omarchy-iso/pull/174) · open |
| basecamp/omarchy | lock screen keeps the fingerprint reader idle while the display is blanked | [omarchy#11273](https://github.com/omacom/omarchy/pull/11273) · open |
| standardagents/t1bridge | bplist offset widths 1 to 8 bytes (the width the T1 writes) | [#16](https://github.com/standardagents/t1bridge/pull/16) · merged, shipped in 0.1.6 |
| standardagents/t1bridge | issues from this work | [#21](https://github.com/standardagents/t1bridge/issues/21) failed keybag unit blocks enrollment · [#22](https://github.com/standardagents/t1bridge/issues/22) document the no-reboot handover · data points on [#14](https://github.com/standardagents/t1bridge/issues/14) |

## 💛 Credits

- **Andrew Boyd**, for [t1bridge](https://github.com/standardagents/t1bridge) and for saying
  early and loudly "back up your EFI partition". This tool exists to produce the file his
  stack requires.
- **The [libimobiledevice](https://libimobiledevice.org/) project**, for idevicerestore,
  libirecovery and usbmuxd, which speak the restore protocol.

Maintained by [@niconistal](https://github.com/niconistal).
Contributions: [CONTRIBUTING.md](CONTRIBUTING.md) ·
Security reports: [SECURITY.md](SECURITY.md) ·
Changes: [CHANGELOG.md](CHANGELOG.md)

## 📄 Licence

MIT for everything authored in this repository. The patches and build recipes under
`vendor/` apply to idevicerestore and libirecovery (LGPL-2.1) and usbmuxd (GPL) and stay under
those licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## 📎 Appendix: installing with no network

<details>
<summary>For the 2017 15-inch that comes up with no Wi-Fi after a fresh install</summary>

<br>

The 2017 15-inch ships a Wi-Fi chip for which `linux-firmware` carries no calibration file,
so a fresh install can come up showing no wireless networks at all, and the tool needs the
network twice: for packages, then for Apple. If that is your situation, there is an install
stick that carries the tool, the firmware bundle and the Wi-Fi fix on one extra partition
next to a stock Omarchy ISO: [docs/install-stick.md](docs/install-stick.md). Everyone else
should ignore it and use the AUR package or the source build above.

</details>
