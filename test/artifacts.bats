#!/usr/bin/env bats
# lib/steps/common-steps.sh: set_aside_artifacts (only this attempt's files pass a gate) and
# fdr_replay_matches (a replayed store that is not the provisioned one stops personalize).
#
# lib/steps/common-steps.sh defines `run`, so the suite uses t1r_run (test_helper/common).

load test_helper/common

setup() {
  t1r_env
  t1r_load discover steps/common-steps
  t1r_need set_aside_artifacts fdr_replay_matches
  P=$T1R_STATE/private; mkdir -p "$P"
}

@test "set_aside_artifacts: moves earlier files into private/attempts/<stamp>-STEP and deletes nothing" {
  printf old > "$P/combined.preflight.memboot"; printf tk > "$P/preflight.apticket"; printf fdr > "$P/FDRData"
  T1R_DRY_RUN=0 t1r_run set_aside_artifacts personalize FDRData.replayed combined.preflight.memboot preflight.apticket
  assert_status 0
  [ ! -e "$P/combined.preflight.memboot" ] && [ ! -e "$P/preflight.apticket" ]
  [ -s "$P/FDRData" ]   # not named, so untouched
  local d; d=$(echo "$P"/attempts/*-personalize)
  [ -d "$d" ] && [ "$(cat "$d/combined.preflight.memboot")" = old ] && [ "$(cat "$d/preflight.apticket")" = tk ]
  [ "$(stat -c %a "$d")" = 700 ]
}

@test "set_aside_artifacts: nothing to move creates no attempts directory" {
  T1R_DRY_RUN=0 t1r_run set_aside_artifacts provision FDRData
  assert_status 0
  [ ! -e "$P/attempts" ]
}

@test "set_aside_artifacts: a dry run prints the move and leaves the file in place" {
  printf old > "$P/FDRData"
  T1R_DRY_RUN=1 t1r_run set_aside_artifacts provision FDRData
  assert_status 0
  assert_contains "$output" "(dry) mv -f"
  [ -s "$P/FDRData" ] && [ ! -e "$P/attempts" ]
}

@test "fdr_replay_matches: byte-identical stores match without plistutil" {
  printf 'same' > "$P/a"; printf 'same' > "$P/b"
  T1R_PLISTUTIL=/nonexistent t1r_run fdr_replay_matches "$P/a" "$P/b"
  assert_status 0
}

@test "fdr_replay_matches: different bytes but the same plist content match" {
  mkdir -p "$T1R_TMP/pb"
  # stub: renders a "plist" as its sorted lines, so reordered input is the same content
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -i) i=$2; shift;; -o) o=$2; shift;; esac; shift; done\nsort "$i" > "$o"\n' > "$T1R_TMP/pb/plistutil"
  chmod +x "$T1R_TMP/pb/plistutil"
  printf 'k1\nk2\n' > "$P/a"; printf 'k2\nk1\n' > "$P/b"
  T1R_PLISTUTIL=$T1R_TMP/pb/plistutil t1r_run fdr_replay_matches "$P/a" "$P/b"
  assert_status 0
  [ -z "$(find "$P" -name '.fdr-*')" ]   # temporary renderings removed
}

@test "fdr_replay_matches: different content does not match" {
  mkdir -p "$T1R_TMP/pb"
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -i) i=$2; shift;; -o) o=$2; shift;; esac; shift; done\nsort "$i" > "$o"\n' > "$T1R_TMP/pb/plistutil"
  chmod +x "$T1R_TMP/pb/plistutil"
  printf 'k1\nk2\n' > "$P/a"; printf 'k1\nk3\n' > "$P/b"
  T1R_PLISTUTIL=$T1R_TMP/pb/plistutil t1r_run fdr_replay_matches "$P/a" "$P/b"
  [ "$status" -ne 0 ]
}

@test "fdr_replay_matches: a missing or empty replayed store does not match" {
  printf 'x' > "$P/a"; : > "$P/b"
  T1R_PLISTUTIL=/nonexistent t1r_run fdr_replay_matches "$P/a" "$P/b"
  [ "$status" -ne 0 ]
  t1r_run fdr_replay_matches "$P/a" "$P/nope"
  [ "$status" -ne 0 ]
}
