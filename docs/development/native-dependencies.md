# Android native dependency inventory

[Main index](../../README.md)

Refreshed November 22, 2026 from a successful releaseRuntimeClasspath report for MailBurrow `main` at `ec6ab9d` (app lock merged). Since the November 6 refresh: `androidx.biometric:biometric` 1.1.0 added, and `androidx.core`/`core-ktx` 1.18.0, `androidx.fragment` 1.8.9 and Kotlin coroutines 1.9.0 selected, all declaring Apache-2.0. The five coordinates without a cached POM declaration are unchanged from the previous refresh (Guava `listenablefuture` 1.0 and the Flutter engine artifacts, whose notices come with Flutter). These are declared cached POM license names, not a completed license-compliance determination. Gradle plugin/build-tool dependencies are outside this runtime list.

Flutter/Dart notices are in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). Coordinates with missing declarations require upstream review. Native notices and binary provenance must be reviewed before each binary release. iOS framework dependency licensing is not inventoried here; successful native compilation does not establish notice completeness.

| Coordinate | Selected version | Cached POM license declaration |
| --- | --- | --- |
| androidx.activity:activity | 1.9.0 | The Apache Software License, Version 2.0 |
| androidx.annotation:annotation | 1.10.0 | The Apache Software License, Version 2.0 |
| androidx.annotation:annotation-experimental | 1.4.1 | The Apache Software License, Version 2.0 |
| androidx.annotation:annotation-jvm | 1.10.0 | The Apache Software License, Version 2.0 |
| androidx.appcompat:appcompat | 1.6.1 | The Apache Software License, Version 2.0 |
| androidx.appcompat:appcompat-resources | 1.6.1 | The Apache Software License, Version 2.0 |
| androidx.arch.core:core-common | 2.2.0 | The Apache Software License, Version 2.0 |
| androidx.arch.core:core-runtime | 2.2.0 | The Apache Software License, Version 2.0 |
| androidx.biometric:biometric | 1.1.0 | The Apache Software License, Version 2.0 |
| androidx.browser:browser | 1.9.0 | The Apache Software License, Version 2.0 |
| androidx.collection:collection | 1.4.2 | The Apache Software License, Version 2.0 |
| androidx.collection:collection-jvm | 1.4.2 | The Apache Software License, Version 2.0 |
| androidx.concurrent:concurrent-futures | 1.1.0 | The Apache Software License, Version 2.0 |
| androidx.core:core | 1.18.0 | The Apache Software License, Version 2.0 |
| androidx.core:core-ktx | 1.18.0 | The Apache Software License, Version 2.0 |
| androidx.core:core-viewtree | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.cursoradapter:cursoradapter | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.customview:customview | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.documentfile:documentfile | 1.0.1 | The Apache Software License, Version 2.0 |
| androidx.drawerlayout:drawerlayout | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.emoji2:emoji2 | 1.2.0 | The Apache Software License, Version 2.0 |
| androidx.emoji2:emoji2-views-helper | 1.2.0 | The Apache Software License, Version 2.0 |
| androidx.exifinterface:exifinterface | 1.4.1 | The Apache Software License, Version 2.0 |
| androidx.fragment:fragment | 1.8.9 | The Apache Software License, Version 2.0 |
| androidx.interpolator:interpolator | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-common | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-common-java8 | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-livedata | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-livedata-core | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-livedata-core-ktx | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-process | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-runtime | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-viewmodel | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.lifecycle:lifecycle-viewmodel-savedstate | 2.7.0 | The Apache Software License, Version 2.0 |
| androidx.loader:loader | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.profileinstaller:profileinstaller | 1.3.1 | The Apache Software License, Version 2.0 |
| androidx.resourceinspection:resourceinspection-annotation | 1.0.1 | The Apache Software License, Version 2.0 |
| androidx.savedstate:savedstate | 1.2.1 | The Apache Software License, Version 2.0 |
| androidx.startup:startup-runtime | 1.1.1 | The Apache Software License, Version 2.0 |
| androidx.tracing:tracing | 1.2.0 | The Apache Software License, Version 2.0 |
| androidx.vectordrawable:vectordrawable | 1.1.0 | The Apache Software License, Version 2.0 |
| androidx.vectordrawable:vectordrawable-animated | 1.1.0 | The Apache Software License, Version 2.0 |
| androidx.versionedparcelable:versionedparcelable | 1.1.1 | The Apache Software License, Version 2.0 |
| androidx.viewpager:viewpager | 1.0.0 | The Apache Software License, Version 2.0 |
| androidx.window:window | 1.2.0 | The Apache Software License, Version 2.0 |
| androidx.window:window-java | 1.2.0 | The Apache Software License, Version 2.0 |
| androidx.window.extensions.core:core | 1.0.0 | The Apache Software License, Version 2.0 |
| com.getkeepsafe.relinker:relinker | 1.4.5 | The Apache Software License, Version 2.0 |
| com.google.code.findbugs:jsr305 | 3.0.2 | The Apache Software License, Version 2.0 |
| com.google.code.gson:gson | 2.13.2 | Apache-2.0 |
| com.google.crypto.tink:tink-android | 1.23.0 | Apache License, Version 2.0 |
| com.google.errorprone:error_prone_annotations | 2.41.0 | Apache 2.0 |
| com.google.guava:listenablefuture | 1.0 | Not declared in cached POM; review upstream notices |
| io.flutter:arm64_v8a_release | 1.0.0-cf636b1dfb818dd6a3ff16e390e93b1a036969c8 | Not declared in cached POM; review upstream notices |
| io.flutter:armeabi_v7a_release | 1.0.0-cf636b1dfb818dd6a3ff16e390e93b1a036969c8 | Not declared in cached POM; review upstream notices |
| io.flutter:flutter_embedding_release | 1.0.0-cf636b1dfb818dd6a3ff16e390e93b1a036969c8 | Not declared in cached POM; review upstream notices |
| io.flutter:x86_64_release | 1.0.0-cf636b1dfb818dd6a3ff16e390e93b1a036969c8 | Not declared in cached POM; review upstream notices |
| org.jetbrains:annotations | 23.0.0 | The Apache Software License, Version 2.0 |
| org.jetbrains.kotlin:kotlin-stdlib | 2.4.0 | Apache-2.0 |
| org.jetbrains.kotlinx:kotlinx-coroutines-android | 1.9.0 | The Apache Software License, Version 2.0 |
| org.jetbrains.kotlinx:kotlinx-coroutines-bom | 1.9.0 | The Apache Software License, Version 2.0 |
| org.jetbrains.kotlinx:kotlinx-coroutines-core | 1.9.0 | The Apache Software License, Version 2.0 |
| org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm | 1.9.0 | The Apache Software License, Version 2.0 |
| org.jspecify:jspecify | 1.0.0 | The Apache License, Version 2.0 |

Regenerate using tools/native_dependency_inventory.py with a successful releaseRuntimeClasspath report. Keep raw reports outside Git if they contain local paths.

## Direct-POM declaration follow-up

The five missing direct declarations have source/SDK provenance in the [Android native license review](android-native-license-review.md). This table preserves the observed cached POM declarations rather than treating those omissions as licence-free artifacts. Guava attribution and Flutter/engine notice inputs are retained; exact next-release APK packaging and device notice verification remain required. The earlier 63-coordinate graph match is historical and does not verify the refreshed 64-coordinate graph or a new signed artifact. The refreshed report is maintainer-generated evidence at `ec6ab9d`; it was not independently rerun in this documentation review.
