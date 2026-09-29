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
import re
import sys
from pathlib import Path

# Keep in sync with Sources/MacPilot/Update/VersionCompatibility.swift
# (ConfigurationSchema) and Resources/Info.plist.
CONFIG_SCHEMA_VERSION = 26
MINIMUM_READABLE_CONFIG_SCHEMA = 20
VERSION_MANAGER_PROTOCOL_VERSION = 1
RIGHT_CLICK_STORE_SCHEMA_VERSION = 2

# 版本号会被拼进输出文件名,必须与 generate-build-info.py 同形:绝不
# 允许携带路径分隔符或 ".." 之类的内容。
VERSION_PATTERN = (
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta\.[1-9][0-9]*)?"
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="full app version, e.g. 1.1.480-beta.1")
    parser.add_argument("output", help="path of the compatibility JSON to write")
    args = parser.parse_args()

    if not re.fullmatch(VERSION_PATTERN, args.version):
        print(f"error: invalid release version: {args.version!r}", file=sys.stderr)
        return 2
    # 规范化后必须仍落在工作目录内:输出路径来自外部输入,
    # 绝不允许写出预期目录(或借助 ../ 与符号链接绕到别处)。
    working_directory = Path.cwd().resolve()
    output = Path(args.output).resolve()
    if not output.is_relative_to(working_directory):
        print(
            f"error: output path must stay inside the working directory: {args.output!r}",
            file=sys.stderr,
        )
        return 2

    manifest = {
        "appVersion": args.version,
        "configSchemaVersion": CONFIG_SCHEMA_VERSION,
        "minimumReadableConfigSchema": MINIMUM_READABLE_CONFIG_SCHEMA,
        "versionManagerProtocolVersion": VERSION_MANAGER_PROTOCOL_VERSION,
        "rightClickStoreSchemaVersion": RIGHT_CLICK_STORE_SCHEMA_VERSION,
    }
    payload = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    output.write_text(payload, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
