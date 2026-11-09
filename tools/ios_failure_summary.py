"""Classify private Xcode failures without printing log lines or matched values."""
import re
import sys
from pathlib import Path

# Only these fixed strings may leave the private runner log.
RULES = (
    ('profile-applied-to-unsupported-target', r'does not support provisioning profiles'),
    ('profile-app-identity-mismatch', r'provisioning profile[^\n]*(?:doesn.t match|does not match)[^\n]*(?:bundle|identifier)'),
    ('profile-certificate-mismatch', r'provisioning profile[^\n]*(?:doesn.t include|does not include)[^\n]*(?:certificate|signing)'),
    ('profile-capability-or-entitlement-mismatch', r'provisioning profile[^\n]*(?:doesn.t support|does not support|doesn.t include|does not include)[^\n]*(?:capability|entitlement|keychain)'),
    ('profile-expired', r'provisioning profile[^\n]*(?:has expired|is expired)'),
    ('profile-not-found', r'(?:no profiles for[^\n]*were found|no provisioning profiles found|requires a provisioning profile)'),
    ('signing-identity-unavailable', r'(?:no signing certificate|no valid signing identities|signing identity[^\n]*not found)'),
    ('signing-team-required', r'signing for[^\n]*requires a development team'),
    ('signing-settings-conflict', r'(?:conflicting provisioning settings|automatically signed[^\n]*manually specified)'),
    ('keychain-access-denied', r'(?:user interaction is not allowed|errSecInternalComponent|unable to build chain to self-signed root)'),
    ('dependency-or-module-build-failure', r'(?:could not build[^\n]*module|no such module|module[^\n]*not found|could not resolve package dependencies)'),
    ('compiler-failure', r'(?:SwiftCompile[^\n]*failed|CompileC[^\n]*failed|command SwiftCompile failed)'),
    ('export-provisioning-failure', r'error: exportArchive[^\n]*(?:provision|signing|certificate)'),
)

def classify(text):
    categories = [label for label, pattern in RULES if re.search(pattern, text, re.I)]
    return categories or ['unclassified-native-failure']

def main(args):
    if len(args) != 1:
        print('Diagnostic unavailable: expected one private log file.')
        return 2
    try:
        path = Path(args[0])
        if path.stat().st_size > 32_000_000:
            print('Diagnostic unavailable: private log exceeds scan bound.')
            return 2
        text = path.read_text(encoding='utf-8', errors='replace')
    except OSError:
        print('Diagnostic unavailable: private log could not be read.')
        return 2
    for category in classify(text):
        print('iOS failure category: ' + category)
    print('Raw native log and all matched values withheld. Categories are clues, not a confirmed root cause.')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
