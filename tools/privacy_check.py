"""Small, dependency-free privacy guard. Findings never include matched values.

Default: scan tracked and non-ignored current files. --history: inspect reachable historical blobs
as a separate audit (never a public-readiness certificate).
"""
import argparse
from artifact_structure import macho_sections, match_structure
from signature_origin import signature_origin
import hashlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AIza[A-Za-z0-9_-]{30,}|sk-(?:proj-)?[A-Za-z0-9_-]{30,})\b")
# Verified upstream format: https://github.com/s1t5/mail-archiver/blob/main/doc/API.md
MAIL_ARCHIVER = re.compile(rb"\bma_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])")
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----")
HOST = re.compile(rb"(?i)\b[a-z0-9.-]+\.ts\.net\b")
LOCAL_PATH = re.compile(rb"(?i)(?:[a-z]:[/\\]+Users[/\\]+|(?<![a-z0-9./:-])/(?:Users|home)/)([a-z0-9_.-]+)")
EMAIL = re.compile(rb"(?i)\b[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]{2,})\b")
ASSIGNMENT = re.compile(rb"""(?ix)
(?:api[_-]?key|access[_-]?token|storepassword|keypassword|authorization)
["']?\s*[:=]\s*["']([^"'\r\n]{8,})["']""")
BEARER = re.compile(rb"(?i)\bBearer\s+([a-z0-9._-]{20,})")
FORBIDDEN = re.compile(r"(?i)(?:^|/)(?:keystore\.properties|local\.properties|key\.properties|\.env(?:\.[^/]+)?)$|\.(?:jks|keystore|p12|pfx|mobileprovision|apk|aab|ipa|eml|mbox)$")
# Owner-approved public mailbox, documented with approval scope in
# docs/security/public-contacts.md. Exact address AND exact authored document;
# never a domain exemption and never applied to distributed artifacts.
APPROVED_PUBLIC_CONTACT_HASHES = {
    "docs/security/public-contacts.md": frozenset({
        "c514aca59a13578c5ee5fa0c93a6661f7f39225b698e80550293f05b25ed2987",
    }),
}

PLACEHOLDER_USERS = {b"your-name", b"username", b"user", b"runner", b"example", b"your-user"}
PLACEHOLDER_WORDS = (b"example", b"replace", b"your-", b"your_", b"dummy", b"fixture", b"fake", b"test", b"not-a-real", b"placeholder")

