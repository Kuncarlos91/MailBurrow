# Android native license review

[Main index](../../README.md) · [Runtime inventory](native-dependencies.md) · [In-app notices](third-party-notices.md)

## Current review scope

The pinned release-runtime graph resolves 63 external coordinates and matches the committed inventory without version changes. This review checks cached POMs, runtime JAR/AAR contents (including nested classes JARs), 13 available source archives, Flutter SDK license inputs and the existing Guava notice. The [machine-readable evidence](android-native-license-evidence.json) records versions/hashes without personal cache paths. This is source/cache evidence, not final signed-APK clearance or legal certification.

## Five absent direct-POM declarations

| Component | License/notice evidence | Result |
| --- | --- | --- |
| Guava ListenableFuture 1.0 | Its exact source archive and bundled notice match the existing [provenance](guava-notice-provenance.json). The source header and parent `guava-parent:26.0-android` declare Apache-2.0. | Attribution already registered from a bundled asset; verify it in the next signed APK. |
| Flutter Android embedding and three release architecture artifacts | Pinned engine revision matches the installed SDK. Flutter uses BSD-style terms; the SDK `sky_engine` multi-license bundle includes Flutter and engine third-party notices and is represented in the locked dependency inventory/root notices. An earlier debug APK contains the aggregate engine notices. | Absence of direct Maven license fields is not evidence of an unlicensed dependency. Preserve the SDK notice inputs and verify the exact release asset. |

The remaining 58 coordinates have direct Apache-2.0 declarations in cached POMs. These declarations do not independently establish all redistribution obligations. The four Flutter coordinates share an engine revision; their transitive third-party notices must not be replaced with only Flutter's own BSD text.

## Supplied artifact notice files

Runtime archives contain explicit AndroidX license files for annotation-jvm, browser, core, core-ktx, core-viewtree and exifinterface. Their six files are byte-identical Apache-2.0 terms; that exact text is already retained in the root notice document. No separate NOTICE/COPYING/COPYRIGHT files were found in the reviewed runtime archives/nested JARs or the 13 available source archives. This bounded search is not proof about unavailable sources, a later dependency version or a final APK.

No additional distinct notice payload was identified by this review. Do not remove, relabel or rewrite the supplied license files. No app dependency or root third-party notice change is needed on the evidence gathered so far.

## Required check on the next release APK

1. Record the exact source, SDK/engine, resolved graph and APK hash. Re-review if any dependency/version changes.
2. Inspect that APK's NOTICES/NOTICES.Z and Guava asset. Verify the expected Flutter/engine license groups and supplied Apache terms survive packaging; inspect the metadata resources actually included.
3. Open Settings > Open source licenses offline on Android, find Flutter and Guava entries, and read/scroll their complete notices. A host mock or an older debug APK does not establish this.
4. Keep binary metadata/privacy, signature/package/version/permissions and device regression as separate release gates. Do not treat this document as permission to publish a binary.

## Primary references

- [Apache-2.0 redistribution conditions](https://www.apache.org/licenses/LICENSE-2.0)
- [Flutter engine license](https://github.com/flutter/engine/blob/main/LICENSE) and [Flutter framework license](https://github.com/flutter/flutter/blob/master/LICENSE): upstream context; the installed pinned SDK inputs and hashes above are the version-specific evidence.
- [Guava published parent POM](https://repo.maven.apache.org/maven2/com/google/guava/guava-parent/26.0-android/guava-parent-26.0-android.pom) and the exact source/license provenance linked above.
