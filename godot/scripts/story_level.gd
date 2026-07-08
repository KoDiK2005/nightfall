extends Node3D
## Сюжетный режим, уровень 1 ("Отрицание") -- порт story.c
## (build_ground_floor/build_upper_floor/story_update). Дом рисуется на той
## же плоской сетке, что и подземелье (WallGridMap/FloorGridMap, шаг 1
## клетка = 1 метр), только вместо процедурных комнат -- прописанный вручную
## план. "Второй этаж" -- отдельное крыло той же карты, вынесенное на восток
## (движок не умеет по-настоящему многоуровневые Z-этажи, см. story.c) --
## связано с первым лестницей-триггером в холле.

const MW := 56
const MH := 34
const WALL_ITEM := 0
const FLOOR_ITEM := 1
const WALL_LAYERS := 2   # двухэтажная высота стен -- две клетки GridMap друг на друге

const DOOR_POS := Vector3(14.5, 0, 13.5)
const MOTHER_POS := Vector3(14.5, 0, 14.6)
const SPAWN_POS := Vector3(14.5, 0.1, 2.5)
const KID1_POS := Vector3(46.0, 0.1, 3.0)

const STAIRS_UP := Vector2(15.5, 20.5)
const STAIRS_UP_TO := Vector3(43.5, 0.1, 6.5)
const STAIRS_DN := Vector2(36.5, 6.5)
const STAIRS_DN_TO := Vector3(15.5, 0.1, 22.5)
const STAIRS_TRIGGER_DIST := 1.0
const STAIRS_COOLDOWN := 1.5

const MEMORY_Z := [4.0, 7.0, 10.0]
const MEMORY_TEXTS := [
	["МАТЬ КРИЧИТ ИЗ-ЗА РАЗБИТОЙ ТАРЕЛКИ.", "ЭТО НЕ ЗЛОСТЬ. ЭТО ВОСПИТАНИЕ.", "У ВСЕХ ТАК В СЕМЬЕ."],
	["ОТЕЦ СНОВА ЗАСНУЛ ПЕРЕД ТЕЛЕВИЗОРОМ.", "БУТЫЛКА НА ПОЛУ -- ОБЫЧНОЕ ДЕЛО.", "ЗНАЧИТ ВСЁ НОРМАЛЬНО."],
	["Я ЗАКРЫВАЮ ДВЕРЬ И НЕ ПЛАЧУ.", "НАДО ПРОСТО ВЫРАСТИ.", "ЗАБЫТЬ ОБ ЭТОМ."],
]
const MOTHER_LINES := [
	"ГДЕ ТЫ ШЛЯЛСЯ?",
	"ОПЯТЬ ОДНИ ПРОБЛЕМЫ ИЗ-ЗА ТЕБЯ.",
	"МАРШ В КОМНАТУ. НЕ ПОПАДАЙСЯ МНЕ НА ГЛАЗА.",
]
const MOTHER_LINE_DUR := 3.5
const MEMORY_POPUP_DUR := 6.0
const APPROACH_SPEED_MULT := 0.3

enum Phase { APPROACH, CONFRONT, AFTERMATH }
var phase: Phase = Phase.APPROACH
var memory_seen: Array = [false, false, false]
var mother: Node3D = null
var mother_line_idx: int = 0
var mother_line_timer: float = 0.0
var stairs_cooldown: float = 0.0

var map: Array = []   # map[y][x] == true, если клетка открыта (не стена)
var house_built := false

@onready var player: CharacterBody3D = $"../Player"
@onready var subtitle: CanvasLayer = $"../StorySubtitle"
@onready var wall_map: GridMap = $"../WallGridMap"
@onready var floor_map: GridMap = $"../FloorGridMap"
@onready var house_props: Node3D = $HouseProps
@onready var world_env: WorldEnvironment = $"../WorldEnvironment"
@onready var dir_light: DirectionalLight3D = $"../DirectionalLight3D"

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	GameState.mode_changed.connect(_on_mode_changed)
	visible = GameState.mode == GameState.Mode.STORY

func _unhandled_input(event: InputEvent) -> void:
	if GameState.mode != GameState.Mode.STORY or GameState.state != GameState.State.PLAY:
		return
	if event is InputEventAction and event.action == "interact" and event.pressed:
		skip_line()

