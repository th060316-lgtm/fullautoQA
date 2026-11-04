# INTEGRATION_NOTES.md — Grok 側 (地上交通) との統合条件

> **本ファイルは統合の必須文書です。**
> MiniMax 側が追加した public な統合点と、Grok 側が満たすべき契約を正確に記載する。

---

## 0. 役割分担のおさらい

| 領域 | 担当 |
|---|---|
| タイル地上交通 / 道路 / 鉄道 / 地上 PathFinder / 地上接続 / 地上建設 UI | **Grok** |
| 船舶輸送 (港・航路・輸送) | MiniMax |
| 航空輸送 (空港・航空路・輸送) | MiniMax |
| AI 輸送会社 2社 / 競争による需要分配 | MiniMax |
| AI → 地上接続の要求境界 | MiniMax (Grok の API を呼ぶ側) |
| 戦争補給の陣営判定 / 戦後 cleanup | MiniMax |
| 輸送モード番号と接続リクエストの形式 | 共通 (`SHARED_INTEGRATION_CONTRACT.md`) |

モード番号 (変更しないこと):

```
0 = ROAD   1 = RAIL   2 = SHIP   3 = AIR
```

接続リクエストの概念形式 (変更しないこと):

```
company_id, mode, origin_settlement_id, destination_settlement_id
```

---

## 1. 【必須】Grok 側 ground provider の仕様

MiniMax 側は地上接続を **一切自前実装していない**。AI の地上接続要求は
`scripts/GroundTransportAdapter.gd` を経由して Grok 側 provider へ委譲する。

### 1-1. provider が実装すべきメソッド (4つ)

```gdscript
# Grok 側実装オブジェクト (Scripts/Classes/的任何名前でよい)
func can_build_ground_connection(
    company_id: int, mode: int, origin_id: int, destination_id: int) -> bool
    # → その地上接続を (：金・経路・予算の観点で) 建設可能か

func request_ground_connection(
    company_id: int, mode: int, origin_id: int, destination_id: int) -> int
    # → 成功: 作成された connection (Route) の id
    #   失敗: -1
    # 注意: 接続は「所有会社つき」で生成すること (Route.company_id = company_id)

func estimate_ground_build_cost(
    mode: int, origin_id: int, destination_id: int) -> float
    # → 地上接続の建設費見積り (AI の採算判断に使う)

func estimate_ground_length(
    mode: int, origin_id: int, destination_id: int) -> float
    # → 地上経路の長さ (px 相当)。AI の距離補正に使う
```

- `mode` は `0 (ROAD)` または `1 (RAIL)` のみが渡る。
- `origin_id` / `destination_id` は `WorldState.get_settlement(id)` で引ける settlement id。
- provider は **Script クラスでも、Object インスタンスでもよい**。
  `has_method()` で存在判定し、無いメソッドは MiniMax 側の Mock にフォールバックする。

### 1-2. 接続方法

`AICompetitionSystem` に次のメソッドがある。ゲーム起動時に1回だけ呼べばよい。

```gdscript
# GameController._ready() 等で:
game.ai_system.configure_ground_provider(grok_provider_object)
```

- 実装が未提供 (null) の場合は **Mock が自動で使われる**。
  Mock は「直線距離ベースの仮接続」を作るだけで、地上タイル PathFinder は持たない。
  統合前テスト用であり、実運用では必ず provider を設定すること。
- provider 設定/解除は随时可能: `configure_ground_provider(null)` で Mock に戻せる。

### 1-3. Mock の仕様 (統合前テスト用)

`GroundTransportAdapter` の内部 Mock:

| 項目 | Mock の挙動 |
|---|---|
| `can_build_ground_connection` | 両端が active で補給基地でなければ true |
| `request_ground_connection` | `WorldState.create_route(from, to, mode, company_id)` を呼ぶ。失敗時 -1 |
| `estimate_ground_build_cost` | `基本建設費 + 距離 × 0.04 (RAIL は 0.02)` |
| `estimate_ground_length` | 2都市間の直線距離 (px) |
| 記録 | `request_log` に `{day, company_id, mode, origin_id, destination_id, mock}` を蓄積 (診断用) |

---

## 2. 【必須】輸送エンジン呼び出し hook

MiniMax 側は **全モードの貨物移動** を `TransportSystem.process_transport()` が一括処理する。
地上 (ROAD/RAIL) もこの中を通る (競合配分がモードをまたぐため)。
地上経路探索・タイル敷設は Grok 側だが、「誰がどれだけ運ぶか」はここで処理する。

