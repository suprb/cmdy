#!/usr/bin/env python3
"""Exercise the actual App/Renderer trace helpers in fresh, isolated processes.

Compile the active helpers against the verified native archive; no app, window or PTY starts.
CMDY_TRACE_FIELDS_TEST_SOURCES optionally selects a frozen source root.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE_ROOT = Path(os.environ.get(
    'CMDY_TRACE_FIELDS_TEST_SOURCES', Path(__file__).resolve().parents[1]))
PROBE = r'''
import Darwin
import Foundation

@main
struct FieldsProbe {
    static func main() throws {
        var evaluations = 0
        func fields() -> [String: Int] {
            evaluations += 1
            let entered = mach_absolute_time()
            var evaluated = mach_absolute_time()
            while evaluated <= entered { evaluated = mach_absolute_time() }
            return ["evaluation": evaluations, "fieldsTick": Int(evaluated)]
        }
        let started = CommandLine.arguments.contains("zero") ? 0 : mach_absolute_time()
        if CommandLine.arguments.contains("limit") {
            for index in 0..<4_120 {
                RendererPerformanceTrace.record(event: "boundedProbe", started: started,
                                                fields: ["index": index])
            }
        } else {
            CmdyPerformanceTrace.record(event: "fieldsProbe", started: started, fields: fields())
            RendererPerformanceTrace.record(event: "fieldsProbe", started: started, fields: fields())
        }
        if CommandLine.arguments.contains("mutate") {
            setenv("CMDY_FRAME_TRACE", "1", 1)
        }
        let receipt: [String: Any] = [
            "evaluations": evaluations,
            "appEnabled": CmdyPerformanceTrace.enabled,
            "rendererEnabled": RendererPerformanceTrace.enabled,
            "appNow": CmdyPerformanceTrace.now(),
            "rendererNow": RendererPerformanceTrace.now(),
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: receipt))
        // The test acknowledges both async records before permitting exit.
        _ = try FileHandle.standardInput.read(upToCount: 1)
    }
}
'''


@unittest.skipUnless(sys.platform == 'darwin', 'The production trace helpers use Darwin.')
class FrameTraceFieldsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix='cmdy-trace-fields-')
        cls.addClassCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        probe = directory / 'FieldsProbe.swift'
        probe.write_text(PROBE)
        cls.binary = directory / 'probe'
        active = SOURCE_ROOT / 'Renderer/Sources/CmdyGPUZig/RendererPerformanceTrace.swift'
        flags = []
        if active.exists():
            core = SOURCE_ROOT / 'Core'
            verification = subprocess.run([sys.executable,
                str(core / 'Tools/ZigEngine/verify.py'), '--core', str(core)],
                capture_output=True, text=True, timeout=45)
            if verification.returncode:
                raise AssertionError(verification.stdout + verification.stderr)
            receipt = json.loads((core / '.zig-build/manifest.json').read_text())
            archive = core / '.zig-build/artifacts' / receipt['source_key'] / 'libcmdy_engine.a'
            module = directory / 'CmdyNative'
            module.mkdir()
            header = core / 'Sources/CmdyNative/include/cmdy_render_trace.h'
            (module / 'module.modulemap').write_text(
                'module CmdyNative { header ' + json.dumps(str(header)) + ' export * }\n')
            flags = ['-I', str(module), str(archive), '-lobjc']
            for framework in ('AppKit', 'Foundation', 'CoreFoundation', 'CoreGraphics',
                              'CoreText', 'Metal', 'MetalKit', 'QuartzCore', 'ImageIO'):
                flags.extend(['-framework', framework])
        else:
            # Explicit frozen roots preserve the original standalone Swift path.
            active = SOURCE_ROOT / 'Renderer/Sources/CmdyGPU/RendererPerformanceTrace.swift'
        command = ['/usr/bin/swiftc', '-parse-as-library', '-Onone',
                   str(SOURCE_ROOT / 'App/CmdyPerformanceTrace.swift'),
                   str(active), str(probe), *flags, '-o', str(cls.binary)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    @staticmethod
    def environment(enabled):
        environment = os.environ.copy()
        environment.pop('CMDY_FRAME_TRACE', None)
        if enabled:
            environment['CMDY_FRAME_TRACE'] = '1'
        return environment

    def silent_receipt(self, enabled, mode):
        result = subprocess.run([str(self.binary), mode], input=b'\n',
                                capture_output=True, env=self.environment(enabled), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b'')
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['appEnabled'], enabled)
        self.assertEqual(receipt['rendererEnabled'], enabled)
        return receipt

    def test_disabled_tracing_never_evaluates_either_fields_expression(self):
        receipt = self.silent_receipt(False, 'positive')
        self.assertEqual(receipt['evaluations'], 0)
        self.assertEqual(receipt['appNow'], 0)
        self.assertEqual(receipt['rendererNow'], 0)

    def test_zero_start_skips_fields_even_when_tracing_is_enabled(self):
        receipt = self.silent_receipt(True, 'zero')
        self.assertEqual(receipt['evaluations'], 0)
        self.assertGreater(receipt['appNow'], 0)
        self.assertGreater(receipt['rendererNow'], 0)

    def test_only_the_exact_enabled_environment_value_activates_tracing(self):
        for value in ('', '0', 'true', '01', '1 ', ' 1'):
            environment = self.environment(False)
            environment['CMDY_FRAME_TRACE'] = value
            result = subprocess.run([str(self.binary), 'positive'], input=b'\n',
                capture_output=True, env=environment, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stderr, b'')
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt['evaluations'], 0)
            self.assertFalse(receipt['rendererEnabled'])
            self.assertEqual(receipt['rendererNow'], 0)

    def test_environment_is_captured_once(self):
        receipt = self.silent_receipt(False, 'mutate')
        self.assertEqual(receipt['evaluations'], 0)
        self.assertEqual(receipt['rendererNow'], 0)

    def test_renderer_writer_keeps_clock_order_and_emits_one_bounded_limit(self):
        process = subprocess.Popen([str(self.binary), 'limit'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=self.environment(True))
        records, pending = [], b''
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                deadline = time.monotonic() + 10
                while len(records) < 4_098:
                    ready = selector.select(max(0, deadline - time.monotonic()))
                    self.assertTrue(ready, 'Timed out waiting for bounded trace output.')
                    chunk = os.read(process.stderr.fileno(), 65536)
                    self.assertTrue(chunk, 'Probe exited before the trace limit record.')
                    pending += chunk
                    lines = pending.split(b'\n')
                    pending = lines.pop()
                    for line in lines:
                        self.assertTrue(line.startswith(b'CMDY_FRAME_TRACE '), line)
                        records.append(json.loads(line[len(b'CMDY_FRAME_TRACE '):]))
            stdout, tail = process.communicate(input=b'\n', timeout=10)
            self.assertEqual(process.returncode, 0, tail.decode())
            self.assertEqual(pending + tail, b'')
            self.assertEqual(json.loads(stdout)['evaluations'], 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=10)
        self.assertEqual(len(records), 4_098)
        self.assertEqual(records[0]['event'], 'clock')
        self.assertEqual(records[0]['started'], records[0]['ended'])
        self.assertEqual(records[0]['durationTicks'], 0)
        self.assertEqual(records[0]['fields']['maxRecords'], 4_096)
        self.assertGreater(records[0]['fields']['numer'], 0)
        self.assertGreater(records[0]['fields']['denom'], 0)
        for index, record in enumerate(records[1:4_097]):
            self.assertEqual(record['component'], 'renderer')
            self.assertEqual(record['event'], 'boundedProbe')
            self.assertEqual(record['fields'], {'index': index})
            self.assertEqual(record['durationTicks'], record['ended'] - record['started'])
        self.assertEqual(records[-1]['event'], 'limit')
        self.assertEqual(records[-1]['fields'], {'maxRecords': 4_096})

    def test_enabled_fields_evaluate_once_before_the_recorded_end(self):
        process = subprocess.Popen([str(self.binary), 'positive'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=self.environment(True))
        records, pending = [], b''
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                deadline = time.monotonic() + 10
                while len(records) < 2:
                    ready = selector.select(max(0, deadline - time.monotonic()))
                    self.assertTrue(ready, 'Timed out waiting for the two bounded trace records.')
                    chunk = os.read(process.stderr.fileno(), 65536)
                    self.assertTrue(chunk, 'Probe exited before publishing both trace records.')
                    pending += chunk
                    lines = pending.split(b'\n')
                    pending = lines.pop()
                    for line in lines:
                        self.assertTrue(line.startswith(b'CMDY_FRAME_TRACE '), line)
                        record = json.loads(line[len(b'CMDY_FRAME_TRACE '):])
                        if record['event'] == 'fieldsProbe':
                            records.append(record)
            stdout, _ = process.communicate(input=b'\n', timeout=10)
            self.assertEqual(process.returncode, 0)
            receipt = json.loads(stdout)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=10)
        self.assertTrue(receipt['appEnabled'] and receipt['rendererEnabled'])
        self.assertEqual(receipt['evaluations'], 2)
        self.assertCountEqual([r['component'] for r in records], ['app', 'renderer'])
        for record in records:
            self.assertEqual(record['fields']['evaluation'], 1 if record['component'] == 'app' else 2)
            self.assertLess(record['started'], record['fields']['fieldsTick'])
            self.assertLessEqual(record['fields']['fieldsTick'], record['ended'])
            self.assertEqual(record['durationTicks'], record['ended'] - record['started'])


if __name__ == '__main__':
    unittest.main()
