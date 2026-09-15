# Troubleshooting

By symptom. Each entry names the exit code the tool uses, what it means, and what to do.
The fallback that is always safe: full shutdown, wait 20 seconds, power on, then
`sudo t1-revive regenerate --from STEP`. The T1 cannot end up worse than recovery mode.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | generic failure |
| 2 | usage |
| 3 | preflight failed: fix the `NO` lines |
| 4 | refused for safety: unsupported model, confirmation declined, unexpected state |
| 5 | device in an unexpected state; fallback: full power cycle |
| 6 | network or Apple service failure |
| 7 | reboot needed: the kernel changed |

Every run leaves a redacted log in `/var/log/t1-revive/` (`latest.log` points at the newest).
`sudo t1-revive report` prints the bundle to attach to an issue. Nothing else needs pasting.

## Preflight says NO (exit 3)

**`kernel headers` or `kernel changed`, exit 7.** Every kernel module this tool and t1bridge
build must match the running kernel. On a fresh Omarchy the installed kernel is usually
newer than the one the ISO booted, and preflight updates the system first. Reboot, then run
the same command again; it continues from where it stopped. Expect this once on every fresh
install.

**`acpi_call not available`.** The T1 reset needs the `acpi_call` module and
`/proc/acpi/call`. Preflight installs `acpi_call-dkms` and `linux-headers`; if the module did
not build, check `sudo dkms status` and `journalctl -k | grep acpi_call`. A headers and kernel
mismatch is the usual cause; see the previous entry.

**`pacman install failed` on a fresh Omarchy.** The fresh system carries only the ISO's
offline package database, which has no `acpi_call-dkms`. Preflight syncs the database and
runs the full upgrade first; if that failed, its error is above the `NO` line. Fix it or run
`omarchy-update`, then rerun.

**No network, and the Wi-Fi adapter shows no networks.** The BCM43602 in the 2017 15-inch
ships without NVRAM calibration in `linux-firmware`, so a fresh install can come up with no
wireless at all. The install stick carries the fixer: see
[install-stick.md](install-stick.md). Preflight also stops here when it finds no default
route.

**`gs.apple.com unreachable`, exit 6.** Regeneration needs Apple's signing and FDR services.
Check name resolution and that TCP 443 to `gs.apple.com` is open. A captive portal or a
proxy that intercepts TLS breaks the restore even when a browser works; a plain network is
needed for the few minutes of the two passes. Apple's endpoints do not serve a browsable
page, so a browser test proves nothing either way.

**`system usbmuxd is running`.** The passes start their own patched usbmuxd and refuse to
run beside the system one. `sudo systemctl disable --now usbmuxd`, rerun.

**`ESP ambiguous`, exit 4.** Two partitions of type EFI System were found and neither stands
out: none of them is the single internal one holding `EFI/APPLE`, and none is the single one
mounted at `/boot` or `/efi`. The tool will not guess. Put `T1R_ESP_DEV=/dev/...` in
`/etc/t1-revive/t1-revive.conf` and rerun; `sudo t1-revive status` lists the candidates, what
each holds, and which one would be chosen.

**Two EFI system partitions (Linux installed next to macOS).** Apple's ESP stays unmounted
while Linux runs and the distro mounts its own at `/boot`. As root, `status`, `preflight`,
`report` and `backup` look inside the unmounted one through a read-only mount and prefer the
internal partition that holds `EFI/APPLE`, whatever is mounted where. Run them with `sudo`:
as a normal user the unmounted partition shows as `?` and the one at `/boot` is chosen. On a
layout where *neither* ESP holds `EFI/APPLE` the one at `/boot` is chosen for staging; that
layout has not been tested (the tested machine has one ESP), so pin Apple's partition with
`T1R_ESP_DEV` if you know which one it is.

**`backup`: "nothing was backed up", exit 1.** The chosen ESP has no `EFI/APPLE` and it is the
only internal one: a wiped ESP. Nothing was saved, and the exit code says so; `regenerate`
does not need this command to have succeeded on a wiped machine.

**`backup`: "this machine has another EFI system partition", exit 4.** The chosen ESP is empty
but a second internal ESP exists. The tool refuses rather than report a backup of nothing.
`sudo t1-revive status` shows what each partition holds; if the other one is Apple's, pin it
with `T1R_ESP_DEV` and run `backup` again.

**`FRST method not found`, exit 4.** The T1 reset method is discovered from this machine's
ACPI tables, never assumed. Not found means either the tables could not be read or this
machine is not one the recipe applies to. Run `sudo t1-revive report` and open an issue with
the bundle; do not try another method by hand.

**`N FRST methods in the ACPI tables ... refusing to guess`, exit 4.** The tables define more
than one method with that name and only one under an xHCI controller node is accepted
automatically. The tool never picks one at random. If you have read the tables and know
which is the T1's, pin it with `T1R_FRST_METHOD=\_SB....FRST` in `/etc/t1-revive/t1-revive.conf`;
it is accepted only if it is one of the discovered candidates.

**`unsupported model`, exit 4.** Only `MacBookPro13,2`, `13,3`, `14,2`, `14,3` are accepted.
On the three untested ones the tool warns and continues. A T2 Mac or a Mac without a Touch
Bar is out of scope.