### 2-1. 現状の呼び出し位置

`scripts/EconomySystem.gd`:

```gdscript
func process_day() -> void:
    _update_demands()
    if transport_system != null:
        transport_system.process_transport()   # ← MiniMax の輸送エンジン (競合込み)
    else:
        _process_transport()                   # ← 従来経路 (フォールバック)
    _apply_growth()
    _maybe_change_economy_state()
```

`transport_system` は `GameController._ready()` で
`economy.transport_system = transport_system` として注入される。

### 2-2. Grok 側が EconomySystem を書き換える場合

`EconomySystem` を置き換える・大きく改変する場合は、
**1日処理の中で `TransportSystem.process_transport()` をちょうど1回呼ぶ** こと。
呼び忘れ・二重呼び出しはいずれも需 要配分の誤りになるので注意。

```gdscript
# GameController 側の保険フックも存在する (二重呼び出し防止):
var ts = economy.get("transport_system")
if ts == null and transport_system != null:
    transport_system.process_transport()
```

> `economy.get("transport_system")` は EconomySystem に同プロパティが無い場合も null を返すため、
> Grok 側が EconomySystem を完全置換しても例外は出ない。

### 2-3. TransportSystem が public に使う WorldState / Route API

| 呼び出し先 | 用途 |
|---|---|
| `world.routes` | 全接続の走査。`Route.active` / `type` / `company_id` / `from_id` / `to_id` / `service_score` / `market_share` / `remaining_capacity()` / `carried_*` を読む |
| `world.settlements` | 都市の需要・供給力・景气・成長反映 |
| `world.get_settlement(id)` | 接続端点の解決 |
| `world.add_company_revenue(company_id, amount)` | 会社別収益計上 |
| `world.pay_operating_cost(company_id, amount)` | 会社別運行費計上 |
| `world.money` | プレイヤー会社の資金 (company_id = 0) |

Grok 側が Route にフィールドを追加/改名する場合は、
`company_id` / `service_score` / `market_share` / `carried_*` / `remaining_capacity()` の
**名前と役割を維持** すること。

---

## 3. 【要確認】WorldState.create_route() の重複判定変更

MiniMax 側は競爭を成立させるため、重複判定を 다음과に変更した。

| | 判定 |
|---|---|
| 従来 (Grok) | 同一都市間に **どちらの会社の接続でも** あれば拒否 |
| MiniMax | 同一都市間 × **同一会社** の接続があれば拒否 (別会社なら並立可) |

- 既存テスト「Duplicate route between same nodes is rejected」は同一会社どうしのため引き続き PASS。
- **影響**: プレイヤーは同一都市対に道路と鉄道を同時に張れない (1社1接続)。
  別会社 (AI) は同じ都市対に並立できる = これが競爭の成立条件。
- 変えたい場合は `WorldState.create_route()` の重複判定ブロックのみ差し替えればよい。

料金関係: 建設費は `TransportModeConfig.build_cost()` を単一出典にしている。
ROAD=40 / RAIL=180 は従来値と同一 (Grok 既存の費用テストに影響なし)。

---

## 4. 【要確認】補給基地のデータ契約

### 4-1. Settlement のフィールド

| フィールド | 意味 |
|---|---|
| `support_nation_id: int` | **新规格**。補給基地が支援する国家 id (-1 = 未設定) |
| `supply_base_owner_nation: int` | 旧名。`support_nation_id` への **読み書きエイリアス** (値は常に同一) |
| `is_supply_base: bool` | 補給基地か |
| `nation_id` | 補給基地は中立 (-1)。国力に含まれない (従来どおり) |

判定ロジック (唯一の実装場所: `WarSupplyPolicy.is_valid_supply_source()`):

```
供給元都市.nation_id == 補給基地.support_nation_id  のときだけ有効
```

- 旧実装 (Grok) は `supply_base_owner_nation` を参照して条件チェックをしていなかったため、
  敵国都市からの補給でも war_bonus _ft っていた。**この判定の追加が必須**。

### 4-2. WorldState のフィールド

| フィールド | 意味 |
|---|---|
| `war_supply_base_ids: Array` | **新规格**。両軍分の補給基地 id |
| `war_supply_base_id: int` | 従来フィールド。両軍制霸時に **A軍基地** を指す (後方互換) |
| `war_supply_log_cooldown: Dictionary` | 無効補給ログの抑止用 (キー: `sourceId:baseId`) |

