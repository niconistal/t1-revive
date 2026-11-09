#!/usr/bin/env bats
# lib/distro.sh on Fedora: rpm queries, kernel-devel headers, dnf installs.
#
# rpm and the module tree are fixtures (t1r_stub_rpm), so the machine running the suite does
# not change the answers. The case that matters most is two kernel-core versions installed at
# once, which Fedora does by default: the running kernel's package has to be resolved from its
# own module directory, not by package name.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/distro.sh ]] || skip "lib/distro.sh not present"
  t1r_use_osrelease fedora
  t1r_stub_rpm
  t1r_load distro
  t1r_need distro_family distro_kernel_pkg distro_kernel_pkg_version distro_headers_pkg \
    distro_required_pkgs distro_installed distro_install distro_kernel_matches distro_pkg_version
}

# two kernels installed, the newer one running
two_kernels() {
  t1r_rpm_installed kernel-core 7.2.11-300.fc45
  t1r_rpm_installed kernel-core 7.2.15-300.fc45
  t1r_rpm_owns "$(t1r_kernel_dir)/vmlinuz" kernel-core 7.2.15-300.fc45
}

@test "distro_family: ID=fedora is the fedora family" {
  run distro_family
  assert_status 0
  assert_eq fedora "$output"
}

@test "distro_family: a derivative with ID_LIKE=fedora is the fedora family too" {
  printf '%s\n' 'ID=synthetic' 'ID_LIKE="fedora"' >"$T1R_TMP/os-release"
  T1R_OS_RELEASE=$T1R_TMP/os-release
  run distro_family
  assert_eq fedora "$output"
}

@test "distro_kernel_pkg: kernel-core, from the owner of the running kernel's vmlinuz" {
  two_kernels
  run distro_kernel_pkg
  assert_status 0
  assert_eq kernel-core "$output"
}

@test "distro_kernel_pkg_version: the running kernel's version, not the first installed one" {
  two_kernels
  run distro_kernel_pkg_version
  assert_status 0
  assert_eq 7.2.15-300.fc45 "$output"
}

@test "distro_kernel_pkg: a kernel no package owns returns 1 and prints nothing" {
  t1r_rpm_installed kernel-core 7.2.15-300.fc45
  run distro_kernel_pkg
  assert_status 1
  assert_eq '' "$output"
}

@test "distro_headers_pkg: kernel-devel for exactly the running kernel" {
  run distro_headers_pkg
  assert_status 0
  assert_eq "kernel-devel-$(uname -r)" "$output"
}

@test "distro_required_pkgs: Fedora names, the running kernel's headers, no acpi_call package" {
  run distro_required_pkgs
  assert_status 0
  assert_contains "$output" 'libusb1'
  assert_contains "$output" 'openssl-libs'
  assert_contains "$output" "kernel-devel-$(uname -r)"
  refute_contains "$output" 'acpi_call'
  refute_contains " $output " ' libusb '
}

@test "distro_installed: by name and by the full kernel-devel NEVRA" {
  t1r_rpm_installed libzip 1.12.1-1.fc45
  run distro_installed libzip
  assert_status 0
  t1r_rpm_installed kernel-devel "$(uname -r | sed 's/\.[^.]*$//')"
  run distro_installed "kernel-devel-$(uname -r)"
  assert_status 0
  run distro_installed libusb1
  assert_status 1
}

@test "distro_install: hands only the missing packages to dnf" {
  t1r_rpm_installed libzip 1.12.1-1.fc45
  t1r_rpm_installed readline 8.3-1.fc45
  run distro_install libzip libusb1 readline libcurl
  assert_status 0
  assert_contains "$output" 'dnf install -y libusb1 libcurl'
  refute_contains "$output" 'libzip'
}

@test "distro_install: nothing missing, nothing run" {
  t1r_rpm_installed libzip 1.12.1-1.fc45
  run distro_install libzip
  assert_status 0
  refute_contains "$output" 'dnf'
}

@test "distro_kernel_matches: ownership of the running kernel is enough" {
  two_kernels
  run distro_kernel_matches
  assert_status 0
}

@test "distro_kernel_matches: no owner -> 1" {
  t1r_rpm_installed kernel-core 7.2.11-300.fc45
  run distro_kernel_matches
  assert_status 1
}

@test "distro_pkg_version: installed version, empty for a missing package" {
  t1r_rpm_installed dkms 3.4.4-1.fc45
  run distro_pkg_version dkms
  assert_eq 3.4.4-1.fc45 "$output"
  run distro_pkg_version acpi_call-dkms
  assert_eq '' "$output"
}