# Exact normalized compiler signatures reviewed from the local Flutter release binary.
# Only used for artifact email classification inside the native Dart app binary.
# See docs/security/artifact-privacy-rules.md for provenance and limits.
REVIEWED_DART_SYMBOL_HASHES = frozenset({
    "020cb2a99eee55bc917c835c4db78da9b32bbf4507b172c25260bf551f867a87",
    "07948cabde73710dc6b423907e05fe149d1240e6fc5b12e5c448c0a225c0a917",
    "08f79e2e345a065bcfbf10f292a6c9e8b89fe348f8d13cd97ddfcd297375ffea",
    "0ea0a76bf81b3ec05dc89a104282d91893cba1791350a01c11765493287db9c9",
    "14f0c37af4acc10870b1587c904f4f1a210a7c0dfd3c2ee6c4656f6d81c0ab50",
    "15d1eb651e1b540d7a226be18988f5f49ac080b97ee5fb18733f33be70c192be",
    "1b544e91861f914318b86e8bf0c4754129464eb43fcb1843f3e10045c339003b",
    "21cd6d014aeaf03ce9b0f89736205bf04659576c30198a9575414ffcb4559d23",
    "22a3a5028308757940210ad565145450a0a67c9fb72a51de8ba2f2da94d1f49d",
    "2e2aa232cafdd81122fbc90ec687fda87c2c7d363653223feef243e8033defcd",
    "409a2a1de9dce0b830917daf80b09127d19578075b95d6f0ef433f8071fd9bb5",
    "497a577e229d2143e4aacf8592eba825e6a6a99a793fa73d55f67cf5de2e44a6",
    "5313baad65231282b9761d83ef7a5f7740f37a4acd9bedf4be7449be4785d97b",
    "560b5f75157ba71811790fa33b73257d6aa6a61866a61b3d81e923d0f3a924e4",
    "5b18627623f84ddf464f1427cbe1a74768d59a5b10d28a3ffdf4b25ef758fd4c",
    "61dd53f76cfac521d265fafb539e17aece16645c2de0b059bdf056de05448efb",
    "64f6713a39284e6869846505fc46e4a69740412398df135d0c175836c1037082",
    "70b51bc4dbaa27215f8a9488dc5b071c7422e9b5d3b6dcbe7f0e215ea8d4426f",
    "71fa358ac68127bfc2aafb9a972cccb45a78d91d4ff5183314ebf035d4c3b2d8",
    "7326dfdccba172d53aa144c123adc6233245fa9a32f559bcb7f71495a549ced2",
    "7bfb8045524ad5976bf67328f975c5efe9ad879d55310aee3486b770471dae80",
    "7d582b084e1ff233cf817a1d9d7360a7dbcf78236ae76071119cdd34f7c8f2e4",
    "803fe060b7307bc12f6d13f868e41fa3e1e8f5419a7d86249100e9d8be156432",
    "82efb906c922ea38cf2301f2810d6471cfb796812e169ea09e6901ca27c04f11",
    "83b6dc6fcaee9129a9dc7190d6bf2b963433aa83f67cbefb6d52388066994418",
    "8782d4d8f8e1e476f3d2cd9a955b863b726c3a2a23952723cd7818b8f1f2266a",
    "926e72f76e2f17a836d4572daf5e9815391c77d0568cd482687d4c61e5274c2e",
    "9cbaec00369b180104804eface762b6b5b56213405b79f3df883bdf27e0b97d5",
    "a231b73867eda27c50379e7849a53c699d7f26f19b3a5e5fdb111bd19614d93f",
    "a476ff64e076ed612ea749b15c29c872121a3979f16f122cfac61e34f11d017d",
    "b22421a206261d89fe14d7026d76a6058a7d3fea7e4e474b470a8a98d6eb42e2",
    "b49a72426a8d74d3343bf1c8f5cd05ba1c6e9439976d35e3948d563c37bb3700",
    "bad0e92a7b75a2a50047d6b8712b948f6f8ef88a30bdeb4a9dba64353ea88368",
    "bc9b0c37156b8dc3d3918ee47c782b039af04ede6ed61e3efba8ec3c5e90de8f",
    "c99a04a87e89f021dc1e5a1828a8a94c81396cbe94a15b008c60bb52a0882eab",
    "c9e8019078fefbb3e946ba3bb2b002a574fde1f2a4ce6365bb7829723c19a41d",
    "d5b874c360824ce19fca002d51ac6895483c2b973f44d5fe2942ecfb9efeba8c",
    "d768d42f38ed55bee3dcac0d4b12417c4e0b52bc1cd85efab43952f28734b506",
    "dead9c07af70428038cb4491da3e49811d7fb15efda99101da51bb5d2cd975f0",
    "e4f4bff36f9b00c192770fba23f4cba3cd3480ab7569403aadf64e4fbf9b526e",
    "e85ba3abce7778125d6bb261c68327824b70c099a5b7cb44d4b193e5451e09e6",
    "e9b368f8c1389f38f2470301eda9b1406242657ddb284335b6a96350c7acd3f7",
    "f8a6ab7ce87282ab52db5945ad881d5bfe0dd6e0a1c95174e551ae7785810299",
    "fc249daafd67e9b993706f33ff74f2800e23b9033f11843383328521f3911f4f",
})
# Build 21 verified this exact match lies in a recomputed SHA-256 CodeDirectory
# code-page digest. Fingerprint alone never clears it; full provenance is required.
REVIEWED_CODE_PAGE_HASHES = frozenset({
    "e7c439282c3f3656aec7eca075cb44ef1a7fc87a2e3db6f90d98a72057e25681",
})
REVIEWED_ENGINE_ATTRIBUTIONS = {
    b'GHASH for ARMv8, CRYPTOGAMS by <': "f8adf0e6bb6ecde7f2d66c61ff622d83185635912daf0b3ba1233015f5190a06",
    b'ECP_NISTZ256 for ARMv8, CRYPTOGAMS by <': "221cc9de8a3af12512773fe2342e1547861349f4aef6b75137298456973d7f88",
    b"GHASH for ARMv8, derived from ARMv4 version by <": "5228d48b234382d900c74c8acf31fe141b38a8da9158577a921206ac2836a49a",
    b"SHA1 block transform for ARMv8, CRYPTOGAMS by <": "21c71015f2ad1e25c862f75c0846634a5c99dfa1d28ce788e80517fc441352f4",
    b"SHA256 block transform for ARMv8, CRYPTOGAMS by <": "11664d0e2447bdedc56a2f8f0850ca8c991409eed958ad3fc6b15b5c393482ad",
    b"SHA512 block transform for ARMv8, CRYPTOGAMS by <": "760d964b9ff313b42f9f61f3c6db4e1dd1f597cee0af2687f525208b476f00f1",
    b"ChaCha20 for ARMv8, CRYPTOGAMS by <": "3aa09eb38c725110cb9beabee9679b8ae7c058bbb8863b45d36a04a245cf4d4d",
    b"Montgomery Multiplication for ARMv8, CRYPTOGAMS by <": "86773b3dc7dc7d393e0b7afa0caccad01bdf06de5beb62fa186f154764a191f0",
}


