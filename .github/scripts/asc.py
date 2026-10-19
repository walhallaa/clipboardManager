#!/usr/bin/env python3
"""Small App Store Connect lookups for the release workflows.

usage: asc.py latest-build  <bundle-id> <marketing-version>   highest build number (0 if none)
       asc.py version-state <bundle-id> <marketing-version>   store state, or NONE if the version doesn't exist yet
env:   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file)
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der: bytes) -> bytes:
    """OpenSSL emits ECDSA signatures as DER; JWT wants r||s, 32 bytes each."""
    index = 2 + (der[1] & 0x7F if der[1] & 0x80 else 0)
    parts = []
    for _ in range(2):
        length = der[index + 1]
        parts.append(int.from_bytes(der[index + 2 : index + 2 + length], "big"))
        index += 2 + length
    return b"".join(value.to_bytes(32, "big") for value in parts)


def token() -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = b64(json.dumps(header).encode()) + b"." + b64(json.dumps(claims).encode())
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]],
        input=signing_input, capture_output=True, check=True,
    ).stdout
    return (signing_input + b"." + b64(der_to_raw(der))).decode()


def get(path: str, bearer: str, **query) -> dict:
    url = f"{API}/{path}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def app_id(bundle_id: str, bearer: str) -> str | None:
    apps = get("apps", bearer, **{"filter[bundleId]": bundle_id})["data"]
    return apps[0]["id"] if apps else None


def latest_build(bundle_id: str, version: str) -> int:
    bearer = token()
    app = app_id(bundle_id, bearer)
    if app is None:
        return 0
    builds = get(
        "builds", bearer,
        **{
            "filter[app]": app,
            "filter[preReleaseVersion.version]": version,
            "fields[builds]": "version",
            "sort": "-uploadedDate",
            "limit": "200",
        },
    )["data"]
    numbers = [int(b["attributes"]["version"]) for b in builds if b["attributes"]["version"].isdigit()]
    return max(numbers, default=0)


def version_state(bundle_id: str, version: str) -> str:
    bearer = token()
    app = app_id(bundle_id, bearer)
    if app is None:
        return "NONE"
    versions = get(
        f"apps/{app}/appStoreVersions", bearer,
        **{"filter[versionString]": version, "filter[platform]": "MAC_OS"},
    )["data"]
    if not versions:
        return "NONE"
    attributes = versions[0]["attributes"]
    return attributes.get("appVersionState") or attributes.get("appStoreState") or "UNKNOWN"


def main() -> None:
    command, bundle_id, version = sys.argv[1:4]
    if command == "latest-build":
        print(latest_build(bundle_id, version))
    elif command == "version-state":
        print(version_state(bundle_id, version))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
