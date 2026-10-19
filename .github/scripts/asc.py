#!/usr/bin/env python3
"""Small App Store Connect lookups for the release workflows.

usage: asc.py latest-build  <bundle-id> [marketing-version]   highest build number across all versions unless scoped (0 if none)
       asc.py version-state <bundle-id> <marketing-version>   store state, or NONE if the version doesn't exist yet
       asc.py latest-upload <bundle-id>                       "<marketing-version> <build>" of the most recently uploaded build
       asc.py set-release-notes <bundle-id> <marketing-version> <notes-directory>
                                                             write fastlane/release_notes into every language's "What's New"
       asc.py wait-processed <bundle-id> <marketing-version> <build> [timeout-minutes]
                                                             block until App Store Connect has finished processing the build
       asc.py mac-app-store-profile <bundle-id> <cert-serial> <output-path>
                                                             write an active Mac App Store profile for the
                                                             distribution cert (created if missing), print its UUID
env:   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file)
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import release_notes

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
    url = urllib.parse.urljoin(f"{API}/", path)
    if urllib.parse.urlsplit(url)[:2] != ("https", "api.appstoreconnect.apple.com"):
        raise ValueError("Refusing to send App Store Connect credentials to another origin")
    if query:
        url += f"?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def post(path: str, bearer: str, body: dict) -> dict:
    request = urllib.request.Request(
        f"{API}/{path}", data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"POST {path} failed ({error.code}): {error.read().decode()}")


def patch(path: str, bearer: str, body: dict) -> dict:
    request = urllib.request.Request(
        f"{API}/{path}", data=json.dumps(body).encode(), method="PATCH",
        headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"PATCH {path} failed ({error.code}): {error.read().decode()}")


def app_id(bundle_id: str, bearer: str) -> str | None:
    apps = get("apps", bearer, **{"filter[bundleId]": bundle_id})["data"]
    return apps[0]["id"] if apps else None


def latest_build(bundle_id: str, version: str | None = None) -> int:
    bearer = token()
    app = app_id(bundle_id, bearer)
    if app is None:
        return 0
    query = {
        "filter[app]": app,
        "fields[builds]": "version",
        "sort": "-uploadedDate",
        "limit": "200",
    }
    if version is not None:
        query["filter[preReleaseVersion.version]"] = version
    page = get("builds", bearer, **query)
    latest = 0
    while True:
        for build in page["data"]:
            number = build["attributes"]["version"]
            if number.isdigit():
                latest = max(latest, int(number))
            elif version is None:
                sys.exit(f"Cannot allocate an integer build number after non-integer build {number}")
        next_page = page.get("links", {}).get("next")
        if not next_page:
            return latest
        page = get(next_page, bearer)


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


def latest_upload(bundle_id: str) -> str:
    """The build most recently uploaded, whatever its marketing version."""
    bearer = token()
    app = app_id(bundle_id, bearer)
    if app is None:
        sys.exit(f"No app with bundle ID {bundle_id} in App Store Connect")
    page = get(
        "builds", bearer,
        **{
            "filter[app]": app,
            "sort": "-uploadedDate",
            "limit": "1",
            "include": "preReleaseVersion",
            "fields[builds]": "version",
            "fields[preReleaseVersions]": "version",
        },
    )
    if not page["data"]:
        sys.exit(f"No builds of {bundle_id} in App Store Connect yet")
    return f'{page["included"][0]["attributes"]["version"]} {page["data"][0]["attributes"]["version"]}'


def set_release_notes(bundle_id: str, version: str, directory: str) -> None:
    """App Store review refuses a version without "What's New" in every language it has."""
    notes = release_notes.load(directory)
    bearer = token()
    app = app_id(bundle_id, bearer)
    if app is None:
        sys.exit(f"No app with bundle ID {bundle_id} in App Store Connect")
    versions = get(
        f"apps/{app}/appStoreVersions", bearer,
        **{"filter[versionString]": version, "filter[platform]": "MAC_OS"},
    )["data"]
    if not versions:
        sys.exit(f"Version {version} doesn't exist in App Store Connect yet")
    localizations = get(
        f"appStoreVersions/{versions[0]['id']}/appStoreVersionLocalizations", bearer, limit="200",
    )["data"]
    for localization in localizations:
        locale = localization["attributes"]["locale"]
        text = notes.get(locale) or notes.get(locale.split("-")[0]) or notes["default"]
        patch(f"appStoreVersionLocalizations/{localization['id']}", bearer, {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": localization["id"],
                "attributes": {"whatsNew": text},
            },
        })
        print(f"Set What's New for {locale}")


def wait_processed(bundle_id: str, version: str, build: str, timeout_minutes: str = "40") -> None:
    """A build can't be submitted for review until processing is VALID (usually a few minutes after upload)."""
    deadline = time.time() + float(timeout_minutes) * 60
    while True:
        bearer = token()  # tokens last 10 minutes, so mint a fresh one per poll
        app = app_id(bundle_id, bearer)
        if app is None:
            sys.exit(f"No app with bundle ID {bundle_id} in App Store Connect")
        builds = get(
            "builds", bearer,
            **{
                "filter[app]": app,
                "filter[preReleaseVersion.version]": version,
                "filter[version]": build,
                "fields[builds]": "processingState,version",
            },
        )["data"]
        state = builds[0]["attributes"]["processingState"] if builds else "NOT_FOUND_YET"
        if state == "VALID":
            print(f"Build {version} ({build}) is processed")
            return
        if state in ("INVALID", "FAILED"):
            sys.exit(f"Build {version} ({build}) failed processing in App Store Connect ({state})")
        if time.time() >= deadline:
            sys.exit(f"Build {version} ({build}) was still {state} after {timeout_minutes} minutes")
        print(f"Build {version} ({build}) is {state}; checking again in 30 seconds", flush=True)
        time.sleep(30)


