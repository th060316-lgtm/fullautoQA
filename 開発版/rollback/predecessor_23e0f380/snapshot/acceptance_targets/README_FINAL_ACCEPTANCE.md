# Windows最終受入

`RUN_FINAL_ACCEPTANCE.cmd`、`launch_final_series.ps1`、`FINAL_CANDIDATE_IDENTITY.json` と検証済みCandidate ZIPを同じフォルダーへ置きます。分割保存された場合は、ZIPの代わりに `FINAL_CANDIDATE_PARTS.json` と全 `candidate.partNNN` を同じフォルダーへ置きます。CMDが各partと結合後ZIPのSize/SHAを確認します。Python等の追加インストールは不要です。

Windowsの非管理者セッションで外部ネット接続を切り、`RUN_FINAL_ACCEPTANCE.cmd` を一度実行してください。同梱Pythonが `FINAL_SERIES_PLAN.json` の凍結系列を処理し、毎回別の空フォルダーへ展開して `START_QA.cmd` を起動します。通常の最終系列は PoliticsTrasport → codegeas → PoliticsTrasport です。初回ゲームはLogic Prototypeとして扱い、未実装のSave/LoadをPASSにはしません。

完了後、表示されたEvidenceフォルダーを渡してください。各Runの完全な `RESULT_FOR_CHATGPT.zip`、Target準備証拠、独立RunID・fresh extraction ID、機械比較 `SERIES_COMPARISON.json` を保持します。検証済みEvidenceを別保存してから、この処理自身が作った成功時の一時展開のみ削除します。失敗した展開は調査用に残ります。

技術的PASS、独立3総本山の最終判断、Human test、完全offlineの実施証明、Product Acceptance、Stable、Releaseは別の状態です。処理は権限・hosted/localの環境情報を記録しますが、offlineや人間評価の証拠を自動で捏造しません。実際に非管理者・offlineで実行したかは受渡し時に添えてください。

既存Code Geass Runは過去診断Evidenceとして保持され、最終3Runには算入されません。ゲーム正本repoと安定版をこの手順で変更することはありません。