def artifact_email_classification(data, match, path):
    """Classify exact reviewed binary metadata, never entire files/domains."""
    native = data[:4] in (b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
    if not native:
        return "unreviewed"
    path = path.replace("\\", "/")
    app = re.fullmatch(r"Payload/[^/]+\.app/Frameworks/App\.framework/App|lib/(?:arm64-v8a|armeabi-v7a|x86_64)/libapp\.so", path)
    if (app and path.startswith("Payload/")
            and hashlib.sha256(match.group()).hexdigest() in REVIEWED_CODE_PAGE_HASHES
            and signature_origin(data, match) == "verified-sha256-code-page-hash"):
        return "reviewed-code-page-hash"
    if app and re.fullmatch(rb"_[A-Za-z0-9_]+@[0-9]{6,12}\.[A-Za-z]+", match.group()):
        normalized = re.sub(rb"@[0-9]+\.", b"@#.", match.group())
        if hashlib.sha256(normalized).hexdigest() in REVIEWED_DART_SYMBOL_HASHES:
            return "reviewed-dart-symbol"
    engine = re.fullmatch(r"Payload/[^/]+\.app/Frameworks/Flutter\.framework/Flutter|lib/(?:arm64-v8a|armeabi-v7a|x86_64)/libflutter\.so", path)
    if engine and data[match.end():match.end()+2] == b">\0":
        for prefix, expected in REVIEWED_ENGINE_ATTRIBUTIONS.items():
            start = match.start() - len(prefix)
            if start >= 0 and data[start:match.start()] == prefix:
                if hashlib.sha256(data[start:match.end()+1]).hexdigest() == expected:
                    return "reviewed-upstream-attribution"
    return "unreviewed"

def placeholder(value):
    low = value.lower()
    return (any(word in low for word in PLACEHOLDER_WORDS)
            or any(char in value for char in (b"$", b"{", b"}", b"(", b")", b"\\"))
            or low in (b"authorization", b"application/json"))

def inspect(data, path="", check_path=True, artifact=False):
    findings = set()
    normalized = path.replace("\\", "/")
    if check_path and (FORBIDDEN.search(normalized)
                       or any(part in (".idea", ".dart_tool", "build", "inspection-results", "inspectionResults") for part in normalized.split("/"))):
        findings.add("prohibited-file")
    if PRIVATE_KEY.search(data):
        findings.add("private-key-material")
    if MAIL_ARCHIVER.search(data):
        findings.add("mail-archiver-key-shaped")
    if TOKEN.search(data):
        findings.add("provider-token-shaped")
    for match in HOST.finditer(data):
        if not placeholder(match.group()):
            findings.add("private-network-host")
    for match in LOCAL_PATH.finditer(data):
        if match.group(1).lower() not in PLACEHOLDER_USERS:
            findings.add("personal-local-path")
    for match in EMAIL.finditer(data) if normalized != "THIRD_PARTY_NOTICES.md" else []:
        if artifact and artifact_email_classification(data, match, path) != "unreviewed":
            continue
        if (not artifact
                and hashlib.sha256(match.group()).hexdigest()
                in APPROVED_PUBLIC_CONTACT_HASHES.get(normalized, ())):
            continue
        domain = match.group(1).lower()
        if re.fullmatch(rb"[123]x\.png", domain):
            continue  # Apple icon asset names contain @2x.png / @3x.png.
        if not (domain.endswith((b".invalid", b".example", b".test", b".noreply.github.com"))
                or domain in (b"example.com", b"example.org", b"example.net", b"noreply.github.com")):
            findings.add("email-address-review")
    for pattern in (ASSIGNMENT, BEARER):
        for match in pattern.finditer(data):
            if not placeholder(match.group(1)):
                findings.add("literal-credential-review")
    return findings

def artifact_context(name, data):
    """Return fixed labels/counts and bounded hash fingerprints, never raw matches."""
    parts = name.replace("\\", "/").split("/")
    leaf = parts[-1]
    if leaf == "embedded.mobileprovision":
        component = "embedded-provisioning-profile"
    elif "_CodeSignature" in parts:
        component = "code-signature-metadata"
    elif "Flutter.framework" in parts or re.fullmatch(r"lib/(?:arm64-v8a|armeabi-v7a|x86_64)/libflutter\.so", name):
        component = "flutter-engine-framework"
    elif "App.framework" in parts or re.fullmatch(r"lib/(?:arm64-v8a|armeabi-v7a|x86_64)/libapp\.so", name):
        component = "dart-app-framework"
    elif any(part.endswith(".framework") for part in parts):
        component = "other-framework"
    elif leaf == "Assets.car":
        component = "asset-catalog"
    elif leaf == "Info.plist":
        component = "bundle-property-list"
    elif len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") and data[:4] in (
            b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        component = "main-app-executable"
    else:
        component = "other-artifact-component"
    addresses = set()
    recognized_symbols = set()
    recognized_attributions = set()
    recognized_code_hashes = set()
    unreviewed_vm_fingerprints = set()
    unreviewed_app_fingerprints = set()
    native_app = data[:4] in (b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca") and re.fullmatch(
        r"Payload/[^/]+\.app/Frameworks/App\.framework/App|lib/(?:arm64-v8a|armeabi-v7a|x86_64)/libapp\.so", name.replace("\\", "/"))
    structures = set()
    sections = macho_sections(data) if native_app else None
    for match in EMAIL.finditer(data):
        domain = match.group(1).lower()
        if re.fullmatch(rb"[123]x\.png", domain):
            continue
        if not (domain.endswith((b".invalid", b".example", b".test", b".noreply.github.com"))
                or domain in (b"example.com", b"example.org", b"example.net", b"noreply.github.com")):
            classification = artifact_email_classification(data, match, name)
            if classification == "reviewed-dart-symbol":
                recognized_symbols.add(match.group())
            elif classification == "reviewed-code-page-hash":
                recognized_code_hashes.add(hashlib.sha256(match.group()).hexdigest())
            elif classification == "reviewed-upstream-attribution":
                recognized_attributions.add(match.group())
            else:
                addresses.add(match.group().lower())
                if native_app:
                    digest = hashlib.sha256(match.group()).hexdigest()
                    unreviewed_app_fingerprints.add(digest)
                    if len(structures) < 16:
                        structures.add(digest + ":" + match_structure(data, match, sections)
                                       + ",origin=" + signature_origin(data, match))
                    if re.search(rb"@[0-9]{1,12}\.", match.group()):
                        normalized_symbol = re.sub(rb"@[0-9]{1,12}\.", b"@#.", match.group())
                        unreviewed_vm_fingerprints.add(hashlib.sha256(normalized_symbol).hexdigest())
    # Informational provenance clue only: matching a notice never clears a finding.
    try:
        notice = (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()
        known = {match.group().lower() for match in EMAIL.finditer(notice)}
        matched = len(addresses & known)
        notice_status = "available"
    except OSError:
        matched = 0
        notice_status = "unavailable"
    return (f"Component: {component}; distinct-review-addresses: {len(addresses)}; "
            f"exact-notice-matches: {matched}; notice-inventory: {notice_status}; "
            f"reviewed-dart-symbols: {len(recognized_symbols)}; reviewed-code-page-hashes: {len(recognized_code_hashes)}; reviewed-upstream-attributions: {len(recognized_attributions)}. "
            f"Unreviewed App match fingerprints (SHA-256, first 16): {','.join(sorted(unreviewed_app_fingerprints)[:16]) or 'none'}. "
            f"Unreviewed numeric-normalized fingerprints (SHA-256, first 16): {','.join(sorted(unreviewed_vm_fingerprints)[:16]) or 'none'}. "
            f"Unreviewed App structural context (first 16): {';'.join(sorted(structures)) or 'none'}. "
            "Context only; findings remain blocking.")

def git(*args, data=None):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], input=data, stderr=subprocess.PIPE)

