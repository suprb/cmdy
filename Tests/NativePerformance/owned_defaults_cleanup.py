"""Read-only classification of receipts for one generated, owned defaults suite."""
from __future__ import annotations

import plistlib
import re
from xml.parsers.expat import ExpatError


def classify_owned_defaults_cleanup(domain, exported, deleted):
    def require(condition):
        if not condition: raise RuntimeError('exact owned defaults cleanup is not proved')

    require(isinstance(domain, str) and re.fullmatch(r'com\.cmdy\.bench\.[0-9a-f]{32}', domain) is not None)
    require(exported.get('command') == ['/usr/bin/defaults', 'export', domain, '-']
            and deleted.get('command') == ['/usr/bin/defaults', 'delete', domain])
    require(type(deleted.get('returncode')) is int)
    if deleted['returncode'] == 0:
        return 'deleted'

    # defaults export can successfully print an empty dictionary for a suite
    # that was never persisted. A failed delete alone proves nothing: require
    # that exact empty plist and the exact owned-domain absence diagnostic.
    require(deleted['returncode'] == 1 and type(exported.get('returncode')) is int
            and exported['returncode'] == 0 and exported.get('stderr', '').strip() == ''
            and deleted.get('stdout', '').strip() == '')
    text = exported.get('stdout')
    require(isinstance(text, str) and len(text.encode()) <= 65536)
    try:
        value = plistlib.loads(text.encode())
    except (ValueError, TypeError, OverflowError, plistlib.InvalidFileException, ExpatError):
        raise RuntimeError('exact owned defaults cleanup is not proved') from None
    require(type(value) is dict and not value)
    lines = [line.strip() for line in deleted.get('stderr', '').splitlines() if line.strip()]
    if lines and re.fullmatch(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ defaults\[\d+:\d+\]', lines[0]):
        lines = lines[1:]
    require(lines == [f'Domain ({domain}) not found.', 'Defaults have not been changed.'])
    return 'already-absent-empty-suite'
