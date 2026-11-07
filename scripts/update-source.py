#!/usr/bin/env python3
"""
Adds a release to altstore/source.json, the app's AltStore-format source,
which SideStore and the Apple TV sideloaders that read the same format
(FlareStore and others) subscribe to.

    python3 scripts/update-source.py <tag> <path to .ipa>

The version comes from project.yml (MARKETING_VERSION), the build from
BUILD_NUMBER, the run number the workflow builds the .ipa's CFBundleVersion
from (CURRENT_PROJECT_VERSION in project.yml when it isn't set), the size
and the date from the .ipa and today. The new version goes first, as
the clients take the first one as the latest; one already listed for the
same version is replaced, so a rebuilt tag doesn't list twice.
"""
import datetime
import json
import os
import re
import sys

REPO = "mickey2266/AIOStreamsTVOS"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "altstore", "source.json")
BUNDLE_ID = "io.github.aiostreams.tvos"


def project_setting(name):
    with open(os.path.join(ROOT, "project.yml"), encoding="utf-8") as f:
        match = re.search(rf'^\s*{name}:\s*"?([^"\s]+)"?\s*$', f.read(), re.MULTILINE)
    if not match:
        sys.exit(f"{name} is not in project.yml")
    return match.group(1)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tag, ipa = sys.argv[1], sys.argv[2]
    version = project_setting("MARKETING_VERSION")
    if tag.lstrip("v") != version:
        sys.exit(f"tag {tag} doesn't match MARKETING_VERSION {version} in project.yml")
    entry = {
        "version": version,
        "buildVersion": os.environ.get("BUILD_NUMBER") or project_setting("CURRENT_PROJECT_VERSION"),
        "date": datetime.date.today().isoformat(),
        "localizedDescription": f"AIOStreams for Apple TV {version}. Release notes: "
        f"https://github.com/{REPO}/releases/tag/{tag}",
        "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/AIOStreams.ipa",
        "size": os.path.getsize(ipa),
        "minOSVersion": project_setting("tvOS"),
    }
    with open(SOURCE, encoding="utf-8") as f:
        source = json.load(f)
    app = next(a for a in source["apps"] if a["bundleIdentifier"] == BUNDLE_ID)
    app["versions"] = [entry] + [v for v in app.get("versions", []) if v["version"] != version]
    with open(SOURCE, "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"source: {version} ({entry['buildVersion']}), {entry['size']} bytes")


if __name__ == "__main__":
    main()
