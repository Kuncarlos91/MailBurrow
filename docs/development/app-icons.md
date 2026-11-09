# MailBurrow app icon assets

[Main index](../../README.md) | [Playbook](../PLAYBOOK.md)

## Selected direction and provenance

The selected concept is an ivory envelope inside a purple burrow arch. [Reference and provenance](../../assets/branding/provenance.json) preserve the selected built-in image-generation concept/hash. The production master is a project-authored vector refinement of that direction: flat opaque indigo background, violet arch and ivory envelope with cleaner small-size geometry. It is an adaptation, not a claim of pixel-identical reproduction of the generated reference. No third-party logo was copied into the replacement assets. Provenance does not establish trademark clearance or exclusive legal rights.

[Geometry/palette](../../assets/branding/icon-design.json) is the shared source for [SVG](../../assets/branding/mailburrow-icon.svg), Android vector resources and the Windows renderer. The source/reference images are not included in the Flutter asset bundle; only existing native icon resources consume the platform outputs. No new app dependency is used.

## Prepared outputs

- iOS: existing AppIcon catalog/path retained; all 19 entries resolve to 15 PNG files at the specified dimensions. PNGs are opaque RGB without an alpha channel, sRGB-tagged and square with no baked corner mask. Marketing export is 1024x1024.
- Android pre-26: existing five launcher PNG paths replaced at 48/72/96/144/192 pixels.
- Android API26+: mipmap-anydpi-v26 foreground/background resources; vectors on a 108dp canvas with centered mark. API33+ adds a separate monochrome layer for supported themed launchers. The conservative geometry/stroke radius is 32.959dp inside the 33dp central safe circle, and the mark dimensions are within 48-66dp.
- Play listing: separate 512x512 sRGB 32-bit RGBA PNG, every alpha sample 255, under 1 MiB; no baked round corners or outer drop shadow. This differs intentionally from the alpha-free iOS files.

App IDs, signing, secure storage, native channels, icon resource names and catalog registration are preserved.

## Reproduce and validate

From repository root:

```powershell
python tools/build_icon_sources.py --write
.\tools\render_app_icons.ps1
python tools/build_icon_sources.py
python tools/check_app_icons.py
```

Text source generation/checking is Python standard-library only. Raster export uses Windows PowerShell and built-in System.Drawing; no Pillow/CairoSVG/package installation. The renderer reads the shared geometry, generates opaque platform assets plus store exports, and creates ignored build/branding/mailburrow-icon-review.png. Checks validate PNG CRC/dimensions/color/alpha/sRGB, catalog completeness, SVG/XML agreement and conservative adaptive geometry. Check receipt is ignored build/branding/validation.json. Rendering on other systems can differ in antialiasing; SVG/Android vectors retain geometry.

Visual review inspected the generated master/circle/rounded previews and actual 64/48/32px samples; envelope/arch remain distinguishable. Masks in the review sheet are illustrative and do not certify every OEM launcher or actual iOS device rendering. The master/export assets themselves remain square.

## Device checks

After changing icons, confirm launcher and app-switcher appearance on Android (circle/squircle masks, themed icons, dark and light wallpapers) and on iOS/iPadOS home screens.

References checked: [Android adaptive layers/safe zone](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive), [Google Play icon attributes](https://developer.android.com/distribute/google-play/resources/icon-design-specifications), [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).

Validation checkpoint: icon source generation check and platform PNG/vector checks passed; all 80 Python helper regressions passed; documentation links, current-source privacy and whitespace checks passed. No Flutter tests were repeated for unchanged Dart behavior in this icon-only step. No native resource compilation or installation was performed.

The vector refinement was reviewed and accepted as the source artwork. Native build, device and store-catalog checks are still needed after any icon change.
