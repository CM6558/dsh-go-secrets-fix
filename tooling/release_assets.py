#!/usr/bin/env python3
"""Prepare GitHub release assets for an in-app update (see docs/release.md).

Takes the version name from app/pubspec.yaml and the build number from the
APKs themselves (aapt2), checks that both flavors agree, copies them to dist/
under their release names, and writes SHA256SUMS and update.json next to them.
Upload everything in dist/ to the release tagged v<version>. Build the APKs
with `tooling/build-apk.sh -f all` first, so both share one build number.

    python3 tooling/release_assets.py --notes notes.md
    python3 tooling/release_assets.py --notes notes.md --base-url https://cdn.example.com/dsh/1.2.0/

--base-url makes update.json point at your own host (self-hosted feed); without
it the app derives GitHub download URLs from the tag and asset names.
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

from build_number import MAX_VERSION_CODE, decode

ROOT = pathlib.Path(__file__).resolve().parent.parent
FLAVORS = ("arm64", "x64")
REPO = "ccch1mneyyy/dsh-go"
VERSION_RE = re.compile(r"^(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\+(\d+))?$")
BADGING_RE = re.compile(r"^package: .*?\bversionCode='(\d*)' versionName='([^']*)'", re.MULTILINE)


class ReleaseError(Exception):
    pass


def pubspec_version() -> str:
    text = (ROOT / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(\S+)", text, re.MULTILINE)
    if not match:
        sys.exit("version: not found in app/pubspec.yaml")
    return match.group(1)


def find_aapt2() -> str | None:
    """aapt2 on PATH, else the newest one in the Android SDK's build-tools."""
    found = shutil.which("aapt2")
    if found:
        return found
    sdks = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT")]
    props = ROOT / "app" / "android" / "local.properties"
    if props.is_file():
        match = re.search(r"^sdk\.dir=(.+)$", props.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            sdks.append(match.group(1).strip())
    for sdk in filter(None, sdks):
        tools = sorted(
            pathlib.Path(sdk).glob("build-tools/*/aapt2"),
            key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.parent.name)),
        )
        if tools:
            return str(tools[-1])
    return None


def apk_version(aapt2: str, path: pathlib.Path) -> tuple[str, int]:
    """(versionName, versionCode) as the APK's manifest says."""
    out = subprocess.run([aapt2, "dump", "badging", str(path)], capture_output=True, text=True).stdout
    match = BADGING_RE.search(out)
    if not match:
        raise ReleaseError(f"{path}: aapt2 could not read its manifest")
    return match.group(2), int(match.group(1) or 0)


def release_build(name: str, expected: int | None, apks: dict[str, tuple[str, int]]) -> int:
    """The build number (versionCode) of the release, once the APKs agree with
    [name], with each other and with [expected] (`--version X.Y.Z+N`)."""
    for flavor, (apk_name, _) in sorted(apks.items()):
        if apk_name != name:
            raise ReleaseError(f"{flavor}: the APK is version {apk_name!r}, the release is {name!r}")
    codes = sorted({code for _, code in apks.values()})
    if len(codes) != 1:
        found = ", ".join(f"{flavor} {code}" for flavor, (_, code) in sorted(apks.items()))
        raise ReleaseError(f"flavors have different build numbers ({found}); rebuild with tooling/build-apk.sh -f all")
    code = codes[0]
    if not 1 < code <= MAX_VERSION_CODE:
        raise ReleaseError(f"versionCode {code} is a placeholder; build with tooling/build-apk.sh")
    if expected is not None and expected != code:
        raise ReleaseError(f"--version says +{expected} but the APKs are {code}")
    return code


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--version",
        help="X.Y.Z[-pre][+build]; default: app/pubspec.yaml's name. The build number is read from the APKs; "
        "a +build given here must match them.",
    )
    parser.add_argument("--notes", type=pathlib.Path, help="Markdown release notes (shown in the app)")
    parser.add_argument("--out", type=pathlib.Path, default=ROOT / "dist")
    parser.add_argument("--base-url", help="absolute or relative URL prefix for the APKs in update.json")
    parser.add_argument(
        "apks",
        nargs="*",
        metavar="FLAVOR=PATH",
        help="default: app/build/app/outputs/flutter-apk/app-<flavor>-release.apk",
    )
    args = parser.parse_args()

    full = args.version or pubspec_version()
    match = VERSION_RE.match(full)
    if not match:
        sys.exit(f"not a release version: {full}")
    name = match.group(1)
    # pubspec's +N is a placeholder; only an explicit --version's +N is an expectation.
    expected = int(match.group(2)) if args.version and match.group(2) else None

    sources = {}
    for item in args.apks:
        flavor, _, path = item.partition("=")
        if flavor not in FLAVORS or not path:
            sys.exit(f"expected FLAVOR=PATH with FLAVOR in {FLAVORS}: {item}")
        sources[flavor] = pathlib.Path(path)
    if not sources:
        for flavor in FLAVORS:
            sources[flavor] = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk" / f"app-{flavor}-release.apk"
    for flavor, path in sources.items():
        if not path.is_file():
            sys.exit(f"{flavor}: {path} not found (tooling/build-apk.sh -f all first)")

    aapt2 = find_aapt2()
    if not aapt2:
        sys.exit("aapt2 not found (Android SDK build-tools): it reads versionName and versionCode from the APKs")
    try:
        build = release_build(name, expected, {flavor: apk_version(aapt2, path) for flavor, path in sources.items()})
    except ReleaseError as e:
        sys.exit(str(e))

    args.out.mkdir(parents=True, exist_ok=True)
    assets = {}
    sums = []
    for flavor, path in sources.items():
        asset = f"dsh-go-{name}-{flavor}.apk"
        target = args.out / asset
        shutil.copyfile(path, target)
        digest = sha256(target)
        sums.append(f"{digest}  {asset}")
        entry = {"name": asset, "size": target.stat().st_size, "sha256": digest}
        if args.base_url:
            entry["url"] = args.base_url.rstrip("/") + "/" + asset
        assets[flavor] = entry
    (args.out / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")

    tag = f"v{name}"
    manifest = {
        "schema": 1,
        "version": f"{name}+{build}",
        "tag": tag,
        "title": f"DSH Go {name}",
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "notes": args.notes.read_text(encoding="utf-8").strip() if args.notes else "",
        "page": f"https://github.com/{REPO}/releases/tag/{tag}",
        "assets": assets,
    }
    (args.out / "update.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    try:
        built = f"{decode(build):%Y-%m-%d %H:%M} UTC+8"
    except ValueError:
        built = "custom build number"
    print(f"DSH Go {name}+{build} ({built})")
    print(f"{args.out}:")
    for line in sums:
        print("  " + line)
    print("  update.json")
    notes = f" --notes-file {args.notes}" if args.notes else ""
    print(f"\ngh release create {tag} {args.out}/* --repo {REPO} --title 'DSH Go {name}'{notes}")


if __name__ == "__main__":
    main()
