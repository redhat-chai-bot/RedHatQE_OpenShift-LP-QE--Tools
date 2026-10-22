#!/bin/bash
# Fail when a build tag selects fewer tests than required. A zero-test run can
#   can otherwise succeed without exercising the intended suite.
set -euxo pipefail; shopt -s inherit_errexit

typeset buildTag="${1:?usage: check--test-selection.sh <buildTag> [packages] [minCnt]}"; (($#)) && shift
typeset pkgsTest="${1:-./pkg/...}"; (($#)) && shift
typeset -i minCnt="${1:-1}"; (($#)) && shift

typeset goCmd="${GO-go}" pkgLst=''
typeset -i funcCnt=0
typeset -a pkgArr="(${pkgsTest})"

: "Checking that \`-tags ${buildTag}\` selects at least ${minCnt} test(s) in \`${pkgsTest}\`..."
# The `go test -list` compiles the (tagged) test binaries and prints one
#   function name per line, plus a per-package summary line. Cnt only the
#   function names.
pkgLst="$("${goCmd}" test -tags "${buildTag}" -list '.*' "${pkgArr[@]}")"
funcCnt="$(
    printf '%s\n' "${pkgLst}" |
    awk '/^(Test|Benchmark|Fuzz|Example)/ {Cnt++} END {print (Cnt+0)}'
)"

if ((funcCnt < minCnt)); then
    : "❌ FAIL: The \`-tags ${buildTag}\` funcCnt ${funcCnt} test(s) in \`${pkgsTest}\` (expected >= ${minCnt})."
    : "    A missing or misspelled \`//go:build ${buildTag}\` line yields 0 test silently."
    false
else
    : "✅ PASS: The \`-tags ${buildTag}\` funcCnt ${funcCnt} test(s) in ${pkgsTest}."
fi

true
