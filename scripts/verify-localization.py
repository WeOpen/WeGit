#!/usr/bin/env python3
"""Check source coverage, translations and format arguments without touching source files."""
import collections
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent


def strings(language):
    path = root / "WeGitCore/Resources" / (language + ".lproj") / "Localizable.strings"
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))


def arguments(value):
    return collections.Counter(re.findall(r"%\d+\$@", value))


english, chinese = strings("en"), strings("zh-Hans")
menu_catalogs = {}
for language in ("en", "zh-Hans"):
    path = root / "WeGitCore/Resources" / (language + ".lproj/MenuTitles.strings")
    menu_catalogs[language] = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
assert menu_catalogs["en"].keys() == menu_catalogs["zh-Hans"].keys(), "Menu tables differ"
assert all(k == v for k, v in menu_catalogs["en"].items()), "Menu English source differs"
assert all(menu_catalogs["zh-Hans"].values()), "Missing Chinese menu translation"

assert english.keys() == chinese.keys(), "Language catalogs have different keys"
for key, value in english.items():
    assert value and arguments(key) == arguments(value), "Missing translation or format mismatch: " + key
    assert value == "简体中文" or not re.search(r"[\u4e00-\u9fff]", value), "Untranslated English value: " + key
    assert chinese[key] == key, "Chinese source wording changed: " + key

plural_catalogs = {}
for language in ("en", "zh-Hans"):
    path = root / "WeGitCore/Resources" / (language + ".lproj") / "Localizable.stringsdict"
    plural_catalogs[language] = plistlib.loads(path.read_bytes())
    for key, entry in plural_catalogs[language].items():
        assert entry["NSStringLocalizedFormatKey"] == "%#@count@"
        assert entry["count"]["NSStringFormatValueTypeKey"] == "lld"
        for form in ("one", "other"):
            assert entry["count"][form].count("%lld") == 1, "Invalid plural argument: " + key
assert plural_catalogs["en"].keys() == plural_catalogs["zh-Hans"].keys()

compiler = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
host = compiler.parent.parent / "lib/swift/host"
with tempfile.TemporaryDirectory(prefix="WeGitLocalizationAudit-") as folder:
    executable = Path(folder) / "inventory"
    output = Path(folder) / "inventory.json"
    subprocess.run([str(compiler), "-sdk", sdk, "-I", str(host), "-L", str(host), "-Xlinker", "-rpath",
                    "-Xlinker", str(host), str(root / "scripts/LocalizationSources.swift"),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(root), str(output)], check=True)
    records = json.loads(output.read_text())

for record in records:
    reason = record.get("skipped")
    assert reason in ("already-localized", "stable-enum-raw-value", "stable-accessibility-id", "path-data"), (
        "Unlocalized literal: " + record["file"] + " " + record["source"])
    if reason in ("stable-accessibility-id", "path-data"):
        continue
    key = record["key"]
    if record["context"] == "L10n.menuTitle":
        assert key in menu_catalogs["en"], "Missing menu title: " + key
        continue
    if record["context"] == "L10n.count":
        key = key.replace("%%lld", "%lld")
        assert key in plural_catalogs["en"], "Missing plural entry: " + key
    else:
        assert key in english, "Missing English resource: " + key
print(f"Localization verified: {len(english)} string keys, {len(plural_catalogs['en'])} plural keys; source coverage and arguments match.")
