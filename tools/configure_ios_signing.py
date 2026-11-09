"""Apply distribution settings only to Runner configs in a disposable CI checkout."""
import os
import re
import sys
from pathlib import Path

BUNDLE = 'com.kuncarlos91.mailshelf'
BLOCK = re.compile(r'(\bbuildSettings = \{\n)(.*?)(^\t{3}\};)', re.S | re.M)

def configure(text, team, profile):
    if not re.fullmatch(r'[A-Z0-9]{10}', team) or not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', profile):
        raise ValueError('Invalid signing input format')
    settings = {
        'CODE_SIGN_STYLE': 'Manual',
        'DEVELOPMENT_TEAM': team,
        'CODE_SIGN_IDENTITY': '"Apple Distribution"',
        '"CODE_SIGN_IDENTITY[sdk=iphoneos*]"': '"Apple Distribution"',
        'PROVISIONING_PROFILE_SPECIFIER': '"' + profile + '"',
    }
    count = 0
    def update(match):
        nonlocal count
        body = match[2]
        if not re.search(r'^\s*PRODUCT_BUNDLE_IDENTIFIER = ' + re.escape(BUNDLE) + r';$', body, re.M):
            return match[0]
        count += 1
        for key, value in settings.items():
            pattern = r'^\t{4}' + re.escape(key) + r' = [^\n]*;\n'
            body = re.sub(pattern, '', body, flags=re.M)
            body += '\t\t\t\t' + key + ' = ' + value + ';\n'
        return match[1] + body + match[3]
    result = BLOCK.sub(update, text)
    if count != 3:
        raise ValueError('Expected exactly three Runner build configurations')
    return result

def main():
    try:
        p = Path('ios/Runner.xcodeproj/project.pbxproj')
        text = p.read_text(encoding='utf-8')
        result = configure(text, os.environ.get('APPLE_TEAM_ID', ''), os.environ.get('IOS_PROFILE_UUID', ''))
        p.write_text(result, encoding='utf-8')
    except (OSError, ValueError):
        print('App-only signing setup failed; private values and paths withheld.', file=sys.stderr)
        return 1
    print('Distribution signing configured for three Runner configurations only; values withheld.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
