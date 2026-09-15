# Testing t1-revive

t1-revive has been proven on one model, by one person, on his own machine. Every other
row in the README's table comes from you. This page says who we need, what the rules
are, and what happens with a report.

## Who we need

| You have | What to do |
| --- | --- |
| A 2016/2017 Touch Bar MacBook Pro (`MacBookPro13,2`, `13,3`, `14,2`, `14,3`) on Arch or Omarchy, `lsusb` shows `05ac:1281`, and `EFI/APPLE/EMBEDDEDOS` is gone | You are the reason this exists. File a [Wiped-ESP registration](https://github.com/niconistal/t1-revive/issues/new?template=wiped-esp-registration.yml) first, then follow the reply. |
| The same Mac, `EFI/APPLE/EMBEDDEDOS/FDRData` exists, Touch Bar working or not | Run `t1-revive status` and `sudo t1-revive report`, use the t1bridge install (on Omarchy, with [docs/omarchy.md](docs/omarchy.md)), and file an [Intact-ESP report](https://github.com/niconistal/t1-revive/issues/new?template=intact-esp-report.yml) whether it worked or not. Do not regenerate; you have nothing to regenerate. |
| A `13,2`, `13,3` or `14,2` in either state | Doubly wanted: the tool warns `untested` on these and continues; your report turns that into `tested` or into a documented difference. |
| A `14,3` | Wanted too: a second machine of the proven model tells us what is machine-specific. |
| A T2 Mac (2018 and later) or a Mac without a Touch Bar | Out of scope. See the t2linux project. |
| Any of the above on another distro | The restore side is distro-neutral; `lib/distro.sh` is not yet. Register and say which distro; expect packaging work before a run. |

## The rules

1. **Docs only.** Nobody from the project connects to your machine, watches your screen,
   or types on your behalf. The README, `docs/`, and the tester skill carry the guide's
   role. If something is unclear enough that you would want a call, that is a
   documentation bug: file it.
2. **Your own agent is the guide.** Install the [tester skill](skills/t1-revive-tester/README.md)
   into the coding agent you already use. It reads the machine, explains the state,
   names the documented next step, and files the report under your login after you have
   read it. It is forbidden from running the device-touching commands for you; you type
   those.
3. **Backup if you still can.** `sudo t1-revive backup --to PATH` runs before anything touches
   the device, and copies `EFI/APPLE` off the disk if any of it is still there. It exits 0 only
   when it wrote and checked a tar: exit 1 means a wiped ESP, exit 4 means it found a second
   EFI system partition and would not choose (a Mac that dual-boots macOS; see
   docs/troubleshooting.md). The
   destination does not have to be a stick: another machine, a phone, a cloud folder. It is
   recommended, not required; `regenerate` warns and asks for confirmation if no backup was
   taken, and continues. Keep the copy encrypted. A reinstall is exactly the event that
   destroys the original, and Apple withdrawing the signing is the one thing regeneration
   cannot get you past.
4. **Password login stays.** Nothing in t1-revive touches PAM. When you later enrol a
   fingerprint with t1bridge, keep a root shell open and test the password fallback for
   `sudo` and the lock screen before you close it. On Omarchy the exact PAM lines and that
   warning are in [docs/omarchy.md](docs/omarchy.md).
5. **Confirmations stay on.** The tool asks before it starts and before it writes the ESP;
   `--confirm-each` asks before every device step if you want to follow along step by step.
   `--no-confirm` and `--demo` exist for the maintainer's rehearsals and recordings. A tester
   never uses them.
6. **Full power cycle means shutdown**, wait 20-30 seconds, power on. A reboot leaves
   the T1 where it was. Every fallback in the tool assumes the real thing.
7. **No identifiers, ever.** Serial numbers, ECIDs, nonces, tickets, anything from
   `EFI/APPLE`, `/var/lib/t1-revive` or `/var/lib/t1bridge`, keybags, hostnames,
   usernames, paths, addresses: not in issues, not in screenshots, not in DMs. The
   report bundle and the `t1-revive-diagnostic` lines are safe by design; see
   [docs/diagnostics.md](docs/diagnostics.md) for the full lists.
8. **No fragments.** Do not run parts of the procedure from gists, screenshots, or
   another Mac's EFI folder. The tool exists because the bare procedure has a window
   where an interrupted step leaves the chip in recovery; the tool's checks and
   confirmations are the guard rails.

## What happens with a report

- New issues are triaged by the maintainer's own agent, which reads the bundle, checks
  it for identifiers, applies `model:<id>` and `state:<t1-state>` labels, and asks the
  first questions under `needs-info`. A human reads every issue before anything is
  concluded about a device or a model.
- A `needs-info` reply usually asks for one thing: a reproduction and
  `sudo t1-revive report --since <MIN>`. Your agent can prepare the reply; you approve it.
- A failure becomes one of: a fix in t1-revive, a report filed upstream (t1bridge,
  libimobiledevice) with your permission and your handle if you want it, or a documented
  limitation in `docs/troubleshooting.md` with the model and the exact symptom.
- A success on a model that was `untested` becomes `tested` in `lib/discover.sh` and a
  row in the README table.

## Response expectations

One person maintains this, next to a job. Best effort means: a first reply within a few
days, faster for a machine that is stuck mid-recovery (say so in the title). Nobody is on
call. If a `STOPPED:` line names a fallback, the fallback is safe to apply while you wait;
the tool was designed so that waiting costs nothing but time.

## Getting into the README table

A model is confirmed when one tester reports, with the bundle attached, that a full power
cycle after staging brings the T1 up booted with the Touch Bar lit, and a second cold boot
does the same. Touch ID on top of that is a separate row. The row carries the model, the
distro and kernel from the bundle, the t1-revive version, the date, and your GitHub handle
if you ticked "yes" in the form. You can ask for the handle to be removed at any time.
