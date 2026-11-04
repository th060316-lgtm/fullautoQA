# Supplementary screen-only real-game QA

This check runs through the existing CORE Session and START_QA paths. It does not alter the frozen Candidate, formal Final Profiles, original game source, Stable or release status. The supplied Profile records the original source identity and prototype classification. A playable test mode does not upgrade the quality of that original prototype.

Use a fresh disposable package root and explicit Profile/source paths:

```powershell
.\RUNTIME\python\python.exe SUPPLEMENTARY\blackbox\prepare_copy.py --profile PROFILE.json --source FROZEN_SOURCE --destination PROFILE_SOURCE_DIRECTORY --proof copy_proof.json
.\RUNTIME\python\python.exe CORE\target_intake.py select --profile PROFILE.json --replace
.\START_QA.cmd -NoFaults
```

The copy helper verifies the Profile's frozen source inventory digest before writing, applies only the exact replacements/removals declared in that Profile, and proves the source inventory stayed unchanged. Source and destination must not overlap. Destination must be absent. Unexpected input, symlinks, recipe path escapes and replacement count mismatches fail visibly. No game-specific names, engine arguments, coordinates, resource paths or bridge names are embedded in the helper/Adapter.

The Profile's game-side Adapter sends actual desktop input. It retains paired screenshots and compares a Profile-declared crop before and after each action. Its measurements live under external_observations.values with explicit provenance and screenshot evidence; internal_state remains empty. The Profile declares no gameplay Goal. An explicit external observation test reports EXTERNAL_OBSERVATION_CHECK and semantic_game_outcome=UNVERIFIED. Crop differences are not OCR, semantic gameplay correctness or proof of a win. Desktop review must calibrate the supplied crop/threshold before these measurements can be accepted.

Windows desktop, packaged Python, the explicitly declared engine runtime and the normal recording/runtime dependencies must be available. No administrator privileges, Registry changes, global PATH edits or product network dependency are added. An unavailable Linux display leaves Window, Screenshot, Input, OCR and Playable E2E at NOT_RUN; a real headless process is supporting evidence only. A fixture/synthetic display must not substitute for the real game.

OCR is NOT_RUN by default. A packaged tesseract executable may be declared through an exact manifest tool ID in blackbox.ocr_tool_id and tools_optional. Only executing that explicit tool produces OCR text. Missing or failed OCR never becomes recognized text.

The intake CLI also supports discover --search DIRECTORY and starter --game-id ID --launch-json JSON_ARRAY. Discovery never auto-binds. Starter generates an UNVALIDATED_STARTER that selection rejects. Existing Profile selection requires one explicit Profile value; replacing a selection requires --replace. Existing matching requirements and baseline are retained. Source/Adapter deployment remains a prerequisite; the CLI does not invent controls/goals or claim target acceptance.

The generic observation contract preserves legacy internal-state predicates by default. Tests may explicitly select observation_source: external_observations; that source requires provenance, a claim scope and existing contained evidence files. External observation sources are rejected for game Goals. The runner logs external observations separately from internal_state and does not apply them to save/load, seed replay or state regression.
