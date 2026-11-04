# Lantern Steps 1.0.0 — supplementary browser target

Independent private acceptance game authored for the authorized FullAutoQA Issue #1 task on 2026-11-04. Original HTML/CSS/JavaScript, no framework, external assets, services, dependencies or downloads. No public distribution or new license grant is made by this task; existing repository rights are unchanged. The reviewed main root has no LICENSE file.

This is a playable supplementary target, not a selftest fixture, commercial/third-party game, PoliticsTrasport/codegeas, or final A→B→A acceptance. Its player moves a lantern along five steps to a gate, receives visible action feedback, and restarts. The runner uses shipped Agent and Adapter implementations, real Chromium-family CDP keyboard/pointer input, and observed BMP pixels. It never mutates game state through JavaScript. Its read-only DOM use covers readiness, focus, title, and visible button geometry.

Run with a preprovisioned Chromium-family executable:

    python run_acceptance.py --source-root <FullAutoQA source> --browser <existing executable> --out <new evidence folder>

The browser executable and SHA-256, actual CDP version, isolated dynamic endpoint, viewport, source/version/hash, per-mode actions, screenshots, console events and process evidence are recorded. Nothing installs/downloads a browser. File and loopback HTTP launches are tested independently. Random arrival is not Goal competence. Viewport focus is not native desktop focus. This supplementary runner does not certify continuous video, full Windows offline/non-admin package operation, user acceptance or Stable promotion.

Product integration uses `display.kind=browser`, `transport=cdp`, `runtime={engine:chromium-cdp,executable,sha256,provenance}`, `viewport={width,height}`, and a work-relative `endpoint` ending in `DevToolsActivePort`. Launch must start that executable with `--remote-debugging-port=0`, a fresh work-contained `--user-data-dir=<endpoint parent>`, browser flags, and `about:blank`. The configured local target is opened after interception is enabled. Fetch-intercepted requests are constrained to work files and loopback. Workers, WebSocket, WebRTC and browser background traffic are not certified by that interception gate.

Legacy Win32 browser transport remains distinct and reports `console=false`, `viewport=false`. CDP reports its supported input kinds and uses standard-library protocol and PNG/BMP code. Unavailable runtime, hash mismatch, unsupported input/transport, missing viewport, launch mismatch or screenshot mismatch is an explicit error; no Desktop PASS substitutes for Browser execution.
