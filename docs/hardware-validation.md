# Hardware validation

The checklist a tester fills in for one regeneration on one machine. It exists because most
of what matters here can only be tested on a real T1. Unit tests cover the pure functions;
this covers the chip.

Record only what the table at the end asks for. Never record serial numbers, ECIDs, nonces,
tickets, MAC addresses, hostnames, the contents of anything under `EFI/APPLE`, or anything
from `/var/lib/t1-revive/private/`. The report bundle is designed so that you do not have
to think about this; paste it and nothing else.

If you work with an agent, point it at [../skills/t1-revive-tester/SKILL.md](../skills/t1-revive-tester/SKILL.md).
It follows this checklist and does not skip the confirmations.

## Before

Stop if any line is a no. Do not change PAM, firmware, USB state or power settings to force
a yes.

- [ ] The model is one of `MacBookPro13,2`, `13,3`, `14,2`, `14,3`
      (`cat /sys/class/dmi/id/product_name`). Note whether it is the tested `14,3` or one of
      the untested three.
- [ ] `lsusb` shows the T1 at `05ac:1281` (recovery), or at `05ac:8600` with no
      `EFI/APPLE/EMBEDDEDOS` on the ESP (a warm reboot after the wipe). Note which.
- [ ] Any copy of `EFI/APPLE` from this Mac that exists anywhere has been located and kept.
- [ ] Recommended, not required: `sudo t1-revive backup --to PATH` ran against a
      destination that is not this disk, and the tool confirmed either that `FDRData` is
      inside the copy, or exited 1 saying nothing was backed up (a wiped ESP). An exit 4
      naming a second EFI system partition means the tool would not choose: read the
      troubleshooting page before going on. Record it as skipped if you skipped it;
      `regenerate` warns and asks for confirmation in that case, and continues.
- [ ] The machine is on mains power. Sleep is off for the duration.
- [ ] Password login works for `sudo`, and, if a lock screen is in use, for the lock screen.
      This must still be true at the end.
- [ ] A root shell is open in a second terminal and stays open until the end.
- [ ] `sudo t1-revive preflight` ends with no `NO` lines (exit 0). If it exits 7, reboot and
      run it again; note that it happened.
- [ ] t1bridge: note whether it is installed before the run. The tested order is
      regeneration first, then t1bridge.

## During

Run `sudo t1-revive regenerate --confirm-each` and answer each confirmation yourself. Record the T1's USB
state at each step as the tool reports it. Note the wall-clock time of each step.

| Step | Expected | Observed (state, time, exit) |
| --- | --- | --- |
| provision | `Restore Finished`; FDR store written; T1 at `8600` degraded | |
| reset (`reset-1`) | return `0x0`; T1 back at `1281` within seconds | |
| personalize | `Restore Finished`; image, ticket and replayed store written; replay byte-identical | |
| reset (`reset-2`) | as above | |
| boot | `8600` within about 10 s, stable for 30 s, no fallback to `1281` | |
| stage | three files verified on the ESP | |
| handover | t1bridge takes the device (if installed), or the instruction to power cycle | |

If the tool stops: record the step, the exit code, and the message. Power cycle. Resume with
`--from STEP`. Record that too. A stop is a result, not a failed test.

## After

- [ ] Full power cycle (shutdown, 20 s, power on), nothing running. The Touch Bar lights
      during boot. This is the cold-boot persistence test and the most important line here.
- [ ] `sudo t1-revive status` shows `EFI/APPLE/EMBEDDEDOS/combined.memboot`, `FDRData`,
      `version.plist` present and the T1 at `8600`.
- [ ] Copy the new `EFI/APPLE` folder off this disk, encrypted. Note done.

Then t1bridge, installed from its own README. On Omarchy read [omarchy.md](omarchy.md)
first: the firewall rule, the PAM lines and the known quirks are there.

- [ ] `sudo t1bridge status`: every row ready (`keybag: not-enrolled` is normal before the
      first enrollment).
- [ ] Import of this machine's data succeeded (automatic, or `--from` with the ESP path).
- [ ] `fprintd-enroll -f right-index-finger` reaches `enroll-completed`. Note whether the
      first attempt failed and a retry was needed.
- [ ] `fprintd-verify -f right-index-finger` returns `verify-match` for the enrolled finger
      and does not match a different finger.
- [ ] `sudo -k; sudo true` succeeds by touch.
- [ ] `sudo` succeeds by password with the fingerprint attempt cancelled or timed out.
- [ ] Lock screen unlocks by touch.
- [ ] Lock screen unlocks by password.
- [ ] Camera: `v4l2-ctl --list-devices` lists the FaceTime camera and one frame can be
      captured. Optional; we have not tested it ourselves.

## Reboot persistence

- [ ] Normal reboot: Touch Bar lit, `fprintd-verify` matches without re-enrolling, sudo by
      touch and by password.
- [ ] Cold boot (full shutdown, then power on): the same four checks. Record it separately;
      one does not establish the other.
- [ ] Suspend and resume: record as not run unless your host already suspends safely with
      the T1 stack. It is known not to work upstream; a failure here is expected and is not
      a regeneration failure.

## What to paste

Only this:

```sh
sudo t1-revive report
```

plus the table below, filled in. The bundle carries the tool version, the model status,
kernel, distribution, t1bridge version, T1 state and configuration, ESP findings, the last
diagnostic lines and package versions, all redacted. If something looks like an identifier
in it, that is a bug; report it privately per [../SECURITY.md](../SECURITY.md).

| Field | Value |
| --- | --- |
| Model | identifier only, and tested or untested |
| Distribution and kernel | |
| t1-revive version | |
| t1bridge version | |
| Starting state | `1281`, or `8600` without the folder |
| Backup off-disk | `FDRData` inside / nothing to copy / skipped |
| Preflight | clean / reboot needed once / NO lines (which) |
| provision / reset / personalize / reset / boot / stage / handover | ok or stopped at, with exit code |
| Resumes needed | step and count |
| Wall clock, provision start to ESP verified | |
| Cold boot: Touch Bar lit | |
| t1bridge import / enroll (first try or retry) / verify | |
| sudo by touch / by password | |
| Lock screen by touch / by password | |
| Reboot / cold boot persistence | |
| Camera / suspend | ok, fail, not run |
| Report bundle | attached |

A failure remains a failure until the same version passes the affected step after a fix. Do
not edit the expected column to match what you saw.
