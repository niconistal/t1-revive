#!/usr/bin/env bash
# lib/distro.sh - package installs and kernel checks. Arch (and Arch-derived, e.g. Omarchy)
# and Fedora implemented; anything else fails with a clear message. Nothing runs at source time.
#
# shellcheck shell=bash

: "${T1R_OS_RELEASE:=/etc/os-release}"
: "${T1R_MODULES_DIR:=/usr/lib/modules}"
export T1R_OS_RELEASE T1R_MODULES_DIR

# Packages the prefix binaries and the T1 reset need (from regen-preflight.sh). The kernel
# headers are deliberately not in this list: which package carries them depends on the kernel
# that is booted, so distro_required_pkgs appends distro_headers_pkg.
T1R_ARCH_PKGS="libzip libusb curl openssl readline dkms acpi_call-dkms"
# Fedora names for the same runtime libraries. Fedora does not package acpi_call, so it is not
# in the list: preflight's /proc/acpi/call check covers it and says where to get it.
T1R_FEDORA_PKGS="libzip libusb1 libcurl openssl-libs readline"
export T1R_ARCH_PKGS T1R_FEDORA_PKGS

_os_release_get() {  # _os_release_get KEY
  local k=$1 v
  [[ -r "$T1R_OS_RELEASE" ]] || return 1
  v=$(sed -n "s/^$k=//p" "$T1R_OS_RELEASE" | head -1)
  v=${v%\"}; v=${v#\"}
  [[ -n "$v" ]] && printf '%s\n' "$v"
}

# distro_id: ID from os-release (e.g. arch, omarchy, fedora); "unknown" when unreadable.
distro_id() { _os_release_get ID || printf 'unknown\n'; }

# distro_family: "arch" or "fedora" when ID or ID_LIKE says so, else the ID.
distro_family() {
  local id like
  id=$(distro_id); like=$(_os_release_get ID_LIKE 2>/dev/null || true)
  case " $id $like " in
    *" arch "*|*" archlinux "*) printf 'arch\n';;
    *" fedora "*) printf 'fedora\n';;
    *) printf '%s\n' "$id";;
  esac
}

_rpm() { env LC_ALL=C rpm "$@"; }  # rpm with untranslated output

_pacman() {  # pacman with Omarchy's direct-pacman guard lifted when Omarchy is present
  if [[ -d /usr/share/omarchy ]]; then env OMARCHY_ALLOW_DIRECT_PACMAN=1 LC_ALL=C pacman "$@"
  else env LC_ALL=C pacman "$@"; fi
}

# distro_install PKG...: install packages (no-op for the ones already present). Only the missing
# ones are handed to pacman, so an up-to-date system prints no "is up to date -- skipping" noise.
distro_install() {
  [[ $# -gt 0 ]] || return 0
  case "$(distro_family)" in
    arch)
      local -a missing=() p
      for p in "$@"; do pacman -Q "$p" >/dev/null 2>&1 || missing+=("$p"); done
      [[ ${#missing[@]} -gt 0 ]] || return 0
      run_cmd _pacman -S --needed --noconfirm "${missing[@]}";;
    fedora)
      local -a missing=() p
      for p in "$@"; do _rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
      [[ ${#missing[@]} -gt 0 ]] || return 0
      run_cmd dnf install -y "${missing[@]}";;
    *) die 1 "package installation is only implemented for Arch-based systems and Fedora (this is '$(distro_id)'). Install the equivalents of: $* - then rerun without --install.";;
  esac
}

# distro_installed PKG...: 0 when every package is installed (Arch, Fedora); 1 otherwise.
distro_installed() {
  case "$(distro_family)" in
    arch) pacman -Q "$@" >/dev/null 2>&1;;
    fedora) _rpm -q "$@" >/dev/null 2>&1;;
    *) return 1;;
  esac
}

# distro_needs_sync: 0 when the sync DB looks like a fresh install's offline DB (go.sh step 2):
# acpi_call-dkms unknown to pacman, or the repo kernel differs from the installed one.
distro_needs_sync() {
  [[ "$(distro_family)" = arch ]] || return 1
  local repo inst
  pacman -Si acpi_call-dkms >/dev/null 2>&1 || return 0
  repo=$(pacman -Si linux 2>/dev/null | awk '/^Version/{print $3}' | kver_normalize)
  inst=$(pacman -Q linux 2>/dev/null | awk '{print $2}' | kver_normalize)
  [[ -n "$repo" ]] && [[ -n "$inst" ]] && [[ "$repo" != "$inst" ]]
}

# distro_sync_and_upgrade: keyring refresh, then a full upgrade (the go.sh logic for a fresh
# Omarchy install). Callers check distro_kernel_matches afterwards and exit 7 if it changed.
distro_sync_and_upgrade() {
  case "$(distro_family)" in
    arch)
      note "refreshing the package keyring and upgrading the system (a few minutes on a fresh install)"
      run_cmd _pacman -Sy --noconfirm archlinux-keyring || return 1
      if [[ -d /usr/share/omarchy ]]; then
        run_cmd _pacman -Syu --noconfirm --overwrite '/usr/share/omarchy/*' || return 1
      else
        run_cmd _pacman -Syu --noconfirm || return 1
      fi
      ;;
    *) die 1 "system upgrade is only implemented for Arch-based systems (this is '$(distro_id)')";;
  esac
}

