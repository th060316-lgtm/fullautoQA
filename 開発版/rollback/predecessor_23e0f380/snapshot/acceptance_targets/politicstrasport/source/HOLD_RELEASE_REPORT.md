# PoliticsTrasport v0.2 HOLD解除修正・再受入記録

## 対象と保護

- 対象: `main/開発版`
- 基準読み直しSHA: `ec3800e62888462dbdeb6136c8e8aeac415ffce6`
- `main/安定版` は未変更。作業開始時・終了時ともツリー `d6447174e3af0c982de0a9df49576fd816b86d89`。

## 修正と原因

1. プレイヤー会計
   - `world.money` の直接増減経路が `TransportCompany.register_revenue/expense()` を通らず、帳簿と評判だけが更新されていなかった。
   - `WorldState` の入出金APIでプレイヤーもAIと同じ原則で帳簿計上し、`world.money` と会社残高を同期。建設費・運行費・運賃/貨物収益の二重計上を防止。
2. obsolete路線撤去
   - Xキーが `_unhandled_input()` のみで処理され、GUIに消費されると撤去へ到達しなかった。
   - `remove_route` を `_input()` で先行処理。A: マウス選択→X、B: マウス選択→撤去ボタンを別テスト。
3. 期待失敗QA
   - 内陸港の正常な拒否を「操作失敗」として再試行・例外停止していた。
   - アクションに `expected_outcome` と拒否理由を持たせ、状態不変と新規イベント理由を両方検証。
4. 上部UI
   - 単一段の右寄せ操作群に動的ボタンを追加し、空港が1280幅から逸出していた。
   - 状態/時間と建設操作を2段化。全操作を画面内に左寄せし、`強制開戦` をテスト操作として分離。
5. 長期・CI/QA
   - 長期試験が物理道路を作らず論理Routeだけを作成していた。GroundNetworkの実タイル接続→論理Route→輸送を検証してから300日実行。
   - 旧CIの古いbase64ペイロード依存を廃止し、作業ツリーのLinux/Windowsテスト、1280x720描画、Windows標準7ランを直接実行。

## 標準7ラン

| ラン | 結果 | PASS根拠 |
|---|---|---|
| 初見道路建設 | PASS | 手動道路成立、輸送効果 |
| 道路→鉄道成長 | PASS | 道路+鉄道、累計輸送 328.082 |
| 船舶進出 | PASS | 2港+船舶路線 |
| 航空進出 | PASS | 2空港+航空路線 |
| AI競争対応 | PASS | 対抗路線、市場シェア 0.28946 |
| 戦時物流 | PASS | 同陣営補給加算、戦後obsolete化、選択→X撤去 |
| 探索・破壊・復旧 | PASS | 内陸港拒否を期待PASS、切断→非接続→復旧→再接続 |

## 300日長期試験

- 物理道路: 5タイル、費用40、論理Route ID 0。
- Day150: プレイヤー money 1346.374 / revenue 1109.874 / expenses 263.5 / lifetime 846.374 / reputation 1.4 / routes 1 / transported 1191.128。
- Day300: プレイヤー money 2166.775 / revenue 2155.275 / expenses 488.5 / lifetime 1666.775 / reputation 1.4 / routes 1 / transported 2390.796。
- Day300 AI: 東邦航空 money 26831.449 / routes 6 / transported 18705.995、銀河海運 money 31623.664 / routes 6 / transported 22380.912。
- Day150/300とも finite=true、全13路線、補給基地0、obsolete残骸0。AI各社の建設数6。

## 回帰と証跡

- Linux: Import/Parse, Boot, FullIntegrationTest, UIInteractionTest, HOLD対応35項目, DestructiveTest, FontSupportTest, LongRunProfile がジョブ成功。
- Windows: 同等のDevelopment AcceptanceとLongRunProfileがジョブ成功。
- 1280x720 VisualSmoke: 操作ボタン8個の画面内配置とスクリーンショット生成に成功。
- FontSupportTestは従来どおり情報診断でexit 0。headlessの `ThemeDB.fallback_font` は日本語グリフ6文字をMISSINGと報告するが、Windows画面ランの画像で日本語描画を確認。変更による回帰なし。

## 変更ファイルと理由

- 会計/入力/UI: `WorldState.gd`, `EconomySystem.gd`, `TransportCompany.gd`, `GameController.gd`, `MiniMaxUI.gd`, `Main.tscn`, `project.godot`
- QA: `runtime/qa/QaBridge.gd`, `runtime/qa/PoliticsTransportQaAdapter.gd`, `.ci/autoplayer/*`
- 試験: `HoldReleaseAcceptanceTest.gd`, `LongRunProfile.gd`, `.ci/UIInteractionTest.gd`, `.ci/DestructiveTest.gd`, `.ci/VisualSmokeTest.gd`
- CI: `.github/workflows/full-prototype-test.yml`

## 裁定候補

Development Acceptance PASS。自動受入のHOLD理由は解消されたため、**Player/Product Acceptance候補**。安定版昇格は別裁定とし、本作業では実施しない。
