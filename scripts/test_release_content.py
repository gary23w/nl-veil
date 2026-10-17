import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("release_content", Path(__file__).with_name("verify-release-content.py"))
content = importlib.util.module_from_spec(spec)
spec.loader.exec_module(content)


class BundleContents(unittest.TestCase):
    def make_bundle(self, directory, extra=None, omit=None, symlink=False):
        path = Path(directory) / "bundle.zip"
        root = "veil-v1.1.24-windows-x86_64/"
        names = {"veil.exe", "bin/neuron.exe", "LICENSE", "README.txt", "veil-install.txt", "start", "start.cmd"}
        with zipfile.ZipFile(path, "w") as archive:
            for name in sorted(names - {omit}):
                archive.writestr(root + name, b"synthetic fixture")
            if extra:
                archive.writestr(root + extra, b"must not ship")
            if symlink:
                info = zipfile.ZipInfo(root + "link")
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, "README.txt")
        return path

    def test_deliberate_application_files_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            content.verify_bundle(self.make_bundle(tmp))

    def test_source_archive_and_runtime_state_are_rejected(self):
        for extra in ("cloud/runtime-source.tar.gz", "data/settings.json", ".server.key", "../escape"):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    content.verify_bundle(self.make_bundle(tmp, extra=extra))

    def test_incomplete_installation_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                content.verify_bundle(self.make_bundle(tmp, omit="bin/neuron.exe"))

    def test_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                content.verify_bundle(self.make_bundle(tmp, symlink=True))


if __name__ == "__main__":
    unittest.main()
