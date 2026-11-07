# GeassDisasterSurvival Core (Grok EXT-20261018-007)

**未検証外部成果** — 正式採用・正本化・検証済みを自己宣言しません。

## 担当範囲（約50%）

- Core基盤: GameState / EventBus / RngService / 時計 / Seed
- 徒歩移動・カメラ・衝突
- Map / Fog of War（視線遮蔽・探索済み記録）
- KMF 搭乗/降機・移動・跳躍・耐久/エナジー/弾薬/センサー・visibilityNoise
- 簡易戦闘（徒歩/KMF射撃、敵歩兵/軽装甲/敵KMF）
- Survival（HP・負傷・疲労・食料・時間消費）
- Save/Load（JSON, schemaVersion, 1スロット, round-trip）
- HUD（常時表示、好感度真値非表示、MiniMax panel用コンテナ）
- 担当範囲の自己テスト

## 操作

| キー | 動作 |
|------|------|
| WASD / 矢印 | 移動 |
| E | KMF搭乗/降機 |
| Space | 射撃（マウス方向） |
| Shift (KMF時) | 短距離跳躍 |
| F5 | Save |
| F6 | Load |
| F3 | 状態ダンプ |
| T | 時間+30分 |
| F8 | Core自己テスト実行 |
| F9 | 7日高速完走 |

## ディレクトリ

```
core/          GameState, EventBus, RngService
player/        PlayerController
kmf/           KmfSystem
map/           MapManager (Fog含む)
combat/        CombatManager
save/          SaveManager
ui/hud/        HUD
tests/core/    自己テスト
data/core/     (予約)
integration_stubs/  MiniMax依存の仮物のみ
scenes/        Main.tscn
```

## 共有API（契約準拠）

- GameState: get_snapshot / apply_snapshot / get_section / set_section / advance_time / get_day / get_minute_of_day
- EventBus: 契約signal群
- RngService: set_seed / get_seed / randf_range_seeded / randi_range_seeded

MiniMax担当ディレクトリ（npc/ social/ geass/ quests/ world/ events/ ui/panels/）へ本番実装を書いていません。

## 不変条件の遵守

- 好感度 -100 を即ゲームオーバーにしない
- 0付近を自動安全扱いしない
- 確定事実(systemFacts)とNPC記憶を分離
- KMF喪失・ヒロイン死亡を主人公死亡以外の即GOにしない
- 徒歩/KMF同時成立禁止
- 時刻逆行禁止

## 起動

Godot 4.2+ で project.godot を開き、Mainシーンを実行。

## 返却

GROK_IMPL_CORE.zip / GROK_IMPLEMENTATION_REPORT.docx / TEST_RESULTS_GROK.txt
