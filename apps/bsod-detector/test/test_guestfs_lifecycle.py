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

    def AssertNoExec(self):
        self.assertFalse([call for call in self.Calls()
                          if call[0] in ('exec', 'cp')])
        self.assertFalse(list(self.out.glob('*.tgz')))

    def test_success_waits_extracts_then_eof_and_reap(self):
        result = self.RunRecovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.VirtctlArgv(), [[
            '-n', 'fixture-ns', 'guestfs', '--vm', 'fixture-vm',
            '--image', 'registry.test/guestfs:fixture', 'rootdisk']])
        self.assertIn('Use image: registry.test/guestfs:fixture',
                      result.stderr)
        self.assertNotIn('Use image:', result.stdout)
        labels = self.Labels()
        execs = [index for index, label in enumerate(labels)
                 if label == 'oc exec']
        self.assertTrue(execs)
        self.assertEqual(labels[:3], ['oc get vm', 'oc get pod',
                                      'virtctl start'])
        self.assertLess(labels.index('virtctl created'),
                        labels.index('oc wait'))
        self.assertLess(labels.index('oc wait'), execs[0])
        self.assertLess(execs[-1], labels.index('virtctl eof'))
        self.assertLess(labels.index('virtctl exit 0'),
                        labels.index('oc delete'))
        self.assertEqual(labels.count('oc wait'), 1)
        self.assertEqual([call for call in self.Calls()
                          if call[0] in ('wait', 'delete')], [
            ['wait', '-n', 'fixture-ns', helperRef,
             '--for=condition=Ready', '--timeout=180s'],
            deleteCall])
        self.AssertReaped(result, 0)
        self.assertFalse((self.root / 'helper-pod').exists())
        expected = dict(self.files)
        expected['MEMORY.DMP'] = expected.pop('pagefile.sys')
        self.assertEqual(self.Contents(), expected)

    def test_default_tag_and_literal_image_override(self):
        for value, image in ((None, dfltImg), ('', dfltImg),
                             ('registry.test/a b:"c" $(x)',
                              'registry.test/a b:"c" $(x)')):
            with self.subTest(value=value):
                case = GuestfsLifecycleTests('test_success_waits_extracts_'
                                             'then_eof_and_reap')
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
        self.assertEqual((self.root / 'helper-pod').read_text(), 'foreign')
        self.AssertNoExec()

    def test_virtctl_exit_before_creation_returns_its_status(self):
        result = self.RunRecovery('virtctl-error')
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertIn('mock PVC is used by another pod', result.stderr)
        self.assertEqual({call[0] for call in self.Calls()}, {'get'})
        self.AssertReaped(result, 41)
        self.AssertNoExec()

    def test_virtctl_exit_after_creation_stops_before_exec(self):
        result = self.RunRecovery('virtctl-attach-error')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.Labels().count('oc wait'), 1)
        self.assertIn('virtctl removePod', self.Labels())
        self.assertFalse([call for call in self.Calls()
                          if call[0] == 'delete'])
        self.AssertReaped(result, 42)
        self.AssertNoExec()

    def test_foreign_pod_seen_during_launch_is_not_deleted(self):
        result = self.RunRecovery('virtctl-foreign-race')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse([call for call in self.Calls()
                          if call[0] == 'delete'])
        self.assertEqual((self.root / 'helper-pod').read_text(), 'foreign')
        self.AssertReaped(result, 1)
        self.AssertNoExec()

    def test_pending_helper_is_deleted_and_wait_status_kept(self):
        result = self.RunRecovery('virtctl-pending')
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertIn('mock startup timeout', result.stderr)
        self.assertIn('mock pod is not in running state', result.stderr)
        self.assertEqual([call for call in self.Calls()
                          if call[0] == 'delete'], [deleteCall])
        self.AssertReaped(result, 44)
        self.AssertNoExec()

    def test_creation_poll_is_bounded_without_for_create(self):
        source = fixtures.recovery.read_text()
        self.assertNotIn('--for=create', source)
        self.assertEqual(source.count('((++podPoll < 60))'), 1)
        script = self.root / fixtures.recovery.name
        script.write_text(source.replace('((++podPoll < 60))',
                                         '((++podPoll < 2))'))
        script.chmod(0o755)
        result = self.RunRecovery('virtctl-hang', script=script)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Helper Pod not created: libguestfs-tools-rootdisk',
                      result.stderr)
        self.assertEqual(self.Labels().count('oc get pod'), 3)
        self.assertFalse([call for call in self.Calls()
                          if call[0] in ('wait', 'delete')])
        self.AssertReaped(result, 43)
        self.AssertNoExec()

    def test_eof_failure_replaces_only_a_success_status(self):
        result = self.RunRecovery('virtctl-eof-error')
        self.assertEqual(result.returncode, 45, result.stderr)
        self.assertEqual(len(self.Contents()), 3)
        self.assertEqual([call for call in self.Calls()
                          if call[0] == 'delete'], [deleteCall])
        self.AssertReaped(result, 45)

    def test_delete_failure_still_reaps_and_replaces_status(self):
        result = self.RunRecovery('cleanup-error')
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertIn('mock delete failure', result.stderr)
        self.assertLess(result.stderr.index('+ wait '),
                        result.stderr.index('mock delete failure'))
        self.AssertReaped(result, 0)
        self.assertTrue((self.root / 'helper-pod').exists())

    def test_unattached_success_is_reaped_before_delete(self):
        self.env['VIRTCTL_ATTACH_DELAY'] = '1.5'
        result = self.RunRecovery('empty-filesystems')
        self.assertEqual(result.returncode, 0, result.stderr)
        labels = self.Labels()
        self.assertLess(labels.index('virtctl eof'), labels.index('oc delete'))
        self.AssertReaped(result, 0)

    def test_virtctl_exit_during_extraction_fails(self):
        result = self.RunRecovery('virtctl-drop')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue([call for call in self.Calls()
                         if call[0] == 'exec'])
        self.assertFalse([call for call in self.Calls()
                          if call[0] == 'delete'])
        self.AssertReaped(result, 0)

    def test_group_sigterm_reaps_virtctl_and_keeps_signal(self):
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
        result = self.RunRecovery('signal')
        self.assertEqual(result.returncode, -15, result.stderr)
        self.assertIn('virtctl eof', self.Labels())
        self.assertEqual([call for call in self.Calls()
                          if call[0] == 'delete'], [deleteCall])
        self.AssertReaped(result, 0)
        self.AssertNoExec()


if __name__ == '__main__':
    unittest.main()
