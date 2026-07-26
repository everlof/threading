#!/usr/bin/env python3
"""One-shot, isolated Playwright runner for Skalman's agent browser tools.

The protocol is one bounded JSON request on stdin and one JSON response on stdout. Every run
creates a new browser plus non-persistent context and closes both before returning.
"""

from __future__ import annotations

import json
import re
import sys
from importlib.metadata import PackageNotFoundError, version
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

try:
    playwright_version = version("playwright")
except PackageNotFoundError:
    playwright_version = "unknown"

try:
    from playwright.sync_api import Error as PlaywrightError
    from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
    from playwright.sync_api import expect, sync_playwright
except ModuleNotFoundError as import_error:
    print(
        json.dumps(
            {
                "ok": False,
                "error_type": "RuntimeMissing",
                "error": f"Python cannot import Playwright: {import_error}",
            },
            separators=(",", ":"),
        )
    )
    raise SystemExit(0)


MAX_STEPS = 50
MAX_PERMISSIONS = 12
MAX_TIMEOUT_MS = 60_000
MAX_SNAPSHOT_CHARS = 12_000
SENSITIVE_QUERY = re.compile(
    r"(?:pass(?:word)?|secret|token|auth|key|code|session|credential)", re.I
)
URL_IN_TEXT = re.compile(r"https?://[^\s\]\[()\"'<>]+")


def clean_line(value: object, maximum: int = 300) -> str:
    text = " ".join(str(value or "").split())
    return text[:maximum]


def redact_url(value: object) -> str:
    try:
        parsed = urlsplit(str(value))
    except ValueError:
        return clean_line(value, 1_000)
    host = parsed.hostname or ""
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    if parsed.port:
        host = f"{host}:{parsed.port}"
    redacted_query = urlencode(
        [
            (key, "[redacted]" if SENSITIVE_QUERY.search(key) else item)
            for key, item in parse_qsl(parsed.query, keep_blank_values=True)
        ]
    )
    return urlunsplit((parsed.scheme, host, parsed.path, redacted_query, ""))


def redact_snapshot(value: str) -> str:
    return URL_IN_TEXT.sub(lambda match: redact_url(match.group(0)), value)


def bounded_timeout(value: object, default: int = 10_000) -> int:
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("timeout_ms must be a number")
    timeout = int(value)
    if timeout < 100 or timeout > MAX_TIMEOUT_MS:
        raise ValueError(f"timeout_ms must be between 100 and {MAX_TIMEOUT_MS}")
    return timeout


def strict_locator(page, step: dict, allow_missing: bool = False):
    sources = [
        key
        for key in ("role", "label", "placeholder", "test_id", "text", "css")
        if step.get(key) not in (None, "")
    ]
    if len(sources) != 1:
        raise ValueError(
            "Each targeted step needs exactly one of role, label, placeholder, test_id, text, or css"
        )
    source = sources[0]
    exact = bool(step.get("exact", True))
    if source == "role":
        options = {"exact": exact}
        if step.get("name") not in (None, ""):
            options["name"] = str(step["name"])
        locator = page.get_by_role(str(step["role"]), **options)
    elif source == "label":
        locator = page.get_by_label(str(step["label"]), exact=exact)
    elif source == "placeholder":
        locator = page.get_by_placeholder(str(step["placeholder"]), exact=exact)
    elif source == "test_id":
        locator = page.get_by_test_id(str(step["test_id"]))
    elif source == "text":
        locator = page.get_by_text(str(step["text"]), exact=exact)
    else:
        locator = page.locator(str(step["css"]))

    nth = step.get("nth")
    if nth is not None:
        if isinstance(nth, bool) or not isinstance(nth, int) or nth < 0 or nth > 100:
            raise ValueError("nth must be an integer from 0 through 100")
        locator = locator.nth(nth)
    elif not allow_missing:
        count = locator.count()
        if count != 1:
            raise ValueError(f"Strict locator matched {count} elements; expected exactly one")
    return locator


def validate_url(value: object) -> str:
    text = str(value or "").strip()
    try:
        parsed = urlsplit(text)
    except ValueError as error:
        raise ValueError("url is invalid") from error
    if parsed.scheme not in ("http", "https"):
        raise ValueError("url must use http or https")
    if not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise ValueError("url must have a host and must not contain credentials")
    return text


