#!/usr/bin/env python3
"""Verify that every first-party embedded helper carries its declared entitlements."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Sequence


HELPER_ENTITLEMENTS = {
    "threading-extension-helper": Path(
        "Targets/ExtensionHelper/threading-extension-helper.entitlements"
    ),
    "threading-extension-helper-network": Path(
        "Targets/ExtensionHelper/threading-extension-helper-network.entitlements"
    ),
    "threading-wasm-extension-runner": Path(
        "Targets/WasmRunner/threading-wasm-extension-runner.entitlements"
    ),
    "threading-mcp-bridge": Path(
        "Targets/MCPBridge/threading-mcp-bridge.entitlements"
    ),
    "threading-ptyd": Path("Targets/PTYHost/threading-ptyd.entitlements"),
    "threading-simulator-helper": Path(
        "Targets/SimulatorHelper/threading-simulator-helper.entitlements"
    ),
    "threading-triggerd": Path("Targets/TriggerDaemon/threading-triggerd.entitlements"),
}

# scc is a checked-in third-party executable, not an Xcode helper target. Its checksum and
# architecture have their own gate; it has no repository entitlement declaration to compare.
UNMANAGED_EXECUTABLES = {"scc"}


def load_entitlements(path: Path) -> Dict[str, object]:
    value = plistlib.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError(f"{path} does not contain an entitlement dictionary")
    return value


def read_signed_entitlements(binary: Path) -> Dict[str, object]:
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(detail or f"codesign exited {result.returncode}")
    if not result.stdout.strip():
        return {}
    value = plistlib.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError("the signed entitlement payload is not a dictionary")
    return value


def embedded_profile_build_settings(bundle: Path) -> Dict[str, str]:
    """Read build-setting prefixes from the profile Xcode embedded during export."""
    profile = bundle / "Contents/embedded.provisionprofile"
    if not profile.is_file():
        return {}
    result = subprocess.run(
        ["/usr/bin/security", "cms", "-D", "-i", str(profile)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(detail or f"security cms exited {result.returncode}")
    value = plistlib.loads(result.stdout)
    prefixes = value.get("ApplicationIdentifierPrefix", [])
    if not isinstance(prefixes, list) or len(prefixes) != 1 or not isinstance(prefixes[0], str):
        raise ValueError("embedded profile has no unambiguous ApplicationIdentifierPrefix")
    return {"AppIdentifierPrefix": prefixes[0] + "."}


def expand_build_settings(value: object, build_settings: Mapping[str, str]) -> object:
    """Expand the plist build settings that Xcode resolves before codesigning."""
    if isinstance(value, str):
        for name, replacement in build_settings.items():
            value = value.replace(f"$({name})", replacement)
        return value
    if isinstance(value, list):
        return [expand_build_settings(item, build_settings) for item in value]
    if isinstance(value, dict):
        return {key: expand_build_settings(item, build_settings) for key, item in value.items()}
    return value


def entitlement_differences(
    expected: Mapping[str, object],
    observed: Mapping[str, object],
) -> List[str]:
    expected_keys = set(expected)
    observed_keys = set(observed)
    differences: List[str] = []
    missing = sorted(expected_keys - observed_keys)
    unexpected = sorted(observed_keys - expected_keys)
    changed = sorted(
        key for key in expected_keys & observed_keys if expected[key] != observed[key]
    )
    if missing:
        differences.append("missing " + ", ".join(missing))
    if unexpected:
        differences.append("unexpected " + ", ".join(unexpected))
    if changed:
        differences.append("different values for " + ", ".join(changed))
    return differences


def verify_bundle(
    bundle: Path,
    repository: Path,
    signed_reader: Callable[[Path], Mapping[str, object]] = read_signed_entitlements,
    build_settings: Mapping[str, str] | None = None,
) -> List[str]:
    helper_directory = bundle / "Contents/Helpers"
    if not helper_directory.is_dir():
        return [f"missing helper directory: {helper_directory}"]

    executable_names = {
        path.name
        for path in helper_directory.iterdir()
        if path.is_file() and os.access(path, os.X_OK)
    }
    problems = [
        f"{name}: executable has no entitlement declaration in the verifier"
        for name in sorted(executable_names - set(HELPER_ENTITLEMENTS) - UNMANAGED_EXECUTABLES)
    ]

    if build_settings is None:
        try:
            build_settings = embedded_profile_build_settings(bundle)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            return problems + [f"could not inspect embedded provisioning profile: {error}"]

    for name, declaration in HELPER_ENTITLEMENTS.items():
        binary = helper_directory / name
        entitlement_file = repository / declaration
        if name not in executable_names:
            problems.append(f"{name}: declared helper executable is missing")
            continue
        try:
            expected = expand_build_settings(load_entitlements(entitlement_file), build_settings)
            observed = signed_reader(binary)
            differences = entitlement_differences(expected, observed)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            problems.append(f"{name}: could not inspect entitlements: {error}")
            continue
        if differences:
            problems.append(f"{name}: " + "; ".join(differences))
    return problems


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    script_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=script_directory.parent,
        help="repository checkout containing the entitlement declarations",
    )
    parser.add_argument("bundle", type=Path)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    problems = verify_bundle(options.bundle, options.root)
    if problems:
        for problem in problems:
            print(f"bundle-entitlements: {problem}", file=sys.stderr)
        return 1
    print(
        "bundle-entitlements: clean — "
        f"{len(HELPER_ENTITLEMENTS)} helper signatures match their target files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
