"""Reporting-only IPA privacy inventory; never emit paths, domains or data payloads."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import zipfile

COMPONENTS = ('Flutter', 'App', 'flutter_secure_storage_darwin', 'url_launcher_ios', 'path_provider_foundation', 'flutter_file_dialog', 'open_filex')


def inventory(path):
    reports = []
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 20000:
            raise ValueError('Archive entry limit exceeded')
        notices = sum(entry.filename.endswith(('/NOTICES', '/NOTICES.Z')) for entry in entries)
        for entry in entries:
            if not entry.filename.endswith('/PrivacyInfo.xcprivacy'):
                continue
            if entry.file_size > 1024 * 1024:
                raise ValueError('Privacy manifest size limit exceeded')
            raw = archive.read(entry)
            data = plistlib.loads(raw)
            if not isinstance(data, dict):
                raise ValueError('Privacy manifest must be a dictionary')
            component = 'bundled-resource'
            for known in COMPONENTS:
                if any(part in (known + '.framework', known + '.bundle', known + '_' + known + '.bundle') for part in entry.filename.split('/')):
                    component = known
                    break
            domains = data.get('NSPrivacyTrackingDomains', [])
            collected = data.get('NSPrivacyCollectedDataTypes', [])
            accessed = data.get('NSPrivacyAccessedAPITypes', [])
            tracking = data.get('NSPrivacyTracking')
            if (tracking is not None and not isinstance(tracking, bool)) or any(not isinstance(items, list) for items in (domains, collected, accessed)):
                raise ValueError('Invalid privacy manifest field type')
            api_entries = []
            for item in accessed:
                if not isinstance(item, dict):
                    raise ValueError('Invalid accessed-API entry')
                category = item.get('NSPrivacyAccessedAPIType', '')
                reasons = item.get('NSPrivacyAccessedAPITypeReasons', [])
                if not isinstance(category, str) or not re.fullmatch(r'NSPrivacyAccessedAPICategory[A-Za-z]+', category):
                    raise ValueError('Invalid accessed-API category')
                if not isinstance(reasons, list) or any(not isinstance(reason, str) or not re.fullmatch(r'[A-F0-9]{4}\.[0-9]+', reason) for reason in reasons):
                    raise ValueError('Invalid accessed-API reason format')
                api_entries.append({'category': category, 'reasons': sorted(reasons)})
            reports.append({'component': component, 'sha256': hashlib.sha256(raw).hexdigest(), 'tracking': tracking,
                            'tracking_domain_count': len(domains), 'collected_type_count': len(collected), 'accessed_apis': api_entries})
    return {'report_only': True, 'compliance_verified': False, 'manifest_count': len(reports),
            'bundled_notice_asset_count': notices, 'manifests': reports}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    args = parser.parse_args(argv)
    try:
        result = inventory(args.artifact)
    except (OSError, ValueError, plistlib.InvalidFileException, zipfile.BadZipFile):
        print('Privacy inventory could not complete; paths and manifest values withheld.')
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
