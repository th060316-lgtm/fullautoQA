# FullAutoQA — Issue #1 完了経路 外部独立技術監査

- 監査対象: `https://github.com/th060316-lgtm/fullautoQA` (公開 / read-only)
- 監査基準点: `main` = `17f6f9ba21adcdfbbc689e312072cb9841ac8461`
- 監査方法: 全clone + git履歴解析 + 全workflow読解 + 実測再現(Python等価実装) + GitHub Actions実データ
- 禁止事項遵守: push / commit / branch / PR / merge / Issue編集 / Actions実行・変更 / repository変更 — **すべて未実施**
- 本回答は未検証外部監査案であり、最終採用判断は内部側で行うこと

---

# 1. Executive Verdict

## RESTRUCTURE CURRENT ROUTE

**confidence: 高 (0.86)**

### 判定理由(3点)

**(1) 現行ルートの"戦略"は正しく、"検証基盤"が壊れている。**
`run_series.py` のCandidate freeze / fresh extraction / A-B-A規律 / 陳腐化Evidence拒否、`coordinator.py` の3総本山独立Gate、`capability_contract.py` のfreeze、Evidence manifest、`prepare_target.py` のオフラインvendored target snapshot(hash検証済)是は健全であり、**保全すべき正資産**である。問題はこの层的外にある。

**(2) 実機Runが連続して止まる直接原因は「handoff経路」でなく、2026-11-06に再導入された実機固有欠陥である。**
`TRANSFER_MANIFEST_MISSING`は3回とも同一原因(PS 5.1のANSIデコード)であり、handoff方式(overlay / fresh freeze)の差では説明できない — 実際2つのhandoff方式で同一エラーが出た時点で変数はhandoffでないと確定している。**この欠陥は2026-11-05に既に「encoding-safe」として解決済みだった**(下記 §8-1)が、Issue #25の戦略再構成で**静かに再導入**された。

**(3) 現行ルートは|Issue #1のDoDに到達不能である。** 技術PASSが出ても**構造的に到達不能なGateが2つある**(管理総本山Gate / 営業総本山Gate)。したがって「実機をもう1回走らせる」だけでは Issue #1 は閉じない。

### KEEP / REPLACE を採らない理由

| 選択肢 | 不採用理由 |
|---|---|
| KEEP CURRENT ROUTE | 実機固有欠陥4件(§1.1)が未修正。加えて2つのGateが構造的に到達不能。実機Run再多では Issue #1 は閉じない。再freeze回数は増えるだけで改善しない。 |
| REPLACE COMPLETION ROUTE | 意味論層(`run_series.py` のfreeze規律・A-B-A・陳腐化拒否・3HQ独立Gate・Evidence manifest・オフラインvendored target)は健全。再実装は「全面書き換えを目的にする」禁止事項にも反する。**置換すべき的不是「runner」而是「runnerが信用できる与否を判定する仕組み」。** |

### 1.1 実機固有欠陥(実測 / Git履歴で立証済み)

| # | 欠陥 | 立証 | 実機での帰結 |
|---|---|---|---|
| **D1** | `RUN_LOCAL_COMPLETION.ps1` / `PREPARE_SOURCE.ps1` / `RESTORE_PREDECESSOR.ps1` が **UTF-8 without BOM + 非ASCIIリテラル `開発版/...`**。実機は `powershell.exe`(PS 5.1 → ANSI/ACPデコード) | 3ファイルとも BOM 無し / 非ASCII含む(11 .ps1中3件)。`RUN_LOCAL_COMPLETION.cmd:4` が `powershell.exe` を呼ぶ | `Resolve-RepositoryRelativePath` が Mojibake パスになり `Test-Path` が False → **`TRANSFER_MANIFEST_MISSING`**(3回再現) |
| **D2** | ローカルrunnerの `prepared_source_fingerprint` を **ACCEPTANCE overlayの「前」**に計算し、builderは **「後」**のtreeで再計算 | `RUN_LOCAL_COMPLETION.ps1:741`(fingerprint)→`:749-752`(ACCEPTANCE copy)→`:761`(`-SourceBaseline`)。`PHASE3_OVERLAY_REBUILD.ps1:95-97` は再計算して不一致なら throw。**実測: 524 files → 783 files、fingerprint不一致を再現** | D1を直した**直後**に `SOURCE_BASELINE_MISMATCH` で停止(確定的) |
| **D3** | offline観測が **fail-open**。`Get-NetIPAddress` が失敗すると `-ErrorAction SilentlyContinue` で**空配列**→`up_adapter_count=0`→「offline PASS」 | `RUN_LOCAL_COMPLETION.ps1:123-135` と `phase3_run_evidence.py:145-160` の2箇所。アドレス取得失敗と「外部IPなし」が区別不能 | 「NOT_RUN/HARNESS_ERRORをPASSへ変換しない」禁止事項に正面から違反。offlineが**偽PASS**しうる |
| **D4** | CI と実機が**別ルート**になっている(下記 §1.2)。Rollbackは CI が `-PredecessorSet` を渡すため manifest分岐を**スキップ**、実機は渡さないため**同じmosaic**に当たる | `rollback-predecessor-qualification.yml:47` vs `RUN_LOCAL_COMPLETION.ps1:859-866` | D1をrunner側だけ直しても、stage 6 rollback が同原因で失敗 |

### 1.2 CI と実機の4つの非対称(これが「検証基盤の欠陥」)

