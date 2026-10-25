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
typeset suiteTag='integration'
typeset goCmd="${GO-go}"
typeset -a suitePkgArr="(${PKGS-./pkg/...})"

GO="${goCmd}" \
    "${scrDir}/check--test-selection.sh" \
    "${suiteTag}" \
    "${suitePkgArr[*]@Q}" \
    1

[ -z "${chkOnly}" ] || exit 0
"${goCmd}" test -v -tags "${suiteTag}" -race "${suitePkgArr[@]}"

true
