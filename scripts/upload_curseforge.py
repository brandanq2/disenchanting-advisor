#!/usr/bin/env python3
"""Upload a packaged addon zip to CurseForge via the upload API."""

import json
import os
import sys

import requests

api_key         = os.environ["CF_API_KEY"]
version         = os.environ["VERSION"]
game_version_id = int(os.environ["GAME_VERSION_ID"])
changelog       = os.environ.get("CHANGELOG_TEXT", f"Version {version}")

metadata = json.dumps({
    "gameVersions":  [game_version_id],
    "releaseType":   "release",
    "displayName":   f"DisenchantingAdvisor v{version}",
    "changelog":     changelog,
    "changelogType": "text",
})

zip_path = f"DisenchantingAdvisor-{version}.zip"
print(f"Metadata: {metadata}")
print(f"Uploading {zip_path} to CurseForge project 1469482...")

with open(zip_path, "rb") as fh:
    r = requests.post(
        "https://wow.curseforge.com/api/projects/1469482/upload-file",
        headers={"X-Api-Token": api_key},
        data={"metadata": metadata},
        files={"file": (zip_path, fh, "application/zip")},
    )

print(f"HTTP Status: {r.status_code}")
print(f"Response:    {r.text}")

if not r.ok:
    sys.exit(1)

print(f"Upload successful. File ID: {r.json()['id']}")
