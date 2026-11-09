import unittest
from select_ios_runtime import select_runtime


class RuntimeSelectionTests(unittest.TestCase):
    def test_matching_available_ios_only(self):
        data = {"runtimes": [
            {"isAvailable": True, "version": "26.2", "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-2"},
            {"isAvailable": False, "version": "26.2", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2"},
            {"isAvailable": True, "version": "26.2", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-2-installed"},
        ]}
        self.assertEqual(select_runtime(data, "26.2"), "com.apple.CoreSimulator.SimRuntime.iOS-26-2-installed")

    def test_no_silent_other_sdk_fallback(self):
        data = {"runtimes": [
            {"isAvailable": True, "version": "18.5", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5"},
        ]}
        with self.assertRaises(ValueError):
            select_runtime(data, "26.2")

    def test_rejects_unexpected_sdk(self):
        with self.assertRaises(ValueError):
            select_runtime({"runtimes": []}, "unknown")


if __name__ == "__main__":
    unittest.main()
