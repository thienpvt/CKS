#!/usr/bin/env python3
"""Offline trust-boundary checks; never downloads or installs packages."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/cks-tools.sh'


class ToolDownloadTests(unittest.TestCase):
    def test_stdin_invocation_rejects_arguments_without_installing(self):
        result = subprocess.run(['bash', '-s', '--', 'invalid'], input=SCRIPT.read_text(),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)
        self.assertNotIn('unbound variable', result.stderr)

    def test_checksum_rejects_tampering_missing_and_ambiguous_entries(self):
        self.assertTrue(SCRIPT.is_file(), 'CKS tools installer missing')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            asset = root / 'tool.tar.gz'
            asset.write_bytes(b'reviewed release')
            digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            for manifest, payload, accepted in [
                (f'{digest}  tool.tar.gz\n', b'reviewed release', True),
                (f'{digest} *tool.tar.gz\n', b'reviewed release', True),
                (f'{digest}  tool.tar.gz\n', b'tampered', False),
                (f'{digest}  other.tar.gz\n', b'reviewed release', False),
                (f'{digest}  tool.tar.gz\n' * 2, b'reviewed release', False),
            ]:
                with self.subTest(manifest=manifest, payload=payload):
                    (root / 'checksums').write_text(manifest)
                    asset.write_bytes(payload)
                    result = subprocess.run(
                        ['bash', '-c', 'source "$1"; verify_asset "$2" tool.tar.gz',
                         'check', str(SCRIPT), str(root)], capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
