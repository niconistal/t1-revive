# Threat model

What this tool sees, what it never sees, what Apple's servers see, what is stored and for how
long, what someone holding the state directory could do, and what we can and cannot claim.

## Parties

- The T1 and its Secure Enclave (SEP). The SEP holds the identity keys burned at the factory,
  does the fingerprint matching, and verifies the factory data record before it will enroll
  anything.
- The host: this Linux install, running `t1-revive` as root.
- Apple's servers: the TSS signing service at `gs.apple.com`, the FDR factory data service
  reached through the restore protocol, and the CDN at `swcdn.apple.com` that serves the
  public firmware package.
- t1bridge, which takes over after regeneration. Its own threat model is in its repository;
  this document stops at the handover.

## What the host sees

During the provision and personalize steps the host is the restore client. It holds, as files under
`/var/lib/t1-revive/private/` (directory 0700, files 0600, root only):

- the FDR store (`FDRData`): the Apple-signed factory data record for this chip and this
  sensor module. It contains identifiers, among them the fingerprint sensor's serial, which
  is how t1bridge's importer later matches it to the live sensor;
- the personalised boot image (`combined.preflight.memboot`) and its AP ticket: the image
  the firmware loads at every boot, signed for this chip;
- the unredacted idevicerestore and usbmuxd logs of each pass, which contain the chip's
  identity and nonces.

The host also holds redacted copies of the logs under `/var/log/t1-revive/` (0700). The
redaction runs at the source: long hex runs, MAC addresses, ECID-style tokens and
serial-looking tokens are replaced before a line is written.

## What the host never sees

- Fingerprints or fingerprint templates. Enrollment and matching happen inside the SEP;
  the host exchanges commands and results with it through t1bridge, never biometric data.
- The SEP's identity keys. They are what the whole scheme relies on staying intact, and
  nothing in this procedure reads or writes them.
- The keys that protect t1bridge's keybag. t1bridge stores the SEP's protected state as an
  opaque blob under its own root-only directory; this tool does not touch it.

## What Apple's servers see

What any T1 or iPhone restore sends: the chip's identity and nonces, so the servers can sign
for this chip and answer with its factory data. The same request a macOS reinstall makes.
Nothing about your files, your users or your fingerprints leaves the machine. As with any
HTTPS request, the servers see the address you connect from.

The firmware package download is an ordinary CDN fetch of a public file. The tool verifies
it against a pinned checksum before extracting it.

## What is stored and for how long

| What | Where | Lifetime |
| --- | --- | --- |
| FDR store, boot image, ticket, unredacted logs | `/var/lib/t1-revive/private/` | until you delete them. Nothing expires. They are the resume material for `--from` and a second copy of what the ESP holds. `private/attempts/` keeps the files of earlier attempts that a new restore set aside |
| previous `EFI/APPLE` files, if any | `/var/lib/t1-revive/efi-backup-<stamp>/` | until you delete them |
| redacted logs | `/var/log/t1-revive/` | until you delete them |
| firmware package and bundle | `/var/cache/t1-revive/` | until you delete them; contains no device data |
| `combined.memboot`, `FDRData`, `version.plist` | ESP `EFI/APPLE/EMBEDDEDOS/` | permanent by design; the firmware loads them at every boot |

`t1-revive status` shows what is present. Removing the package does not remove any of it;
the ESP folder must never be removed, because it is what the T1 boots from.

## An attacker with the state directory

Assume someone obtains a copy of `/var/lib/t1-revive/private/` and the ESP folder.

They could:

- learn the chip's identifiers and the sensor module's serial;
- boot this same T1 with the captured image and ticket, which is what the Mac's firmware
  does at every boot anyway from the unencrypted ESP;
- read the restore logs of the passes.

They could not:

- enroll or match a fingerprint. There is no biometric data in these files;
- use the data on another Mac. The record is bound to this chip and this sensor; the SEP
  rejects another machine's file, which is also why another machine's backup cannot help
  you;
- obtain a new signed ticket or a new record without the chip. The signing happens on
  Apple's side against the chip's identity.

The ESP is a FAT filesystem outside any disk encryption on every Mac, so the three staged
files are as exposed on a stock macOS machine as they are here. The private directory adds
the unredacted logs to that exposure, which is why it is 0700 and why the report bundle
never includes it.

## Why an off-disk copy is still wise

Every failure mode we know of ends in the same recovery mode a wiped machine already is in,
and a preserved copy of `EFI/APPLE` turns even that into a copy back and a power cycle. The
one permanent scenario is external: Apple withdrawing the server-side signing that
regeneration depends on. Apple does stop signing old firmware. From that day a wiped T1 with
no backup is unrecoverable by anyone, macOS reinstall included.

Everything short of that day is recoverable without a backup, so the backup is not a gate.
`stage` records any existing `EMBEDDEDOS` files under `efi-backup-<stamp>/` in the state
directory before it overwrites them, and regeneration produces the data again whenever it is
needed. `regenerate` warns when no off-disk copy has been confirmed and asks you to confirm
before it continues; it does not stop. What the warning is about is the one scenario above,
which no on-disk copy survives, because the disk is what a reinstall erases.

If any of `EFI/APPLE` still exists, `backup --to` copies it and checks that `FDRData` is
inside. The destination only has to be somewhere other than this disk. If the folder is
gone, there is nothing to copy, and the first thing to do after regeneration is to copy the
new folder off the disk, encrypted, and keep it.

## Failure modes and what is permanent

| Event | Permanent | Recovery |
| --- | --- | --- |
| a restore step aborts mid-way | no | the T1 falls back to its ROM recovery mode (`05ac:1281`); power cycle, resume |
| a wrong or interrupted write during the restore | no, by design | the boot ROM is immutable silicon; recovery lives there, as on an iPhone |
| the boot step starts then falls back | no | rerun personalize; never request a new ticket alone |
| a bad file on the ESP | no | the ROM validates what it loads; bad means recovery mode, not damage |
| the forbidden ACPI method | unknown | never called; the runtime refuses it, CI greps for it |
| Apple stops signing | yes | none, for anyone; hence the backup |
| SEP-internal state wedged by an enrollment | no evidence of permanence | two independent machines cleared stuck enrollments with a service restart or a power cycle; listed as unknown, not as safe |

Nothing here writes Mac firmware, SEP fuses, or NVRAM beyond what a normal boot does.

## What "equivalent in kind" means

The record macOS writes on a first boot comes from the same online repair, against the same
servers, as a signed IMG4 record, and is verified locally by the SEP before enrollment. The
record this tool produces comes from that same transaction. So: same kind, same origin, same
verification. Afterwards the machine works offline, as it does under macOS.

What we do not claim: that the file is byte-identical to the one macOS would have written
(unverifiable; the original is gone); that Apple approved this use; that Apple's security
was bypassed, cracked or jailbroken in any way (nothing was circumvented: the chip asked
Apple for its own data, Apple signed it, the SEP checked it); that this works on every T1
Mac (one model tested); or that this is the first T1 brought up on Linux (it is not: the
restore recipe and the Touch Bar drivers came before, and Touch ID on Linux is t1bridge's).

## Reporting

A redaction gap, a path that touches the device without confirmation, or a write outside
`EFI/APPLE/EMBEDDEDOS` is a security issue. See [SECURITY.md](../SECURITY.md).
