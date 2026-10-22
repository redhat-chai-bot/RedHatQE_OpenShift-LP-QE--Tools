#!/bin/bash
function ExitTrap--PostProcessPrep () {(
################################################################################
#   Exit Trap for CI Operator Step that executes the actual Test Cases.
#
#   CI Operator Step Script Trap Function to perform required actions necessary
#   for post-processing.
#
#   Workflow:
#    1. Collect and merge all jUnit XML Test Results from the executed Test
#       Cases.
#    2. If the Env. Var. `LP_IO__ET_PPP__NEW_TS_NAME` is set to non-empty, then
#       the Test Suite Name is set to it.
#    3. Archive the original jUnit XMLs into `${ARTIFACT_DIR}/`
#    4. Put the merged jUnit XML into `${SHARED_DIR}/` for consumption of
#       subsequent Step.
#
#   Usage:
#       eval "$(
#           typeset -a _fURL=()
#           type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
#           "${_fURL[@]}" \
#       https://<urlAuthToRawContent>/<urlPathToRawContents...>\
#       <repoPaths...>/ExitTrap--PostProcessPrep.sh
#       )"; trap '
#           ExitTrap--PostProcessPrep jUnit--<unique-merge-filename>.xml
#       ' EXIT
#
#   Required Env. Var. from Step Configuration:
#       LP_IO__ET_PPP__NEW_TS_NAME
#           The new Test Suite Name. Use `%s` as a placeholder for the
#           original name (use `%%` for a literal `%`).
#           This can be used to set the Test Suite Name to a specific
#           searchable pattern, say for Component Readiness input
#           filtering.
#
#   Used CI Operator default Env. Var.:
#       ARTIFACT_DIR
#       SHARED_DIR
################################################################################
    set -euxo pipefail; shopt -s inherit_errexit
    typeset mergedFN="${1:-jUnit.xml}"; (($#)) && shift

    typeset resultFile=''
    typeset -a xmlFiles=()

    # Ensure requirements are met.
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/common/EnsureReqs.sh
    )"; EnsureReqs yq

    while IFS= read -r -d '' resultFile; do
        grep -qE '<testsuites?\b' "${resultFile}" && xmlFiles+=("${resultFile}")
    done 0< <(
        find "${ARTIFACT_DIR}/" \
            -type f -iname "*.xml" ! -name "${mergedFN}" \
            -print0
    )

    ((${#xmlFiles[@]})) || {
        : 'WARNING: No jUnit XML file found to process!'
        return
    }

    # Collect all jUnit XMLs, set TS Name if applicable, and merge them to one.
    yq eval-all -px -ox -I2 '
        [.] | {
            "+p_xml": "version=\"1.0\" encoding=\"UTF-8\"",
            "testsuites": {"testsuite": [
                .[][] |
                select(kind == "map") |
                ((select(has("testsuite")) | .testsuite) // .) |
                (([] + .)[] | (
                    select(strenv(LP_IO__ET_PPP__NEW_TS_NAME) != "") |
                    (
                        (."+@name" // "") |
                        sub("^\\s+", "") |
                        sub("\\s+$", "")
                    ) as $oldName |
                    ."+@name" = (
                        strenv(LP_IO__ET_PPP__NEW_TS_NAME) |
                        sub("(^|[^%])((%%)*)%s", "${1}${2}\($oldName)") |
                        sub("%%", "%")
                    )
                ) // .) |
                ([] + (.testcase // [])) as $tc |
                ."+@tests" = ($tc | length | tostring) |
                ."+@failures" = ([$tc[] | select(.failure)] | length | tostring) |
                ."+@errors" = ([$tc[] | select(.error)] | length | tostring)
            ]}
        }
    ' "${xmlFiles[@]}" 1> "${ARTIFACT_DIR}/${mergedFN}"

    # Archive the original jUnit XMLs.
    {
        tar \
            zcf "${ARTIFACT_DIR}/jUnit-original.tgz" \
            -C "${ARTIFACT_DIR}/" \
            "${xmlFiles[@]#${ARTIFACT_DIR}/}" &&
        rm -f "${xmlFiles[@]}"
    }

    # The Data Router Step needs to be able to fetch the merged jUnit XML.
    cp "${ARTIFACT_DIR}/${mergedFN}" "${SHARED_DIR}/"

    true
)}
