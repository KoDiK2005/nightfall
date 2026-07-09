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
@onready var fade_rect: ColorRect = $"../Fade/Black"

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
	# материалы общие с подземельем -- без сброса дом унаследовал бы
	# каменную кладку с трещинами, если до этого уже играли endless
	wall_mat.albedo_texture = null
	floor_mat.albedo_texture = null
	if dir_light:
		dir_light.visible = true
	if world_env and world_env.environment:
		var env := world_env.environment
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		# высокий ambient -- комнаты дома под крышей отрезаны от неба и
		# направленного света, так что без него интерьер чёрный; вместо окон
		# заливаем всё рассеянным дневным светом (как высокий biome_amb в story.c)
		env.ambient_light_color = Color(0.85, 0.82, 0.78)
		env.ambient_light_energy = 1.5
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
	_place_lamps()
	_place_gazebo(26.0, 6.0)
	_place_car_and_clothesline()
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

## тёплая потолочная лампа: ровный ambient делает комнаты плоскими, поэтому
## добавляем по мягкому точечному свету в основные помещения -- появляется
## объём и градиент к углам, без теней (дёшево для Intel UHD 620).
func _lamp(x: float, z: float) -> void:
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(x, 1.85, z)
	lamp.light_color = Color(1.0, 0.9, 0.72)
	lamp.light_energy = 1.1
	lamp.omni_range = 7.0
	lamp.shadow_enabled = false
	house_props.add_child(lamp)

func _place_lamps() -> void:
	# первый этаж
	_lamp(24.0, 22.0)   # кухня-гостиная
	_lamp(14.0, 19.0)   # холл с лестницей
	_lamp(11.0, 24.0)   # гостевая спальня
	# второй этаж
	_lamp(38.0, 3.0)    # мастер-спальня
	_lamp(46.0, 3.0)    # детская 1
	_lamp(51.0, 3.0)    # детская 2

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

## беседка на лужайке -- порт place_gazebo (story.c): четыре столба и
## плоская крыша, чисто декор, без коллизии (как и вся прочая мебель тут).
func _place_gazebo(cx: float, cz: float) -> void:
	var half := 1.6
	var post_color := Color(0.55, 0.42, 0.30)
	for ox in [-half, half]:
		for oz in [-half, half]:
			_prop(Vector3(cx + ox, 0.575, cz + oz), Vector3(0.18, 1.15, 0.18), post_color)
	_prop(Vector3(cx, 1.125, cz), Vector3((half + 0.25) * 2.0, 0.15, (half + 0.25) * 2.0), post_color * 0.85)

## ржавая развалюха у забора и бельевая верёвка -- порт куска
## place_yard_clutter (story.c) про машину и верёвку; двор дома, где пьют и
## срываются на детях, не ухоженная лужайка. Южнее дома, на открытой части
## общей дворовой плоскости (Yard-плейн покрывает весь двор целиком, так что
## пределы MW/MH из карты комнат тут ни при чём -- те нужны только стенам).
func _place_car_and_clothesline() -> void:
	var cx := 24.0
	var cz := 33.5
	_prop(Vector3(cx, 0.275, cz), Vector3(3.0, 0.55, 1.7), Color(0.28, 0.14, 0.10))    # кузов
	_prop(Vector3(cx, 0.635, cz), Vector3(2.2, 0.17, 1.4), Color(0.24, 0.12, 0.09))    # кабина/крыша

	var clx0 := 17.0
	var clx1 := 20.0
	var clz := 33.5
	var pole_color := Color(0.30, 0.22, 0.16)
	_prop(Vector3(clx0, 0.5, clz), Vector3(0.1, 1.0, 0.1), pole_color)
	_prop(Vector3(clx1, 0.5, clz), Vector3(0.1, 1.0, 0.1), pole_color)
	_prop(Vector3((clx0 + clx1) / 2.0, 0.985, clz), Vector3(clx1 - clx0, 0.03, 0.04), Color(0.55, 0.52, 0.46))   # провисшая верёвка
	_prop(Vector3(clx0 + 0.6, 0.825, clz), Vector3(0.28, 0.25, 0.06), Color(0.62, 0.60, 0.55))                   # тряпка на ней

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

	# мягкое проявление из черноты на входе в воспоминание
	if fade_rect:
		fade_rect.color.a = 1.0
		create_tween().tween_property(fade_rect, "color:a", 0.0, 1.2)

	# dev-хук: сразу в свободный обход дома (минуя подход и сцену с матерью)
	# -- удобно тестировать/скриншотить интерьер, пока идёт работа над домом.
	# Спавн в просторной кухне-гостиной, лицом вдоль комнаты.
	if OS.get_environment("NIGHTFALL_STORY_ROAM") != "":
		phase = Phase.AFTERMATH
		player.global_position = Vector3(24.0, 0.9, 22.0)
		player.rotation.y = PI * 0.5
		player.story_speed_mult = 1.0

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

