import json
import os
import subprocess
import unittest

if __package__:
    from . import test_recovery as fixtures
    from . import test_recursive_mapping as mapping
else:
    import test_recovery as fixtures
    import test_recursive_mapping as mapping


dfltImg = fixtures.dfltImg
helperRef = 'pod/libguestfs-tools-rootdisk'
deleteCall = ['delete', '-n', 'fixture-ns', helperRef,
              '--ignore-not-found', '--timeout=60s', '--wait=true']
createWait = ['wait', '-n', 'fixture-ns', helperRef,
              '--for=create', '--timeout=60s']
readyWait = ['wait', '-n', 'fixture-ns', helperRef,
             '--for=condition=Ready', '--timeout=180s']


class GuestfsLifecycleTests(unittest.TestCase):
    RunRecovery = fixtures.RecoveryTests.RunRecovery
    Calls = fixtures.RecoveryTests.Calls
    Lifecycle = fixtures.RecoveryTests.Lifecycle
    VirtctlArgv = fixtures.RecoveryTests.VirtctlArgv
    WriteGuest = mapping.RecursiveMappingTests.WriteGuest
    Contents = mapping.RecursiveMappingTests.Contents

    def setUp(self):
        mapping.RecursiveMappingTests.setUp(self)

    def Labels(self):
        labels = []
        for source, *event in self.Lifecycle():
            if source == 'oc':
                labels.append(' '.join(['oc', event[0]] + (
                    ['vm' if event[1] == 'vm' else 'pod']
                    if event[0] == 'get' else [])))
            elif isinstance(event[0], str):
                labels.append('virtctl ' + event[0])
            elif 'exit' in event[0]:
                labels.append(f"virtctl exit {event[0]['exit']}")
            else:
                labels.append('virtctl start')
        return labels

    def Waits(self):
        return [call for call in self.Calls() if call[0] == 'wait']

    def Deletes(self):
        return [call for call in self.Calls() if call[0] == 'delete']

    def VirtctlStart(self):
        start, = [event[1] for event in self.Lifecycle()
                  if event[0] == 'virtctl' and 'argv' in event[1]]
        return start

    def AssertReaped(self, result, status):
        start = self.VirtctlStart()
        self.assertTrue(start['stdinFIFO'])
        self.assertIn(['virtctl', {'exit': status}], self.Lifecycle())
        self.assertTrue((self.root / 'virtctl-exited').exists())
        self.assertIn(f"+ wait {start['pid']}\n", result.stderr)
        with self.assertRaises(ProcessLookupError):
            os.kill(start['pid'], 0)

    def AssertCleanupOrder(self, result, reapFirst):
        reap = result.stderr.rindex('+ wait ')
        delete = result.stderr.index('+ oc -n fixture-ns delete')
        self.assertEqual(reap < delete, reapFirst)

    def AssertNoChildCleanup(self, result):
        self.assertNotIn('+ kill -0 0\n', result.stderr)
        self.assertNotIn('+ wait 0\n', result.stderr)
        self.assertFalse(self.Deletes())

    def AssertNoExec(self):
        self.assertFalse([call for call in self.Calls()
                          if call[0] in ('exec', 'cp')])
        self.assertFalse(list(self.out.glob('*.tgz')))

    def test_success_waits_for_create_and_ready_then_eof_reap(self):
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.VirtctlArgv(), [[
            '-n', 'fixture-ns', 'guestfs', '--vm', 'fixture-vm',
            '--image', 'registry.test/guestfs:fixture', 'rootdisk']])
        self.assertIn('Use image: registry.test/guestfs:fixture',
                      result.stderr)
        self.assertNotIn('Use image:', result.stdout)
        labels = self.Labels()
        self.assertEqual(labels[:3], ['oc get vm', 'oc get pod',
                                      'virtctl start'])
        self.assertEqual(labels.count('oc get pod'), 1)
        self.assertEqual(self.Waits(), [createWait, readyWait])
        execs = [index for index, label in enumerate(labels)
                 if label == 'oc exec']
        ready = len(labels) - labels[::-1].index('oc wait') - 1
        self.assertTrue(execs)
        self.assertLess(labels.index('virtctl created'), ready)
        self.assertLess(ready, execs[0])
        self.assertLess(execs[-1], labels.index('virtctl eof'))
        self.assertLess(labels.index('virtctl exit 0'),
                        labels.index('oc delete'))
        self.assertEqual(self.Deletes(), [deleteCall])
        self.AssertCleanupOrder(result, reapFirst=True)
        self.AssertReaped(result, 0)
        self.assertFalse((self.root / 'helper-pod').exists())
        expected = dict(self.files)
        expected['MEMORY.DMP'] = expected.pop('pagefile.sys')
        self.assertEqual(self.Contents(), expected)

    def test_source_waits_natively_without_polling(self):
        source = fixtures.recovery.read_text()
        for retired in ('podPoll', 'ownedPod', 'helperPod=', 'sleep 1'):
            self.assertNotIn(retired, source)
        create = source.index('--for=create')
        ready = source.index('--for=condition=Ready')
        self.assertLess(create, ready)
        self.assertLess(ready, source.index('FindNTFS "${hlprPod}"'))

    def test_owned_stdin_descriptor_survives_coprocess_reaping(self):
        line = 'exec {guestfsIn}>&"${guestfsProc[1]}"-'
        self.assertEqual(fixtures.recovery.read_text().count(line), 1)
        script = ('set -euo pipefail\n'
                  'typeset -i guestfsIn=0\n'
                  'coproc guestfsProc { sleep 0.3; exit 3; }\n'
                  'typeset -i pid="${guestfsProc_PID}"\n'
                  + line + '\n'
                  'wait "${pid}" || (($? == 3))\n'
                  '/bin/true\n'
                  '[ -e "/proc/$$/fd/${guestfsIn}" ]\n'
                  'echo "${guestfsIn} ${guestfsProc[1]-unset}"\n'
                  'exec {guestfsIn}>&-\n'
                  '[ ! -e "/proc/$$/fd/${guestfsIn}" ]\n')
        result = subprocess.run(['bash', '-c', script], text=True,
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        number, slot = result.stdout.split()
        self.assertGreaterEqual(int(number), 10)
        self.assertEqual(slot, 'unset')

    def test_default_tag_and_literal_image_override(self):
        for value, image in ((None, dfltImg), ('', dfltImg),
                             ('registry.test/a b:"c" $(x)',
                              'registry.test/a b:"c" $(x)')):
            with self.subTest(value=value):
                case = GuestfsLifecycleTests(
                    'test_success_waits_for_create_and_ready_then_eof_reap')
                case.setUp()
                self.addCleanup(case.doCleanups)
                case.env.pop('BSOD_DET__GUEST_FS__CTR_IMG')
                if value is not None:
                    case.env['BSOD_DET__GUEST_FS__CTR_IMG'] = value
                result = case.RunRecovery()
                self.assertEqual(result.returncode, 0, result.stderr)
                argv, = case.VirtctlArgv()
                self.assertEqual(argv[argv.index('--image') + 1], image)

    def test_preexisting_helper_is_not_adopted_or_deleted(self):
        (self.root / 'helper-pod').write_text('foreign')
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Pre-existing helper Pod: ' + helperRef, result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get', 'get'])
        self.assertFalse(self.VirtctlArgv())
        self.AssertNoChildCleanup(result)
        self.assertEqual((self.root / 'helper-pod').read_text(), 'foreign')
        self.AssertNoExec()

    def test_failure_before_launch_has_no_child_to_clean(self):
        result = self.RunRecovery('vm-status-Running')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in self.Calls()], ['get'])
        self.assertFalse(self.VirtctlArgv())
        self.AssertNoChildCleanup(result)

    def test_virtctl_exit_before_creation_returns_its_status(self):
        result = self.RunRecovery('virtctl-error')
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertIn('mock PVC is used by another pod', result.stderr)
        self.assertEqual(self.Waits(), [createWait])
        self.assertFalse(self.Deletes())
        self.AssertReaped(result, 41)
        self.AssertNoExec()

    def test_virtctl_exit_after_creation_stops_before_exec(self):
        result = self.RunRecovery('virtctl-attach-error')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.Waits(), [createWait, readyWait])
        self.assertIn('virtctl removePod', self.Labels())
        self.assertFalse(self.Deletes())
        self.AssertReaped(result, 42)
        self.AssertNoExec()

    def test_foreign_pod_seen_during_launch_is_not_deleted(self):
        result = self.RunRecovery('virtctl-foreign-race')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.Deletes())
        self.assertEqual((self.root / 'helper-pod').read_text(), 'foreign')
        self.AssertReaped(result, 1)
        self.AssertNoExec()

    def test_pending_helper_is_deleted_first_and_child_status_wins(self):
        result = self.RunRecovery('virtctl-pending')
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assertIn('mock startup timeout', result.stderr)
        self.assertIn('mock pod is not in running state', result.stderr)
        self.assertEqual(self.Deletes(), [deleteCall])
        self.AssertCleanupOrder(result, reapFirst=False)
        self.AssertReaped(result, 44)
        self.AssertNoExec()

    def test_create_timeout_deletes_while_child_runs(self):
        result = self.RunRecovery('create-timeout')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('timed out waiting for the condition', result.stderr)
        self.assertEqual(self.Waits(), [createWait])
        self.assertEqual(self.Labels().count('oc get pod'), 1)
        self.assertEqual(self.Deletes(), [deleteCall])
        self.AssertCleanupOrder(result, reapFirst=False)
        self.AssertReaped(result, 0)
        self.AssertNoExec()

    def test_unattached_success_is_reaped_before_delete(self):
        self.env['VIRTCTL_ATTACH_DELAY'] = '1.5'
        result = self.RunRecovery('empty-filesystems')
        self.assertEqual(result.returncode, 0, result.stderr)
        labels = self.Labels()
        self.assertLess(labels.index('virtctl eof'), labels.index('oc delete'))
        self.AssertCleanupOrder(result, reapFirst=True)
        self.AssertReaped(result, 0)

    def test_virtctl_exit_during_extraction_fails(self):
        result = self.RunRecovery('virtctl-drop')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue([call for call in self.Calls()
                         if call[0] == 'exec'])
        self.assertFalse(self.Deletes())
        self.AssertReaped(result, 0)

    def test_exit_status_precedence_delete_then_child_then_original(self):
        for overrides, status in (({}, 35),
                                  ({'VIRTCTL_EOF_STATUS': '45'}, 45),
                                  ({'VIRTCTL_EOF_STATUS': '45',
                                    'MOCK_DELETE_STATUS': '25'}, 25),
                                  ({'MOCK_DELETE_STATUS': '25'}, 25)):
            with self.subTest(overrides=overrides):
                case = GuestfsLifecycleTests(
                    'test_success_waits_for_create_and_ready_then_eof_reap')
                case.setUp()
                self.addCleanup(case.doCleanups)
                case.env.update(overrides)
                result = case.RunRecovery('tar-error')
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(case.Deletes(), [deleteCall])
                case.AssertCleanupOrder(result, reapFirst=False)
                case.AssertReaped(
                    result, int(overrides.get('VIRTCTL_EOF_STATUS', 0)))

    def test_child_failure_replaces_a_success_status(self):
        self.env['VIRTCTL_EOF_STATUS'] = '45'
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 45, result.stderr)
        self.assertEqual(len(self.Contents()), 3)
        self.assertEqual(self.Deletes(), [deleteCall])
        self.AssertCleanupOrder(result, reapFirst=True)
        self.AssertReaped(result, 45)

    def test_delete_failure_still_reaps_and_replaces_status(self):
        result = self.RunRecovery('cleanup-error')
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertIn('mock delete failure', result.stderr)
        self.AssertCleanupOrder(result, reapFirst=True)
        self.AssertReaped(result, 0)
        self.assertTrue((self.root / 'helper-pod').exists())

    def test_group_sigterm_reaps_virtctl_and_keeps_signal(self):
        # Bash re-raises a terminating signal after the EXIT trap, so the
        # child status cannot replace it.
        self.meta.write_text(json.dumps(self.metadata))
        result = subprocess.run(
            [str(fixtures.recovery), '--metadata', str(self.meta)],
            env=dict(self.env, SCENARIO='signal-group'), text=True,
            capture_output=True, timeout=10, start_new_session=True,
            check=False)
        self.assertEqual(result.returncode, -15, result.stderr)
        self.assertIn('virtctl sigterm', self.Labels())
        self.AssertReaped(result, 1)
        self.AssertNoExec()

    def test_sigterm_closes_stdin_reaps_and_keeps_signal(self):
        # The trap sees the last completed command's status (0 here), so
        # cleanup takes the clean-exit order: reap virtctl, then delete.
        result = self.RunRecovery('signal')
        self.assertEqual(result.returncode, -15, result.stderr)
        self.assertIn('\n++ Cleanup 0 ', result.stderr)
        self.assertIn('virtctl eof', self.Labels())
        self.assertEqual(self.Deletes(), [deleteCall])
        self.AssertCleanupOrder(result, reapFirst=True)
        self.AssertReaped(result, 0)
        self.AssertNoExec()


if __name__ == '__main__':
    unittest.main()
