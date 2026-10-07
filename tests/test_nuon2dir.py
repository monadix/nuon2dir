"""Native Nu API and CLI regression tests; Python standard library only."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
NU = shutil.which("nu")


@unittest.skipUnless(NU and os.name == "posix", "requires Nushell and POSIX")
class Nuon2dirTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def native(self, expression, *, ok=True, prefix="", env=None):
        code = (
            f"use {json.dumps(str(REPO / 'nuon2dir.nu'))}; "
            f"{prefix} {expression} | nuon2dir"
        )
        result = subprocess.run(
            [NU, "--no-config-file", "-c", code],
            cwd=self.root, capture_output=True, env=env, timeout=30,
        )
        self.assertEqual(result.returncode == 0, ok, result.stderr.decode())
        self.assertEqual(result.stdout, b"")
        if not ok:
            self.assertTrue(result.stderr)
        return result

    def cli(self, data, *, ok=True, args=()):
        result = subprocess.run(
            [str(REPO / "bin/json2dir"), *args], input=data,
            cwd=self.root, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode == 0, ok, result.stderr.decode())
        self.assertEqual(result.stdout, b"")
        if not ok:
            self.assertTrue(result.stderr)
        return result

    def test_binary_strings_and_special_nodes(self):
        self.native(r'''{
            blob: 0x[00 01 fe ff], text: "a\u{0}b\n世界",
            empty: 0x[], link: [link '../missing/./target'],
            script: [script "#!/bin/sh\necho hello\n"]
        }''')
        self.assertEqual((self.root / "blob").read_bytes(), b"\0\1\xfe\xff")
        self.assertEqual((self.root / "text").read_bytes(), "a\0b\n世界".encode())
        self.assertEqual((self.root / "empty").read_bytes(), b"")
        self.assertEqual(os.readlink(self.root / "link"), "../missing/./target")
        script = self.root / "script"
        self.assertEqual(script.read_bytes(), b"#!/bin/sh\necho hello\n")
        self.assertEqual(script.stat().st_mode & 0o111, 0o111)

    def test_literal_names_including_nested_dot_shorthand(self):
        tree = {
            "...": {"....": "dots", "*?[x]": "glob"}, "~": "tilde",
            "*": "literal star", "[file]": "literal brackets",
            " spaced ": "space", "-dash": "dash", "back\\slash": "slash",
            '$(touch escaped);`touch escaped`': "literal",
        }
        self.cli(json.dumps(tree).encode())
        self.assertEqual((self.root / "..." / "....").read_text(), "dots")
        self.assertEqual((self.root / "..." / "*?[x]").read_text(), "glob")
        for name, value in tree.items():
            if isinstance(value, str):
                self.assertEqual((self.root / name).read_text(), value)
        self.assertFalse((self.root / "escaped").exists())
        (self.root / "unmanaged").write_text("keep")
        # Replacement must also treat glob characters and dots literally.
        self.cli(json.dumps(tree).encode())
        self.assertEqual((self.root / "unmanaged").read_text(), "keep")
        self.assertEqual((self.root / "*").read_text(), "literal star")

    def test_deep_native_tree_with_small_recursion_budget(self):
        self.native(
            '$tree', prefix='''$env.config.recursion_limit = 12;
            mut tree: any = {leaf: "deep"};
            for i in 0..<100 { $tree = {d: $tree} };''',
        )
        path = self.root
        for _ in range(100):
            path /= "d"
        self.assertEqual((path / "leaf").read_text(), "deep")

    def test_complete_validation_before_writes(self):
        (self.root / "keep").write_text("original")
        for expression in (
            '{keep: "changed", sub: {bad: 42}}',
            '{keep: "changed", bad: ["unknown" "x"]}',
            '{keep: "changed", "../escape": "x"}',
            '{keep: "changed", bad: ["link" 0x[01]]}',
        ):
            with self.subTest(expression=expression):
                self.native(expression, ok=False)
                self.assertEqual((self.root / "keep").read_text(), "original")
                self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["keep"])

    def test_unsupported_native_types(self):
        for value in ("42", "true", "null", "1sec", "1kb", "2026-10-07", "[{}]", "{|| 1}"):
            with self.subTest(value=value):
                self.native(f"{{bad: {value}}}", ok=False)
        for root in ("[]", '"string"', "0x[01]", "null"):
            with self.subTest(root=root):
                self.native(root, ok=False)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_missing_root_and_nuon_example(self):
        target = self.root / "new" / "tree"
        code = (
            f"use {json.dumps(str(REPO / 'nuon2dir.nu'))}; "
            f"open {json.dumps(str(REPO / 'examples/tree.nuon'))} "
            f"| nuon2dir --root {json.dumps(str(target))}"
        )
        result = subprocess.run([NU, "-n", "-c", code], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual((target / "blob.bin").read_bytes(), b"\0\1\xfe\xff")

    def test_dangling_links_and_external_targets_untouched(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret").write_text("secret")
        (self.root / "victim").symlink_to(outside, target_is_directory=True)
        (self.root / "dangling").symlink_to("missing")
        self.native('{victim: {new: "x"}, dangling: 0x[ff]}')
        self.assertFalse((self.root / "victim").is_symlink())
        self.assertEqual((self.root / "victim" / "new").read_text(), "x")
        self.assertEqual(list(p.name for p in outside.iterdir()), ["secret"])
        self.assertEqual((outside / "secret").read_text(), "secret")
        self.assertEqual((self.root / "dangling").read_bytes(), b"\xff")

    def test_merge_preserves_directory_mode_and_unlisted_files(self):
        directory = self.root / "dir"
        directory.mkdir(mode=0o700)
        (directory / "keep").write_text("keep")
        self.native('{dir: {new: "new"}}')
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((directory / "keep").read_text(), "keep")
        self.assertEqual((directory / "new").read_text(), "new")
        self.native('{dir: "file"}', ok=False)
        self.assertEqual((directory / "keep").read_text(), "keep")

    def test_umask_and_script_replacement(self):
        code = f'use {json.dumps(str(REPO / "nuon2dir.nu"))}; {{f: "x", s: ["script" "x"]}} | nuon2dir'
        result = subprocess.run(
            ["sh", "-c", 'umask 077; exec "$@"', "nuon2dir-test", NU, "-n", "-c", code],
            cwd=self.root, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual((self.root / "f").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "s").stat().st_mode & 0o777, 0o711)
        self.native('{s: "plain"}')
        self.assertEqual((self.root / "s").stat().st_mode & 0o111, 0)

    def test_external_command_failures_propagate(self):
        fake_bin = self.root / "tools"
        fake_bin.mkdir()
        chmod = fake_bin / "chmod"
        chmod.write_text('#!/bin/sh\necho simulated failure >&2\nexit 23\n')
        chmod.chmod(0o755)
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"])
        result = self.native('{s: ["script" "x"]}', ok=False, env=env)
        self.assertIn(b"simulated failure", result.stderr)

    def test_strict_json_and_no_changes_on_parse_failure(self):
        for data in (
            b'{"f":"x",}', b'{/* comment */"f":"x"}', b'{f:"x"}',
            b'{"f":"x"} trailing', b'{"f":"x","bad":"\\ud800"}',
            b'{"f":"\xff"}', b'{"f": NaN}', b'{"f": Infinity}', b'',
        ):
            with self.subTest(data=data):
                self.cli(data, ok=False)
                self.assertEqual(list(self.root.iterdir()), [])

    def test_cli_rejects_arguments(self):
        for args in (("unexpected",), ("--help",), ("-h",), ("--",), ("--root", "out")):
            with self.subTest(args=args):
                result = self.cli(b'{}', ok=False, args=args)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, b'Usage: json2dir < file.json\n')
                self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