| # | 非対称 | 実測 |
|---|---|---|
| A | **インタプリタ**: CI のスクリプト実行は全て `shell: pwsh`(PS 7 = UTF-8)。実機は `powershell.exe`(PS 5.1 = ANSI) | `shell: powershell` は3箇所のみ — 全て**parseのみ**(`local-completion-runner-syntax.yml:29`、`phase2-source-tests.yml:55`、`phase3-windows-candidate-build.yml:128`)。`PREPARE_SOURCE.ps1` のCI実行4回すべて `pwsh` |
| B | **引数**: CI の rollback は `-PredecessorSet` を渡す → 欠陥分岐を回避。実機は渡さない | `rollback-predecessor-qualification.yml:47` / `RUN_LOCAL_COMPLETION.ps1:859-866` |
| C | **自己検査の盲点**: PS自己検査は `Get-Content -LiteralPath $PSCommandPath -Raw`(**`-Encoding` なし** → 同じANSI) でスクリプト自身を読み、`$live.Contains('開発版/...')` を比較 → **Mojibake 対 Mojibake で常に True** | `RUN_LOCAL_COMPLETION.ps1:404`(Encoding無し) vs `:695`(UTF8あり) |
| D | **Python側テスト**は `read_text(encoding="utf-8")` で正しく読む → リテラルは見えるが「PS 5.1がどう読むか」は訊かない | `TESTS/test_issue25_strategic_route_contract.py:9,20` は非ASCIIリテラルを assert していない |

