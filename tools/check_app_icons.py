"""Validate generated catalog/launcher/store icon assets without imaging dependencies."""
import hashlib
import json
import math
import re
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zlib
from build_icon_sources import ROOT, sources


def png(path, size, color_type):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid PNG signature'
    chunks = {}
    offset = 8
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        kind = data[offset+4:offset+8]
        payload = data[offset+8:offset+8+length]
        checksum = struct.unpack('>I', data[offset+8+length:offset+12+length])[0]
        assert zlib.crc32(kind + payload) == checksum, 'PNG checksum mismatch'
        chunks.setdefault(kind, []).append(payload)
        offset += length + 12
    w,h,depth,color,compression,filter_method,interlace = struct.unpack('>IIBBBBB',chunks[b'IHDR'][0])
    assert (w,h,depth,color,compression,filter_method,interlace) == (size,size,8,color_type,0,0,0), 'Unexpected PNG dimensions/format'
    assert b'tRNS' not in chunks, 'Transparent-color chunk is not allowed'
    assert b'sRGB' in chunks, 'Missing sRGB declaration'
    if color_type == 6:
        raw = zlib.decompress(b''.join(chunks[b'IDAT']))
        stride = size * 4
        assert len(raw) == (stride + 1) * size
        previous = bytearray(stride)
        for row in range(size):
            start = row * (stride + 1)
            method = raw[start]
            current = bytearray(raw[start+1:start+1+stride])
            for i in range(stride):
                left = current[i-4] if i >= 4 else 0
                up = previous[i]
                upper_left = previous[i-4] if i >= 4 else 0
                if method == 0: predictor = 0
                elif method == 1: predictor = left
                elif method == 2: predictor = up
                elif method == 3: predictor = (left + up) // 2
                elif method == 4:
                    p = left + up - upper_left
                    distances = (abs(p-left),abs(p-up),abs(p-upper_left))
                    predictor = (left,up,upper_left)[distances.index(min(distances))]
                else: raise AssertionError('Unsupported PNG row filter')
                current[i] = (current[i] + predictor) & 255
            assert all(current[i] == 255 for i in range(3,stride,4)), 'Transparent pixels in store icon'
            previous = current
    return hashlib.sha256(data).hexdigest()


def main():
    hashes = {}
    for name,content in sources().items():
        assert (ROOT/name).read_text(encoding='utf-8') == content, 'Stale vector resources'
        if name.endswith(('.xml','.svg')):
            ET.fromstring(content)
    catalog = json.loads((ROOT/'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())
    files = set()
    for entry in catalog['images']:
        name = 'ios/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename']
        size = int(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        hashes[name] = png(ROOT/name,size,2)
        files.add(name)
    for density,size in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
        name = f'android/app/src/main/res/mipmap-{density}/ic_launcher.png'
        hashes[name] = png(ROOT/name,size,2)
    for size,color in [(512,6),(1024,2)]:
        name = f'assets/branding/store-icon-{size}.png'
        hashes[name] = png(ROOT/name,size,color)
        assert (ROOT/name).stat().st_size < 1024*1024
    d = json.loads((ROOT/'assets/branding/icon-design.json').read_text())
    # A Bezier curve lies in the convex hull of its control points. Bound every
    # path's hull plus stroke radius rather than relying on cached coordinates.
    point_sets = {}
    for key in ('arch','body','flap'):
        numbers = [float(value) for value in re.findall(r'-?\d+(?:\.\d+)?',d[key])]
        assert len(numbers) % 2 == 0
        point_sets[key] = list(zip(numbers[::2],numbers[1::2]))
    assert d['viewbox'] == 1000
    maximum_radius = max((max(math.hypot(x-500,y-500) for x,y in points) + (d['arch_width']/2 if key=='arch' else 0)) * d['adaptive_scale'] for key,points in point_sets.items())
    assert maximum_radius <= 33, 'Adaptive mark exceeds central safe circle'
    arch_x,arch_y = zip(*point_sets['arch'])
    assert 48 <= (max(arch_x)-min(arch_x)+d['arch_width'])*d['adaptive_scale'] <= 66
    assert 48 <= (max(arch_y)-min(arch_y)+d['arch_width'])*d['adaptive_scale'] <= 66
    assert d['adaptive_translate'] + 500*d['adaptive_scale'] == 54
    record={'ios_catalog_entries':len(catalog['images']),'ios_unique_files':len(files),'legacy_android_files':5,'adaptive_safe_radius_dp':round(maximum_radius,3),'sha256':hashes,'native_compiled':False,'device_tested':False}
    destination=ROOT/'build/branding/validation.json'; destination.parent.mkdir(parents=True,exist_ok=True)
    destination.write_text(json.dumps(record,indent=2)+'\n')
    print(f'Validated {len(files)} iOS files, five Android PNGs, adaptive/monochrome XML and both store exports; safe radius {maximum_radius:.3f}dp.')


if __name__ == '__main__':
    main()
