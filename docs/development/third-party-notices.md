# In-app third-party notices

[Main index](../../README.md) | [Playbook](../PLAYBOOK.md) | [Dependency inventory](dependencies.md)

## Open source licenses screen

Settings contains Open source licenses. It opens Flutter's built-in LicensePage under the MailBurrow name and supplied build information. Users can select a package, read bundled notices and return to Settings. Flutter's LicenseRegistry reads the existing bundled NOTICES/NOTICES.Z asset; the screen needs no server connection, API key, browser, plugin, new dependency or added permission. License text is displayed, not interpreted as HTML or executed. No original-code license or copyright ownership is asserted by the screen title.

Source: [tile](../../lib/third_party_licenses.dart), [Settings integration](../../lib/screens/settings_view.dart), [host tests](../../test/third_party_licenses_test.dart). Internal IDs/storage/signing/bridge and protected root THIRD_PARTY_NOTICES.md are unchanged. Check the screen on a device in each new signed build.

## Verified inventory and remaining scope

Read-only dependency verification matched 80 package rows and 30 distinct normalized retained texts. Android offline releaseRuntimeClasspath resolves 63 external coordinates. Five cached POMs lack license declarations: Guava listenablefuture plus four Flutter embedding/engine coordinates. Lack of a POM field does not establish no license or a violation. The [Android native review](android-native-license-review.md) records the source/SDK provenance follow-up; exact signed-artifact inclusion remains to be checked. Package-cache and POM evidence are not a complete native compliance assessment.

Do not substitute the root notice document for the runtime registry, or assume the registry includes every native SDK notice. Verify the exact final artifact's NOTICES asset and any separately required native notices. Keep full upstream attribution text, root path and strict privacy rules intact. iOS framework privacy manifests/required-reason APIs, SDK licenses, crypto declarations, copied-code/icon provenance and store disclosures remain open; a passing artifact privacy scan is not that inventory.

## Validation and device handoff

Host coverage exercises registered synthetic notice rendering, package detail/back navigation and 3x text in 640x320 landscape. The landscape test waits for scroll/layout animations before testing reachability; an unsettled assertion was corrected, not a product bug hidden by changing text scale. Host tests do not prove final asset inclusion on both platforms.

On each new signed build, update without uninstalling, open Settings > Open source licenses offline, inspect real entries (including Flutter and used packages), open a long notice, scroll at largest text in portrait/landscape, go back twice and confirm account/connection state remains. Record platform/build/device and missing notices without sending personal mail or paths.

## Verifying notices

Run the Flutter tests (`flutter test --no-pub`), which cover offline synthetic notice rendering, package navigation and largest-text landscape, and the Python helper tests (`python -m unittest discover -s tools -p 'test_*.py'`). `python tools/dependency_notices.py --check` confirms the inventory and root notices match the locked dependencies without changing any file. Passing these checks does not establish native notice completeness or final binary compliance; those remain separate checks on each signed artifact.

For reference, a read-only inspection of an earlier signed Android build's NOTICES.Z found 1,622 notice groups and 146 named components, including Flutter, flutter_secure_storage, html, url_launcher, path_provider, open_filex and flutter_file_dialog. These counts describe Flutter's aggregated asset and are distinct from 80 package rows/30 normalized source notice texts. It establishes existing Android asset presence, not the new screen's device behavior, every native license obligation or iOS bundle completeness.

Protected inputs (root THIRD_PARTY_NOTICES.md, pubspec.yaml and pubspec.lock) must not change as part of notice tooling work.

## Additional native Android attribution

The app adds [Guava attribution registration](../../lib/native_license_notices.dart) using a separate verified asset, lazily loaded only on Android. [Provenance](guava-notice-provenance.json) records the exact published source archive and license checksums. Full upstream header/license is retained; root THIRD_PARTY_NOTICES.md and dependency lock are unchanged. Host coverage checks iOS skips this Android-only entry, repeated registration does not duplicate it, and the real bundled text includes copyright/license start/end. Confirm this entry in each new signed Android build's Open source licenses screen.
