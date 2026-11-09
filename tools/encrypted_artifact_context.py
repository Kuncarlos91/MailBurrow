"""Opt-in private diagnostic: bounded app matches encrypted before any file write.

No plaintext report, signing material or IPA is retained. This never clears a gate.
OpenSSL RSA-OAEP with SHA-256 and MGF1-SHA-256; 4096-bit public key required.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile

from privacy_check import EMAIL, artifact_email_classification, inspect

MAGIC = b"MSCTX01\0"
HEADER = struct.Struct(">8s4s32sQHHH")
OPTIONS = ["-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
           "-pkeyopt", "rsa_mgf1_md:sha256"]


def validate_public_key(public_key, openssl="openssl"):
    key = public_key.read_bytes()
    if len(key) > 2048 or not re.fullmatch(rb"-----BEGIN PUBLIC KEY-----[A-Za-z0-9+/=\r\n]+-----END PUBLIC KEY-----\s*", key):
        raise ValueError("Public key required")
    subprocess.run([openssl, "pkey", "-pubin", "-pubcheck", "-noout", "-in", str(public_key)],
                   capture_output=True, check=True, timeout=15)
    details = subprocess.run([openssl, "pkey", "-pubin", "-text", "-noout", "-in", str(public_key)],
                             capture_output=True, check=True, timeout=15)
    if b"Public-Key: (4096 bit)" not in details.stdout or b"Modulus:" not in details.stdout:
        raise ValueError("4096-bit RSA required")
    return key


def capture(artifact, public_key, destination, openssl="openssl"):
    key = validate_public_key(public_key, openssl)
    ciphertexts = []
    with zipfile.ZipFile(artifact) as archive:
        candidates = [e for e in archive.infolist() if re.fullmatch(
            r"Payload/[^/]+\.app/Frameworks/App\.framework/App", e.filename)]
        if len(candidates) != 1 or candidates[0].file_size > 80000000:
            raise ValueError("Expected one bounded native app entry")
        entry = candidates[0]
        data = archive.read(entry)
        if data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
            raise ValueError("Unsupported app header")
        digest = hashlib.sha256(data).digest()
        for match in EMAIL.finditer(data):
            if (artifact_email_classification(data, match, entry.filename) != "unreviewed"
                    or "email-address-review" not in inspect(match.group(), check_path=False)):
                continue
            if len(ciphertexts) >= 16 or len(match.group()) > 128:
                raise ValueError("Capture limit reached")
            start, end = max(0, match.start() - 64), min(len(data), match.end() + 64)
            window = data[start:end]
            payload = HEADER.pack(MAGIC, data[:4], digest, start, match.start() - start,
                                  len(match.group()), len(window)) + window
            if len(payload) > 446:  # 512 - 2*SHA256 length - 2, RSA-OAEP limit
                raise ValueError("Payload limit reached")
            result = subprocess.run([openssl, "pkeyutl", "-encrypt", "-pubin", "-inkey", str(public_key)] + OPTIONS,
                                    input=payload, capture_output=True, check=True, timeout=15)
            if len(result.stdout) != 512:
                raise ValueError("4096-bit RSA required")
            ciphertexts.append(result.stdout)
    # Create no output until all captures are successfully encrypted.
    destination.mkdir(exist_ok=False)
    for index, ciphertext in enumerate(ciphertexts):
        (destination / f"context-{index:02d}.bin").write_bytes(ciphertext)
    (destination / "manifest.json").write_text(json.dumps({
        "version": 1, "algorithm": "RSA-OAEP-SHA256-MGF1-SHA256", "records": len(ciphertexts),
        "public_key_sha256": hashlib.sha256(key).hexdigest(),
    }), encoding="utf-8")
    return len(ciphertexts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        count = capture(args.artifact, args.public_key, args.destination)
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError):
        print("Encrypted diagnostic failed; values withheld. Privacy gate unchanged.")
        return 1
    print(f"Encrypted diagnostic captured {count} bounded record(s). Privacy gate unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
