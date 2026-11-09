# Setup and automated checks

[Main documentation index](../../README.md) · [Contributing](../../CONTRIBUTING.md) · [Documentation rules](documentation.md)

## Flutter checks

The `Flutter checks` workflow runs on pushes and pull requests, and can be started from the Actions tab with **Run workflow**.

It uses Ubuntu 24.04 and Flutter 3.47.8 stable. It installs the committed lockfile, runs analysis with info-level findings treated as failures, and runs all Flutter tests. A lockfile mismatch fails rather than silently resolving different dependency versions. Update the SDK pin deliberately when upgrading Flutter.

Only read access to repository contents is granted. No API keys, signing files, private server access or secrets are needed. This workflow does not build or sign APKs, publish releases or test iOS.

Actions are pinned to verified commit revisions. New pushes to the same branch or pull request cancel obsolete runs. The job has a 20-minute limit.

Local equivalents, from the repository root:

```powershell
flutter pub get --enforce-lockfile
flutter analyze --no-pub --fatal-infos
flutter test --no-pub
```

## Privacy guard

A separate dependency-free Python job scans tracked/non-ignored files and runs the Python helper and privacy regression tests. It does not print matched values or filenames. This is a pattern guard, not a security certification. Run it locally with `python tools/privacy_check.py` and `python -m unittest discover -s tools -p 'test_*.py'`. See [artifact privacy rules](../security/artifact-privacy-rules.md).

## Documentation checks

The same job validates local documentation links with `python tools/check_docs.py`. It has no network dependency. See [documentation rules](documentation.md).

## iOS builds

There is no hosted iOS workflow in this repository. Build and run iOS locally on macOS with Xcode (`flutter run` or `flutter build ios`). Signed iOS distribution is handled privately by the maintainer and is not part of this repository.

## Manual Android test APK

`.github/workflows/android-test-apk.yml` runs only on request: push a commit whose message contains `[build apk]`, or start it from Actions, Android test APK, Run workflow. On other pushes the job is skipped and uses no minutes. It builds a debug APK for 64-bit phones on Linux and uploads it with a SHA-256 checksum as the `mailburrow-test-apk` artifact, kept for 3 days. It uses no signing secrets and creates no tag or release.

The APK is debug-signed and installs as MailBurrow Preview (`com.kuncarlos91.mailburrow.debug`). Every run signs with a fresh throwaway debug key, so remove any earlier debug install first; otherwise Android reports "App not installed".

## Build information

Release builds supply version/build values to Settings through the `MAILSHELF_BUILD_VERSION` and `MAILSHELF_BUILD_NUMBER` Dart defines. Unstamped local builds say build information is unavailable.

## Signed Android releases

Signed release APKs are built locally by the maintainer; see [Android signing](../releasing/android.md). The keystore and its passwords never go in Git or CI logs.
