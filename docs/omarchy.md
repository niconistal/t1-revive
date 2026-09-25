# t1bridge on Omarchy: the three things its README does not cover

Install t1bridge from its own README:
[standardagents/t1bridge](https://github.com/standardagents/t1bridge). It ships signed
packages for Arch and Omarchy, and its docs are the authority on everything below the
surface. This page is the Omarchy delta only: a firewall rule, the PAM wiring, and the
quirks we hit on a real Omarchy machine. Nothing here is a fork of the installer and
nothing here replaces a t1bridge command.

All of it belongs upstream. Issues and pull requests are being filed; until they land,
this page is the written-down version.

Verified on one MacBookPro14,3, Omarchy 4.0.2, kernel 7.1.9.

## 1. The firewall rule

t1bridge's xART service listens on inbound IPv6 TCP 61500, on the T1's own private USB
network link. Its setup doc says to permit that and to scope any exception to that
interface. On Omarchy, ufw is active and default-deny, so a first enrollment times out and
then fails immediately until the rule exists. `xart: ready` means the service runs, not
that the T1 can reach it.

The interface is driven by `apple_t1_ncm` and its name is assigned at enumeration, so read
it rather than hard-coding it:

```sh
for d in /sys/class/net/*; do
  [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = apple_t1_ncm ] &&
    basename "$d"
done
```

`sudo t1bridge status` also reports it. With that name in `$ncm`, one rule:

```sh
sudo ufw allow in on "$ncm" proto tcp from fe80::/10 to any port 61500 comment 't1bridge xART (T1 link only)'
```

Scoped to that interface and to link-local sources. Never open 61500 on Wi-Fi, on
Ethernet, or on all interfaces, and do not save the interface name into a portable rule
set: it can differ on the next machine or the next boot.

## 2. The PAM lines

t1bridge deliberately ships no PAM files. Omarchy has its own fingerprint lines, applied
by `omarchy-setup-security-fingerprint`. Do not run that command here: alongside the PAM
edits it installs the stock `fprintd` and `libfprint` packages, which would replace
t1bridge's matched pair and break Touch ID. Apply only the PAM half, by hand.

Before you edit anything, open a root shell in a second terminal and leave it open. Test
the password fallback for `sudo` and for the lock screen before you close it.

Top of `/etc/pam.d/sudo`, in this order, above the existing lines:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
```

The first line is the clamshell gate. When the lid is closed the sensor is unreachable, so
it skips the fingerprint line and the stack falls through to the password. The second line
is `sufficient`, not `required`, so a failed or cancelled touch still reaches `pam_unix`.
Leave every existing line in the file untouched; those lines are the password fallback.

`/etc/pam.d/polkit-1` gets the same two lines at the top. If the file does not exist,
create it:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
```

The lock screen reads its own file, `/etc/pam.d/omarchy-lock-fingerprint`:

```
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
```

This one is `required` on purpose: it is a fingerprint-only path the lock screen offers
next to its normal password path, not a replacement for it.

Apply the lines only after a finger is enrolled and `fprintd-verify` matches. Then, in the
terminal that still has the root shell next to it:

```sh
sudo -k; sudo true          # by touch
sudo -k; sudo true          # again, cancel the touch, then type the password
```

Lock the screen and test both ways too. To back out, delete every line mentioning
`pam_fprintd.so` or `omarchy-hw-laptop-closed` from `sudo` and `polkit-1`, and remove
`/etc/pam.d/omarchy-lock-fingerprint`.

## 3. Known quirks on Omarchy

**A failed keybag unit blocks enrollment.** If `t1bridge-keybag.service` was left in the
`failed` state, for instance by a crash loop before a reinstall, the broker's relay check
errors out before enrollment reaches the enclave. Clear it first:

```sh
sudo systemctl reset-failed t1bridge-keybag.service t1-touchid-auth.service
```

**The first enrollment can fail once.** `enroll-unknown-error` on the very first attempt
means the keybag is still being bootstrapped. Restart the broker and try once more:

```sh
sudo systemctl restart t1-touchid-auth.service
fprintd-enroll -f right-index-finger
```

A second failure is real. Check `sudo t1bridge status` for `xart: ready` and check the
firewall rule above.

**Touch ID stops after the machine sat locked overnight.** `t1bridge-keybag.service`
restarts every 2 s with "load biometric keybag failed". The lock screen retries the
fingerprint every 30 s and a long run of timeouts wedges the enclave session. Fix: full
shutdown, then power on. A reboot is not enough. Password login is never affected. Do not
delete `/var/lib/t1bridge` to clear it. Reported upstream.

**`t1bridge-import.service` fails with exit 30, "private import temporary file could not be
created".** Seen on a 13,3 (issue #4): the unit runs with `ProtectSystem=strict`, so `/` is
read-only, and the importer writes its temporary file to its working directory. A drop-in
that gives it a writable one clears it:

```sh
sudo systemctl edit t1bridge-import.service
# [Service]
# WorkingDirectory=/var/lib/t1bridge/machine-data
sudo systemctl daemon-reload && sudo systemctl start t1bridge-import.service
```

Not seen on the 14,3. On a 13,2 (issue #10) the drop-in was **not** enough and the unit still
failed with exit 30; running the import by hand against the already-mounted ESP worked:

```sh
sudo t1bridge machine-data import --from /boot/EFI/APPLE/EMBEDDEDOS
```

If the unit fails for you either way, the import by hand is the way through, and the unit
belongs upstream with t1bridge.

**The Touch Bar stays dark until you log out and back in.** The renderer runs under your
systemd user manager, which fixed its supplementary groups when the session started, before
the `t1bridge` group existed. Log out and back in, then the bar lights. Touch ID does not
depend on the renderer and works before that.

## 4. No reboot needed after regeneration

`t1-revive regenerate` leaves the T1 booted and the ESP staged. `t1-revive handover`
re-enumerates the device so t1bridge's configuration selector picks it up, with no restart
of anything. So the order that works in one sitting is: regenerate, install t1bridge,
`sudo t1-revive handover`, then enroll.

A plain reboot works just as well. The firmware loads the staged files at boot and
t1bridge takes the T1 from there. Use whichever you prefer; nothing downstream depends on
the choice.

## 5. Volume and media buttons on the Touch Bar

t1bridge's built-in renderer draws volume, mute and media buttons only when a desktop
provider is set. The core package ships none, by design: its README leaves audio, media and
HUDs to distribution integrations. Without one the bar keeps Escape, the hardware controls
and the F-keys, with no volume.

[`contrib/omarchy/t1bridge-omarchy-provider.sh`](../contrib/omarchy/t1bridge-omarchy-provider.sh)
implements t1bridge's
[desktop provider v1](https://github.com/standardagents/t1bridge/blob/main/docs/interfaces.md#desktop-provider-v1)
contract with Omarchy's own tools:

- Volume and mute move the same sink as Omarchy's volume keys (`omarchy-audio-output-sink`,
  `pactl`) and show Omarchy's OSD.
- Previous, play/pause and next go through `omarchy-shell media`. They appear only while an
  MPRIS player is running.
- Display and keyboard brightness changes show Omarchy's OSD.
- The bar goes dark while Hyprland has the displays off, such as after the lock screen
  blanks them. The Touch Bar does not wake the displays.

It runs as you, never as root. Install it where your user can execute it and point the
Touch Bar user service at it:

```sh
install -Dm755 contrib/omarchy/t1bridge-omarchy-provider.sh ~/.local/bin/t1bridge-omarchy-provider
mkdir -p ~/.config/systemd/user/t1-touchbar.service.d
printf '[Service]\nEnvironment=T1BRIDGE_DESKTOP_PROVIDER=%%h/.local/bin/t1bridge-omarchy-provider\n' \
  > ~/.config/systemd/user/t1-touchbar.service.d/omarchy-provider.conf
systemctl --user daemon-reload
systemctl --user restart t1-touchbar.service
```

`%h` is systemd's specifier for your home directory; the value must be an absolute path.
To check the provider by hand, `~/.local/bin/t1bridge-omarchy-provider v1 status` prints
one line such as `T1BRIDGE-DESKTOP 1 29 50 0 1`: capabilities, volume, muted, display on.
To remove it, delete the drop-in and restart the service.

The dark-bar-with-the-displays behaviour needs t1bridge 0.1.10 or newer, the first release
whose built-in renderer understands display power. An older release is not harmed by it:
0.1.9 accepts the capability and ignores it, checked against a running 0.1.9 renderer, so the
bar simply keeps its controls. If some renderer ever does object to the bit, adding
`Environment=T1BRIDGE_OMARCHY_DISPLAY_POWER=0` to the same drop-in withdraws it and leaves
volume, media and the OSDs untouched.

Tested on one MacBookPro13,3, Omarchy 4.0.4, t1bridge 0.1.12, kernel 7.2.5, and one
MacBookPro14,2, Omarchy 4.0.4, t1bridge 0.1.12, kernel 7.2.5-3-omarchy.
