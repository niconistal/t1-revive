# FAQ

Short answers, consistent with the README's claims. Expand only where the reader needs it.

## Will it work on my machine?

**Does this work on T2 Macs (2018 and later)?** No. T1 only: the 2016 and 2017 Touch Bar
MacBook Pros, `MacBookPro13,2`, `13,3`, `14,2`, `14,3`. T2 Macs keep their firmware
differently and have their own Linux projects (t2linux).

**Will it work on my 13,2, 13,3 or 14,2?** Untested by us. The tool accepts these four
models, warns on the three untested ones, and continues. t1bridge itself is confirmed on
13,2 and 13,3 by its testers. The restore recipe this tool follows was first done on a 13,2
for the Touch Bar. If you run it, use the checklist in
[hardware-validation.md](hardware-validation.md) and report the result either way; your row
goes in the README's tested table.

**Does it work on Ubuntu, Fedora, Debian?** The regeneration itself is distribution-neutral,
but the tool's package layer is implemented for Arch-based systems only and fails clearly
elsewhere. t1bridge ships signed packages for Arch and Omarchy only right now. Other
distributions need packaging work, not new discoveries.

**Does it survive kernel updates?** Yes. The `acpi_call` module is a DKMS package and
t1bridge's modules are too; they rebuild on update. The regenerated data on the ESP does not
depend on the kernel at all.

**Does sleep and wake work?** Not with the T1 stack, for anyone, at the time of writing.
t1bridge lists system suspend and resume as not working. Screen blanking is fine.

**Camera?** t1bridge ships a camera driver with H.264 support. We have not tested it on
regenerated data.

**Ambient light sensor?** Not available under t1bridge's USB configuration; upstream lists it
as planned.

## How do I recover mine?

**My installer wiped it. What do I run?** Read the README's caution first, then
`preflight`, `backup`, `regenerate`, in that order, at the keyboard, on mains power. If you
still have any copy of your EFI partition anywhere, keep it safe and tell the tool where it
is; with that copy you may not need regeneration at all.

**Can I run it if my Touch Bar works?** There is no need, and the tool refuses: a T1 at
`05ac:8600` with the `EMBEDDEDOS` folder present has nothing to regenerate. What you should
do instead is copy `EFI/APPLE` off the disk today, with `sudo t1-revive backup --to PATH` or by
hand. `backup` exits 0 only when it wrote a tar and checked it; on a Mac that dual-boots
macOS it looks inside the unmounted Apple ESP itself (see the troubleshooting page, "Two EFI
system partitions").

**Why not just reinstall macOS?** You can. A macOS restore through a complete first boot
regenerates the same data, and if you have macOS or a second Mac and the patience, that path
is Apple's own. This tool is for the machine that has no macOS left, no backup, and an owner
who does not want to rebuild the disk to get a fingerprint reader back. Both paths depend on
Apple's servers in the same way.

**I still have macOS. What should I do before installing Linux?** Copy the folder
`EFI/APPLE` from the EFI partition somewhere safe, or install into free space so the
partition is preserved. With that folder you never need any of this.

**Can I use someone else's EFI folder?** No. The data is bound to your chip and your
fingerprint sensor's serial. The Secure Enclave rejects another machine's file. That is also
why it is safe.

**What does resume mean?** Every step is a checkpoint. If the tool stops, power cycle and
`sudo t1-revive regenerate --from STEP`. The provision step's output is kept, so a failure
later does not repeat the first conversation with Apple.

## Is it safe? Is it allowed?

**Is this a jailbreak?** No. A jailbreak defeats a device's code signing to run code the
vendor did not sign. Here every image the T1 runs is signed by Apple for this chip, in a
transaction Apple's servers took part in, and the Secure Enclave verifies the record before
it enrolls anything. The open-source tools are patched to speak the T1's variant of the
restore protocol, not to skip any check. Nothing was circumvented, patched around, or
extracted.

**Does Apple know?** Apple's servers are used exactly the way a restore uses them: the chip
presents its identity and nonces, the signing service answers, the factory data service
answers. It is the same request a macOS reinstall makes. We have not asked Apple for
anything and do not claim their approval.

**Did you bypass or break Apple's security?** No. See the two answers above.

**Is regenerated data as safe as the original?** Same online repair, same servers, same kind
of Apple-signed record, same verification inside the enclave. Fingerprints are matched inside
the enclave; the host never sees them. We say "equivalent in kind" and not "byte-identical",
because the original file is gone and cannot be compared. The one policy difference is in
t1bridge, not in the data: after a reboot a fingerprint alone unlocks, where macOS wants a
password first. Full-disk encryption sits in front of that.

**Does this need Apple's servers forever?** Only to regenerate. Once the folder exists the
machine works offline, like on macOS.

**What if Apple stops signing?** Then regeneration stops working for everyone, macOS
reinstalls included, and a wiped T1 with no backup becomes unrecoverable. Apple does stop
signing old firmware. This is the one permanent scenario we know of, it is external, and it
is why the backup step comes first, and why the README tells you to copy the new folder off
the disk as soon as it exists. An off-disk copy is the only thing that survives it. The copy
`stage` keeps under the state directory does not: the disk is what a reinstall erases.

**What data is sent to Apple?** What a restore sends: the chip's identity and nonces, so the
servers can sign for that chip. Nothing about your files or your fingerprints. Fingerprints
never leave the enclave. See [threat-model.md](threat-model.md).

**Could this brick my Mac?** We have not found a permanent failure mode in anything the tool
runs. The T1's boot ROM is immutable and its recovery mode lives there, so an interrupted
step leaves the chip in recovery, which is where a wiped machine already is. The tool never
calls the one ACPI method known to freeze the host. That is different from promising there
is none, which is why the tool asks you to back up, confirms every device-touching step, and
ships a tested table with one row.

**Is this legal?** It uses public Apple services the way Apple's own installer does, with
open-source tooling that has restored iPhones for over a decade, and nothing of Apple's is
redistributed: the firmware package is downloaded from Apple at run time. The maintainer is
not a lawyer and this is not advice.

## Credit and priority

**Didn't Boyd already do Touch ID?** Yes, and this runs on his t1bridge. What t1bridge
requires is the factory data file macOS writes. What this tool shows is that the T1 can
regenerate that file from Linux, and that t1bridge accepts it (after a decoder fix that is
now upstream in 0.1.6).

**Can I write about this?** Yes. Link the repository, quote the claim precisely (no macOS
reinstall, no file from another Mac, Apple's own protocol, one model tested), and credit
t1bridge.
