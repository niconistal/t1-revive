# Shareable diagnostics

t1-revive emits one structured line per event, always on, with no free text and no
identifiers. Those lines, plus the bundle printed by `t1-revive report`, are the only
things a tester needs to paste into an issue. Everything else the tool writes stays on the
machine.

## The diagnostic line

```text
t1-revive-diagnostic v=1 component=regenerate step=provision result=ok elapsed=97
t1-revive-diagnostic v=1 component=regenerate step=reset-1 result=error code=5 t1=none
t1-revive-diagnostic v=1 component=preflight check=kernel-headers result=error
t1-revive-diagnostic v=1 component=stage step=verify result=ok files=3
```

Rules of the format:

- The prefix is literally `t1-revive-diagnostic v=1 `. `v` is the format version; a change
  that alters the meaning of an existing key bumps it.
- After the prefix come `key=value` pairs separated by single spaces. Keys are lowercase
  `[a-z-]+`. Values match `[A-Za-z0-9._:-]+`: no spaces, no quotes, no paths, no free text.
  The emitter rejects anything else rather than escaping it.
- `component` is always present and names the command that emitted the line.
- Every line is appended to the redacted log for the current command under the log
  directory (`/var/log/t1-revive`, root only) and sent to the journal with the tag
  `t1-revive`, so `journalctl -t t1-revive` finds it. `T1R_NO_JOURNAL=1` keeps lines out of
  the journal; the test suite sets it. `component=test` lines are the suite's and are
  ignored by `report` and `status`.

### Keys

| Key | Values | Meaning |
| --- | --- | --- |
| `component` | `preflight` `backup` `status` `regenerate` `stage` `handover` `firmware` `distro` `report` | the command or module that emitted the line |
| `step` | `provision` `reset-1` `personalize` `reset-2` `boot` `stage` `handover` `fetch` `verify` `extract` `backup` | the step inside a command |
| `phase` | `start` `wait` `done` | position inside a step, when a step has a long wait |
| `check` | a preflight check name, e.g. `model` `kernel-headers` `acpi-call` `usbmuxd` `network` `esp` `t1-state` | which preflight check produced the result |
| `result` | `ok` `error` `skipped` `refused` `timeout` | outcome of the step or check |
| `code` | an exit code from the table in `AGENTS.md` (`1`-`7`) | present when `result=error` or `result=refused` |
| `t1` | `recovery` `booted` `none` | USB state of the T1 at the moment of the line |
| `config` | `1` `2` | USB configuration of a booted T1 |
| `model` | a DMI product name such as `MacBookPro14,3` | the model the tool identified (a model is not an identifier) |
| `model-status` | `tested` `untested` `unsupported` | the allowlist verdict |
| `elapsed` | seconds as an integer | wall time of the step |
| `attempt` | `1` `2` ... | retry counter |
| `files` | an integer | number of files verified or staged |
| `esp` | an integer | number of EFI System Partitions found |

Adding a key means adding a row here, in the same change. Values that would need free text
belong in the human-readable message next to the line, not in the line.

### What a line never contains

Serial numbers, ECIDs, nonces, tickets, hashes of device data, MAC addresses, hostnames,
usernames, home directories, device names beyond `/dev/...` block device paths, sysfs
paths, file contents, URLs with query strings. The emitter cannot put those in a line
because of the value grammar, and the log the line lands in is itself redacted at the
source (`redact` replaces long hex runs, MAC addresses, ECID values and serial-looking
tokens before anything reaches disk).

## The report bundle

`t1-revive report` prints the whole picture in one pass, in a fixed order, so both a person
and an agent can read it without guessing. Every line is either `key: value` or a
diagnostic line. The sections, in order:

