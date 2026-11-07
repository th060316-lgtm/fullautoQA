extends Node
## EventBus - 共通イベントバス (Grok Core実装 / Phase A)
## MiniMaxは変更せず公開signalのみ使用する
## 既存signalは削除しない

signal time_advanced(minutes: int)
signal player_mode_changed(mode: String)
signal location_changed(location_id: String)
signal fact_observed(fact_id: String, payload: Dictionary)
signal npc_state_changed(npc_id: String)
signal quest_changed(quest_id: String)
signal world_event_triggered(event_id: String)
signal save_completed(slot_name: String)
signal load_completed(slot_name: String)

# 追加のCore用signal (MiniMax非依存)
signal player_hp_changed(hp: float, max_hp: float)
signal player_fatigue_changed(fatigue: float)
signal kmf_state_changed()
signal combat_started(enemy_ids: Array)
signal combat_ended(result: String)
signal visibility_noise_changed(noise: float)
signal debug_message(msg: String)
signal player_notice(msg: String)

# --- Social/UI integration signals (MiniMax contract extension) ---
signal affection_changed(npc_id: String, old_val: int, new_val: int)
signal emotion_changed(npc_id: String, emotion_type: String, intensity: float)
signal geass_triggered(target_id: String, geass_type: String, source_id: String)
signal memory_modified(npc_id: String, memory_id: String, old_val: Dictionary, new_val: Dictionary)
signal report_added(report_id: String, category: String)
signal quest_completed(quest_id: String, success: bool)
signal heroine_state_changed(field: String, old_val, new_val)
signal world_state_changed(key: String, old_val, new_val)
signal npc_relationship_changed(npc_a: String, npc_b: String, old_val: float, new_val: float)
signal ending_evaluated(ending_type: String, score: float)
signal debug_hook_called(hook_name: String, args: Dictionary)

# --- Phase A Day1 signals (追加のみ。既存削除禁止) ---
signal day1_action_committed(action: Dictionary)
signal day1_case_discovered(case_id: String, source: Dictionary)
signal day1_case_state_changed(case_id: String, old_status: String, new_status: String)
signal day1_facility_changed(facility_id: String, snapshot: Dictionary, reason: String)
signal day1_npc_moved(npc_id: String, from_location: String, to_location: String, reason: String)
signal day1_information_recorded(record: Dictionary)
signal day1_kmf_exposure_changed(old_value: float, new_value: float, reason: String)
signal day1_summary_ready(summary: Dictionary)
signal day1_feedback(payload: Dictionary)
signal kmf_digest_ready(digest: Dictionary)
signal day1_feedback_ready(feedback: Dictionary)

# Helper emitters used by the social module.
func emit_time_advanced(minutes: int) -> void:
	time_advanced.emit(minutes)

func emit_fact_observed(fact_id: String, payload: Dictionary) -> void:
	fact_observed.emit(fact_id, payload)

func emit_npc_state_changed(npc_id: String) -> void:
	npc_state_changed.emit(npc_id)

func emit_quest_changed(quest_id: String) -> void:
	quest_changed.emit(quest_id)