**`no backup confirmed`, exit 4.** Run `sudo t1-revive backup --to /path/on/another/device`
first, then confirm. See the threat model for why this is not optional.

## No T1 on the bus (exit 5)

`lsusb` shows neither `05ac:1281` nor `05ac:8600`. Nothing to talk to. Do a full power
cycle (shutdown, 20 seconds, power on), not a reboot, and look again. If the T1 is still
absent, the machine may be in a state the tool cannot reach from Linux; report it. Do not
run any step.

## The T1 is at 8600 already and I have no EMBEDDEDOS folder

A warm reboot can leave the T1 running from the previous boot's data even though the folder
is gone. `preflight` says so. `regenerate` resets it into recovery with FRST first and
proceeds. If the folder exists and the T1 is at `8600`, there is nothing to regenerate; the
tool refuses (exit 4).

## Provision or personalize failed (exit 5 or 6)

The tool names the step and stops. Read the tail of `latest.log`.

- A dispatch or device error before the restore started: host side. The T1 is untouched.
  Power cycle, fix what the message says, rerun.
- The restore started and aborted: the T1 falls back to recovery. Power cycle, then
  `--from provision` or `--from personalize`. The provisioned data survives a personalize
  failure, so `--from personalize` does not repeat it.
- A network error mid-restore, exit 6: same fallback. Both steps need Apple for their whole
  duration; do not let the machine sleep.

## Boot fell back to 1281 (exit 5)

`8600` appeared and disappeared within seconds. iBoot rejected the image or the ticket. In
order of likelihood: the image and ticket did not come from the same personalize run; the boot
arguments differ from the recipe; auto-boot was not saved. Power cycle, then
`--from personalize`. Never request a new ticket alone; a ticket obtained after a reset paired
with the old image sent the T1 back to recovery every time.

## Boot: 8600 stays but nothing works

The T1 is at `8600` but exposes no HID devices after configuration 1 was selected. That is
the degraded restore personality, not a booted OS: the image did not boot. Power cycle,
`--from personalize`, and open an issue with the report bundle if it repeats.

## Boot: nothing happens, still 1281

The blind memboot was not accepted. Power cycle and try `--from boot` once more before
changing anything.

## T1 in recovery after regeneration completed

The run finished, the ESP is staged, and after a power cycle the T1 is at `1281` and the bar
is dark.

- Check that `EFI/APPLE/EMBEDDEDOS` holds the three files: `sudo t1-revive status`.
- If the files are there, run `sudo t1-revive regenerate --from boot`. It boots the T1
  from the saved pair without touching Apple. If that works but the cold boot does not,
  report it: that is the persistence case we need to hear about.
- If the files are missing, `--from stage` while the T1 is booted, or `--from boot` and
  let it stage again.

## Handover to t1bridge

The t1bridge side of these entries is Omarchy-specific in places; the exact commands are in
[omarchy.md](omarchy.md).

**`not in group t1bridge` / the bar stays dark after handover.** The Touch Bar renderer runs
as your user and needs the `t1bridge` group, which your current login session predates. The
Touch ID side does not depend on the renderer. Log out and back in and the bar lights.

**`t1bridge-keybag.service` is `failed` and enrollment errors.** A keybag unit left in the
failed state (for instance by a crash loop before a reinstall) makes the broker's relay check
fail; t1bridge accepts only active or inactive. `sudo systemctl reset-failed
t1bridge-keybag.service t1-touchid-auth.service`, then retry. Reported upstream.

**`enroll-unknown-error` on the very first enrollment.** The keybag is being bootstrapped.
Restart the broker with `sudo systemctl restart t1-touchid-auth.service` and retry once. If
it fails again, check `sudo t1bridge status` for `xart: ready` and the firewall rule below.

**First enrollment times out, then fails immediately every time.** A default-deny firewall
is blocking xART. It needs inbound IPv6 TCP 61500 on the T1's private link only, from
link-local only. Never open it on Wi-Fi or Ethernet. `xart: ready` means the service runs,
not that the T1 can reach it. [omarchy.md](omarchy.md) has the one-line scoped rule and how
to find the interface name.

**Touch ID stopped after the laptop sat locked overnight.** `t1bridge-keybag.service`
restarts every 2 s with "load biometric keybag failed". The lock screen retried the
fingerprint every 30 s and a long run of timeouts wedged the enclave session. Fix: full
shutdown and power on. Password login is never affected. Do not delete `/var/lib/t1bridge`
to "fix" it. Reported upstream.

**A touch that seems ignored.** The sensor arms about a second after the prompt appears on
the Touch Bar. Touch after the prompt, and hold still.

**The T1 is at `8600` in configuration 1 and t1bridge does not take it.** The handover
re-enumerates the device; if t1bridge's units did not come up within about ten seconds, do a
full power cycle. The ESP is staged, so the T1 comes back on its own and t1bridge takes it
at boot.

## Something else

`sudo t1-revive report`, then an issue. Include the model, what you expected, what happened,
and the bundle. Never paste serial numbers, ECIDs, nonces, tickets, MAC addresses, private
logs, or the contents of anything under `EFI/APPLE`. Keep password login working throughout.
