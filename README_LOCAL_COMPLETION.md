# Local Final Completion

GitHub Actions の artifact 容量を完成経路から外し、Windows実機で現在の凍結Sourceから Candidate を再構築し、その同一bytesで Source regression → START_QA selftest → PoliticsTrasport → codegeas → PoliticsTrasport を実行するための入口です。

## 実行

1. GitHub の main 一式をWindowsへ取得・展開する。部分取得ではなく、開発版/complete_v033/blocks、開発版/transfer/FullAutoQA_Recovery_Source_20261102.zip、開発版/source、開発版/acceptance_targets を含める。
2. 管理者として実行しない。通常のWindowsユーザーセッションを使う。
3. 完全offline条件も同時に確認する場合は、実行前に外部ネットワークを切断する。このrunner自身はネットワークを要求しないが、「インターネットへ到達不能だった」ことを自動で断定はしない。
4. リポジトリ直下の RUN_LOCAL_COMPLETION.cmd を1回実行する。
5. 成功時は LOCAL_FINAL_ACCEPTANCE_<RunTag> が残る。少なくとも LOCAL_COMPLETION_SUMMARY.json、ABA_EVIDENCE/SERIES_COMPARISON.json、3個の RESULT_FOR_CHATGPT.zip、SELFTEST_RESULTS、candidate_build/PHASE3_CANDIDATE_IDENTITY.json を保存する。

## 成功条件

runnerは以下を順番固定で実行し、途中FAILなら後工程へ進みません。

donor JOIN → current Source再構築 → Candidate build/Size/SHA確認 → bundled Source regression → fresh START_QA.cmd -SelfTest → fresh A→B→A → 3 Result ZIP確認 → PATH readback。

技術系列PASSは Human test、Product Acceptance、Stable、Release の自動PASSを意味しません。失敗した場合は LOCAL_FINAL_ACCEPTANCE_* を削除せず、そのまま技術デバッグ入力として使用してください。
