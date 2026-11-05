# Issue #1 独立管理監査（再開・実Evidence再検証）

監査基準はGitHub main `23e0f3809ecb0da2ab68d62ffee443c68e68e408`、Final series `41778937797`、Final Candidate SHA-256 `1609669c150b738c5ef82c4ab8f5e163aaf26618cd12c66ed073f0015cd2c8d2`。2026-11-04の再開監査として実データを再読し、過去の自己回答を事実の証拠には使っていない。

**Management最終判定はNOT_RUN、Product Acceptance / Stable / ReleaseはHOLD。** 限定的に導出可能なsignalを接続したが、未測定・未証明を0/PASSへ変換していない。main・Target・生Result ZIPを書き換えず、同一technical系列を再build・再runしていない。

## 確認した事実

GitHub artifact `13300004174` のmetadataはFinal series runにBindingされる。再取得されたwrapperのSHA-256 `4556995e91aaf970a29a4b1086f17fd2890a27c020687660ebcf590a5926c00e` を実ファイルで照合した。

| Run | RunID | Manifest検証件数 | Result参照欠落 |
| --- | --- | ---: | ---: |
| A1 | 20261104T054954_472a6a42 | 230 | 0 |
| B2 | 20261104T055820_f1051db3 | 228 | 0 |
| A3 | 20261104T060748_db44ced6 | 232 | 0 |

全memberを読み出してCRC、manifest Size/SHA、重複・path escape、manifest外member、Result参照とRunIDを確認。3ZIPのSHAはSERIES_RECORDSと一致し、原ZIPは不変。生ZIPとmember SHAを構造化JSONのprovenanceに保持した。

資源値はmanagement_evidence.jsonに存在する。RAM/Handles/metrics観測区間をresources.jsonから再計算し全て一致。CPU正規化に使われたlogical CPU countはEvidenceに記録がなく、監査ホストのCPU数を代用しなかった。disk/evidence容量はpre-seal値で、sealed ZIP容量とは別量である。

| 測定 | A1 | B2 | A3 |
| --- | ---: | ---: | ---: |
| CPU percent | 81.61612116538743 | 80.27589736610615 | 82.44474859235658 |
| RAM MiB | 263.00390625 | 263.65625 | 262.703125 |
| Handles | 442 | 441 | 443 |
| metrics観測区間 秒 | 420.38005239999984 | 480.3288566000001 | 409.6011057999999 |
| pre-seal disk bytes | 300705807 | 561362737 | 302100768 |
| pre-seal evidence bytes | 282838830 | 536769370 | 284232546 |

これらは対象process中心の測定であり、Harness/Videoを含む全システム負荷へ一般化しない。絶対上限/回帰許容差が未設定のqualityはINCONCLUSIVEのままとする。

## signalの導出範囲

| Signal | 実Evidenceが支える範囲 | 導出できないこと |
| --- | --- | --- |
| 再現性 | 同runのbehavioral_regressionでtrajectory_equal/actions_equal=true、Required PASS。Profile/Seedをprovenance付き接続 | 全state・全seed・Profile順序反転の決定性 |
| A1/A3 | 同Target fingerprint・Profile SHA、独立RunID、Required case/status map完全一致 | 性能品質PASS、全軌跡同一 |
| Fresh | 3個の独立extraction IDをenvironment/seriesで交差照合 | local PC上の実証 |
| START_QA | controllerで各Run1回、exit0 | setupを含む全手動操作ゼロ |
| Performance Regression | NOT_RUN/PERFORMANCE_LIMITS_NOT_DECLARED。JSONはversion/scopeのみ | performance_regression=false |
| 手動介入 | controller operation11、START_QA3、retry0、NOT_OBSERVED_BY_CONTROLLER | 全工程の介入不存在 |
| 非管理者 | 3RunともELEVATEDを観測 | standard userで全工程完走 |
| Offline | hosted_ci=true、local_windows_offline=NOT_VERIFIED | local完全offline |
| Persistent PATH | user/machineの値hash・型・存在がbefore/after一致 | local PC、Registry全体、Program Files全体の恒久無変更 |
| Registry全体 | registry_write_audit=NOT_RUN | 全write不存在 |