def mac_app_store_profile(bundle_id: str, cert_serial: str, output_path: str) -> str:
    """Xcode's automatic export signing falls back to cloud-managed certificates, which
    the API key can't use, so the workflow signs manually with this profile instead."""
    bearer = token()

    bundles = get("bundleIds", bearer, **{"filter[identifier]": bundle_id, "limit": "200"})["data"]
    bundle = next((b["id"] for b in bundles if b["attributes"]["identifier"] == bundle_id), None)
    if bundle is None:
        sys.exit(f"Bundle ID {bundle_id} is not registered in the developer account")

    serial = cert_serial.upper().lstrip("0")
    certs = get(
        "certificates", bearer,
        **{"filter[certificateType]": "DISTRIBUTION,MAC_APP_DISTRIBUTION", "limit": "200"},
    )["data"]
    cert = next((c["id"] for c in certs if c["attributes"]["serialNumber"].upper().lstrip("0") == serial), None)
    if cert is None:
        sys.exit(f"Distribution certificate {cert_serial} from DIST_CERT_P12 is not active in the developer account")

    profiles = get(
        "profiles", bearer,
        **{
            "filter[profileType]": "MAC_APP_STORE",
            "filter[profileState]": "ACTIVE",
            "include": "bundleId,certificates",
            "limit[certificates]": "50",
            "limit": "200",
        },
    )["data"]
    profile = next(
        (
            p for p in profiles
            if p["relationships"]["bundleId"]["data"]["id"] == bundle
            and any(c["id"] == cert for c in p["relationships"]["certificates"]["data"])
        ),
        None,
    )
    if profile is None:
        profile = post("profiles", bearer, {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": f"{bundle_id} Mac App Store CI {time.strftime('%Y%m%d%H%M%S')}",
                    "profileType": "MAC_APP_STORE",
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                    "certificates": {"data": [{"type": "certificates", "id": cert}]},
                },
            },
        })["data"]

    with open(output_path, "wb") as file:
        file.write(base64.b64decode(profile["attributes"]["profileContent"]))
    return profile["attributes"]["uuid"]


def main() -> None:
    command, *args = sys.argv[1:]
    if command == "latest-build":
        print(latest_build(*args))
    elif command == "version-state":
        print(version_state(*args))
    elif command == "latest-upload":
        print(latest_upload(*args))
    elif command == "set-release-notes":
        set_release_notes(*args)
    elif command == "wait-processed":
        wait_processed(*args)
    elif command == "mac-app-store-profile":
        print(mac_app_store_profile(*args))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
