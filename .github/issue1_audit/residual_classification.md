# Issue #1 残29項目: 検証経路（開始時）

基準 main `23e0f3809ecb0da2ab68d62ffee443c68e68e408`、Source tree `d2fac7374b68677f037c5166d92e0da7a72e53b3`。開始時120 checked / 29 unchecked。旧Final Candidate SHA-256 `1609669c150b738c5ef82c4ab8f5e163aaf26618cd12c66ed073f0015cd2c8d2` と final series 41778937797 を履歴として保全。分類は初期の実証経路であり、証拠成立や条件変更を意味しない。調査結果で必要に応じ再分類する。

| 番号 | Issue未完項目 | 先に行う経路・必要時の次工程 |
|---:|---|---|
| 1 | Windows完全オフライン・管理者権限不要・Registry/PATH変更なしを維持 | LOCAL_MACHINE_REQUIRED |
| 2 | 実ゲーム投入時に低負担でTarget/Profile生成・選択可能 | SOURCE_LIGHT → FINAL_PACKAGE_REQUIRED |
| 3 | Godot / Unity / Unreal / Java / Node / Python / C / EXE の実ゲーム適用をProfile/Adapter方式で維持 | LIGHT_RUNTIME; 別Engine実対象が必要な範囲あり |
| 4 | Black-boxゲームは Screenshot / Window / Input / OCR / Log を用いて検証 | LIGHT_RUNTIME → 必要なら FINAL_PACKAGE_REQUIRED |
| 5 | Bridgeなしでも最低限のPlayable QAが成立すること | LIGHT_RUNTIME → 必要なら FINAL_PACKAGE_REQUIRED |
| 6 | URL/ローカルWeb起動、Window/Viewport、Input、Screenshot、Console/Process evidence を取得 | LIGHT_RUNTIME → FINAL_PACKAGE_REQUIRED |
| 7 | WebゲームでもSmoke/Goal/Explorer/Randomが使用可能 | LIGHT_RUNTIME → FINAL_PACKAGE_REQUIRED |
| 8 | Randomだけで偶然Goal到達した結果をGoal能力PASSと誤認しない | SOURCE_LIGHT → FINAL_PACKAGE_REQUIRED |
| 9 | 保存後→変更→再起動→復元を検証 | LIGHT_RUNTIME → FINAL_PACKAGE_REQUIRED |
| 10 | 壊れたStorage/旧Version/Migration/複数Slot/Autosaveを対応可能な範囲で検査 | SOURCE_LIGHT / LIGHT_RUNTIME → FINAL_PACKAGE_REQUIRED |
| 11 | 初見30秒評価Evidence | EVIDENCE_ONLY; Humanは別 |
| 12 | 5分行動→反応→判断→結果ループEvidence | EVIDENCE_ONLY; 連続区間不足時 LIGHT_RUNTIME |
| 13 | 操作、移動、Camera、Menu、Combat/UI/Sound/Tutorial/Retry/SaveLoad/Main Loop をProfile要求に応じ確認 | EVIDENCE_ONLY; 対応Capabilityのみ |
| 14 | Profile順序反転でもRequired結果が変化しない | SOURCE_LIGHT; 実target順序は別 |
| 15 | stale cache / stale runtime / stale baseline の検出 | SOURCE_LIGHT → FINAL_PACKAGE_REQUIRED |
| 16 | 管理者権限要求がないこと | LOCAL_MACHINE_REQUIRED |
| 17 | ネット接続要求がないこと | LOCAL_MACHINE_REQUIRED |
| 18 | Program Files / Registry / PATH恒久変更がないこと | LOCAL_MACHINE_REQUIRED |
| 19 | ゲーム固有の事前知識なしで開始した評価を別Run/別Sessionとして保持 | EVIDENCE_ONLY; model session |
| 20 | README/説明資料を読む前と読んだ後を混同しない | EVIDENCE_ONLY |
| 21 | 初見30秒で目的・操作が読み取れるかEvidence化 | EVIDENCE_ONLY; Humanは別 |
| 22 | 5分で継続理由/フィードバックループが存在するかEvidence化 | EVIDENCE_ONLY; 連続区間不足時 LIGHT_RUNTIME |
| 23 | ゲーム名/IP/無料条件に依存しない商品説明テスト | EVIDENCE_ONLY; model verdict |
| 24 | 「何をするゲームか」をEvidenceから要約 | EVIDENCE_ONLY |
| 25 | 操作不能、意味不明、無反応、debug表示依存等を商品品質FAIL候補にする | EVIDENCE_ONLY |
| 26 | RESULT/SUMMARY/HTML reportが技術者以外にも読める | EVIDENCE_ONLY → 必要なら FINAL_PACKAGE_REQUIRED |
| 27 | 管理総本山Gate PASS | EVIDENCE_ONLY / SOURCE_LIGHT → FINAL_PACKAGE_REQUIRED + LOCAL_MACHINE_REQUIRED |
| 28 | 営業総本山Gate PASS | EVIDENCE_ONLY / HUMAN_REQUIRED / SPEC_SEMANTIC_CONFLICT候補 |
| 29 | Rollback可能 | EVIDENCE_ONLY; Stable実行物欠如は SPEC_SEMANTIC_CONFLICT候補 |

EVIDENCE_ONLY=既存証拠、SOURCE_LIGHT=小規模Source/fixture/negative、LIGHT_RUNTIME=軽量実対象、FINAL_PACKAGE_REQUIRED=製品bytes変更後の最終再構築・再系列、LOCAL_MACHINE_REQUIRED=利用者PC、HUMAN_REQUIRED=実人間、SPEC_SEMANTIC_CONFLICT=正本上の意味が一意に決まらない場合。

旧Candidateで行った実ゲーム3RunはSource変更後のCandidateの証拠に流用しない。新規小Issueは作らず、Stable/Release/Issue closeはユーザーの明示承認なしに実行しない。


## Integration checkpoint — 2026-11-05

PR #17 now integrates the preserved residual branches through merge commit `592fc733eef29c49fe50ece9475e92a0d2d40e2a` plus report compatibility fix `18c81e46e797c8f2d25549d7647a7444a50f437d`.

Integrated heads:
- generic QA: `709f773b1b5a2af8ca273dec7753dfcdc815127e`
- supplementary browser acceptance: `dc4db737897093e2343588602ff431b4d8acf3d8`
- management evaluator/evidence: `880b648f872e764d2f3c897cfe1ba1f2b77989fd`
- sales blind/model audit: `1a62f8dd309e6cd58b9d32184288a7a10e02da1e`
- independent management audit: `4aaacdcc626e640b9bd1b336271a4016d8e54797`
- local acceptance observer kit: `af08018acc1db852c0deb6f2dcce0b04e1fa699e`

This checkpoint is integration provenance only. It does not mark Management, Sales, Human, local offline/non-admin, Stable, Product Acceptance, or Issue #1 complete. Existing final Candidate and final A-B-A evidence remain historical acceptance evidence until a shipped Candidate change is actually rebuilt and re-run.