### 4-3. 戦後 cleanup

`WarSupplyPolicy.finalize_bases()` が以下を行う。

1. 両基地を `active = false` / `support_nation_id = -1` にする。
2. 基地に接続した connection に `obsolete = true` を立てる (= 戦後不要 connection)。
3. 基地実体を `world.settlements` から除去する (一時データ無制限増殖の防止)。
4. `WorldState.purge_inactive_supply_bases()` で残存した不活性基地を掃除する。

接続線 (Route) は **削除しない**。プレイヤーが判断して撤去する (requirement: 撤去判断できる状態)。

---

## 5. 【要確認】Route に追加したフィールド

```gdscript
var company_id: int = 0              # 0 = プレイヤー, 1.. = AI
var speed: float                     # px/day 相当 (競合スコアに使用)
var operating_cost: float            # 1日あたり運行費
var service_score: float             # 競合スコア (CompetitionResolver が毎 tick 設定)
var market_share: float              # 自市場における需要シェア (0..1)
var daily_revenue: float
var daily_operating_cost: float
var profit: float                    # daily_revenue - operating_cost (AI 撤退判断に使用)
var unprofitable_days: int
var obsolete: bool                   # 戦後不要 connection
var path_length: float               # SHIP = 海上経路長, AIR = 直線距離
var path_points: PackedVector2Array  # SHIP の描画用海上経路
```

`enum RouteType { ROAD, RAIL, SHIP, AIR }` に拡張した (番号は共通契約どおり 0/1/2/3)。

---

## 6. 【任意】UI の統合 (Main.tscn へ移す場合)

MiniMax の追加 UI は **実行時に動的生成** している (`scripts/MiniMaxUI.gd`,
`scripts/TransportOverlay.gd`)。Main.tscn / UIController.gd は無改変のまま統合できる。

Main.tscn 側へ固定したい場合は:

- `TransportOverlay` を `UI/MapView` の直後 (兄弟) に `Control` として配置し、
  `game` プロパティを `GameController` に差し、`mouse_filter = IGNORE` を設定する。
- `MiniMaxUI` は `UI/RightPanel` に `RichTextLabel` を1つ追加し、TopBar に `Button` を4つ追加する。
  ボタンとメソッドの対応は下表。

| ボタン文言 | キー | 呼び出すメソッド |
|---|---|---|
| 船舶航路(Y) | `build_ship` | `game.start_build_ship()` |
| 航空路(U) | `build_air` | `game.start_build_air()` |
| 港(P) | `build_port` | `game.build_port_selected()` |
| 空港(A) | `build_airport` | `game.build_airport_selected()` |

---

## 7. 【任意】水路マップの差し替え

`scripts/WaterMap.gd` は以下の定数で海と海岸線を定義している。

| 項目 | 値 |
|---|---|
| `WORLD_RECT` | `Rect2(0, 0, 960, 720)` |
| `CELL_SIZE` | 12.0 px (グリッド 80×60) |
| `land_polygon()` | 内側 = 陸 のポリゴン (12点) |
| `coast_polygon()` | 海岸線 (折れ線) |
| `TransportModeConfig.PORT_COAST_LIMIT` | 150.0 px (この距離以内なら港建設可) |

Grok 側が正式マップ (タイル/画像) を持つようになった場合は、
`WaterMap.is_water()` / `distance_to_coast()` の判定部分を
正式マップの判定へ差し替えるだけでよい。港可否・海上経路の呼び出し側はそのまま使える。

---

## 8. 統合チェックリスト

- [ ] `GameController._ready()` で `economy.transport_system = transport_system` が入っているか
- [ ] `ai_system.configure_ground_provider(<Grok provider>)` を呼んでいるか
- [ ] Grok provider が 1-1 の 4 メソッドを実装しているか (名称・引数・戻り値の一致)
- [ ] `request_ground_connection` が `Route.company_id` に要求会社を設定しているか
- [ ] EconomySystem を置換した場合に `TransportSystem.process_transport()` を1回だけ呼んでいるか
- [ ] `WorldState.create_route()` の重複判定が「同一都市間 × 同一会社」になっているか
- [ ] `Settlement.support_nation_id` が war_bonus 判定に使われているか (旧ロジックだと旧バグが復活する)
- [ ] `world.war_supply_base_ids` を2基分維持しているか
- [ ] `Route.obsolete` が戦後不要 connection の表示・撤去判断に使われているか
