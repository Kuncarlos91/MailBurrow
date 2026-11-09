"""Generate SVG/Android text resources from the approved geometry; check by default."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sources():
    d = json.loads((ROOT / 'assets/branding/icon-design.json').read_text())
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1000 1000"><title>MailBurrow envelope in a burrow</title><rect width="1000" height="1000" fill="{d["background"]}"/><path d="{d["arch"]}" fill="none" stroke="{d["arch_color"]}" stroke-width="{d["arch_width"]}" stroke-linecap="round" stroke-linejoin="round"/><path d="{d["body"]}" fill="{d["envelope_color"]}"/><path d="{d["flap"]}" fill="{d["envelope_color"]}"/></svg>\n'
    result = {'assets/branding/mailburrow-icon.svg': svg}
    res = 'android/app/src/main/res/'
    for name, mono in [('mailburrow_icon_foreground', False), ('mailburrow_icon_monochrome', True)]:
        color = '#FFFFFFFF' if mono else d['arch_color']
        envelope = '#FFFFFFFF' if mono else d['envelope_color']
        result[res + 'drawable/' + name + '.xml'] = f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
  <group android:scaleX="{d['adaptive_scale']}" android:scaleY="{d['adaptive_scale']}" android:translateX="{d['adaptive_translate']}" android:translateY="{d['adaptive_translate']}">
    <path android:pathData="{d['arch']}" android:strokeColor="{color}" android:strokeWidth="{d['arch_width']}" android:strokeLineCap="round" android:strokeLineJoin="round" android:fillColor="#00000000" />
    <path android:pathData="{d['body']}" android:fillColor="{envelope}" />
    <path android:pathData="{d['flap']}" android:fillColor="{envelope}" />
  </group>
</vector>
'''
    result[res + 'values/mailburrow_icon_colors.xml'] = '<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="mailburrow_icon_background">' + d['background'] + '</color></resources>\n'
    for api in [26, 33]:
        mono = '\n  <monochrome android:drawable="@drawable/mailburrow_icon_monochrome" />' if api == 33 else ''
        result[res + f'mipmap-anydpi-v{api}/ic_launcher.xml'] = '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n  <background android:drawable="@color/mailburrow_icon_background" />\n  <foreground android:drawable="@drawable/mailburrow_icon_foreground" />' + mono + '\n</adaptive-icon>\n'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    for name, content in sources().items():
        path = ROOT / name
        if args.write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
        elif not path.exists() or path.read_text(encoding='utf-8') != content:
            raise SystemExit('Icon source/resources are stale; regenerate explicitly with --write')
    print('Icon text sources ' + ('generated.' if args.write else 'verified without writes.'))


if __name__ == '__main__':
    main()
