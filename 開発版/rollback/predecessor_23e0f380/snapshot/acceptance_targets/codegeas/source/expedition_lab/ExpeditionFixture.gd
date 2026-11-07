extends RefCounted

const SEED := 20261022
const MAP_RECT := Rect2(0, 0, 1280, 800)
const EXTRACTION_PRIMARY := Vector2(110, 690)
const EXTRACTION_BACKUP := Vector2(110, 170)

# Physical blockers used by the prototype navigation. The hospital itself remains
# traversable so the abstracted interior objectives can be reached.
const BLOCKED_RECTS := [
	Rect2(445,315,300,105),
]

static func build() -> Dictionary:
	return {"seed":SEED,"map_rect":MAP_RECT,"extraction_primary":EXTRACTION_PRIMARY,"extraction_backup":EXTRACTION_BACKUP,"blocked":BLOCKED_RECTS.duplicate(),
		"friendlies":[
			{"id":"hero","name":"主人公","kind":"human","hp":100.0,"position":Vector2(145,680),"meta":{"role":"Follow","speed":88.0}},
			{"id":"scout","name":"偵察担当","kind":"human","hp":100.0,"position":Vector2(175,650),"meta":{"role":"Scout","speed":96.0,"sensor":1.35}},
			{"id":"medic","name":"衛生・整備担当","kind":"human","hp":100.0,"position":Vector2(175,710),"meta":{"role":"Medic","speed":82.0}},
			{"id":"friendly_kmf","name":"汎用KMF F-01","kind":"kmf","hp":180.0,"position":Vector2(230,680),"meta":{"role":"Guard","speed":155.0,"sensor":1.7,"pilot_id":"","boarded":false}},
		],
		"enemies":[
			{"id":"patrol_a","name":"東部巡回兵","kind":"human","hp":80.0,"position":Vector2(870,430),"patrol":[Vector2(800,330),Vector2(1040,520)]},
			{"id":"patrol_b","name":"病院警戒兵","kind":"human","hp":80.0,"position":Vector2(620,190),"patrol":[Vector2(530,170),Vector2(760,230)]},
			{"id":"hostile_kmf","name":"敵汎用KMF H-02","kind":"kmf","hp":180.0,"position":Vector2(1080,170),"patrol":[Vector2(1020,120),Vector2(1160,300)]},
		],
		"loot":{"medical_cache":{"position":Vector2(585,135),"taken":false},"spare_parts":{"position":Vector2(940,610),"taken":false},"food_crate":{"position":Vector2(345,390),"taken":false}},
		"intel":{"hospital_terminal":{"position":Vector2(650,120),"examined":false},"radio_wreck":{"position":Vector2(450,515),"examined":false},"resident_report":{"position":Vector2(300,260),"examined":false}},
		"rescue":{"civilian_01":{"position":Vector2(710,165),"status":"waiting","important":true}},
		"cover":[Rect2(290,300,150,80),Rect2(500,350,180,70),Rect2(190,120,170,120),Rect2(540,70,240,135)],
		"narrow_route":Rect2(360,520,310,70),"open_route":Rect2(760,300,430,210)}