| Section | What it holds |
| --- | --- |
| `tool` | report format, time (UTC, minute precision), whether it ran as root, tool version, dry-run and demo flags |
| `system` | distro `PRETTY_NAME`, running kernel, installed kernel package, whether they match, whether headers exist |
| `model` | DMI product name and its allowlist status |
| `t1` | `t1-state` (`recovery`, `booted`, `none`) and `t1-config` for a booted T1 |
| `esp` | one block per EFI System Partition: device path, mounted, `EFI/APPLE` present, `EMBEDDEDOS` present, and for `combined.memboot`, `FDRData`, `version.plist` a yes/no plus size rounded to KB. A partition that is not mounted (Apple's ESP on a dual-boot Mac) is looked at through a read-only probe mount when the report runs as root (`note: probed-read-only`); otherwise its fields stay `?` (`note: not-mounted-needs-root`). Then `esp-candidates`, `esp-selected` (the device the tool would use, or `ambiguous`) and `esp-selected-why`. Names and sizes only; nothing is opened |
| `reset` | whether `acpi_call` is loaded and whether the FRST method was found in the ACPI tables (found/not-found, never the path, never a call) |
| `state` | whether the private state directory exists, the names of step markers, the number of EFI backups |
| `packages` | versions of the kernel, headers, `acpi_call-dkms`, `dkms`, t1bridge and its fingerprint packages |
| `t1bridge` | the first 30 lines of `t1bridge status` when installed and running as root |
| `diagnostics` | the last 200 diagnostic lines from the log directory and from the journal, each source counted |
| `end` | marker, followed by the checksum line |

The last line is `report-sha256: <hex>`, the SHA-256 of every line above it. Someone reading
a pasted bundle can check it was not truncated or edited:

```bash
head -n -1 report.txt | sha256sum
```

Without root the bundle still prints; sections that need root say `needs-root` instead of
failing (`/boot` is often mode 0700, the state and log directories always are, and
`t1bridge status` needs root). Run it both ways if unsure; the root bundle is the useful one.

### Options

```text
t1-revive report [--out FILE] [--since MIN]
```

`--out FILE` writes the bundle to a file instead of the terminal. `--since MIN` restricts the
diagnostic section to the last MIN minutes, useful right after a reproduction:

```bash
sudo t1-revive report --since 15 --out t1-revive-report.txt
```

## More detail

There is no verbosity switch. Diagnostic lines are always on and always identifier-free.
The redacted per-command logs under `/var/log/t1-revive` hold the human-readable messages
around each line (`latest.log` points at the most recent run). They are redacted at the
source, but redaction is a filter, not a proof; do not paste a whole log into a public
issue. If the maintainer needs a specific passage, they will ask for a specific passage,
and you read it before you paste it.

Nothing under `/var/lib/t1-revive` is ever shareable: it holds the FDR store, the
personalised boot image, the ticket, and the EFI backups. The tool never prints from it and
the report only lists names and counts from it.

## Export

```bash
sudo t1-revive report --out t1-revive-report.txt
cat t1-revive-report.txt        # read it once, all of it
```

For a reproduction of one problem, note the time, reproduce once, then use `--since`. If the
tool is not installed or will not run, the journal alone still works:

```bash
journalctl -t t1-revive -o cat --no-pager | grep '^t1-revive-diagnostic '
```

## Safe to paste

- the complete `t1-revive report` bundle, in a fenced code block, checksum line included
- any line starting with `t1-revive-diagnostic ` or `t1bridge-diagnostic `
- the `STOPPED:` line and the exit code the tool printed
- `pacman -Q` output for the packages in the bundle
- the model identifier (`MacBookPro14,3` is a model, not a serial)

## Never paste

- serial numbers, ECIDs, nonces, tickets, SHSH blobs, or anything from the restore
  transaction with Apple
- the contents of any file under `EFI/APPLE`, of `/var/lib/t1-revive`, or of
  `/var/lib/t1bridge`; not hexdumps, not "just the header", not sizes beyond what the
  report already rounds
- full journals, `dmesg`, `lsusb -v`, or `udevadm info` output: they carry serials and
  bus paths
- keybags, catacombs, calibration, or any biometric state
- hostnames, usernames, home-directory paths, IP addresses, MAC addresses
- screenshots of a terminal that shows any of the above

If something slipped into a paste, edit the issue immediately. Nothing needs rotating,
because nothing in the T1's data can be rotated; that is exactly why it must not leak.