A1/A3の資源deltaも計算してJSONに保持した。許容差なしに性能回帰なし/PASSを作っていない。空のproduction residual_riskは、Management/Sales/local未知リスクの不存在を意味しない。

限定same-run再現性を別JSONへ接続し、固定mainのevaluatorで再評価した。3RunともreproducibilityはPASS、Management全体はNOT_RUN。元Resultと再評価を分離した。

## 閾値とGate意味論の仕様監査

[Issue #1](https://github.com/th060316-lgtm/fullautoQA/issues/1) C-1は計測、持続増加候補、前BaselineとのPerformance Regression、Profile単位の上限/許容差、計測不能を0/PASSにしないことを要求する。全Profileへ任意の絶対上限を設定する義務は本文に記載がない。

固定mainのmanagement_evaluator.py L78–92は6測定をrequired=True、L321–328は閾値欠落をINCONCLUSIVE、L162–167はRequired非PASSで全体を阻止する。**全Profileへの無条件の絶対閾値必須化は、正本にない追加MUSTと判断する。** これは仕様解釈であり、勝手にRequired Evidenceや設定済み違反を緩和する許可ではない。

計測availability・Evidence完全性・evaluator実行・資源quality・Stable採否を別に保持する汎用修正が整合する。未設定qualityをPASSにしない。設定済み閾値違反、明示required品質契約の不足、測定欠落は厳格に扱う。QA装置が正しくTarget品質FAILを検出したこととevaluator実行失敗も分ける。

固定mainのhq_evidence.pyから正確な_as_number/compare_thresholdをAST抽出し、隔離実行した。NaN対max1、1対maxNaN、+Infinity対min0の3例が全てTrue/within boundsを返した。これは非finite誤PASSの実バグである。Finalの実測値に非finiteが見つかったという主張ではない。

推奨negative testsは、値とbound双方のNaN/±Infinity/文字列nan・inf/bool/不正数、単位不一致、設定済み違反、required契約不足、欠落Evidence、run/target/profile不一致、evaluator例外である。閾値なしの観測coverage成功とquality INCONCLUSIVEを同時に保持することも検証する。

## 隔離・Rollback

Sourceは復元済みsubstrate+固定main95blob overlayを専用copyへ移した。pycacheを除く500ファイルで制御改変→差分検出→復元→全SHA一致、元Source不変を実証。監査対象4COREはGitHub固定mainのgit blob SHAと一致。管理・phase3・HQ対象58testsは隔離Sourceで全PASS。現仕様バグがテスト網を通る事実であり、バグ解消の証拠ではない。

全3RunのFinal Profileと生Result ZIPも専用copyで制御改変→復元SHA一致。Profile SHAは凍結Profileと一致。Source/Profile/Evidenceのbyte回復を、実ゲーム再実行や受入済みStable機能rollbackへ置換しない。

この再開監査ではCandidate package実体を独立検証していない。CANDIDATE_FREEZEはmetadataとして保持する。旧sessionのpackage検証申告を現在の実証へ再昇格させない。

GitHub固定mainのStable tree `0c57de0cfcd945f87bbdd1b793d7edb4436c9813` はREADME.mdのみ。実行可能Stable rollbackはNOT_RUN。現CandidateをStableと呼び替えて解消しない。

## 成果物・限界

[構造化監査JSON](management_evidence_audit.json) に観測値、provenance、A1/A3差分、再評価、rollback、実行test、未確認理由を保持する。Run別のreconstructed JSONとfrozen evaluator readbackは元Evidenceの上書きではない。

本監査の新規GitHub書込みは専用branchの報告ファイルだけ。ローカルWindows完全offline/nonadmin/Registry/PATH恒久無変更等は未実行のまま残る。Stable/Release/Issue closeを承認・実行していない。同一AI内の5専門視点で出力査読と読戻しを行い、外部第三者査読とは称さない。

