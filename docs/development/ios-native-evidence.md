# Native license and iOS privacy evidence

[Main index](../../README.md) | [Playbook](../PLAYBOOK.md) | [Offline notices](third-party-notices.md)

This is a review of package sources and caches, not a native archive inspection or compliance certification.

## Local package evidence

| Locked component | Reviewed local manifest / packaging | Remaining evidence |
| --- | --- | --- |
| flutter_secure_storage_darwin 0.4.3 | Resources/PrivacyInfo.xcprivacy SHA256 47226a29608df206ad0a110e6afeb5a77ff575ac1df9c76bfdb2d6dfb3fafed1; tracking false, collected/accessed-API arrays empty. Podspec resource declaration and SPM `.process("Resources")` include the directory | Actual exported resource/SDK graph and collection/API-use reconciliation |
| url_launcher_ios 6.4.2 | Resources/PrivacyInfo.xcprivacy SHA256 6d2da0d8d930227d428c1d9363b0ad6e3a12e2c9b68c5ce297158a7412fc8c31; tracking false, collected/accessed-API arrays empty. Podspec and SPM both package Resources | Actual exported resource and final native graph |
| path_provider_foundation 2.6.0 | FFI implementation, native_build false in local plugin graph; no local manifest or Swift package declaration found | Listed-SDK/FFI integration and actual final required-reason evidence; native_build false is not an exemption |
| flutter_file_dialog 3.3.3 | Native plugin; podspec and Package.swift found; no production package PrivacyInfo.xcprivacy found | Assess actual bundled code/API use and notice obligations; absence alone is not a finding of violation |
| open_filex 5.0.0 | Native plugin; podspec and Package.swift found; no production package PrivacyInfo.xcprivacy found | Same final graph/API/notice review; custom app bridge handles mobile save/open |
| Flutter engine | No local ios-release engine archive available in this Windows cache; previously shipped Android notice asset contains Flutter/engine notices | Actual signed iOS framework manifests/resources and Xcode aggregate report |
| App Runner | No app-level PrivacyInfo.xcprivacy in current source; native entry point unchanged except display-name metadata | Evaluate actual API usage and SDK declarations before adding justified app reasons; no guessed reasons or encryption exemption added |

The local plugin graph also contains development-only integration_test after host tests. It is not proof that a production archive ships that plugin; the existing release workflow regenerates production registration and validates source/lock stability.

Apple's [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/) identify Flutter, path_provider and url_launcher families and explain manifest/signature obligations. Xcode can aggregate SDK manifests, but source manifests alone do not establish their presence in a signed archive or determine final privacy labels. No privacy declaration or SDK version was changed in this review.

## Android missing-POM clarification

The resolved listenablefuture 1.0 POM inherits com.google.guava:guava-parent:26.0-android. Its cached parent declares The Apache Software License, Version 2.0 with the Apache license URL. This resolves why a direct-child-POM-only inventory showed an empty field; it is **not** evidence that every required license/notice text is included in the app. Its notice is added separately (see below).

Four Flutter engine/embedding POMs also omit direct license fields. The pinned [Flutter 3.47.8 license](https://raw.githubusercontent.com/flutter/flutter/3.47.8/LICENSE) supplies Flutter license terms; engine dependencies have their own retained notices. The old five direct-POM gaps remain honestly labeled in the runtime inventory. Parent/source evidence improves provenance but does not close binary attribution completeness or replace the protected root notice file. No legal conclusion about all bundled components is claimed.

## iOS build evidence, without retaining the IPA

[Inventory tool](../../tools/ios_privacy_inventory.py) reads an IPA in place before the existing strict scan and cleanup. It reports only fixed component labels, manifest hashes, tracking boolean, domain/data-type counts, accessed API category/reason identifiers and notice-asset count. It does not emit archive paths, tracking-domain values or collected-data payloads. It is reporting-only and always states compliance_verified false: zero manifests is an absence report, not a pass. Malformed or oversized manifests stop the report with a fixed error; no raw values are printed.

The signed workflow calls this tool before the privacy scanner. Synthetic tests cover resource counting/redaction, missing manifests, malformed manifests and untrusted reason text.

The report does not replace the complete Xcode privacy report, SDK signatures, actual license text review, required-reason justification, native logs/network verification or App Store/Play declarations. Final iOS archive inspection and store answers remain open.

## Guava attribution

Retrieved the exact com.google.guava:listenablefuture:1.0 source archive from Maven Central and verified its published SHA1; retained SHA256/source/license/asset provenance in [the record](guava-notice-provenance.json). Source copyright is Copyright (C) 2007 The Guava Authors, not an inferred current-year attribution. The separate Android asset preserves its upstream header plus complete Apache License 2.0 text from Apache's official versioned license URL.

Added an Android-only lazy LicenseRegistry entry for the offline viewer. No native SDK upgrade or root notice rewrite. This covers that coordinate only; other native obligations are reviewed separately.
