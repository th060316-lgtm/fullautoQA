extends RefCounted

## 統合前検証用の擬似 Grok provider。
## Grok 側が実装する provider と同じシグネチャを持ち、
## 「境界が provider へ委譲すること」を確認するために使う。
## 本体は scripts/GroundTransportAdapter.gd の仕様コメントを参照。

var world: WorldState = null
var request_count: int = 0
var can_build_result: bool = false

func can_build_ground_connection(_company_id: int, _mode: int, _origin_id: int, _destination_id: int) -> bool:
	return can_build_result

func request_ground_connection(_company_id: int, _mode: int, _origin_id: int, _destination_id: int) -> int:
	request_count += 1
	return -1

func estimate_ground_build_cost(_mode: int, _origin_id: int, _destination_id: int) -> float:
	return 999.0

func estimate_ground_length(_mode: int, _origin_id: int, _destination_id: int) -> float:
	return 999.0
