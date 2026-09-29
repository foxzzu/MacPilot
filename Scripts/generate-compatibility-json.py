#!/usr/bin/env python3
"""Generate the per-release compatibility manifest.

The Version Manager reads `MacPilot-<version>-compatibility.json` from a
release to decide whether a target release is known to read the current
configuration schema, and whether it ships the Version Manager (and can
therefore apply a pending configuration restore). Releases published before
this manifest existed simply have none — that is an honest "unknown", never
guessed.

Usage:
    generate-compatibility-json.py <version> <output-path>
"""

import argparse
import json
import sys

# Keep in sync with Sources/MacPilot/Update/VersionCompatibility.swift
# (ConfigurationSchema) and Resources/Info.plist.
CONFIG_SCHEMA_VERSION = 26
MINIMUM_READABLE_CONFIG_SCHEMA = 20
VERSION_MANAGER_PROTOCOL_VERSION = 1
RIGHT_CLICK_STORE_SCHEMA_VERSION = 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="full app version, e.g. 1.1.480-beta.1")
    parser.add_argument("output", help="path of the compatibility JSON to write")
    args = parser.parse_args()

    manifest = {
        "appVersion": args.version,
        "configSchemaVersion": CONFIG_SCHEMA_VERSION,
        "minimumReadableConfigSchema": MINIMUM_READABLE_CONFIG_SCHEMA,
        "versionManagerProtocolVersion": VERSION_MANAGER_PROTOCOL_VERSION,
        "rightClickStoreSchemaVersion": RIGHT_CLICK_STORE_SCHEMA_VERSION,
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