def context_options(request: dict) -> dict:
    options: dict = {
        "accept_downloads": False,
        "strict_selectors": True,
    }
    width = request.get("viewport_width")
    height = request.get("viewport_height")
    if (width is None) != (height is None):
        raise ValueError("viewport_width and viewport_height must be provided together")
    if width is not None:
        if not 200 <= int(width) <= 4_096 or not 200 <= int(height) <= 4_096:
            raise ValueError("viewport dimensions must be between 200 and 4096")
        options["viewport"] = {"width": int(width), "height": int(height)}

    direct = {
        "locale": "locale",
        "timezone": "timezone_id",
        "user_agent": "user_agent",
        "color_scheme": "color_scheme",
        "reduced_motion": "reduced_motion",
        "forced_colors": "forced_colors",
        "offline": "offline",
        "device_scale_factor": "device_scale_factor",
        "is_mobile": "is_mobile",
        "has_touch": "has_touch",
        "java_script_enabled": "java_script_enabled",
    }
    bounded_strings = {
        "locale": 80,
        "timezone": 100,
        "user_agent": 1_024,
        "color_scheme": 32,
        "reduced_motion": 32,
        "forced_colors": 32,
    }
    for key, maximum in bounded_strings.items():
        value = request.get(key)
        if value is not None and (
            not isinstance(value, str) or len(value.encode("utf-8")) > maximum
        ):
            raise ValueError(f"{key} must be a string of at most {maximum} UTF-8 bytes")
    for source, destination in direct.items():
        if request.get(source) is not None:
            options[destination] = request[source]

    scale = options.get("device_scale_factor")
    if scale is not None and (
        isinstance(scale, bool) or not isinstance(scale, (int, float)) or not 0.25 <= scale <= 8
    ):
        raise ValueError("device_scale_factor must be between 0.25 and 8")

    latitude = request.get("geolocation_latitude")
    longitude = request.get("geolocation_longitude")
    if (latitude is None) != (longitude is None):
        raise ValueError(
            "geolocation_latitude and geolocation_longitude must be provided together"
        )
    if latitude is not None:
        latitude = float(latitude)
        longitude = float(longitude)
        accuracy = float(request.get("geolocation_accuracy", 0))
        if not -90 <= latitude <= 90 or not -180 <= longitude <= 180 or accuracy < 0:
            raise ValueError("geolocation coordinates or accuracy are outside their valid range")
        options["geolocation"] = {
            "latitude": latitude,
            "longitude": longitude,
            "accuracy": accuracy,
        }
    return options


def step_result(index: int, action: str, detail: str) -> dict:
    return {"index": index, "action": action, "status": "passed", "detail": detail}


def execute_step(page, step: dict, index: int) -> dict:
    action = str(step.get("action") or "").strip().lower()
    timeout = bounded_timeout(step.get("timeout_ms"))
    if action == "goto":
        url = validate_url(step.get("url"))
        wait_until = str(step.get("wait_until") or "load").lower()
        if wait_until not in ("commit", "domcontentloaded", "load", "networkidle"):
            raise ValueError("wait_until is invalid")
        page.goto(url, wait_until=wait_until, timeout=timeout)
        return step_result(index, action, f"Loaded {redact_url(page.url)}")

    if action == "wait_for":
        state = str(step.get("state") or "visible").lower()
        if state not in ("attached", "detached", "visible", "hidden"):
            raise ValueError("wait_for state must be attached, detached, visible, or hidden")
        target = strict_locator(page, step, allow_missing=True)
        target.wait_for(state=state, timeout=timeout)
        if state in ("attached", "visible") and step.get("nth") is None:
            count = target.count()
            if count != 1:
                raise ValueError(f"Strict locator matched {count} elements; expected exactly one")
        return step_result(index, action, f"Reached state {state}")

    if action == "snapshot":
        targeted = any(
            step.get(key) not in (None, "")
            for key in ("role", "label", "placeholder", "test_id", "text", "css")
        )
        target = strict_locator(page, step) if targeted else page.locator("body")
        snapshot = redact_snapshot(target.aria_snapshot(timeout=timeout))
        truncated = len(snapshot) > MAX_SNAPSHOT_CHARS
        snapshot = snapshot[:MAX_SNAPSHOT_CHARS]
        if truncated:
            snapshot += "\n… [snapshot truncated]"
        return step_result(index, action, snapshot)

    target = strict_locator(page, step)
    if action == "click":
        target.click(timeout=timeout)
        return step_result(index, action, "Clicked one strict target")
    if action == "hover":
        target.hover(timeout=timeout)
        return step_result(index, action, "Hovered one strict target")
    if action == "fill":
        if (target.get_attribute("type") or "").lower() == "password":
            raise ValueError("Password fields are not accepted by isolated automation")
        value = step.get("value")
        if not isinstance(value, str) or len(value.encode("utf-8")) > 16_384:
            raise ValueError("fill requires a string value of at most 16384 UTF-8 bytes")
        target.fill(value, timeout=timeout)
        return step_result(index, action, "Filled one strict target; value omitted")
    if action == "press":
        key = str(step.get("key") or "")
        if not key or len(key.encode("utf-8")) > 100:
            raise ValueError("press requires a bounded key")
        target.press(key, timeout=timeout)
        return step_result(index, action, "Pressed a key on one strict target")
    if action == "select":
        value = step.get("value")
        label = step.get("option_label")
        if (value is None) == (label is None):
            raise ValueError("select requires exactly one of value or option_label")
        selected = target.select_option(
            value=str(value) if value is not None else None,
            label=str(label) if label is not None else None,
            timeout=timeout,
        )
        return step_result(index, action, f"Selected {len(selected)} option(s); value omitted")
    if action == "check":
        target.check(timeout=timeout)
        return step_result(index, action, "Control is checked")
    if action == "uncheck":
        target.uncheck(timeout=timeout)
        return step_result(index, action, "Control is unchecked")
    if action == "expect":
        state = str(step.get("state") or "").lower()
        expected_text = step.get("expected_text")
        if state and expected_text is not None:
            raise ValueError("expect accepts state or expected_text, not both")
        if expected_text is not None:
            expect(target).to_contain_text(str(expected_text), timeout=timeout)
            return step_result(index, action, "Expected text was present; value omitted")
        assertions = {
            "visible": expect(target).to_be_visible,
            "hidden": expect(target).to_be_hidden,
            "enabled": expect(target).to_be_enabled,
            "disabled": expect(target).to_be_disabled,
            "checked": expect(target).to_be_checked,
            "unchecked": lambda **kwargs: expect(target).not_to_be_checked(**kwargs),
        }
        assertion = assertions.get(state)
        if assertion is None:
            raise ValueError(
                "expect state must be visible, hidden, enabled, disabled, checked, or unchecked"
            )
        assertion(timeout=timeout)
        return step_result(index, action, f"Expectation {state} passed")
    raise ValueError(
        "action must be goto, wait_for, snapshot, click, hover, fill, press, select, "
        "check, uncheck, or expect"
    )