def scan_current():
    findings = []
    files = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().split("\0")
    for name in filter(None, files):
        file = ROOT / name
        if not file.is_file():
            continue
        categories = inspect(file.read_bytes(), name)
        # Never echo user-provided filenames: report an ordinal and category.
        if categories:
            findings.append((name, categories))
    return findings, len(list(filter(None, files)))

def scan_history():
    entries = {}
    for line in git("rev-list", "--objects", "--all").decode().splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            entries[parts[0]] = parts[1]
    data = git("cat-file", "--batch", data=("\n".join(entries) + "\n").encode())
    at = 0
    findings = []
    scanned = 0
    for oid, name in entries.items():
        end = data.index(b"\n", at)
        header = data[at:end].split()
        size = int(header[2])
        at = end + 1
        body = data[at:at + size]
        at += size + 1
        if header[1] != b"blob":
            continue
        scanned += 1
        categories = inspect(body, name)
        if categories:
            findings.append((oid, categories))
    return findings, scanned

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true")
    parser.add_argument("--artifact", type=Path, help="Privately inspect a release ZIP/APK or other file; never upload the file.")
    parser.add_argument("--show-paths", action="store_true", help="Local review only: print source paths/object IDs, never matched values.")
    parser.add_argument("--artifact-context", action="store_true", help="With --artifact, print fixed component types and redacted match counts; never clears findings.")
    args = parser.parse_args()
    if args.artifact_context and not args.artifact:
        parser.error("--artifact-context requires --artifact")
    contexts = []
    if args.history and args.artifact:
        parser.error("--history and --artifact cannot be combined")
    if args.artifact:
        import zipfile
        findings, count = [], 0
        if zipfile.is_zipfile(args.artifact):
            with zipfile.ZipFile(args.artifact) as archive:
                for entry in archive.infolist():
                    if entry.is_dir():
                        continue
                    count += 1
                    if entry.file_size > 80000000:
                        findings.append(("archive-entry", {"oversize-entry-unscanned"}))
                        continue
                    data = archive.read(entry)
                    categories = inspect(data, entry.filename, check_path=False, artifact=True)
                    if categories:
                        findings.append(("archive-entry", categories))
                    if args.artifact_context and (categories or EMAIL.search(data)):
                        contexts.append(artifact_context(entry.filename, data))
        else:
            if args.artifact.stat().st_size > 125000000:
                parser.error("File exceeds the bounded scan limit")
            findings = [("artifact", categories)] if (categories := inspect(args.artifact.read_bytes(), check_path=False)) else []
            count = 1
    else:
        findings, count = scan_history() if args.history else scan_current()
    print(f"Examined {count} {'artifact entries' if args.artifact else 'historical blobs' if args.history else 'tracked/non-ignored files'}.")
    for index, (location, categories) in enumerate(findings, 1):
        print(f"Finding {index}: {', '.join(sorted(categories))}; values and filenames withheld.")
        if args.show_paths:
            import json
            print("  Location: " + json.dumps(location))
    for context in contexts:
        print(context)
    print(f"{len(findings)} item(s) need review. This bounded pattern scan does not prove absence of secrets.")
    return 1 if findings else 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError):
        print("Privacy scan could not complete. Check file access and Git state locally; diagnostic values withheld.", file=sys.stderr)
        sys.exit(2)