func _on_mode_changed(new_mode: GameState.Mode) -> void:
	visible = new_mode == GameState.Mode.STORY
	set_process(visible)
	set_physics_process(visible)

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY and GameState.mode == GameState.Mode.STORY:
		_start_denial()

## -------------------------------------------------------------- геометрия

func is_open(x: int, y: int) -> bool:
	if x < 0 or x >= MW or y < 0 or y >= MH:
		return false
	return map[y][x]

func _carve(x0: int, y0: int, x1: int, y1: int) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x > 0 and x < MW - 1 and y > 0 and y < MH - 1:
				map[y][x] = true

func _wall_ring(x0: int, y0: int, x1: int, y1: int) -> void:
	for x in range(x0, x1 + 1):
		map[y0][x] = false
		map[y1][x] = false
	for y in range(y0, y1 + 1):
		map[y][x0] = false
		map[y][x1] = false

func _door_gap(x: int, y: int) -> void:
	map[y][x] = true

## порт build_ground_floor (story.c): тамбур, бойлерная, холл с лестницей,
## гостевой санузел, гостевая спальня/кабинет, кухня-гостиная одним пространством.
func _build_ground_floor() -> void:
	_wall_ring(8, 13, 32, 31)
	_wall_ring(12, 13, 16, 16)
	_wall_ring(17, 13, 20, 16)
	_wall_ring(12, 17, 16, 22)
	_wall_ring(8, 17, 11, 20)
	_wall_ring(8, 21, 14, 27)

	_door_gap(14, 13)
	_door_gap(16, 14); _door_gap(17, 14)
	_door_gap(14, 16); _door_gap(14, 17)
	_door_gap(16, 18); _door_gap(16, 19); _door_gap(16, 20)
	_door_gap(11, 18); _door_gap(12, 18)
	_door_gap(13, 21); _door_gap(13, 22)

## порт build_upper_floor: отдельное крыло восточнее, связано только лестницей.
func _build_upper_floor() -> void:
	_wall_ring(34, 1, 53, 12)
	_wall_ring(35, 1, 43, 5)
	_wall_ring(44, 1, 48, 5)
	_wall_ring(49, 1, 53, 5)
	_wall_ring(35, 7, 40, 11)
	_door_gap(39, 5)
	_door_gap(46, 5)
	_door_gap(51, 5)
	_door_gap(37, 7)

func _paint_region(x0: int, y0: int, x1: int, y1: int) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if is_open(x, y):
				floor_map.set_cell_item(Vector3i(x, 0, y), FLOOR_ITEM)
			else:
				var neighbours_open: bool = is_open(x + 1, y) or is_open(x - 1, y) \
					or is_open(x, y + 1) or is_open(x, y - 1)
				if neighbours_open:
					for layer in range(WALL_LAYERS):
						wall_map.set_cell_item(Vector3i(x, layer, y), WALL_ITEM)

## Тёплая "домашняя" палитра стен/пола вместо серого камня подземелья
## (порт bwall/bfloor из story_start_denial в story.c) и уличное освещение:
## сюжетный двор -- это день, а не тёмный склеп, так что небо/направленный
## свет держим включёнными (endless-режим их гасит, story возвращает).
func _setup_house_look() -> void:
	var wall_mat: StandardMaterial3D = load("res://resources/wall_material.tres")
	var floor_mat: StandardMaterial3D = load("res://resources/floor_material.tres")
	wall_mat.albedo_color = Color(0.52, 0.44, 0.34)
	floor_mat.albedo_color = Color(0.34, 0.26, 0.19)
	if dir_light:
		dir_light.visible = true
	if world_env and world_env.environment:
		var env := world_env.environment
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.15, 0.14, 0.16)
		env.ambient_light_energy = 0.5
		env.fog_enabled = false

func _build_house() -> void:
	_setup_house_look()
	map.clear()
	for _y in range(MH):
		var row: Array = []
		row.resize(MW)
		row.fill(false)
		map.append(row)

	_carve(1, 1, MW - 2, MH - 2)
	_build_ground_floor()
	_build_upper_floor()

	wall_map.clear()
	floor_map.clear()
	_paint_region(8, 13, 32, 31)
	_paint_region(34, 1, 53, 12)

	for child in house_props.get_children():
		child.queue_free()
	_place_roof()
	_place_ground_floor_furniture()
	_place_upper_floor_furniture()
	house_built = true

