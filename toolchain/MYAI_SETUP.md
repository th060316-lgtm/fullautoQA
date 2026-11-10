# myAI Local Development Baseline

## 基本線

myAI の一般開発環境は、fullautoQA の固定Runtimeとは別系統で管理します。

推奨構成:

1. **WinPython 3.14.10**
   - Portable。
   - 一般AI/Python開発の標準。
   - Python 3.15を無条件な標準にしない。Windows向け主要AIライブラリの対応状況を優先する。

2. **uv**
   - Python version / virtual environment / dependency / CLI tool管理。
   - Global site-packagesへ大量投入せず、projectごとに環境を分ける。

3. **Ollama**
   - ローカルLLM推論。
   - Model本体はGit repositoryへcommitしない。
   - model storageの場所はMACHINE_PATHS等の機械設定で扱う。

4. **Official MCP Python SDK v2**
   - Governor、ローカルLLM、外部Host/Toolを標準化して接続する基盤。
   - Python packageとしてproject環境へ導入する。
   - 例: `uv add "mcp[cli]"`

5. **Git + GitHub CLI**
   - Gitはコード/正本。
   - GitHub CLIはIssue/PR/Release/Actions等のGit外メタデータをローカルAIから取得するときの候補。
   - 認証情報はrepositoryへ保存しない。

6. **SQLite + ripgrep**
   - SQLite: 小規模な永続状態・索引・実験DB。
   - ripgrep: 大量のコード/Prompt/設定/Reportから高速に根拠箇所を探す。

7. **PyTorch**
   - 自作モデルやGPU学習/推論が必要な案件で導入。
   - CUDA wheelはGPU/driver/PyTorch releaseによって変わるため、この共通Toolchainでは固定しない。
   - PyTorch公式のWindows selectorから、その時点のStableと対応CUDAを選ぶ。

8. **Node.js 26 LTS**
   - JS/TS実装、Web UI、JS系MCP/Tool用。

9. **w64devkit**
   - C/C++ native extension、低レベルTool、ビルド問題の再現が必要な場合に使う。

## repositoryへ置かないもの

- API key / token / password / private key
- Ollama model本体
- 巨大なPython package cache
- CUDA toolkit一式
- 一時生成物・model checkpoint
- machine固有の絶対パスを含む個人設定

## 分離原則

- fullautoQAの再現性用固定Runtime: QA正本として維持。
- myAI一般開発環境: 新版を利用可能。
- Project固有依存: project自身のlockfile/manifestで固定。
- PC固有path: MACHINE_PATHS.json等へ隔離。

この構成により、一般開発を更新しても fullautoQA の既存受入証拠を暗黙に書き換えません。
