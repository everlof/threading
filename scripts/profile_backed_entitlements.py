#!/usr/bin/env python3
"""The entitlement families that require an Apple provisioning profile."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


NAMED_PROFILE_BACKED_ENTITLEMENTS = frozenset(
    {
        "keychain-access-groups",
        "com.apple.security.application-groups",
    }
)


def is_profile_backed_entitlement(key: str) -> bool:
    """Return whether Apple requires a provisioning profile to authorize ``key``."""
    return key.startswith("com.apple.developer.") or key in NAMED_PROFILE_BACKED_ENTITLEMENTS


def profile_backed_entitlements(entitlements: Mapping[str, Any]) -> set[str]:
    """Return every profile-backed key in an entitlement declaration."""
    return {key for key in entitlements if is_profile_backed_entitlement(key)}