func _prop(pos: Vector3, size: Vector3, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	mesh.position = pos
	house_props.add_child(mesh)

## плоская крыша-заглушка над каждым крылом -- проще ступенчатой из C-версии,
## но закрывает вид на небо изнутри дома.
func _place_roof() -> void:
	_prop(Vector3(20.0, 2.15, 22.0), Vector3(25.0, 0.3, 19.0), Color(0.30, 0.16, 0.13))
	_prop(Vector3(43.5, 2.15, 6.5), Vector3(20.0, 0.3, 12.0), Color(0.30, 0.16, 0.13))

## подмножество place_ground_floor_furniture (story.c) -- по предмету на
## комнату вместо полного списка, для узнаваемости планировки.
func _place_ground_floor_furniture() -> void:
	_prop(Vector3(15.3, 0.65, 13.6), Vector3(1.0, 1.3, 0.36), Color(0.32, 0.22, 0.16))    # шкаф в тамбуре
	_prop(Vector3(18.4, 0.55, 14.4), Vector3(0.6, 1.1, 0.6), Color(0.42, 0.42, 0.44))     # котёл
	for i in range(6):   # лестница наверх -- растущие ступени
		_prop(Vector3(15.3, (0.14 + i * 0.16) * 0.5, 18.4 + i * 0.35), Vector3(0.9, 0.14 + i * 0.16, 0.32), Color(0.36, 0.28, 0.20))
	_prop(Vector3(9.3, 0.19, 18.3), Vector3(0.36, 0.38, 0.4), Color(0.75, 0.75, 0.75))    # унитаз
	_prop(Vector3(9.6, 0.13, 25.3), Vector3(2.0, 0.26, 1.1), Color(0.42, 0.36, 0.28))     # кровать гостевой
	_prop(Vector3(12.7, 0.23, 22.6), Vector3(0.84, 0.46, 0.64), Color(0.36, 0.26, 0.18))  # стол
	_prop(Vector3(20.0, 0.25, 15.6), Vector3(1.8, 0.5, 1.1), Color(0.42, 0.30, 0.22))     # кухонный остров
	_prop(Vector3(26.0, 0.21, 15.5), Vector3(1.7, 0.42, 1.7), Color(0.40, 0.30, 0.22))    # обеденный стол
	_prop(Vector3(27.0, 0.21, 26.0), Vector3(2.6, 0.42, 1.1), Color(0.30, 0.22, 0.30))    # диван
	_prop(Vector3(27.0, 0.25, 28.0), Vector3(1.1, 0.5, 0.36), Color(0.18, 0.16, 0.16))    # ТВ-тумба

## подмножество place_upper_floor_furniture (story.c).
func _place_upper_floor_furniture() -> void:
	_prop(Vector3(38.0, 0.14, 3.4), Vector3(2.4, 0.28, 1.2), Color(0.40, 0.30, 0.30))     # кровать мастер-спальни
	_prop(Vector3(41.3, 0.65, 2.4), Vector3(0.6, 1.3, 0.7), Color(0.30, 0.22, 0.18))       # гардероб
	_prop(Vector3(KID1_POS.x, 0.13, KID1_POS.z + 0.5), Vector3(1.7, 0.26, 0.9), Color(0.40, 0.34, 0.26))  # кровать детская 1
	_prop(Vector3(46.6, 0.23, 2.3), Vector3(0.56, 0.46, 0.56), Color(0.42, 0.30, 0.20))    # стол детская 1
	_prop(Vector3(51.0, 0.13, 3.5), Vector3(1.7, 0.26, 0.9), Color(0.38, 0.30, 0.30))      # кровать детская 2
	_prop(Vector3(50.4, 0.23, 2.3), Vector3(0.56, 0.46, 0.56), Color(0.40, 0.28, 0.20))    # стол детская 2
	_prop(Vector3(39.0, 0.19, 8.4), Vector3(0.36, 0.38, 0.4), Color(0.75, 0.75, 0.75))     # унитаз санузла
	_prop(Vector3(36.6, 0.3, 10.3), Vector3(0.56, 0.6, 0.56), Color(0.68, 0.68, 0.70))     # стиральная машина

## -------------------------------------------------------------- сценарий

func _start_denial() -> void:
	if not house_built:
		_build_house()
	phase = Phase.APPROACH
	memory_seen = [false, false, false]
	stairs_cooldown = 0.0
	player.velocity = Vector3.ZERO
	player.global_position = SPAWN_POS
	player.rotation.y = 0.0
	player.stamina = 1.0
	player.exhausted = false
	player.hidden = false
	player.monster = null   # без монстра -- этап "Отрицание" тихий
	if mother:
		mother.visible = false
	subtitle.hide_line()

func _process(delta: float) -> void:
	if GameState.state != GameState.State.PLAY or GameState.mode != GameState.Mode.STORY:
		return
	match phase:
		Phase.APPROACH:
			_process_approach(delta)
		Phase.CONFRONT:
			_process_confront(delta)
		Phase.AFTERMATH:
			_process_aftermath(delta)

func _process_approach(_delta: float) -> void:
	# совсем медленный, тяжёлый шаг -- время прочитать всплывающие воспоминания
	player.story_speed_mult = APPROACH_SPEED_MULT
	var pz := player.global_position.z
	for i in range(MEMORY_Z.size()):
		if not memory_seen[i] and pz > MEMORY_Z[i] - 1.2 and pz < MEMORY_Z[i] + 1.2:
			memory_seen[i] = true
			subtitle.show_lines(MEMORY_TEXTS[i], MEMORY_POPUP_DUR)
	if player.global_position.distance_to(DOOR_POS) < 1.3:
		_begin_confront()

func _begin_confront() -> void:
	phase = Phase.CONFRONT
	player.story_speed_mult = 0.0
	if mother == null:
		mother = _make_mother()
		add_child(mother)
	mother.visible = true
	mother.global_position = MOTHER_POS
	mother_line_idx = 0
	mother_line_timer = MOTHER_LINE_DUR
	subtitle.show_lines([MOTHER_LINES[0]], MOTHER_LINE_DUR + 0.6)

func _process_confront(delta: float) -> void:
	mother_line_timer -= delta
	if mother_line_timer <= 0.0:
		mother_line_idx += 1
		if mother_line_idx >= MOTHER_LINES.size():
			_end_confront()
		else:
			mother_line_timer = MOTHER_LINE_DUR
			subtitle.show_lines([MOTHER_LINES[mother_line_idx]], MOTHER_LINE_DUR + 0.6)

func skip_line() -> void:
	if phase == Phase.CONFRONT:
		mother_line_timer = 0.0

func _end_confront() -> void:
	mother.visible = false
	player.story_speed_mult = 1.0
	player.global_position = KID1_POS
	phase = Phase.AFTERMATH
	subtitle.hide_line()

## герой уже наверху -- дом открыт для свободного обхода, включая лестницу
## между этажами (в обе стороны, с коротким "остыванием" после перехода).
func _process_aftermath(delta: float) -> void:
	if stairs_cooldown > 0.0:
		stairs_cooldown -= delta
		return
	var p := Vector2(player.global_position.x, player.global_position.z)
	if p.distance_to(STAIRS_UP) < STAIRS_TRIGGER_DIST:
		player.global_position = STAIRS_UP_TO
		stairs_cooldown = STAIRS_COOLDOWN
	elif p.distance_to(STAIRS_DN) < STAIRS_TRIGGER_DIST:
		player.global_position = STAIRS_DN_TO
		stairs_cooldown = STAIRS_COOLDOWN

func _make_mother() -> Node3D:
	var body := CharacterBody3D.new()
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.1, 0.12)
	mesh.mesh = capsule
	mesh.material_override = mat
	mesh.position = Vector3(0, 0.9, 0)
	body.add_child(mesh)
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.16
	head_mesh.height = 0.32
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.75, 0.72, 0.68)
	head.mesh = head_mesh
	head.material_override = head_mat
	head.position = Vector3(0, 1.75, 0)
	body.add_child(head)
	return body
