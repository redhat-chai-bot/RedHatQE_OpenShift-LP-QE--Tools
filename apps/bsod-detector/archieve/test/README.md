# Archived pre-RHOV Bats tests

These tests are retained as historical coverage for the former KVM/libvirt
workflow. Their original targets have moved under `archieve/src/` or were
removed during the RHOV rewrite, so they do not describe the active pipeline
and are excluded from `test/run-tests.sh`.

The Bats files also depend on `test/test-helper.bash`, which exports paths for
the active tree; several archived tests still expect those old targets under
`src/scripts/`. They are preserved for reference and are not expected to run
from this directory. Current RHOV coverage lives in `test/test-rhov-reliability.bats`.

## Watcher end-to-end fixture status

The three legacy `watch-crash` end-to-end scenarios in
`test/test-rhov-reliability.bats` are marked `ARCHIVED` and skipped by Bats.
Their mock relies on fixed 30/60-second sleeps and the earlier memory-dump and
recovery command flow, so it does not exercise the current watcher contract.
There is currently no end-to-end simulation of the full active watcher workflow.
The sentinel regression for `watch-crash --help` and source-contract checks remain
active in the maintained suite.
