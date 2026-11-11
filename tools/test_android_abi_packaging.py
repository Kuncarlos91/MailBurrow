"""Guard the arm64-only release packaging (see docs/releasing/android.md).

Flutter's Gradle plugin sets abiFilters to every ABI it supports, and
--target-platform only limits Flutter's own libraries, so plugin native
libraries (for example jni's libdartjni.so) would be packaged for ARMv7 and
x86-64 too. These checks fail if the release-only exclude rule or the
documented build flag is removed, and test the APK checker helper.
"""
from pathlib import Path
import io
import re
import tempfile
import unittest
import zipfile

from check_apk_abis import main, native_libraries, problems

ROOT = Path(__file__).resolve().parents[1]
GRADLE = ROOT / "android/app/build.gradle.kts"
NON_ARM64 = ("**/armeabi-v7a/**", "**/armeabi/**", "**/x86/**", "**/x86_64/**")


def strip_comments(text):
    # Drop whole-line // comments only: the exclude globs themselves contain
    # "/**" and "**/", so a general comment stripper would eat them.
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))


class GradleReleaseExcludeTests(unittest.TestCase):
    def setUp(self):
        self.gradle = strip_comments(GRADLE.read_text(encoding="utf-8"))

    def release_block(self):
        match = re.search(
            r'androidComponents\s*\{\s*onVariants\(\s*selector\(\)\.withBuildType\("release"\)\s*\)'
            r'\s*\{\s*variant\s*->(?P<body>.*?)\n\s*\}\s*\n\s*\}',
            self.gradle, re.S)
        self.assertIsNotNone(match, "release-only androidComponents block is missing")
        return match.group("body")

    def test_release_variants_exclude_every_non_arm64_abi(self):
        body = self.release_block()
        self.assertIn("variant.packaging.jniLibs.excludes.addAll", body)
        for pattern in NON_ARM64:
            self.assertIn('"' + pattern + '"', body)

    def test_arm64_is_never_excluded(self):
        self.assertNotIn("arm64-v8a", self.release_block())
        self.assertNotRegex(self.gradle, r'excludes[^\n]*arm64')

    def test_exclude_is_not_applied_to_debug_builds(self):
        self.assertNotRegex(self.gradle, r'withBuildType\("debug"\)[^}]*jniLibs\.excludes')
        self.assertEqual(self.gradle.count("jniLibs.excludes"), 1)

    def test_release_build_command_targets_arm64(self):
        for doc in ("docs/releasing/android.md", "docs/releasing/android-rc9.md"):
            text = (ROOT / doc).read_text(encoding="utf-8")
            # Command lines only (code blocks); prose may mention a plain build.
            commands = re.findall(r"^flutter build apk --release[^\n]*", text, re.M)
            self.assertTrue(commands, doc)
            for command in commands:
                self.assertIn("--target-platform android-arm64", command, doc)


class ApkAbiCheckerTests(unittest.TestCase):
    def apk(self, names):
        handle = tempfile.NamedTemporaryFile(suffix=".apk", delete=False)
        handle.close()
        with zipfile.ZipFile(handle.name, "w") as archive:
            for name in names:
                archive.writestr(name, b"x")
        self.addCleanup(Path(handle.name).unlink)
        return handle.name

    def run_main(self, path):
        import contextlib
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(["check_apk_abis.py", path])
        return code, output.getvalue()

    def test_arm64_only_passes(self):
        path = self.apk(["AndroidManifest.xml", "lib/arm64-v8a/libapp.so",
                         "lib/arm64-v8a/libdartjni.so", "lib/arm64-v8a/libflutter.so"])
        code, output = self.run_main(path)
        self.assertEqual(code, 0)
        self.assertIn("ABIs: arm64-v8a", output)

    def test_plugin_library_for_other_abi_fails(self):
        path = self.apk(["lib/arm64-v8a/libapp.so", "lib/armeabi-v7a/libdartjni.so",
                         "lib/x86_64/libdartjni.so"])
        code, output = self.run_main(path)
        self.assertEqual(code, 1)
        self.assertIn("unexpected ABI armeabi-v7a: libdartjni.so", output)
        self.assertIn("unexpected ABI x86_64: libdartjni.so", output)

    def test_missing_native_libraries_fails(self):
        self.assertEqual(problems([]), ["no native libraries under lib/"])
        self.assertEqual(native_libraries(self.apk(["classes.dex", "lib/"])), [])

    def test_usage_without_path(self):
        import contextlib
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(main(["check_apk_abis.py"]), 2)


if __name__ == "__main__":
    unittest.main()
