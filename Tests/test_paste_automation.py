#!/usr/bin/env python3
"""Compile actual Cocoa script-command dispatch with the exact surface paste body.

No app/window, clipboard, event post, permission request, or benchmark runs.
"""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def surface_method():
    source = (ROOT / 'App/CmdyTerminalSurface.swift').read_text()
    start = source.index('@discardableResult func pasteText(')
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class PasteDictionaryTests(unittest.TestCase):
    def test_only_existing_terminal_read_and_input_are_exposed(self):
        dictionary = ET.parse(ROOT / 'App/Resources/Cmdy.sdef').getroot()
        commands = dictionary.findall('.//command')
        self.assertEqual([c.attrib['name'] for c in commands], ['input text'])
        command = commands[0]
        self.assertEqual(command.attrib['code'], 'GhstInTx')
        self.assertEqual(command.find('cocoa').attrib['class'], 'CmdyScriptInputTextCommand')
        self.assertEqual(command.find('parameter').attrib['code'], 'GItT')
        self.assertEqual(command.find('parameter/cocoa').attrib['key'], 'terminal')
        self.assertEqual(dictionary.find('.//class[@name="terminal"]').attrib['code'], 'Gtrm')
        self.assertTrue(all(p.attrib['access'] == 'r' for p in dictionary.findall('.//property')))

    @unittest.skipUnless(sys.platform == 'darwin', 'Cocoa scripting requires macOS')
    def test_actual_command_and_surface_paste_path_without_gui(self):
        with tempfile.TemporaryDirectory(prefix='cmdy-paste-automation-') as value:
            directory = Path(value)
            source = directory / 'PasteAutomationTests.swift'
            body = surface_method()
            fixture = (ROOT / 'Tests/PasteAutomationTests.swift').read_text()
            self.assertEqual(fixture.count('// PASTE_IMPLEMENTATION'), 1)
            source.write_text(fixture.replace('// PASTE_IMPLEMENTATION', body))
            command = ['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library',
                str(ROOT / 'App/CmdyPasteAutomation.swift'),
                str(ROOT / 'App/CmdyPasteAutomationBridge.swift'), str(source),
                '-o', str(directory / 'test')]
            built = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(directory / 'test')], capture_output=True, text=True, timeout=15)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertIn('checks passed', ran.stdout)
            print(ran.stdout.strip())
            print('Exact production paste method SHA256: ' + hashlib.sha256(body.encode()).hexdigest())


if __name__ == '__main__':
    unittest.main()
