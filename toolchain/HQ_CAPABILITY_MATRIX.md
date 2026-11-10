# HQ Capability Matrix

優先度:
- **P0**: その系統の標準実務を成立させる基盤。
- **P1**: かなり頻繁に使う。案件によってはP0。
- **P2**: 特定案件・形式で有用。常時必須ではない。

## 共通基盤

| Tool | 優先度 | 主用途 |
| --- | --- | --- |
| Git for Windows | P0 | repository、branch、commit、差分、復旧 |
| VSCodium | P0 | コード・設定・Markdown編集 |
| WinPython 3.14 | P0 | Python実装、分析、QA補助、myAI |
| uv | P0 | Python環境・依存関係・CLI tool管理 |
| 7-Zip | P0 | ZIP/7z展開、外注受渡し、Evidence処理 |
| ripgrep | P0 | 大規模コード・資料横断検索 |
| SQLite tools | P1 | ローカル状態・試験DB・AI記憶/インデックス確認 |
| GitHub CLI | P1 | Issue/PR/Release/Actions等をローカルから扱う |
| Pandoc | P1 | Markdown/HTML/文書形式の変換 |

## ゲーム制作総本山

| Tool | 優先度 | 主用途 |
| --- | --- | --- |
| Godot 4.7.2 Stable | P0 | ゲーム実装・実機起動 |
| Node.js 26 LTS | P1 | Webゲーム、Tool、JS/TS |
| Temurin OpenJDK 21 LTS | P1 | Javaゲーム・Tool・OculiX |
| w64devkit | P1 | C/C++、GCC/GDB/Make/CMake/Ninja/NSIS |
| Krita | P1 | 2D、UI、テクスチャ、画像素材 |
| Inkscape | P1 | SVG、アイコン、ベクターUI |
| Audacity | P1 | 音声編集・効果音処理 |
| FFmpeg | P0 | 動画/音声変換、QA Failure Clip |
| ImageMagick | P1 | 画像変換、比較前処理、バッチ処理 |
| OBS Studio | P0 | 実機録画・Evidence |
| AutoHotkey v2 | P1 | Windows GUI入力・補助自動化 |
| OculiX 4.0 | P1 | 画像認識GUI自動化、画面ベースQA |
| Playwright | P1 | Browser/WebゲームE2E |
| Blender | 除外 | 今回はユーザー指定により導入しない |

## 管理総本山

| Tool | 優先度 | 主用途 |
| --- | --- | --- |
| WinPython + uv | P0 | 数量比較、ログ解析、データ処理 |
| Git / GitHub CLI | P0/P1 | 正本・履歴・Issue/PR確認 |
| ripgrep | P0 | 根拠箇所・設定・コード横断照合 |
| SQLite | P1 | 状態・ログ・DBの直接検査 |
| 7-Zip | P0 | ZIP成果・Evidence・外注返却の検査 |
| Pandoc | P1 | Report/Markdown/HTML等の変換 |
| FFmpeg / ImageMagick | P2 | Evidence動画・画像の検査補助 |

## 営業総本山

| Tool | 優先度 | 主用途 |
| --- | --- | --- |
| Krita / Inkscape | P1 | 提示画像・UI素材・説明図 |
| Audacity / FFmpeg | P1 | 音声・動画素材 |
| ImageMagick | P1 | 媒体別画像変換・リサイズ |
| OBS Studio | P1 | デモ・紹介・実機記録 |
| Playwright | P1 | Web公開物・導線の動作確認 |
| Pandoc | P1 | 説明資料・公開用文書変換 |
| Git / VSCodium | P0 | 原稿・素材メタデータ・版管理 |

## myAI

| Tool | 優先度 | 主用途 |
| --- | --- | --- |
| WinPython 3.14 + uv | P0 | AIコード、MCP、解析、依存環境 |
| Ollama | P0 | ローカルLLM推論 |
| MCP Python SDK v2 | P0 | Governor/ChatGPT/ローカルAI連携基盤 |
| Git / GitHub CLI | P0/P1 | 正本、Issue/PR、モデル/Tool開発 |
| VSCodium | P0 | AI実装 |
| SQLite | P1 | ローカル記憶・状態・小規模検索DB |
| ripgrep | P0 | repository・Prompt・設定横断検索 |
| w64devkit | P2 | Python native extension/C++補助 |
| Node.js LTS | P1 | JS系MCP/Tool/UI |
| PyTorch | P1 | 自作モデル・GPU実験。公式Selectorから環境別導入 |
| FFmpeg / ImageMagick | P2 | multimodal前処理 |
| 7-Zip | P0 | モデル・成果・外注パッケージ |

## 判断

「Toolがあるから使う」ではなく、各案件の目的へ寄与するときだけ利用します。
同一機能を複数Toolで重複させる場合も、既存資産・再現性・作業時間を比較して選びます。