> **結論: hosted CI に、この欠陥クラスを検出できる検査は1つも存在しない。**
> 症状の再現は自明(Issue #25 comment `6690050689` / `6690557490`)だが、**検査側が構造的に見えない**ので、再実行しても必ず次の境界で止まる。

### 1.3 現行ルートでは到達不能なGate(再実行では閉じない)

| Gate | 状態 | 決定箇所 |
|---|---|---|
| **G-8 管理総本山Gate PASS** | **到達不能**。唯一の producer は `scope:'same_run_seed_replay'` を出し、evaluator は**その scope だけを** `INCONCLUSIVE / MANAGEMENT_REPRODUCIBILITY_SCOPE_LIMITED` に強制 downgrade。`management.reproducibility` は required=True | `phase3_run_evidence.py:252-262` vs `management_evaluator.py:428-434` |
| **G-9 営業総本山Gate PASS** | **到達不能**。producer が `evidence_kind:'model_proxy'` / `human_test_performed:False` をハードコード、evaluator の `sales.human_test`(required)は proxy をPromotionしない。加えて4 phase gate に verdict 源が無い | `phase3_run_evidence.py:389-391` vs `sales_evaluator.py:637-642`、`phase3_run_evidence.py:344-355` |
| A-3.5 / C-3.4 / C-3.5 (offline / Registry / Program Files) | 観測器自身が「**Full offline always remains NOT_RUN**」「Program Files remain NOT_RUN」と明文化。**設計上 NOT_RUN** | `local_acceptance_kit/LOCAL_OBSERVATION_LIMITS.md` / `run_series.py:223` |

---

# 2. Issue #1 completion gap map

## 2.1 前提

- Issue #1 本文 = **127 checked / 22 unchecked**(本文から実測。正本の数値と一致)
- 判定区分:
  - **(a)** 能力はあるが Final Evidence 待ち
  - **(b)** 本当の Source gap(実装が無い)
  - **(c)** Gate / observer 設計不足(実装はあるが構造上 verdict が出ない)
  - **(d)** 不要 / 重複
- **合計: (a) 13 / (b) 0 / (c) 8 / (a/c) 1 / (d) 0**

## 2.2 未完22項目の分類

| # | Section.Item | 分類 | 決定的な証拠 | 根拠 |
|---|---|---|---|---|
| 1 | A-3.5 完全offline / 非管理者 / Registry・PATH不変 | **c** | `local_acceptance_observer.ps1:154-156`、`LOCAL_OBSERVATION_LIMITS.md`、`run_series.py:223` | PATH境界値 fingerprint は測れるが、Registry全域監査・Program Files監査・offline恒常性は観測器が自ら NOT_RUN と宣言 |
| 2 | A-4.1 低負担でTarget/Profile生成・選択 | **a** | `target_intake.py:46-220`、`TESTS/test_target_intake_cli.py` | `discover`/`starter`/`select` CLI は完成・単体テスト済。最終パッケージ/実機Evidenceのみ不足 |
| 3 | B-1.1 8引擎をProfile/Adapter方式で | **a** | `adapters.py:7-28`、`tools.py:45-108`、`TESTS/test_issue1_generic_profile_matrix.py:68-87` | 1つのProfile/Adapter契約で8系統を賄う(matrix test済)。引擎ごとの受入targetがGodotのみ |
| 4 | B-1.2 Black-box: Screenshot/Window/Input/OCR/Log | **a** | `adapters.py:29-62`、`windows.py:88-137`、`ocr_backend.py`、`observations.py:26-44` | 5観測チャネル全部存在・provenance付き。bridge-less は `internal_state:false` と正直に報告 |
| 5 | B-1.4 Bridgeなしでも最低限Playable QA | **a** | `windows_runner.py:313,373,386-388`、`agents.py:150-212` | 画面差分学習 + bridge-less実targetあり |
| 6 | B-4.3 保存→変更→再起動→復元 | **a/scoped** | `storage_qa.py:289,292-378`、`windows_runner.py:259-289`、`TESTS/test_issue1_storage_lifecycle.py` **だが** `acceptance_targets/codegeas/profile.json` の `"storage": {"locations": [], "required": true, "contract": "persisted_save", "scenarios":[{"id":"restart_restore",...}]}` | 機構は完成/unit test済。**ただし実targetが storage locations を空宣言** → 実機では `HARNESS_ERROR / STORAGE_NO_DECLARED_LOCATIONS`。**緑の実機Runでもここで落ちる。** |
| 7 | B-4.4 壊れたStorage/旧Version/Migration/複数Slot/Autosave | **a** | `storage_qa.py:289,366-373`、`windows_runner.py:242-269`、`contracts.py:35` | 5機能すべて実装・unit test済。corrupt-save は codegeas で REQUIRED 済。残る4つは「target が宣言しない」ため NOT_RUN |
| 8 | B-5.1 初見30秒評価Evidence | **c** | `windows_runner.py:417` — 判定が `INCONCLUSIVE`/`READABILITY_REQUIRES_VALIDATED_PROXY` に**ハードコード**、gate=OPTIONAL | 記録はできるがPositive verdictを出す主体が存在しない |
| 9 | B-5.2 5分行動→反応→判断→結果ループ | **a** | `windows_runner.py:418-419` — `ok = elapsed>=300 and changed>=10` → PASS(ただし `claim='Automated proxy cycles only; does not establish enjoyment or comprehension'`) | 制作側の行動/反応ループEvidenceは PASS 可能。Sales側の読みは (c) |
| 10 | B-5.3 操作/移動/Camera/Menu/Combat/UI/Sound/Tutorial/Retry/SaveLoad/Main Loop | **a** | `contracts.py:24-75`、`observations.py:9-17`、`TESTS/test_issue1_generic_profile_matrix.py:18-28` | Profile駆動機構が存在し「profile data であり CORE にカテゴリをハードコードしない」ことを test が担保。実target が期待値未宣言 |
| 11 | C-2.2 Profile順序反転でもRequired不変 | **a** | `TESTS/test_issue1_order_and_bindings.py:22-31` | AB vs BA の構造完全一致を自動化済み |
| 12 | C-3.4 ネット接続要求なし | **c** | `phase3_run_evidence.py:279-285`、`LOCAL_OBSERVATION_LIMITS.md`「Full offline always remains NOT_RUN」 | 受動的adapter countのみ。**かつ §1.1 D3 の fail-open により偽PASSしうる** |
| 13 | C-3.5 Program Files / Registry / PATH恒久変更なし | **c** | `run_series.py:223` `registry_write_audit:'NOT_RUN'`、`local_acceptance_observer.ps1:154-155`、**source/acceptance_targets 内に "Program Files" の参照はゼロ** | PATH2値のみfingerprint。Registry全域・Program Files監査は未実装 |
| 14 | D-1.1 事前知識なしの別Run/別Session保持 | **a/scoped** | `phase3_run_evidence.py:358-379` — `cold_start` + provenance `fresh_extraction_start_qa` | Session record は生成される。ただし `session_id == run_id`(同一Run)、cold-start は「fresh-extraction marker から**推定**」であり観察ではない |
| 15 | D-1.3 初見30秒で目的・操作が読み取れるか | **c** | #8 と同じ (`windows_runner.py:417`、`sales_evaluator.py:374-379`) | 読みやすさゲートが positive verdict を構造的に出せない |
| 16 | D-1.4 5分で継続理由/フィードバックループ | **c** | `phase3_run_evidence.py:344-355` | phase record は video を持つが verdict 無し → `SALES_OBSERVATION_INCOMPLETE` |
| 17 | D-2.1 ゲーム名/IP/無料条件に非依存商品名説明 | **a** | `audience_summary.py:42-92`(`excluded_metadata: game_id,game_name,title,ip,license,price,free`)、`windows_runner.py:659-665` | 実装済み。`player_review_packet.json` 実在すれば PASS 可能 |
| 18 | D-2.2 「何をするゲームか」をEvidenceから要約 | **a** | `audience_summary.py:55-59`、`sales_evaluator.py:581-592` | #17 と同じ経路 |
| 19 | D-3.1 RESULT/SUMMARY/HTML reportが技術者以外に読める | **a/c** | `audience_summary.py:95-119` → `AUDIENCE_SUMMARY.txt` は生成される。**が**認証する gate `sales.nontechnical_report` は `communication_readability == PASS` を要求し CORE はそれを出さない | 成果物は( a )、ゲートは( c ) |
| 20 | **G-8 管理総本山Gate PASS** | **c** | `phase3_run_evidence.py:252-262` vs `management_evaluator.py:428-434` | §1.3 参照。producer と evaluator が互いに矛盾 |
| 21 | **G-9 営業総本山Gate PASS** | **c** | `phase3_run_evidence.py:389-391` vs `sales_evaluator.py:637-642` | §1.3 参照。`sales.human_test` は proxy で充足不能 |
| 22 | G-15 Rollback可能 | **a** | `RESTORE_PREDECESSOR.ps1`、`RUN_LOCAL_COMPLETION.ps1:852-891`、`.github/workflows/rollback-predecessor-qualification.yml` | 実行可能なpredecessor復元entrypoint + CI job + 実機 stage 6 が存在。実機未実行。**注意: 復元対象は preserved predecessor Candidate であり `安定版/`(READMEのみ)ではない** |

## 2.3 分類から読み取れる構造

1. **(b) 本当の Source gap は 22 項目中ゼロ。** コードは原則存在する。問題は「Evidenceが出てこない」こと。
2. **(c) が 8 項目。** これらは **再実行では絶対に閉じない**。特に **G-8 / G-9 は Issue #1 の DoD そのもの** Stabilization 条件。
3. **残り13項目 (a) も「実機1回で全部閉じる」わけではない。** #6(codegeas storage locations)のように、**緑の実機Runでも HARNESS_ERROR になる設定不備**が混在している。
4. **22項目の外側に、ルートcao欠陥 (D1–D4) が4件ある。** これらはIssue #1のチェックリストには現れないが、22項目を閉じる前に必ず塞ぐ必要がある。

---

# 3. PR #27 decision

## 部分採用 (Partial adoption) — ただし2点_chunk の書き直し必須

PR #27 = `work/issue25-source-immutability-20261106` / head `304e556` / base = **`7a48d3e`(mainのPR #26 mergeそのもの)

### 3.1 採用する部分: `source_tree_immutability.py` + workflow配線

**Issue #1完了への寄与(実測):**

| 評価点 | 実測 |
|---|---|
| 紅だったhosted gateが緑になるか | **なる**。`Phase 3 Windows Candidate Build` は base `7a48d3e` で **failure**、PR #27 head `304e556` で **success** |
| 前提となる不変条件は実際に成立するか | **成立**。実測で prepared source(524 files)に対し Source回帰475 tests を実行 → **added 0 / removed 0 / changed 0**(`__pycache__`/`.pyc` 除く) |
| 意味 | 回帰が**自分の入力を変更してはならない**という不変条件を機械的に固定する。`-SourceBaseline` fail-closed の前提(土台)を明示化する |

→ この不変条件は PR #26 が持ち込んだ `SOURCE_BASELINE_MISMATCH` fail-closed の**前提そのもの**。固定しないと「fingerprint が何を指しているか」が曖昧になる。**採用する。**

**ただし hosted の `__pycache__` 残留は注意:** 実測で `python -B -m compileall` は `-B` でも `__pycache__` を生成する(`sys.dont_write_bytecode` は compileall を止めない)。CI workflow の除去ステップは `__pycache__` ディレクトリ単位で除去するため `Get-TreeFingerprint`(全ファイル採録)とは整合するが、**除去が失敗した場合のみ** fingerprint が壊れる。PR #27 の compare は `__pycache__` を除外する定義なので、**CI の fingerprint 定義(`Get-TreeFingerprint` = 除外なし)と PR #27 の compare 定義(除外あり)は別物**。この2定義の不一致は §9 で解消する。

### 3.2 棄却 / 書き直しが必要な部分: `SOURCE_TREE_FINGERPRINT.ps1`

**このファイルは dead code である。** PR #27 head を grep しても `SOURCE_TREE_FINGERPRINT` を参照する箇所は**どこにも存在しない**(workflow / script / test すべて0件)。追加されただけで、**誰も呼んでいない**。

さらに**アルゴリズムが4つ目に分岐している**:

| 実装 | 場所 | ソート | 行結合 |
|---|---|---|---|
| A | `RUN_LOCAL_COMPLETION.ps1:216-229` `Get-TreeFingerprint` | `Sort-Object FullName`(culture依存) | `[Environment]::NewLine` |
| B | `PHASE3_OVERLAY_REBUILD.ps1:21-34` `Get-TreeFingerprint` | 同上 | 同上 |
| C | `phase3-windows-candidate-build.yml:99-112` | 同上 | 同上 |
| **D** | **PR #27 `SOURCE_TREE_FINGERPRINT.ps1`** | **`[Array]::Sort(Ordinal)`** | **`[char]10`(LF)** |

D は A/B/C と**別の値を出す**。このまま採用すると「fingerprint 定義が5個になる」だけ。**D ではなく、A/B/C を1つに畳んで D の位置昇格させるのが正解**(§9-B)。

補足: 現在の prepared source は**全ファイル名がASCII**(`開発版/source` の basename に非ASCII 0件、Recovery zip 460 entries 全部ASCII)のため、culture依存ソートと ordinal の差は今すぐには出ない。**理論上の問題であり実害は未発生** — ただし定義の分散は将来の事故の温床であり、Issue #1 の「Candidate identity」要求には1定義が要る。

### 3.3 PR #27 が**カバーしていない**重要穴

PR #27 は hosted CI の **Source回帰**に immutability check を足すだけ。**実機 local route の stage 3 (bundled Source regression) には check が無い**。つまり **§1.1 D2 の決定的バグ(ローカルrunnerのfingerprint計算順序)は PR #27 で直らない**。実機では「ACCEPTANCE overlay で 259ファイル増えて fingerprint 不一致 → `SOURCE_BASELINE_MISMATCH`」が**確実**に起きる。

### 3.4 判定

**部分採用。** 採用: `source_tree_immutability.py` + workflow配線(ただし fingerprint 定義の統一が前提)。棄却: `SOURCE_TREE_FINGERPRINT.ps1` の現行形(dead code かつ第4のアルゴリズム)。追加要求: 実機 local route の stage 3 にも immutability check を入れる。

---

# 4. PR #29 decision

## 部分採用(再設計必須) — **現状のままの merge は不可**

PR #29 = `work/issue25-handoff-preflight-20261107` / head `c80facb`

### 4.1 現在の PR #29 は **既に CI で赤**

| 事実 | 証拠 |
|---|---|
| PR #29 head で `Local completion runner syntax` が **failure** | Actions run (branch `work/issue25-handoff-preflight-20261107`, `c80facb`, 2026-11-06T16:36:52Z) — failing step = "Run repository-discovery contract test on Windows PowerShell 5.1" |
| 原因 | PR #29 は `開発版/transfer/TRANSFER_MANIFEST.json` リテラルを main block の**外**(関数 `Assert-RealMachineHandoff`)へ移動した。`Invoke-RepositoryDiscoveryContractTest` は `$live` = main block 以降のテキストしか見ないため **リテラル出現回数 0 → `.Contains()` False** → `STRATEGIC_ROUTE_DECLARED_INPUT_OR_PROVENANCE_MISSING`。実測: ファイル全体 2回 / `$live` 内 0回 |

**これは「自己検査がテキスト一致アサーションである」ことの実証**であり、機能変更ゼロで壊れる脆さを示している。

### 4.2 実機での機能的ゲインはゼロ(むしろ逆)

PR #29 は `Assert-RealMachineHandoff` に **非ASCII `開発版/...` リテラルを8個追加**する。実机的 PS 5.1 では最初のチェックで
`REAL_MACHINE_HANDOFF_PREFLIGHT_FAILED:TRANSFER_MANIFEST_MISSING`
となり、**Stage 0 で即死**する。つまり:

- 実機では「後で失敗する」のが「最初に失敗する」に変わっただけ
- **実機Runを1回消費して、能力はゼロ**
- さらに **Stage 0 が manifest を先に見る**ため、§1.1 D1 の解決前では**他のどのstageも到達不能**

### 4.3 ただし「Stage 0 preflight」という**概念は正しい**

評価すべき点: preflight は
- donor blocks 数・`manifest.json`/`JOIN_COMPLETE.ps1` の存在
- Recovery archive の **SHA-256 一致**
- build script / FINAL_SERIES_PLAN / run_series.py / rollback entrypoint の存在
を**まとめて**検査する。これは「handoff を期待ではなく契約にする」的正确な方向であり、**実機負担を1回の失敗から複数項目の一括報告に変える**。

### 4.4 判定 — 部分採用の具体形

**採用する(概念):** Stage 0 handoff preflight。チェック対象は manifest / plan から**導出**する(ハードコード `開発版/...` を禁止)。検査は **hosted CI の PS 5.1 job -hosted で実行可能**にして、実機ではなく gate にする。

**棄却する(実装):**
1. 非ASCIIリテラルの追加(実機では即死)
2. ファイル存在チェック中心 → **「その interpreter で解決できるか」** へ変更(BOM/encoding/regex-escape/実パス解決)
3. `schema_version` bump と `handoff_preflight='NOT_RUN'` の追加自体は可。ただし**自己検査の text needle を `$live` 限定からやめる**こと(§9-C)

**したがって: 部分採用。ただし「PR #29 のコード」を merging するのではなく、「PR #29 の意図」をHosted gate として再実装する。**

---

# 5. Architecture decision

## 5.1 責務境界(責任境界の定義)

| ゾーン | 所有者 | 契約 | 禁止 |
|---|---|---|---|
| **repo**(`main`) | 権威 Source + 契約 + CI | PS 5.1 が実行する全 `.ps1` は **ASCIIのみ** or **UTF-8+BOM**。宣言入力は manifest/plan から導出 | 非ASCIIリテラル、fingerprint 実装の複製、ハードコード絶対Path |
| **source**(prepared tree) | 不変のビルド入力 | `prepared_source_fingerprint` は**全overlay完了後**に計算。Source回帰は入力を変更しない | overlay前のfingerprint、回帰による入力改変 |
| **candidate** | 凍結成果物 | `size`/`sha256` 固定。`CANDIDATE_FREEZE.json` を Run1 前に記録、Run ごとに再検証 | runごとの再freeze、過去PASSの流用 |
| **workspace** | 一時・repo外・短縮ドライブ | runごとに fresh、終了時削除、入力にならない | repo内 work、前run再利用 |
| **evidence** | 保全・repo外(sibling) | 書き Nafiziral後は不変、readback 検証、Gate 判定を含む | repo内保存、PASS/FAIL による削除 |
| **rollback** | 独立資格(series の後) | byte identity + 実行可能な predecessor selftest | rollback が他Evidence収集を阻害 |
| **real-machine acceptance** | 環境オラクル | offline / 非管理者 / 実ゲーム / 実GPU の事実のみ | **移植性(script portability)の判定** |

## 5.2 中核原則(これが本次再構成の軸)

> **実機は最後のゲートであり、最初の判定装置ではない。**

現在のルートは「実機Run」が**スクリプト可搬性の最初の判定装置**になっている。だから「実機で初めて気づく」→局所修正→再実行→次の境界、となる。**可搬性・引数契約・fingerprint順序・encoding は hosted CI で決定的に判定でき、実機に残すべきのは環境事実だけ** にすべきである。

## 5.3 CI / 実機の役割分担(再設計)

| 判定 | 旧(CI) | 旧(実機) | 新(CI) | 新(実機) |
|---|---|---|---|---|
| script encoding / BOM | — | **初回判定(失敗)** | **PS 5.1 で判定** | 判定しない(再現済み) |
| 宣言入力の解決可能性 | — | **初回判定(失敗)** | **PS 5.1 + 実引数で判定** | 判定しない |
| rollback entrypoint | `-PredecessorSet` で**分岐回避** | 本来分岐 | **実機と同じ引数(省略)で判定** | 判定しない |
| fingerprint baseline | overlay後に計算 | **overlay前に計算(不一致)** | **overlay後に計算** | 同一ロジック |
| Source回帰の非改変 | (PR #27で追加予定) | なし | **あり** | **あり** |
| offline / 非管理者 / PATH / Registry | — | 判定 | 判定(判定**不能**なものは NOT_MEASURED) | **判定** |
| 実ゲーム3周 / A-B-A | hosted A-B-A (fixture) | 判定 | fixture probe | **判定** |
| Management / Sales Gate | — | NOT_RUN | — | **判定(observers 実装後)** |

---

# 6. Candidate freeze prerequisites

**freeze 前に必ずSource側で閉じるべき項目。** 1件でも欠けていれば、freeze後の実機Runは失敗し、**再freeze(1 Candidates再生成)** が必要になる。

## P0-1 PS 5.1 encoding 契約(最優先・3ファイルが違反)

- 対象: `RUN_LOCAL_COMPLETION.ps1`、`開発版/source/scripts/PREPARE_SOURCE.ps1`、`開発版/rollback/RESTORE_PREDECESSOR.ps1`
- 対応: (a) **ASCII化**(PR #19 方式の構造探索に寄せる) or (b) **UTF-8 BOM付与**。**推奨は (a)+(b) 両方** — literal 自体を消せば BOM 問題も消える
- 検証: hosted CI に **「PS 5.1 が実行する `.ps1` は BOM あり or ASCIIのみ」** の gate を追加

> 参考: PR #19 (`ed15668`) は "encoding-safe local completion path discovery — Remove non-ASCII path literals" として既にこれを解決していた。**再導入ではなく、復元である。**

## P0-2 `.ps1` からの非ASCIIリテラル除去

- `開発版` を `.ps1` に書かない。宣言情報は `TRANSFER_MANIFEST.json`(既に `-Encoding UTF8` で読む)へ集約するか、`.ps1` 内の ASCII な構造探索に寄せる
- 対象: runner 6箇所、`PREPARE_SOURCE.ps1:40`、`RESTORE_PREDECESSOR.ps1:52`

## P0-3 fingerprint 定義の統一 + ローカルrunnerの計算順序修正

- `Get-TreeFingerprint` を **1実装**(PR #27 の `SOURCE_TREE_FINGERPRINT.ps1` を正本化して昇格) に畳む。runner / builder / workflow の3コピー、CI workflow の embedded コピーを削除
- **ローカルrunner**: `prepared_source_fingerprint` を **ACCEPTANCE overlay 後**に計算(`RUN_LOCAL_COMPLETION.ps1:741` → `:752` の後に移動)。**これが直しないと §1.1 D2 が確定的に起きる**
- 検証: 「runner の計算値 == builder の再計算値」を hosted CI で assert

## P0-4 offline 観測の fail-closed 化(2箇所)

- `RUN_LOCAL_COMPLETION.ps1:118-152` と `CORE/phase3_run_evidence.py:125-192`
- 対策: adapter ごとに「アドレス取得成功件数」を保持し、**取得失敗があれば全体 `NOT_MEASURED`**(0件 adapters と区別)。現状は `-ErrorAction SilentlyContinue` の失敗が空配列に化け → 偽PASS
- 追加: `Get-NetIPAddress` の失敗を `up_adapter_count=0` として扱わないことを unit test で固定

## P0-5 Management Gate の producer/evaluator 矛盾解消

- `management.reproducibility`(required=True) は「独立run間の再現性」を要求する。現状 producer は run 内 seed replay しか出せず、evaluator はその scope を拒否する
- 選択肢: (a) **A-B-A series の level で独立run再現性を算出**し evaluator が受理する scope を追加(A run 2 回目 vs 1 回目) or (b) evaluator が run 内 scope も受理する
- **どっちでもよいが、現状のまま (c) のまま放置しない**。「Required を削って PASS にする」，禁止事項に照らして、**新しい証拠形态を追加する**方向で解く

## P0-6 Sales Gate の observer 設計

- 現状: `sales.human_test`(required, proxy 充足不能) / `sales.nontechnical_report`(required, 認証不能) / 4 phase gates(verdict 源なし)
- **判断が要るポイント**: 営業総本山Gate PASS を「人間実試 required」にするなら、Issue #1 は**人手review  受入を必須**にすることになり DoD の「全自動QAパイプライン」解釈と衝突する。**「自動観測可能な範囲 = required」「人間の実施有無 = 開示(非blocking)」という契約**を明示的に定義・実装し、Test で固定
- ただし **「proxy を human 扱いして PASS にする」ことは禁止**。Proxy は proxy のまま、`model_proxy` 表記のまま、開示行として残す
- 30秒/5分の phase verdict について: 現状 `windows_runner.py:417` は `INCONCLUSIVE` ハードコード。**機械で観測可能な部分(操作成立・画面遷移・メニュー到達等)を verdict に昇格**し、Enjoyment/理解度は proxy のまま、とするのが筋

## P0-7 codegeas の storage locations 宣言

- `acceptance_targets/codegeas/profile.json` の `"storage": {"locations": [], "required": true, ..., "scenarios":[{"id":"restart_restore"}]}` → **実際の save location を宣言**
- これを直さないと、**緑の実機Runでも B-4.3 が `HARNESS_ERROR / STORAGE_NO_DECLARED_LOCATIONS`** になる(freeze前に潰す最後の穴)

## P0-8 Registry / Program Files / offline 恒常性の観測器

- `local_acceptance_kit/local_acceptance_observer.ps1` と `run_series.py:223` を拡張: HKCU 配下の書込監査、Program Files 配下の書込監査、`registry_write_audit` を NOT_RUN から実測へ
- **失敗は NOT_MEASURED**。PASS への変換は禁止(LOCAL_OBSERVATION_LIMITS.md の自己宣言どおり)

## P0-9 hosted CI に「実機と同じ実行契約」job を新設

- `windows-latest` + `shell: powershell`(=PS 5.1) で:
  1. checkout から `PREPARE_SOURCE.ps1` を実行 → 宣言入力の解決成功
  2. Candidate build 完走 + `SOURCE_BASELINE` 一致
  3. **rollback entrypoint を実機と同じ引数(=`PredecessorSet 省略)で**実行
  4. 非ASCIIディレクトリを含む合成treeで、パス解決が**実パスと一致**することを assert(自己テキスト照合ではなく)
- これがあれば §1.1 D1–D4 は hosted で **0件** になる

## P0-10 実機local route の Source回帰 immutability check

- PR #27 の `source_tree_immutability.py` を **ローカルrunnerの stage 3** にも適用(現状 PR #27 は hosted のみ)

---

# 7. Final acceptance sequence

**Candidate は1つ。実機Runは1回。** 途中の Source 変更があれば Candidate を再freezeし、系列を 처음부터再開する(`FINAL_SERIES_PLAN.json` の `target_update_policy: restart_series_after_candidate_profile_or_target_change` に一致)。

### F0 — hosted preflight(実機に出る前に全部閉じる)
1. PS 5.1 encoding gate / 宣言入力解決 / Candidate build / rollback(実機同引数) が **緑**
2. Management/Sales observer の contract test が緑
3. `codegeas` storage locations 宣言済み
4. この時点で **Candidate を freeze**(`CANDIDATE_FREEZE.json` + size/sha 固定)

### F1 — 実機の入手
- frozen commit の **fresh extraction**(overlay 禁止、失敗runツリー再利用禁止)
- 標準ユーザー / 非管理者 / 外部ネット切断

### F2 — `RUN_LOCAL_COMPLETION.cmd` を **1回だけ**
8 stage:
| Stage | 内容 | 判定 |
|---|---|---|
| 0 | Handoff preflight(manifest 駆動 / PS 5.1 実パス解決) | PASS/FAIL |
| 1 | preserved v0.3.3 donor JOIN + byte identity | PASS |
| 2 | Source 再構築 → **overlay後** fingerprint → Candidate build + identity | PASS |
| 3 | fresh Candidate の bundled Source回帰 + **immutability** | PASS |
| 4 | fresh Candidate `START_QA.cmd -SelfTest` | PASS |
| 5 | fresh PoliticsTrasport → codegeas → PoliticsTrasport(3 fresh extraction / frozen target / 過去Run不使用) | 3/3 PASS + Result ZIP 3件 |
| 6 | preserved predecessor rollback(実機と同引数) | PASS |
| 7 | environment readback(non-admin / offline start・series・end / PATH / Registry / Program Files) | PASS or NOT_MEASURED(FAIL化しない) |

### F3 — 単一 Evidence bundle からの総合判定
- Production / Management / Sales / Rollback / Offline / NonAdmin / PATH / Registry を **1つの readback** で確定
- `NOT_RUN` / `HARNESS_ERROR` は **PASS へ変換しない**。`MANAGEMENT_*` / `SALES_*` の reason_code をそのまま残す

### F4 — Issue #1 チェックリスト照合(同一Evidenceから)
- 22項目を「そのEvidenceで閉じられるか」で判定。閉じられないものは **未チェックのまま残す**(、ホスト generality からの推定 promoted しない)
- 特に **G-8 / G-9 は P0-5 / P0-6 実装前は必ず未チェック**

### F5 — Product Acceptance / Stable
- 全 Gate 成立まで **HOLD**。Human は `NOT_RUN` のまま明示

---

# 8. Things to stop doing

1. **handoff 方式(overlay / fresh freeze)を blocker として扱うことをやめる。** 2つのhandoffで同一エラーが出た時点で変数はhandoffではない。**変数は `84e7d1f`(2026-11-06 20:07)が再導入した非ASCIIリテラル**である
2. **「既知の解法」の再導入をやめる。** PR #19 `ed15668` は "encoding-safe local completion path discovery — Remove non-ASCII path literals" として既に解いていた。**PR #26 は「構造的改善」として，把它を静かに壊した。** 戦略PRは**既存ゲート(特にPS 5.1 gate)を赤くしてから merge する**運用にすべき
3. **自己検査による自己検証をやめる。** `$live.Contains(<自身のリテラル>)` は Mojibake 対 Mojibake で恒真。**振る舞いを assert する**(hosted CI で実パスを解決して一致を確かめる) に置換
4. **`Get-TreeFingerprint` を新しく複製しない。** 既に4定義。**1定義に畳んで他を削除**。追加是什么时候も「既存正本の再利用」に，倒_AUTHORITYの低い新実装を作る
5. **「次の blocker を見つけるための Candidate 再構築」をやめる。** Source が変われば Candidate が変わる。**Source を動かさずに Candidate を再 freeze する理由はない**
6. **実機を「移植性の判定装置」として使わない。** 移植性(encoding / 引数 / 順序)は hosted CI の PS 5.1 で判定し、実機には環境事実だけを残す
7. **PR #29 型の preflight を、実機で回さない。** CI の PS 5.1 gate として hosting する
8. **Management / Sales の NOT_RUN を「次回Runで解決される話」として扱わない。** observer 設計の問題であり、Run 回数の問題ではない
9. **`Get-NetAdapter` の「0 up adapters」を offline PASS としない。** アドレス取得失敗を NOT_MEASURED に直す(「NOT_RUN/HARNESS_ERROR を PASS へ変換しない」の直接違反)
10. **Issue #1 の checked 項目を「実装が存在する」だけで再確認しない。** 特に **G-8 / G-9 / A-3.5 / C-3.4 / C-3.5** は checked になるべきでない
11. **過去 Candidate/A-B-A の PASS を新 Candidate へ流用しない**(現状は正しく運用されている。**維持**)
12. **「ローカル修正 → 再実行」を，改善のないまま繰り返さない。** 次の修正は「どの host gate を緑にするか」が定義されていなければ禁止

---

# 9. Concrete implementation plan

単発バグ単位ではなく、**ファイル/領域単位**でまとめる。

## A. PowerShell encoding 契約(最優先・3ファイル + gate)

| 対象 | 変更 |
|---|---|
| `RUN_LOCAL_COMPLETION.ps1` | 非ASCIIリテラル6箇所(425, 693, 722, 723, 744, 853)を宣言駆動へ置換。ASCII化 + UTF-8 BOM |
| `開発版/source/scripts/PREPARE_SOURCE.ps1` | `:40` のリテラルを manifest 駆動へ。ASCII化 + BOM |
| `開発版/rollback/RESTORE_PREDECESSOR.ps1` | `:52` のリテラルを manifest 駆動へ。ASCII化 + BOM |
| `.github/workflows/local-completion-runner-syntax.yml` | **encoding gate 追加**(`.ps1` が BOM あり or ASCII のみ)。自己テキスト照合を実パス解決へ置換 |

> 参照: PR #19 `ed15668` の実装が既にこの形の解法を持つ。**復元して構造的にBrother them する。**

## B. fingerprint 正本化

| 対象 | 変更 |
|---|---|
| `SOURCE_TREE_FINGERPRINT.ps1`(PR #27) | **正本へ昇格**。`RUN_LOCAL_COMPLETION.ps1` / `PHASE3_OVERLAY_REBUILD.ps1` から `Get-TreeFingerprint` を削除し、正本へ委譲 |
| `phase3-windows-candidate-build.yml` | embedded `Get-TreeFingerprint`(99-112)を削除し、正本Invokeに置換 |
| `RUN_LOCAL_COMPLETION.ps1:741` | fingerprint 計算を **ACCEPTANCE overlay 後**(`:752` の後)へ移動 |
| `PHASE3_OVERLAY_REBUILD.ps1:95-97` | 比較対象の定義を正本と一致(現状は同一実装のコピー) |

## C. Runner 自己検査の電子化(行動ベースへ)

| 対象 | 変更 |
|---|---|
| `RUN_LOCAL_COMPLETION.ps1:383-435` `Invoke-RepositoryDiscoveryContractTest` | `$live.Contains(<リテラル>)` 型の text needle を廃止。**合成tree(非ASCIIディレクトリ名を含む)を作り、実パス解決が実パスと一致することを assert**。PR #29 で text needle が original 位置から動くと壊れる脆さを解消 |
| `開発版/source/TESTS/test_issue25_strategic_route_contract.py` | `read_text(encoding="utf-8")` による text 検査を、**PS 5.1 の実デコード結果**検査に置換(または追加) |

## D. Hosted CI の実行契約 job(新設)

| 対象 | 変更 |
|---|---|
| `.github/workflows/windows-powershell51-contract.yml`(新設) | `shell: powershell`(PS 5.1)で ①encoding gate ②checkout からの `PREPARE_SOURCE.ps1` 実行 ③Candidate build + `SOURCE_BASELINE` 一致 ④**rollback を実機と同じ引数で**実行 ⑤非ASCIIパスの実解決 assert |
| `.github/workflows/phase2-source-tests.yml` | PR #27 の immutability 配線 + 上記④を host |
| `.github/workflows/phase3-windows-candidate-build.yml` | PR #27 の immutability 配線(既に差分あり) |
| `.github/workflows/rollback-predecessor-qualification.yml` | `-PredecessorSet` を外す / 両分岐を走らせる |

## E. Observer 実装(Management / Sales / environment)

| 対象 | 変更 |
|---|---|
| `CORE/phase3_run_evidence.py:252-262` | `management.reproducibility` の scope 拡張(独立run再現性を算出) or evaluator 受容 scope 追加 |
| `CORE/management_evaluator.py:428-434` | 上記に追随。**required を削らない** |
| `CORE/phase3_run_evidence.py:344-355` `_phase_evidence` | 30秒/5分の phase に**機械観測可能な verdict**を付与(操作成立・遷移・メニュー到達等)。Enjoyment/理解度は proxy のまま |
| `CORE/windows_runner.py:417` | 30秒行の `INCONCLUSIVE` ハードコードを、観測可能項目は PASS/NOT_RUN に、proxy 限定項目は proxy のままに分割 |
| `CORE/sales_evaluator.py:637-656` / `:594-619` | `sales.human_test` / `sales.nontechnical_report` の required 性を**契約として明示**。proxy を human に昇格させない |
| `CORE/phase3_run_evidence.py:125-192` / `RUN_LOCAL_COMPLETION.ps1:118-152` | **offline 観測 fail-closed**(アドレス取得失敗 → NOT_MEASURED)。2箇所の実装を1つに |
| `local_acceptance_kit/local_acceptance_observer.ps1` / `run_series.py:223` | Registry 書込監査 / Program Files 書込監査を実装。失敗は NOT_MEASURED |
| `RUN_LOCAL_COMPLETION.ps1` Summary | `management` / `sales` / `offline` / `registry` / `program_files` の **Gate verdict を Summary に明記**(現状、総合判定に含まれない) |

## F. Target / Profile データ

| 対象 | 変更 |
|---|---|
| `acceptance_targets/codegeas/profile.json` | `"storage".locations` に実 save location を宣言(`"locations": []` は `HARNESS_ERROR` 原因) |
| `acceptance_targets/politicstrasport/profile.json` | 同様に storage 契約を確認 |
| `acceptance_targets/*/profile.json` | `verify_seed_replay` scenario の要否を再確認(P0-5 の再現性観測に使うなら宣言) |

## G. テスト

| 追加 | 意図 |
|---|---|
| `TESTS/test_windows_script_encoding.py` | 出荷 `.ps1` すべての encoding 契約(BOM/ASCII)を固定 |
| `TESTS/test_offline_observer_fail_closed.py` | 「アドレス取得失敗」と「up 0 adapters」の区別を固定 |
| `TESTS/test_runner_fingerprint_ordering.py` | runner の overlay後 fingerprint == builder の再計算、を固定 |
| `TESTS/test_hq_gate_reachability.py` | Management/Sales の required row が Automated run で PASS しうるかを**構造的に**固定(現在の到達不能を回帰で塞ぐ) |

---

# 10. Final recommendation

## 次に何をするべきか(1本)

> **「実機実行契約(Windows PowerShell 5.1)を hosted CI の gate として作り上げる」ことを、1つの作業単位として完了させる。**
>
> 具体的には、PR #19 `ed15668` が解いた encoding-safe な入力解決(構造探索 or manifest 駆動)を**3スクリプトへ復元し**、overlay後の fingerprint 順序を直し、offline 観測を fail-closed にし、その3点すべてを **`shell: powershell`(PS 5.1) の hosted job で緑にする**。
> **それが緑になった後、Candidateを1つだけfreezeし、実機を1回だけ走らせる。**

### なぜこれが「1本」か

- 実機の3回の失敗は、**1つの原因(PS 5.1 + 非ASCIIリテラル)**の3つの表出であった
- その原因は **CI が PS 5.1 で実パスを一度も解決していない**ことに起因する
- したがって **「PS 5.1 で実パスを解決する hosted job」を1本作る**だけで、D1(解決)、D2(順序gate:I-1)、D3(fail-open gate:I-4 で別途)、D4(引数不一致:I-2)は**まとめて消える**
- 現状で実機を走らせると **確実に次の境界で止まる**(D2 は確定的)。**実機Runの回数を増やさないこと自体が成果**である

### 同時に(同じ作業単位の一部として)片付ける3点

- **P0-5 / P0-6**: Management / Sales の到達不能を解消する観測器。これ無しでは Issue #1 の DoD(3総本山Gate)に**原理的に到達しない**
- **P0-7**: codegeas の storage locations。これ無しでは緑の実機Runが B-4.3 で落ちる
- **PR #27 の取り込み**(fingerprint 正本化 + immutability 契約)と **PR #29 の取り込み**(preflight 概念)を **上2点の CI job の中に統合**する

### やってはいけないこと(この1本の中)

- 実機の再走(green gate が立つまで)
- Candidate の再freeze(Source が変わらない限り)
- Issue #1 の checked 項目の再確認(Evidence なしの昇格は禁止)
- Management / Sales の required を落とすこと / proxy を human にすること

---

## 監査の限界(未検証部分)

- 失敗した hosted job の**詳細ログは取得不能**(匿名での job log DL は `403 Must have admin rights`)。したがって §3.1 の「base で赤 → PR #27 head で緑」は**前後の観測**であり、ログによる因果確認ではない。PR #27 の mechanism は PR 自身の記述と整合するが、ログ未確認
- 実機が生成した Mojibake 実バイトは Linux から再現不能。結論は Microsoft の documented behavior(`about_Character_Encoding`: BOM 無しのスクリプトは ANSI codepage と解釈される / `Get-Content` の既定は ANSI)+ 3回の同一症状から導出
- 実機の実 ANSI codepage が CP932 だったか CP1252 だったかはリポジトリからは観測不能。**いずれでも同一の「一致しない文字列」が生成されるため結論は不変**
- GitHub Actions 全 923 run の全量ではなく、main 32 run + 分岐 run + 近期 run を列挙
- Management / Sales の「required row が Automated run で PASS しうるか」の評価は、忠実な bundle を CORE の producer/evaluator に投入して導出。**実機での再確認は未実施**
- `安定版/` は `README.md` のみで、Rollback の対象は preserved predecessor Candidate である点に注意(Issue #1 G-15 の解釈に影響)
