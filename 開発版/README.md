# FullAutoQA 開発版

## 欠落のない保存済み最新版：v0.3.3

`complete_v033/` にRuntime/Payloadを含む完全Candidateを可逆分割して収録しています。リポジトリ全体をDownload ZIPで取得・展開するかcloneし、`complete_v033/JOIN_COMPLETE.cmd`を一度起動してください。全128ブロックと結合後ZIPのサイズ・SHA-256を自動検査します。

復元された `FullAutoQA_v0.3.3_CANDIDATE.zip` を展開して利用します。詳細は `complete_v033/README_JA.md`。移送前に全3,840ファイル、10系統Payload、全ZIP Entry CRCを検査しました。

ファイル一式の完全性と製品の受入は別です。製品受入はHOLD、実ゲームにはProfile/Target設定が必要です。安定版へ昇格していません。

## 復旧Sourceも保持

`transfer/FullAutoQA_Recovery_Source_20261102.zip` は後続修正Source原本、`source/` はコード閲覧用抜粋です。Source原本はRuntime未同梱・CORE Manifest未再発行で、完全実行用Candidateの代替ではありません。
