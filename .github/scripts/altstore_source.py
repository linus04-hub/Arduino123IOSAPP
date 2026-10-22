#!/usr/bin/env python3
"""Erzeugt altstore-source.json fuer die frisch gebaute App.

Liest Version, Build-Nummer und Datenschutz-Texte direkt aus dem gebauten
Info.plist, damit die Angaben exakt zur .ipa passen (AltStore prueft das).
Aufruf: altstore_source.py <App.app> <.ipa> <Download-URL> <Ausgabe.json>
"""
import datetime
import glob
import json
import os
import plistlib
import subprocess
import sys

REPO = "linus04-hub/Arduino123IOSAPP"
RAW = f"https://raw.githubusercontent.com/{REPO}/main"
SOURCE_URL = f"https://github.com/{REPO}/releases/latest/download/altstore-source.json"


def read_plist(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def main():
    app_dir, ipa, download_url, out = sys.argv[1:5]
    info = read_plist(os.path.join(app_dir, "Info.plist"))

    # Datenschutz-Texte der App und aller Erweiterungen
    privacy = {}
    plists = [os.path.join(app_dir, "Info.plist")]
    plists += glob.glob(os.path.join(app_dir, "PlugIns", "*.appex", "Info.plist"))
    for p in plists:
        for k, v in read_plist(p).items():
            if k.endswith("UsageDescription"):
                privacy[k] = v

    notes = subprocess.run(["git", "log", "-1", "--pretty=%B"], capture_output=True, text=True).stdout
    notes = "\n".join(l for l in notes.strip().splitlines()
                      if not l.startswith(("Co-Authored-By:", "Claude-Session:"))).strip()

    source = {
        "name": "Citroën Anzeige",
        "identifier": "de.linus.citroenanzeige.source",
        "sourceURL": SOURCE_URL,
        "subtitle": "Anzeige und Abstimmung für den 2CV6",
        "iconURL": f"{RAW}/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": "#FD8C00",
        "apps": [{
            "name": "Citroën",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "Linus",
            "subtitle": "Lambda, Öl, Zündung und Kennfeld",
            "localizedDescription": "Live-Anzeige der Bridge und der 123ignition, Fahrtenschreiber, "
                                    "Lambda-Kennfeld, Zündkurve und Werkzeuge für die Vergaserabstimmung.",
            "iconURL": f"{RAW}/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            "tintColor": "#FD8C00",
            "category": "utilities",
            "versions": [{
                "version": info["CFBundleShortVersionString"],
                "buildVersion": str(info["CFBundleVersion"]),
                "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "localizedDescription": notes or "Neue Version",
                "downloadURL": download_url,
                "size": os.path.getsize(ipa),
                "minOSVersion": info.get("MinimumOSVersion", "16.1"),
            }],
            # unsignierte .ipa: keine Entitlements, AltStore signiert selbst
            "appPermissions": {"entitlements": [], "privacy": privacy},
        }],
        "news": [],
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
    print(json.dumps(source["apps"][0]["versions"][0], ensure_ascii=False))


if __name__ == "__main__":
    main()
