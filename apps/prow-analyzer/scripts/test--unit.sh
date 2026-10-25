#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit extglob

typeset chkOnly="${1:-}"; (($#)) && shift

case "${#}:${chkOnly}" in
  (0:?(--check-only))   ;;
  (*)
    echo 'Expected no arguments or `--check-only`.'
    exit 2
    ;;
esac

typeset scrDir="${BASH_SOURCE[0]%/*}"
typeset suiteTag='unit'
typeset goCmd="${GO-go}"
typeset -a suitePkgArr="(${PKGS-./pkg/... ./cmd/...})"

typeset covMin='100.0' covFile='coverage.out' covHTML='coverage.html'
typeset covOut='' totCov=''

: 'Guarding that the unit build tag actually selects tests...'
GO="${goCmd}" \
    "${scrDir}/check--test-selection.sh" \
    "${suiteTag}" \
    "${suitePkgArr[*]@Q}" \
    1

[ -z "${chkOnly}" ] || exit 0
: 'Running Unit Test with Code Coverage...'
"${goCmd}" test -v -tags "${suiteTag}" \
    -covermode=set -coverprofile="${covFile}" \
    "${suitePkgArr[@]}"

: 'Generating Code Coverage report...'
"${goCmd}" tool cover -html="${covFile}" -o "${covHTML}"
: 'Calculating Code Coverage percentage...'
covOut="$("${goCmd}" tool cover -func="${covFile}")"
totCov="$(
    echo "${covOut}" |
    sed -nE 's/^total:[^.0-9]+([.0-9]+)%/\1/p;tq;b;:q q'
)"
: "Total Code Coverage: ${totCov}%"
: "Required Code Coverage: ${covMin}%"
if awk -v tot="${totCov}" -v min="${covMin}" '
    BEGIN {
        if (tot !~ /^[0-9]+([.][0-9]+)?$/) exit 2
        exit !((tot+0) >= (min+0))
    }
'; then
    : "✅ PASS: Code Coverage ${totCov}% meets threshold ${covMin}%"
    : "Code Coverage report: ${covHTML}"
else
    : "❌ FAIL: Code Coverage ${totCov}% is below threshold ${covMin}%."
    : "Code Coverage report: ${covHTML}"
    false
fi

true
