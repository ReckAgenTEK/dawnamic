#!/usr/bin/env python3
"""Resolve configured Dawn build targets into a GitHub Actions matrix."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import NoReturn


TARGET_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]*$")
SNAPSHOT_PATTERN = re.compile(r"^(?:[0-9]{4}/[0-9]{2}/[0-9]{2}|[0-9]{8}T[0-9]{6}Z)$")
BUILD_TYPES = {"Debug", "Release", "RelWithDebInfo", "MinSizeRel"}


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def selected_ids(value: str, available: list[str]) -> list[str]:
    value = value.strip()
    if not value or value == "all":
        return available

    if value.startswith("["):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError as error:
            fail(f"invalid target JSON: {error}")
        if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
            fail("target JSON must be an array of strings")
        requested = parsed
    else:
        requested = [item.strip() for item in value.split(",") if item.strip()]

    if not requested:
        fail("target selection is empty")
    return list(dict.fromkeys(requested))


def main() -> None:
    if len(sys.argv) != 2:
        fail(f"usage: {Path(sys.argv[0]).name} <all|target-list|json-array>")

    catalog_path = Path(__file__).with_name("targets.json")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if catalog.get("schema_version") != 1:
        fail("unsupported target catalog schema")

    defaults = catalog.get("defaults")
    targets = catalog.get("targets")
    if not isinstance(defaults, dict) or not isinstance(targets, list) or not targets:
        fail("target catalog must define defaults and at least one target")

    indexed: dict[str, dict[str, object]] = {}
    for target_override in targets:
        if not isinstance(target_override, dict):
            fail("every target entry must be an object")
        target = {**defaults, **target_override}
        target_id = target.get("id")
        if not isinstance(target_id, str) or not TARGET_PATTERN.fullmatch(target_id):
            fail(f"invalid target ID: {target_id!r}")
        if target_id in indexed:
            fail(f"duplicate target ID: {target_id}")

        labels = target.get("runner_labels")
        if not isinstance(labels, list) or not labels or not all(isinstance(label, str) for label in labels):
            fail(f"{target_id}: runner_labels must be a non-empty string array")
        if target.get("build_type") not in BUILD_TYPES:
            fail(f"{target_id}: unsupported build_type")
        if not isinstance(target.get("artifact_retention_days"), int):
            fail(f"{target_id}: artifact_retention_days must be an integer")
        for key in ("display_name", "dockerfile", "base_image", "runner_name", "runner_user"):
            if not isinstance(target.get(key), str) or not target[key]:
                fail(f"{target_id}: {key} must be a non-empty string")
        package_snapshot = target.get("package_snapshot")
        security_snapshot = target.get("security_snapshot")
        if not isinstance(package_snapshot, str) or not SNAPSHOT_PATTERN.fullmatch(package_snapshot):
            fail(f"{target_id}: package_snapshot has an invalid format")
        if not isinstance(security_snapshot, str) or (
            security_snapshot and not SNAPSHOT_PATTERN.fullmatch(security_snapshot)
        ):
            fail(f"{target_id}: security_snapshot has an invalid format")

        target["runner_labels_json"] = json.dumps(labels, separators=(",", ":"))
        target.pop("runner_labels", None)
        indexed[target_id] = target

    requested = selected_ids(sys.argv[1], list(indexed))
    unknown = [target_id for target_id in requested if target_id not in indexed]
    if unknown:
        fail(f"unknown target(s): {', '.join(unknown)}")

    matrix = {"include": [indexed[target_id] for target_id in requested]}
    print(json.dumps(matrix, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