# distro_kernel_pkg: the installed package that owns the running kernel, resolved from that
# kernel's own module directory - never assumed to be `linux`. On Omarchy the booted kernel
# comes from linux-omarchy while a stock, unbooted `linux` is usually installed alongside it,
# and reading that one names a kernel that is not running (issues #7 and #9). Prints nothing
# and returns 1 for a kernel no package owns (hand-built, or a fixture module directory).
distro_kernel_pkg() {
  local owner
  case "$(distro_family)" in
    arch)
      command -v pacman >/dev/null 2>&1 || return 1
      owner=$(pacman -Qqo "$T1R_MODULES_DIR/$(uname -r)/vmlinuz" 2>/dev/null | awk 'NF{print $1; exit}');;
    fedora)  # kernel-core owns the vmlinuz in the module directory
      command -v rpm >/dev/null 2>&1 || return 1
      # rpm -qf prints "file ... is not owned by any package" on stdout, so trust its exit
      # status, not its output
      owner=$(_rpm -qf --qf '%{NAME}\n' "$T1R_MODULES_DIR/$(uname -r)/vmlinuz" 2>/dev/null) || return 1
      owner=$(awk 'NF{print $1; exit}' <<<"$owner");;
    *) return 1;;
  esac
  [[ -n "$owner" ]] || return 1
  printf '%s\n' "$owner"
}

# distro_kernel_pkg_version: version of the package that owns the running kernel. Fedora keeps
# several kernel-core versions installed at once, so this asks for the owner of this kernel's
# vmlinuz rather than the package name. Prints nothing and returns 1 when unresolved.
distro_kernel_pkg_version() {
  local v kpkg
  case "$(distro_family)" in
    fedora)
      command -v rpm >/dev/null 2>&1 || return 1
      v=$(_rpm -qf --qf '%{VERSION}-%{RELEASE}\n' "$T1R_MODULES_DIR/$(uname -r)/vmlinuz" 2>/dev/null) || return 1
      v=$(awk 'NF{print; exit}' <<<"$v");;
    arch)
      kpkg=$(distro_kernel_pkg) || return 1
      v=$(distro_pkg_version "$kpkg");;
    *) return 1;;
  esac
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# distro_headers_pkg: the package that carries the headers for the running kernel - the owner
# of its build directory when they are installed, otherwise "<kernel package>-headers", and
# the stock "linux-headers" when neither can be resolved. So the check reads the headers dkms
# actually builds against on a -lts or -omarchy kernel instead of the stock ones, and
# `preflight --install` installs those.
#
# On Fedora the headers are kernel-devel, versioned per kernel; the full NEVRA of the running
# kernel's (`kernel-devel-$(uname -r)`) is what both `rpm -q` and `dnf install` take, and it
# names exactly the build tree DKMS uses, whichever kernels are installed besides it.
distro_headers_pkg() {
  local owner kpkg
  if [[ "$(distro_family)" = fedora ]]; then
    printf 'kernel-devel-%s\n' "$(uname -r)"
    return 0
  fi
  if [[ "$(distro_family)" = arch ]] && command -v pacman >/dev/null 2>&1; then
    owner=$(pacman -Qqo "$T1R_MODULES_DIR/$(uname -r)/build" 2>/dev/null | awk 'NF{print $1; exit}')
    if [[ -n "$owner" ]]; then printf '%s\n' "$owner"; return 0; fi
    if kpkg=$(distro_kernel_pkg); then printf '%s-headers\n' "$kpkg"; return 0; fi
  fi
  printf 'linux-headers\n'
}

# distro_required_pkgs: the family's package list plus the headers package for the running kernel.
distro_required_pkgs() {
  case "$(distro_family)" in
    fedora) printf '%s %s\n' "$T1R_FEDORA_PKGS" "$(distro_headers_pkg)";;
    *) printf '%s %s\n' "$T1R_ARCH_PKGS" "$(distro_headers_pkg)";;
  esac
}

# distro_kernel_matches: 0 when the running kernel is the installed one. Primary rule: a package
# owns the running kernel's module directory (any flavour: linux, -lts, -omarchy). Also
# accepted: the `linux` package version (normalised) equals uname -r, for a module directory
# no package owns.
distro_kernel_matches() {
  local running inst
  running=$(uname -r)
  if [[ "$(distro_family)" = arch ]] && command -v pacman >/dev/null 2>&1; then
    distro_kernel_pkg >/dev/null 2>&1 && return 0
    inst=$(pacman -Q linux 2>/dev/null | awk '{print $2}' | kver_normalize)
    [[ -n "$inst" ]] && [[ "$inst" = "$running" ]] && return 0
    return 1
  fi
  # Fedora installs each kernel as its own package version, so ownership of the running
  # kernel's module directory is the whole rule there.
  if [[ "$(distro_family)" = fedora ]]; then
    distro_kernel_pkg >/dev/null 2>&1
    return
  fi
  return 1
}

# distro_headers_present: kernel headers for the running kernel.
distro_headers_present() { [[ -d "$T1R_MODULES_DIR/$(uname -r)/build" ]]; }

# distro_pkg_version PKG: installed version or empty.
distro_pkg_version() {
  case "$(distro_family)" in
    arch) pacman -Q "$1" 2>/dev/null | awk '{print $2}';;
    fedora)  # like rpm -qf, rpm -q reports "not installed" on stdout with a non-zero status
      local v
      v=$(_rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1" 2>/dev/null) || return 1
      awk 'NF{print; exit}' <<<"$v";;
    *) return 1;;
  esac
}
