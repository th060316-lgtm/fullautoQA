# 3総本山 + myAI Windows Toolchain

このディレクトリは、ゲーム制作総本山・管理総本山・営業総本山・myAI が Windows PC 上で実務を行うための共通ツール入口です。

## 目的

- 新PCで必要な開発・制作・QA・AI・資料処理ソフトを一か所から確認できるようにする。
- fullautoQA の既存QA Runtimeと、一般開発用Toolchainを混同しない。
- 特定ユーザー名、特定ドライブ、固定絶対パスへ依存しない。
- 可能な限り Portable / ZIP / self-contained を優先し、管理者権限・Registry・恒久PATH変更を前提にしない。
- 実バイナリをGitへ無制限に積み増さず、重いもの・再配布条件が不明確なものは公式配布元へのリンクを正本とする。

## 明示除外

- Blender: 今回のユーザー指定により導入対象外。

## 既存 fullautoQA との境界

Issue #1 が要求している既存 Runtime / Candidate / Evidence / Stable 条件は、このToolchain追加だけでは変更しません。
特に fullautoQA が現在使用している固定Runtimeを、一般開発用の新しいバージョンへ勝手に差し替えません。

一般開発側の推奨と、QA再現性のための固定版は別物です。

## ファイル

- `TOOL_CATALOG.json`: ソフト一覧・用途・優先度・公式配布元。
- `HQ_CAPABILITY_MATRIX.md`: 3総本山とmyAIごとの利用目的。
- `OPEN_DOWNLOADS.cmd` / `OPEN_DOWNLOADS.ps1`: 公式配布ページをまとめて開く。インストールはしない。
- `VERIFY_ENVIRONMENT.ps1`: PATHまたはMACHINE_PATHS.jsonに登録された実体を確認する。設定変更はしない。
- `MACHINE_PATHS.example.json`: PC固有の実体パスを論理IDへ割り当てる雛形。
- `MYAI_SETUP.md`: myAI向けのAI/MCPローカル開発基盤。

## 推奨運用

1. `OPEN_DOWNLOADS.cmd` を実行し、必要な公式配布ページを開く。
2. Portable版があるものは任意のTool rootへ展開する。
3. `MACHINE_PATHS.example.json` を `MACHINE_PATHS.json` にコピーし、自分の実体パスだけ記録する。
4. `VERIFY_ENVIRONMENT.ps1 -Config .\MACHINE_PATHS.json` で存在確認する。
5. 各プロジェクトは物理パスではなくTool IDを参照する。

このブランチ自体は fullautoQA Stable、Product Acceptance、人間試験、3総本山GateのPASS証拠ではありません。