const MOTHER_TEX := 64
static var _mother_tex: ImageTexture = null

## Порт спрайта 6 (MOTHER) из build_sprites (render.c): платье, несвежий
## фартук, скрещённые на груди руки, растрёпанные волосы -- и гладкое
## бледное пятно вместо лица (ей никогда не до вас, лицо ей просто ни к
## чему). Раньше это были голая капсула тела и сфера-голова без единой
## детали. Billboard-плоскость, как и у монстра -- всегда лицом к камере.
static func _build_mother_texture() -> ImageTexture:
	var img := Image.create(MOTHER_TEX, MOTHER_TEX, false, Image.FORMAT_RGBA8)
	for y in range(MOTHER_TEX):
		for x in range(MOTHER_TEX):
			var nx: float = x - 32.0
			var part := 0   # 1 платье, 2 лицо, 3 волосы, 4 кисти, 5 фартук, 6 туфли
			var hhy: float = y - 9.0
			var hhe: float = (nx * nx) / (8.6 * 8.6) + (hhy * hhy) / (10.0 * 10.0)
			var frayed: int = int(abs(sin(nx * 1.3 + y * 0.7)) * 3.0)
			if hhe < 1.0 and y < 15 + frayed:
				part = 3
			var hy: float = y - 10.0
			var he: float = (nx * nx) / (7.0 * 7.0) + (hy * hy) / (8.5 * 8.5)
			if he < 1.0:
				part = 2
			if y >= 17 and y <= 19 and abs(nx) < 3.0 and part == 0:
				part = 1
			if y >= 19 and y <= 60:
				var tt: float = (y - 19) / 41.0
				var hw: float = 8.0 + tt * 13.0
				if abs(nx) < hw and part == 0:
					part = 1
			if y >= 60 and y <= 63 and abs(nx) < 9.0:
				part = 6
			var arm_band: bool = y >= 26 and y <= 32 and abs(nx) < 11.0
			if y >= 22 and y <= 46 and abs(nx) < 7.5 and not arm_band:
				part = 5
			if arm_band:
				part = 1
			if y >= 27 and y <= 31 and abs(abs(nx) - 10.0) < 2.2:
				part = 4
			var c: Color
			match part:
				1:
					var fold: float = 6.0 / 255.0 if (int(nx + 40) % 4) == 0 else 0.0
					var v: float = max((16.0 + randf() * 5.0) / 255.0 - fold, 4.0 / 255.0)
					c = Color(v, v * 0.85, v * 0.95, 1.0)
				2:
					var v: float = (150.0 + randf() * 12.0) / 255.0
					c = Color(v, v * 0.94, v * 0.90, 1.0)
				3:
					var v: float = (6.0 + randf() * 6.0) / 255.0
					c = Color(v, v * 0.92, v * 0.88, 1.0)
				4:
					var v: float = (130.0 + randf() * 14.0) / 255.0
					c = Color(v, v * 0.90, v * 0.84, 1.0)
				5:
					var v: float = (22.0 + randf() * 4.0) / 255.0
					if randf() < 0.10:
						v -= 9.0 / 255.0
					v = max(v, 6.0 / 255.0)
					c = Color(v, v * 0.92, v * 0.70, 1.0)
				6:
					c = Color(10 / 255.0, 9 / 255.0, 9 / 255.0, 1.0)
				_:
					continue
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

func _make_mother() -> Node3D:
	var body := Node3D.new()
	if _mother_tex == null:
		_mother_tex = _build_mother_texture()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _mother_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.mesh.size = Vector2(1.0, 1.9)
	mesh.material_override = mat
	mesh.position = Vector3(0, 0.95, 0)
	body.add_child(mesh)
	return body
