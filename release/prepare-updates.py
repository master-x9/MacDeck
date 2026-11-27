"""Prepare immutable Mac and Android update packages and feeds for a GitHub release."""
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("tag")
parser.add_argument("notes", type=Path)
parser.add_argument("--app", type=Path)
parser.add_argument("--apk", type=Path)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9._-]+", args.tag) or not (args.apk or args.app):
    parser.error("Supply a release tag and at least one application")
args.out.mkdir(parents=True, exist_ok=True)
notes = args.notes.read_text().strip()
if not notes:
    parser.error("Provide release notes for the update prompt")
base = f"https://github.com/master-x9/MacDeck/releases/download/{args.tag}/"
if args.app:
    bins = Path(__file__).resolve().parents[1] / "Vendor/Sparkle/bin"
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    public_key = subprocess.check_output([bins / "generate_keys", "--account", "MacDeck", "-p"], text=True).strip()
    if info.get("SUPublicEDKey") != public_key:
        raise SystemExit("Built app and release signing key do not match")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", args.app], check=True)
    package = args.out / "MacDeck-update.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", args.app, package], check=True)
    signature = subprocess.check_output([bins / "sign_update", "--account", "MacDeck", "-p", package], text=True).strip()
    subprocess.run([bins / "sign_update", "--account", "MacDeck", "--verify", package, signature], check=True)
    ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", ns)
    feed = ET.Element("rss", version="2.0")
    channel = ET.SubElement(feed, "channel")
    ET.SubElement(channel, "title").text = "MacDeck updates"
    item = ET.SubElement(channel, "item")
    for key, value in [("version", info["CFBundleVersion"]), ("shortVersionString", info["CFBundleShortVersionString"]),
                       ("minimumSystemVersion", info["LSMinimumSystemVersion"])]:
        ET.SubElement(item, f"{{{ns}}}{key}").text = value
    ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {"url": base + package.name, "length": str(package.stat().st_size),
                  "type": "application/octet-stream", f"{{{ns}}}edSignature": signature})
    ET.ElementTree(feed).write(args.out / "appcast.xml", encoding="utf-8", xml_declaration=True)
if args.apk:
    subprocess.run(["apksigner", "verify", args.apk], check=True)
    badging = subprocess.check_output(["aapt", "dump", "badging", args.apk], text=True)
    package = re.search(r"^package: name='com.example.macdeck' versionCode='([0-9]+)' versionName='([^']+)'", badging, re.M)
    if not package:
        raise SystemExit("Unexpected Android package metadata")
    apk = args.out / "MacDeck.apk"
    if apk.resolve() != args.apk.resolve():
        shutil.copy2(args.apk, apk)
    manifest = dict(tag=args.tag, versionCode=int(package[1]), versionName=package[2], notes=notes,
                    sha256=hashlib.sha256(apk.read_bytes()).hexdigest())
    (args.out / "android-update.json").write_text(json.dumps(manifest, indent=2))
