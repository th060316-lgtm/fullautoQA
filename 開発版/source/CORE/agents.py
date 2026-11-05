"""FullAutoQA agents — Phase-2 observational learning extension.

Based on the supplied CORE_agents.py (baseline a4ccbf28...).
Preserves Smoke / Goal / Explorer / Random behaviour.
Adds deterministic, bounded-memory observational learning that can improve
action selection from black-box screen signatures when no internal state
bridge exists.

Rules enforced:
- wall-clock noise alone is never treated as reward
- unchanged / no-reaction observations cannot create false success
- memory remains bounded
- same seed + same observation sequence remains reproducible
- no online model, no NumPy, no external API, no new package dependency
"""
from __future__ import annotations

from collections import Counter, deque
import hashlib
import json
import random
import time
from typing import Any, Dict, List, Optional, Tuple


def _stable_screen_sig(data: Any) -> str:
    """Produce a deterministic short signature from screen / image data.

    Accepts:
    - None  -> constant 'NONE'
    - str/bytes already a signature
    - list/tuple of ints (image_features style)
    - bytes (raw)
    Never incorporates wall-clock or process-id.
    """
    if data is None:
        return "NONE"
    if isinstance(data, str):
        return data if len(data) <= 64 else hashlib.sha256(data.encode("utf-8", errors="replace")).hexdigest()[:32]
    if isinstance(data, (bytes, bytearray)):
        return hashlib.sha256(bytes(data)).hexdigest()[:32]
    if isinstance(data, (list, tuple)):
        # image_features returns list of int 0-255; hash the packed bytes
        try:
            raw = bytes(int(x) & 0xFF for x in data)
            return hashlib.sha256(raw).hexdigest()[:32]
        except (TypeError, ValueError):
            return hashlib.sha256(repr(data).encode("utf-8", errors="replace")).hexdigest()[:32]
    return hashlib.sha256(repr(data).encode("utf-8", errors="replace")).hexdigest()[:32]