def run(request: dict) -> dict:
    engine_name = str(request.get("engine") or "chromium").lower()
    if engine_name not in ("chromium", "firefox", "webkit"):
        raise ValueError("engine must be chromium, firefox, or webkit")
    steps = request.get("steps")
    if not isinstance(steps, list) or not 1 <= len(steps) <= MAX_STEPS:
        raise ValueError(f"steps must contain between 1 and {MAX_STEPS} entries")
    if not all(isinstance(item, dict) for item in steps):
        raise ValueError("every step must be an object")
    permissions = request.get("permissions") or []
    if (
        not isinstance(permissions, list)
        or len(permissions) > MAX_PERMISSIONS
        or not all(isinstance(item, str) and item for item in permissions)
    ):
        raise ValueError(f"permissions must contain at most {MAX_PERMISSIONS} names")

    screenshot_path = request.get("_screenshot_path")
    completed: list[dict] = []
    page = None
    with sync_playwright() as playwright:
        browser_type = getattr(playwright, engine_name)
        browser = browser_type.launch(headless=bool(request.get("headless", True)))
        try:
            context = browser.new_context(**context_options(request))
            try:
                if permissions:
                    context.grant_permissions(permissions)
                page = context.new_page()
                if request.get("media_type") is not None:
                    media_type = str(request["media_type"]).lower()
                    if media_type not in ("screen", "print"):
                        raise ValueError("media_type must be screen or print")
                    page.emulate_media(media=media_type)
                page.set_default_timeout(bounded_timeout(request.get("timeout_ms")))
                for index, step in enumerate(steps):
                    completed.append(execute_step(page, step, index))
                if screenshot_path:
                    page.screenshot(path=screenshot_path, full_page=bool(request.get("full_page")))
                return {
                    "ok": True,
                    "backend": "playwright_isolated",
                    "engine": engine_name,
                    "playwright_version": playwright_version,
                    "final_url": redact_url(page.url),
                    "title": clean_line(page.title()),
                    "steps": completed,
                }
            finally:
                context.close()
        finally:
            browser.close()


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--probe":
        print(
            json.dumps(
                {
                    "ok": True,
                    "backend": "playwright_isolated",
                    "playwright_version": playwright_version,
                },
                separators=(",", ":"),
            )
        )
        return 0
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise ValueError("request must be a JSON object")
        response = run(request)
    except (ValueError, PlaywrightTimeoutError, PlaywrightError, OSError) as error:
        response = {
            "ok": False,
            "error_type": type(error).__name__,
            "error": clean_line(error, 1_000),
        }
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
