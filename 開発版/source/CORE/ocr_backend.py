"""Optional Windows/OculiX OCR observation backend.

The backend is activated only when a Profile explicitly asks for OCR and the
bundled Java/OculiX tools are actually prepared. It never turns OCR text into a
semantic game-state claim; it reports visible-window text with provenance.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import time
from pathlib import Path


class OculixOCR:
    def __init__(self, tools, desktop, evidence_root, interval_seconds=5.0):
        self.tools = tools
        self.desktop = desktop
        self.evidence_root = Path(evidence_root)
        self.interval_seconds = float(interval_seconds)
        if not 0 <= self.interval_seconds <= 60:
            raise ValueError("OCR_INTERVAL_INVALID")
        self._last_at = None
        self._last_record = None
        self._seq = 0

    @staticmethod
    def supported(tools, desktop):
        if os.name != "nt" or tools is None or desktop is None:
            return False
        available = getattr(tools, "is_available", None)
        if not callable(available) or not (available("java") and available("oculix")):
            return False
        try:
            state = desktop.state() or {}
            rect = state.get("rect")
        except Exception:
            return False
        return (
            state.get("native_window") is True
            and isinstance(rect, (list, tuple))
            and len(rect) == 4
        )

    def _write_proof(self, payload):
        self._seq += 1
        name = "ocr_observation_%06d.json" % self._seq
        path = self.evidence_root / name
        path.write_text(json.dumps(payload, ensure_ascii=False, sort_keys=True), encoding="utf-8")
        return name

    def read(self):
        now = time.monotonic()
        if (
            self._last_record is not None
            and self._last_at is not None
            and now - self._last_at < self.interval_seconds
        ):
            cached = dict(self._last_record)
            cached["cached"] = True
            return cached

        state = self.desktop.state() or {}
        rect = state.get("rect")
        if not isinstance(rect, (list, tuple)) or len(rect) != 4:
            raise OSError("OCR_WINDOW_RECT_UNAVAILABLE")
        left, top, right, bottom = [int(v) for v in rect]
        width, height = right - left, bottom - top
        if width <= 0 or height <= 0:
            raise OSError("OCR_WINDOW_RECT_INVALID")

        source = Path(__file__).with_name("OculixOcrRead.java")
        if not source.is_file():
            raise OSError("OCR_BRIDGE_SOURCE_MISSING")
        java = self.tools.get("java")
        jar = self.tools.get("oculix")
        proc = subprocess.run(
            [
                java,
                "-Dfile.encoding=UTF-8",
                str(source),
                jar,
                str(left),
                str(top),
                str(width),
                str(height),
            ],
            capture_output=True,
            timeout=45,
            check=False,
        )
        stdout = (proc.stdout or b"").decode("utf-8", errors="replace")
        stderr = (proc.stderr or b"").decode("utf-8", errors="replace")
        marker = next((line for line in stdout.splitlines() if line.startswith("OCR_BASE64=")), None)
        if proc.returncode != 0 or marker is None:
            proof = self._write_proof({
                "status": "HARNESS_ERROR",
                "reason_code": "OCULIX_OCR_FAILED",
                "rect": [left, top, right, bottom],
                "exit_code": proc.returncode,
                "stdout": stdout[-4000:],
                "stderr": stderr[-4000:],
            })
            record = {
                "status": "HARNESS_ERROR",
                "reason_code": "OCULIX_OCR_FAILED",
                "text": "",
                "evidence": [proof],
                "method": "oculix_region_text",
                "claim_scope": "visible_window_text_only",
                "cached": False,
            }
        else:
            try:
                text = base64.b64decode(marker.split("=", 1)[1]).decode("utf-8", errors="replace")
            except Exception as ex:
                raise OSError("OCULIX_OCR_OUTPUT_INVALID") from ex
            proof = self._write_proof({
                "status": "PASS",
                "reason_code": "OCR_CAPTURE_COMPLETED",
                "rect": [left, top, right, bottom],
                "text": text,
                "exit_code": proc.returncode,
            })
            record = {
                "status": "PASS",
                "reason_code": "OCR_CAPTURE_COMPLETED",
                "text": text,
                "evidence": [proof],
                "method": "oculix_region_text",
                "claim_scope": "visible_window_text_only",
                "cached": False,
            }

        self._last_at = now
        self._last_record = record
        return dict(record)

    def close(self):
        return None