class Agent:
    def __init__(self, profile, scenario, seed):
        self.profile = profile
        self.scenario = scenario
        self.mode = scenario["agent"]
        self.requested_mode = self.mode
        self.action_modes: List[str] = []
        self.actions_by_mode = Counter()
        self.seed = seed
        self.rng = random.Random(seed)
        self.total_actions = 0
        self.history: List[str] = []
        self.visited = Counter()
        self.failed = Counter()
        self.success = Counter()
        self.retry_count = 0
        self.started = time.monotonic()
        self.current_goal = scenario.get("goal")
        self.memory: Dict[Tuple[str, str], int] = {}
        self.loops = 0
        # --- Phase-2 observational layer ---
        # (screen_sig, action) -> count of times the action produced a visible change
        self.obs_success: Counter = Counter()
        # (screen_sig, action) -> count of times the action produced no visible change
        self.obs_failed: Counter = Counter()
        self.obs_visits: Counter = Counter()
        self.obs_attempts: Counter = Counter()
        # bounded FIFO of recent (screen_sig, action, changed) for reproducibility tests
        self.obs_trace: deque = deque(maxlen=int(scenario.get("obs_trace_limit", 256)))
        self._last_screen_sig: Optional[str] = None
        # memory bound (shared with soak limit when present)
        self._mem_limit = int(scenario.get("memory_limit", 1024))

    def signature(self, state):
        # Adapter/profile decides which changing values represent progress; wall clocks are excluded.
        fields = self.profile.get(
            "state_signature",
            ["scene", "position", "money", "turn", "branch", "score"],
        )
        return json.dumps({f: state.get(f) for f in fields}, sort_keys=True)

    def _obs_sig(self, screen) -> str:
        return _stable_screen_sig(screen)

    def choose(self, state, screen=None):
        """Select next action.

        Optional `screen` argument supplies a black-box observation (image
        features, capture bytes, or pre-computed signature). When present and
        the agent is in Observational / Explorer mode, screen-derived preference
        is used in addition to the existing state-based counters.
        """
        sig = self.signature(state)
        self.visited[sig] += 1
        screen_sig = self._obs_sig(screen) if screen is not None else None
        if screen_sig is not None:
            self._last_screen_sig = screen_sig
            self.obs_visits[screen_sig] += 1

        allowed = [
            x
            for x in self.profile["actions"]
            if x not in self.profile.get("forbidden_actions", [])
            and x not in ("save", "load")
        ]
        random_allowed = [
            x for x in self.profile.get("allowed_random_actions", allowed) if x in allowed
        ]
        if not allowed:
            raise ValueError("NO_ALLOWED_ACTIONS")

        if (
            len(self.history) >= 8
            and len(set(self.history[-8:])) <= 2
            and self.visited[sig] >= 3
        ):
            self.mode = "Explorer"
            self.loops += 1
            self.retry_count += 1

        sequence = self.scenario.get("sequence", [])
        a = None
        selected_mode = self.mode

        if self.mode == "Smoke" and len(self.history) < len(sequence):
            a = sequence[len(self.history)]
        elif self.mode == "Goal":
            policies = self.scenario.get("policy", [])
            from profile import condition
            a = next(
                (x["action"] for x in policies if condition(state, x["when"])),
                None,
            )
            if a is None and sequence and len(self.history) < len(sequence):
                a = sequence[len(self.history)]
            if a is None or self.visited[sig] > 4:
                self.mode = "Explorer"
                selected_mode = "Explorer"
                a = None
            if a is None:
                a = min(
                    allowed,
                    key=lambda x: self.failed[(sig, x)] + self.history.count(x),
                )
        elif self.mode == "Random":
            a = self.rng.choice(random_allowed or allowed)
        elif self.mode in ("Explorer", "Observational"):
            # Deterministic preference:
            # 1. Prefer actions that previously produced a screen change for this screen_sig
            # 2. Avoid actions that previously produced no-reaction for this screen_sig
            # 3. Fall back to classic Explorer ordering (visit count, failure, history)
            def obs_key(x):
                if screen_sig is not None:
                    # Higher obs_success is better (we invert for min-key)
                    succ = self.obs_success[(screen_sig, x)]
                    fail = self.obs_failed[(screen_sig, x)]
                    # Preserve immediate learning preference, but repeated
                    # observations must not let one successful cycle starve
                    # every untried edge. Balance attempts after two visits;
                    # screen change alone does not establish goal progress.
                    attempts = self.obs_attempts[(screen_sig, x)]
                    fairness = attempts if self.obs_visits[screen_sig] >= 3 else 0
                    return (fairness, -succ, fail, self.memory.get((sig, x), 0), self.failed[(sig, x)], self.history.count(x), x)
                return (
                    self.memory.get((sig, x), 0),
                    self.failed[(sig, x)],
                    self.history.count(x),
                    x,
                )

            a = min(allowed, key=obs_key)
        else:
            selected_mode = "Random"
            a = self.rng.choice(random_allowed or allowed)

        if screen_sig is not None:
            self.obs_attempts[(screen_sig, a)] += 1
        self.action_modes.append(selected_mode)
        self.actions_by_mode[selected_mode] += 1
        self.total_actions += 1
        self.memory[(sig, a)] = self.memory.get((sig, a), 0) + 1
        self.history.append(a)
        self._trim_memory()
        return a

    def feedback(self, before, after, action, screen_before=None, screen_after=None):
        """Record outcome of an action.

        State-based success/failure uses the existing signature comparison
        (wall-clock fields are already excluded by profile state_signature).

        Observational layer: a positive observation is recorded only when the
        screen signature actually changed. Unchanged / None / identical screens
        increment obs_failed and never obs_success. This prevents no-reaction
        from being treated as success.
        """
        key = (self.signature(before), action)
        state_changed = self.signature(before) != self.signature(after)
        if state_changed:
            self.success[key] += 1
        else:
            self.failed[key] += 1

        # Observational learning from black-box screen
        sb = self._obs_sig(screen_before) if screen_before is not None else None
        sa = self._obs_sig(screen_after) if screen_after is not None else None
        if sb is not None and sa is not None:
            changed = sb != sa
            okey = (sb, action)
            if changed:
                self.obs_success[okey] += 1
            else:
                # Explicit: no-reaction must not become success
                self.obs_failed[okey] += 1
            self.obs_trace.append((sb, action, changed))
            self._last_screen_sig = sa
        self._trim_memory()

    def _trim_memory(self):
        """Bound observational caches without changing baseline action-budget semantics."""
        limit = max(1, self._mem_limit)
        for cache in (self.obs_success, self.obs_failed, self.obs_visits, self.obs_attempts):
            while len(cache) > limit:
                try:
                    cache.pop(next(iter(cache)))
                except (StopIteration, KeyError):
                    break
        if self.scenario.get("soak"):
            if len(self.history) > limit:
                del self.history[:-limit]
                del self.action_modes[:-limit]
            for cache in (self.memory, self.visited, self.failed, self.success):
                while len(cache) > limit:
                    try:
                        cache.pop(next(iter(cache)))
                    except (StopIteration, KeyError):
                        break

    def exhausted(self):
        return (
            (self.total_actions if self.scenario.get("soak") else len(self.history))
            >= self.scenario.get("action_budget", 100)
            or time.monotonic() - self.started >= self.scenario.get("time_budget", 60)
        )

    def goal_assessment(self, goal_reached):
        """Goal attainment alone never certifies a Goal policy or fallback."""
        direct = (self.requested_mode == "Goal" and bool(self.action_modes)
                  and self.action_modes[-1] == "Goal"
                  and self.actions_by_mode.get("Goal", 0) > 0)
        status = "PASS" if goal_reached and direct else "INCONCLUSIVE"
        reason = ("GOAL_POLICY_REACHED_GOAL" if status == "PASS" else
                  "GOAL_NOT_REACHED" if not goal_reached else "GOAL_POLICY_NOT_DEMONSTRATED")
        return {"status": status, "reason_code": reason, "goal_reached": bool(goal_reached),
                "requested_agent": self.requested_mode,
                "last_action_agent": self.action_modes[-1] if self.action_modes else None,
                "actions_by_agent": dict(self.actions_by_mode),
                "scope": "Goal policy demonstration; goal attainment is reported separately"}

    def export(self):
        return {
            "total_actions": self.total_actions,
            "history_truncated": self.total_actions > len(self.history),
            "seed": self.seed,
            "mode": self.mode,
            "requested_mode": self.requested_mode,
            "action_modes": list(self.action_modes),
            "actions_by_mode": dict(self.actions_by_mode),
            "current_goal": self.current_goal,
            "action_history": self.history,
            "visited_state": dict(self.visited),
            "failed_action": {str(k): v for k, v in self.failed.items()},
            "success_action": {str(k): v for k, v in self.success.items()},
            "obs_success": {str(k): v for k, v in self.obs_success.items()},
            "obs_failed": {str(k): v for k, v in self.obs_failed.items()},
            "obs_visits": dict(self.obs_visits),
            "obs_attempts": {str(k): v for k, v in self.obs_attempts.items()},
            "retry_count": self.retry_count,
            "loops": self.loops,
        }


class StallDetector:
    def __init__(self, seconds=10):
        self.seconds = seconds
        self.samples = deque(maxlen=200)

    def observe(self, now, state_sig, screen_sig, action, waiting=False, reaction=None):
        self.samples.append((now, state_sig, screen_sig, action, reaction))
        if waiting:
            self.samples.clear()
            return None
        # Preserve the continuous no-progress interval even when capture/input
        # overhead makes samples farther apart than the configured timeout.
        # Four real observations and two distinct attempted actions remain required.
        segment = []
        for sample in reversed(self.samples):
            stable = sample[1] == state_sig
            if reaction is not None:
                stable = stable and sample[4] == reaction
            else:
                stable = stable and screen_sig is not None and sample[2] == screen_sig
            if not stable:
                break
            segment.append(sample)
        if len(segment) < 4 or now - segment[-1][0] < self.seconds:
            return None
        if len({x[3] for x in segment if x[3]}) >= 2:
            return "SOFTLOCK"
        return None
