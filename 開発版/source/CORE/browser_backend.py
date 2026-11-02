"""Offline browser display binding for FullAutoQA.

The browser process itself is launched by the normal profile launch command. This module
validates that browser targets are local-only and attaches to the launched process tree
through the same Win32 Desktop/SendInput/BitBlt implementation used by WindowDisplay.
"""
from __future__ import annotations

import ipaddress
import os
from pathlib import Path
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname


def _loopback_host(host):
    if not host:
        return False
    host = host.strip("[]").lower()
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_browser_target(target, work):
    if not isinstance(target, str) or not target.strip():
        raise OSError("BROWSER_TARGET_MISSING")
    text = target.strip()
    parsed = urlparse(text)
    root = Path(work).resolve()
    if not parsed.scheme:
        resolved = (root / unquote(text)).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            raise OSError("BROWSER_FILE_TARGET_OUTSIDE_WORK")
        if not resolved.exists():
            raise OSError("BROWSER_FILE_TARGET_MISSING")
        return {"scheme": "file", "target": target, "resolved": str(resolved)}
    if parsed.scheme == "file":
        if parsed.netloc:
            raise OSError("BROWSER_FILE_HOST_FORBIDDEN")
        raw = url2pathname(unquote(parsed.path or ""))
        # Windows file URLs can encode /C:/...
        if os.name == "nt" and len(raw) >= 3 and raw[0] in "/\\" and raw[2] == ":":
            raw = raw[1:]
        path = Path(raw)
        if not path.is_absolute():
            path = root / path
        resolved = path.resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            raise OSError("BROWSER_FILE_TARGET_OUTSIDE_WORK")
        if not resolved.exists():
            raise OSError("BROWSER_FILE_TARGET_MISSING")
        return {"scheme": "file", "target": target, "resolved": str(resolved)}
    if parsed.scheme in ("http", "https") and _loopback_host(parsed.hostname):
        return {"scheme": parsed.scheme, "target": target, "host": parsed.hostname,
                "port": parsed.port}
    raise OSError("BROWSER_EXTERNAL_NETWORK_FORBIDDEN")


def validate_browser_profile(profile, work, launch_args=None):
    display = profile.get("display") or {}
    target = display.get("target") or display.get("url") or display.get("start_url")
    result = validate_browser_target(target, work)
    # Validate the actual expanded launch arguments when the caller has them.
    # This prevents a tool/profile token from expanding into an external URL after
    # an earlier check of only the literal profile text.
    args = launch_args
    if args is None:
        launch = profile.get("launch") or {}
        args = list(launch.get("argv", [])) + list(launch.get("extra_args", []))
    for arg in args:
        text = str(arg)
        if "://" in text:
            validate_browser_target(text, work)
    return result


class BrowserDisplay:
    """Real Windows GUI binding to an already-launched local browser process."""

    def __init__(self, profile, work, process):
        if os.name != "nt":
            raise OSError("BROWSER_WINDOWS_DESKTOP_REQUIRED")
        self.profile = profile
        self.work = Path(work)
        self.target = validate_browser_profile(profile, work)
        from windows import Desktop, child_pids
        self.d = Desktop()
        self.d.find(child_pids(process.pid))

    def focus(self):
        self.d.focus()
        state = self.d.state()
        if not state.get("focused"):
            raise OSError("FOCUS_NOT_VERIFIED")
        return {"verified": True, "window": state, "method": "SendInput/BitBlt",
                "backend": "browser"}

    def perform(self, item):
        return self.d.perform(item)

    def capture(self, path):
        return self.d.capture(path)

    def release(self):
        return self.d.release()

    def close(self):
        return self.release()

    def state(self):
        state = self.d.state()
        state["backend"] = "browser"
        state["browser_target"] = self.target
        return state

    def windows(self, pids):
        return self.d.windows(pids)


def select_browser_display(profile, work, process):
    return BrowserDisplay(profile, work, process)