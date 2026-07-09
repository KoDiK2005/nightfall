extends Node
## Порт генерации уровня из gen.c (generate_rooms): несколько случайных
## непересекающихся прямоугольных комнат, соединённых Г-образными
## коридорами. Заполняет две GridMap (стены/пол) получившейся сеткой.
## Дальше сюда же лягут темы комнат/биомы -- пока только форма уровня.

const MW := 29
const MH := 21
const WALL_ITEM := 0
const WALL_ITEMS := [0, 2, 3]   # три варианта текстуры стены, см. Biomes.WALL_RESOURCES
const FLOOR_ITEM := 1
const FLOOR_ITEMS := [1, 4]     # два варианта текстуры пола, см. Biomes.FLOOR_RESOURCES
const WALL_H := 2   # стены в две клетки высотой -- иначе игрок видит поверх них
const TORCH_SPACING := 2.6   # совпадает с TORCH_SPACING в render.c
const TORCH_SCENE := preload("res://scenes/torch.tscn")
const PICKUP_DIST := 0.9
const EXIT_DIST := 0.7
const MAX_KEYS := 6
const MONSTER_SCENE := preload("res://scenes/monster.tscn")
const NUM_LOCKERS := 5

static var _chest_tex: ImageTexture = null
static var _locker_tex: ImageTexture = null
static var _door_wood_tex: ImageTexture = null
static var _door_iron_tex: ImageTexture = null

## дощатый косяк дверного проёма -- та же идея, что и у мебели в
## story_level.gd, но тут своя копия: level_gen.gd не зависит от
## story-скрипта и наоборот, у каждого файла свой набор текстур.
static func _door_wood_texture() -> ImageTexture:
	if _door_wood_tex:
		return _door_wood_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var grain: float = sin(y * 0.35 + x * 1.7) * 0.05 + sin(y * 0.9) * 0.03
			var seam: bool = (x % 16) < 1
			var base: float = 0.24 + grain
			if seam:
				base -= 0.07
			base = max(base, 0.03)
			img.set_pixel(x, y, Color(base * 1.3, base * 0.9, base * 0.55))
	_door_wood_tex = ImageTexture.create_from_image(img)
	return _door_wood_tex

## мятое кованое железо для рамы двери выхода -- вместо гладкой заливки.
static func _door_iron_texture() -> ImageTexture:
	if _door_iron_tex:
		return _door_iron_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var base: float = 0.13 + randf() * 0.03
			var scratch: bool = ((x * 3 + y * 5) % 23) < 1
			if scratch:
				base += 0.05
			img.set_pixel(x, y, Color(base, base * 1.02, base * 1.05))
	_door_iron_tex = ImageTexture.create_from_image(img)
	return _door_iron_tex

## Порт спрайта 7 (CHEST) из build_textures/build_sprites (render.c):
## окованный железом деревянный сундук -- тёплое дерево между холодными
## обручами. Раньше сундук с ключом был просто золотым кубом.
static func _chest_texture() -> ImageTexture:
	if _chest_tex:
		return _chest_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var band: bool = (x < 3 or x > 60 or y < 3 or y > 60
				or absi(x - 32) < 3 or absi(y - 32) < 3)
			var plank: bool = (x % 7) < 1
			var wood: float = 0.30
			var v: float = wood + randf() * 0.03 - (0.09 if plank else 0.0) - (0.16 if band else 0.0)
			v = max(v, 0.025)
			var c: Color = Color(v + 0.02, v + 0.017, v + 0.02) if band \
				else Color(v + 0.12, v * 0.8 + 0.03, v * 0.4)
			# латунный навесной замок в центре передней грани
			if absi(x - 32) < 5 and y > 26 and y < 40:
				c = Color(0.62, 0.5, 0.15)
			if absi(x - 32) < 3 and y > 20 and y < 27:
				c = Color(0.5, 0.4, 0.1)
			img.set_pixel(x, y, c)
	_chest_tex = ImageTexture.create_from_image(img)
	return _chest_tex

## Порт спрайта 3 (LOCKER): крашеный металл со швом двери, горизонтальными
## жалюзи-рёбрами и ручкой -- раньше шкафчик был просто тёмно-серым кубом.
static func _locker_texture() -> ImageTexture:
	if _locker_tex:
		return _locker_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var body: float = 0.27 + randf() * 0.05
			var seam: bool = (x % 21) < 2
			var slat: bool = y > 8 and y < 56 and (y % 6) < 2
			var handle: bool = x >= 41 and x <= 46 and y >= 30 and y <= 40
			var v: float = body
			if seam: v -= 0.09
			if slat: v -= 0.11
			var c: Color = Color(0.68, 0.63, 0.44) if handle else Color(v, v + 0.015, v + 0.03)
			img.set_pixel(x, y, c)
	_locker_tex = ImageTexture.create_from_image(img)
	return _locker_tex

var map: Array = []   # map[y][x] == true, если клетка открыта (пол)
var rooms: Array = [] # Rect2i(x, y, w, h) на каждую комнату
var torches: Array = []   # Node3D-инстансы факелов этого уровня

var num_keys: int = 3
var keys_left: int = 3
var chests: Array = []       # [{pos: Vector2, active: bool, mesh: MeshInstance3D}]
var exit_pos: Vector2 = Vector2.ZERO
var exit_mesh: MeshInstance3D = null
var exit_door_pivot: Node3D = null
var exit_door_open: bool = false
var monster: CharacterBody3D = null

var noise_pos: Vector2 = Vector2.ZERO
var noise_t: float = 0.0
var biome_name: String = ""

signal hud_changed
signal chest_opened

## порт make_noise из ai.c: шум, который монстр может пойти расследовать,
## даже если не увидел/не услышал игрока напрямую -- громче/дольше
## перекрывает более старый, а не складывается.
func make_noise(pos: Vector2, ttl: float) -> void:
	if ttl >= noise_t:
		noise_pos = pos
		noise_t = ttl

@onready var wall_map: GridMap = $"../WallGridMap"
@onready var floor_map: GridMap = $"../FloorGridMap"
@onready var player: CharacterBody3D = $"../Player"
@onready var torch_root: Node3D = $"../Torches"
@onready var props_root: Node3D = $"../Props"
@onready var world_env: WorldEnvironment = $"../WorldEnvironment"
@onready var dir_light: DirectionalLight3D = $"../DirectionalLight3D"
@onready var fade_rect: ColorRect = $"../Fade/Black"

func _ready() -> void:
	randomize()
	AudioManager.player = player
	if GameState.mode == GameState.Mode.ENDLESS:
		_build_level()
	GameState.state_changed.connect(_on_state_changed)
	if OS.get_environment("NIGHTFALL_GDTRACE") != "":
		print("GDTRACE rooms=%d player_pos=%s wall_items=%d floor_items=%d torches=%d keys=%d" % [
			rooms.size(), player.position, wall_map.get_used_cells().size(),
			floor_map.get_used_cells().size(), torches.size(), num_keys])

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY and GameState.mode == GameState.Mode.ENDLESS:
		# рассудок сбрасывается только на настоящем старте нового забега --
		# _build_level() вызывается и здесь, и из descend() на каждом этаже,
		# а sanity раньше сбрасывался в _spawn_monster() безусловно на обоих
		# путях. С глубиной трата рассудка ускоряется (см. player.gd), но
		# смысла в этом почти не было: любой накопленный страх стирался в
		# ноль на первой же лестнице вниз -- "мой рассудок трещит по швам
		# глубже" (README) не успевал накопиться дальше одного этажа.
		player.sanity = 1.0
		_build_level()
		_play_descend_fade()   # проявление из черноты и при старте новой игры

func _build_level() -> void:
	_setup_dungeon_env()
	biome_name = Biomes.apply(GameState.depth)
	_generate()
	_paint()
	_place_torches()
	_place_keys_and_exit()
	_spawn_player()
	_spawn_monster()
	hud_changed.emit()

## Тёмное замкнутое подземелье: гасим "дневной" направленный свет и небо,
## оставляем очень слабый эмбиент и плотный тёмный туман -- так основной
## свет идёт от факелов, а даль тонет в черноте (порт AMBIENT/FOG_K и общей
## беспросветности из C-версии). Сюжетный режим на улице свою среду ставит
## сам (см. story_level.gd), так что трогаем окружение только здесь.
func _setup_dungeon_env() -> void:
	if dir_light:
		dir_light.visible = false
	if world_env == null or world_env.environment == null:
		return
	var env := world_env.environment
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.10, 0.10, 0.13)
	env.ambient_light_energy = 0.25
	env.fog_enabled = true
	env.fog_light_color = Color(0.03, 0.03, 0.04)
	env.fog_density = 0.14
	env.fog_sky_affect = 0.0

## волновой поиск (BFS) от заданной клетки -- порт flood_from_cell из
## gen.c. Возвращает сетку [y][x] расстояний в клетках, 1<<20 -- недостижимо.
func flood_from(target: Vector2i) -> Array:
	var dist: Array = []
	for _y in range(MH):
		var row: Array = []
		row.resize(MW)
		row.fill(1 << 20)
		dist.append(row)
	if not is_open(target.x, target.y):
		return dist
	dist[target.y][target.x] = 0
	var queue: Array = [target]
	var head := 0
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in dirs:
			var n: Vector2i = c + d
			if is_open(n.x, n.y) and dist[n.y][n.x] > dist[c.y][c.x] + 1:
				dist[n.y][n.x] = dist[c.y][c.x] + 1
				queue.append(n)
	return dist

## Сталкер стартует как можно дальше от игрока -- порт того же выбора в
## reset_level (gen.c).
func _spawn_monster() -> void:
	if monster:
		monster.queue_free()
		monster = null
	var start: Rect2i = rooms[0]
	var sx: int = start.position.x + start.size.x / 2
	var sy: int = start.position.y + start.size.y / 2
	var best_d := -1
	var best := Vector2i(sx, sy)
	for y in range(1, MH - 1):
		for x in range(1, MW - 1):
			if is_open(x, y):
				var d := (x - sx) * (x - sx) + (y - sy) * (y - sy)
				if d > best_d:
					best_d = d
					best = Vector2i(x, y)
	monster = MONSTER_SCENE.instantiate()
	add_child(monster)
	monster.position = Vector3(best.x + 0.5, 0.1, best.y + 0.5)
	# dev-хук NIGHTFALL_SHOWMON: поставить монстра в паре шагов перед игроком
	# (для скриншотов светящихся глаз/силуэта), а не в дальнем углу
	if OS.get_environment("NIGHTFALL_SHOWMON") != "":
		var fwd := -player.transform.basis.z
		monster.position = player.position + fwd * 2.5
		monster.position.y = 0.1
		monster.frozen = true
	monster.setup(self, player)
	player.monster = monster
	player.level_gen = self

func _process(delta: float) -> void:
	if GameState.state != GameState.State.PLAY or GameState.mode != GameState.Mode.ENDLESS:
		return
	if noise_t > 0.0:
		noise_t -= delta
	var p := Vector2(player.position.x, player.position.z)
	if Input.is_action_just_pressed("interact"):
		try_pickup_nearby(p)
	if keys_left == 0 and p.distance_to(exit_pos) < EXIT_DIST:
		descend()
	_update_shrine_hum(delta, p)
	_update_phantom(delta)

## "hallucinated phantom Stalker... flickers in down the corridor you face
## when dread>0.35 & not hunting (visual only, no catch)" -- часть системы
## галлюцинаций из C-версии, отдельная от PNG-вспышек (см. hud.gd): не
## фотография, а призрачный силуэт самого Сталкера, которого на самом деле
## тут нет. Переиспользует ту же жуткую текстуру, что и настоящий монстр --
## не setup() (никакого ИИ, никакой коллизии с реальной поимкой), просто
## билборд, что постоит и растворится.
var _phantom: CharacterBody3D = null
var _phantom_mat: StandardMaterial3D = null
var _phantom_t: float = 0.0
var _phantom_timer: float = 14.0
func _update_phantom(delta: float) -> void:
	if _phantom:
		_phantom_t += delta
		var fade: float = 1.0
		if _phantom_t < 0.3:
			fade = _phantom_t / 0.3
		elif _phantom_t > 1.2:
			fade = clamp(1.0 - (_phantom_t - 1.2) / 0.5, 0.0, 1.0)
		# MeshInstance3D -- не CanvasItem, у него нет modulate; гасим через
		# альфу материала (он уже TRANSPARENCY_ALPHA в _build_body_material)
		var a: float = fade * (0.7 + 0.3 * sin(_phantom_t * 23.0))
		_phantom_mat.albedo_color.a = a
		_phantom_mat.emission_energy_multiplier = 4.0 * a
		if _phantom_t > 1.7:
			_phantom.queue_free()
			_phantom = null
			_phantom_timer = 16.0 + randf() * 14.0
		return
	if monster == null or monster.state == monster.State.HUNT:
		_phantom_timer = max(_phantom_timer, 6.0)
		return
	var dread: float = 1.0 - player.sanity
	if dread < 0.35 or dread > 0.8:
		_phantom_timer = max(_phantom_timer, 6.0)
		return
	_phantom_timer -= delta
	if _phantom_timer > 0.0:
		return
	_spawn_phantom()

func _spawn_phantom() -> void:
	var fwd := -player.transform.basis.z
	var dist := 5.0 + randf() * 3.0
	var pos: Vector3 = player.position + fwd * dist
	var space := player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(player.position, pos)
	query.collision_mask = 1
	if not space.intersect_ray(query).is_empty():
		_phantom_timer = 5.0   # стена на пути -- попробуем ещё раз чуть позже
		return
	_phantom = MONSTER_SCENE.instantiate()
	add_child(_phantom)
	_phantom.position = Vector3(pos.x, 0.1, pos.z)
	_phantom.mon_type = _phantom.MonType.STALKER
	_phantom_mat = _phantom._build_body_material()
	_phantom.body.material_override = _phantom_mat
	_phantom.collision_layer = 0
	_phantom.collision_mask = 0
	_phantom_t = 0.0

## "золотой компас-чутьё на ключи" из README -- звуковая половина: тихий
## гул у ближайшего непройденного сундука (порт play_positional(CH_SHRINE,
## ...) из audio.c), громче по мере приближения. shrine.wav лежал
## неиспользованным.
var _shrine_player: AudioStreamPlayer3D = null
var _shrine_timer: float = 0.0
func _update_shrine_hum(delta: float, p: Vector2) -> void:
	_shrine_timer -= delta
	if _shrine_timer > 0.0:
		return
	var nearest_pos := Vector2.ZERO
	var best_d := INF
	for c in chests:
		if not c.active:
			continue
		var d: float = p.distance_to(c.pos)
		if d < best_d:
			best_d = d
			nearest_pos = c.pos
	if best_d > 12.0:
		_shrine_timer = 1.0
		return
	if _shrine_player == null:
		_shrine_player = AudioStreamPlayer3D.new()
		_shrine_player.stream = load("res://assets/shrine.wav")
		_shrine_player.unit_size = 3.0
		_shrine_player.max_distance = 12.0
		props_root.add_child(_shrine_player)
	_shrine_player.position = Vector3(nearest_pos.x, 0.4, nearest_pos.y)
	_shrine_player.volume_db = linear_to_db(clamp(1.0 - best_d / 12.0, 0.1, 1.0))
	_shrine_player.play()
	_shrine_timer = lerp(6.0, 2.0, clamp(1.0 - best_d / 12.0, 0.0, 1.0))

## подобрать ключ из сундука, если игрок рядом с активным (вынесено из
## _process, чтобы дёргать и из самотеста без эмуляции ввода)
func try_pickup_nearby(p: Vector2) -> bool:
	for c in chests:
		if not c.active:
			continue
		if p.distance_to(c.pos) < PICKUP_DIST:
			c.active = false
			c.mesh.visible = false
			keys_left -= 1
			hud_changed.emit()
			# скрип открывающегося сундука -- ещё один источник шума
			# (см. README), которого раньше тут не было вовсе
			make_noise(c.pos, 6.0)
			# assets/pickup.wav лежал неиспользованным -- подбор ключа был
			# совершенно беззвучным
			var pickup_snd := AudioStreamPlayer3D.new()
			pickup_snd.stream = load("res://assets/pickup.wav")
			pickup_snd.unit_size = 3.0
			pickup_snd.max_distance = 12.0
			pickup_snd.position = Vector3(c.pos.x, 0.5, c.pos.y)
			props_root.add_child(pickup_snd)
			pickup_snd.play()
			pickup_snd.finished.connect(pickup_snd.queue_free)
			chest_opened.emit()
			if keys_left == 0:
				_open_exit_door()
			return true
	return false

## спуск на следующий этаж -- все ключи собраны, игрок дошёл до выхода.
## Логика (глубина + перестройка) синхронна, поверх пускаем косметическое
## проявление из черноты, чтобы новый этаж не "щёлкал" резко (порт fade-to-
## black спуска из main.c).
func descend() -> void:
	GameState.advance_floor()
	_build_level()
	_play_descend_fade()

func _play_descend_fade() -> void:
	if fade_rect == null:
		return
	fade_rect.color.a = 1.0
	var tw := create_tween()
	tw.tween_property(fade_rect, "color:a", 0.0, 0.7)

func is_open(x: int, y: int) -> bool:
	if x < 0 or x >= MW or y < 0 or y >= MH:
		return false
	return map[y][x]

func _carve_rect(x0: int, y0: int, w: int, h: int) -> void:
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if x > 0 and x < MW - 1 and y > 0 and y < MH - 1:
				map[y][x] = true

func _carve_h(x0: int, x1: int, y: int) -> void:
	var a: int = min(x0, x1)
	var b: int = max(x0, x1)
	for x in range(a, b + 1):
		if y > 0 and y < MH - 1 and x > 0 and x < MW - 1:
			map[y][x] = true

func _carve_v(y0: int, y1: int, x: int) -> void:
	var a: int = min(y0, y1)
	var b: int = max(y0, y1)
	for y in range(a, b + 1):
		if x > 0 and x < MW - 1 and y > 0 and y < MH - 1:
			map[y][x] = true

func _generate() -> void:
	map.clear()
	for _y in range(MH):
		var row: Array = []
		row.resize(MW)
		row.fill(false)
		map.append(row)

	rooms.clear()
	var target: int = 7 + randi() % 4
	var attempts := 0
	while rooms.size() < target and attempts < 300:
		attempts += 1
		var w: int = 4 + randi() % 5
		var h: int = 3 + randi() % 4
		var x: int = 1 + randi() % (MW - w - 1)
		var y: int = 1 + randi() % (MH - h - 1)
		var ok := true
		for r in rooms:
			if x - 1 < r.position.x + r.size.x and x + w + 1 > r.position.x \
					and y - 1 < r.position.y + r.size.y and y + h + 1 > r.position.y:
				ok = false
				break
		if not ok:
			continue
		rooms.append(Rect2i(x, y, w, h))
		_carve_rect(x, y, w, h)

	# соединяем каждую комнату с предыдущей -- гарантирует связность всей карты
	for i in range(1, rooms.size()):
		var a: Rect2i = rooms[i - 1]
		var b: Rect2i = rooms[i]
		var ax: int = a.position.x + a.size.x / 2
		var ay: int = a.position.y + a.size.y / 2
		var bx: int = b.position.x + b.size.x / 2
		var by: int = b.position.y + b.size.y / 2
		if randi() % 2 == 0:
			_carve_h(ax, bx, ay)
			_carve_v(ay, by, bx)
		else:
			_carve_v(ay, by, ax)
			_carve_h(ax, bx, by)

func _paint() -> void:
	wall_map.clear()
	floor_map.clear()
	for y in range(MH):
		for x in range(MW):
			if is_open(x, y):
				floor_map.set_cell_item(Vector3i(x, 0, y), FLOOR_ITEMS[randi() % FLOOR_ITEMS.size()])
				# потолок над каждой открытой клеткой -- замыкает пространство
				# сверху, чтобы небо не проглядывало (тот же плоский тайл пола,
				# поднятый на высоту стен); собственный случайный вариант,
				# независимый от пола под ногами -- ещё меньше похоже на штамп
				floor_map.set_cell_item(Vector3i(x, WALL_H, y), FLOOR_ITEMS[randi() % FLOOR_ITEMS.size()])
			else:
				# стена рисуется, только если рядом есть открытая клетка --
				# как в build_world_mesh (render.c): по одной грани на
				# открытого соседа, а не сплошной блок камня повсюду. В высоту
				# -- WALL_H клеток, иначе игрок смотрит поверх стен.
				var neighbours_open: bool = is_open(x + 1, y) or is_open(x - 1, y) \
					or is_open(x, y + 1) or is_open(x, y - 1)
				if neighbours_open:
					# один из трёх вариантов текстуры на весь столбец клетки --
					# иначе одна и та же кладка, отштампованная по каждой грани
					# коридора подряд, читается как явный повторяющийся тайл.
					var item: int = WALL_ITEMS[randi() % WALL_ITEMS.size()]
					for layer in range(WALL_H):
						wall_map.set_cell_item(Vector3i(x, layer, y), item)

func _place_torches() -> void:
	for t in torches:
		t.queue_free()
	torches.clear()

	# та же идея, что и place_torches в render.c: собрать все клетки пола,
	# у которых есть соседняя стена, перемешать, и раскладывать факелы по
	# одному, пропуская кандидатов, что оказались слишком близко к уже
	# поставленному -- получается неравномерная, но всюду покрывающая сетка.
	var candidates: Array = []
	for y in range(1, MH - 1):
		for x in range(1, MW - 1):
			if not is_open(x, y):
				continue
			if not is_open(x + 1, y) or not is_open(x - 1, y) \
					or not is_open(x, y + 1) or not is_open(x, y - 1):
				candidates.append(Vector2i(x, y))
	candidates.shuffle()

	# "факелы расставлены реже, так что тьма сгущается" (README) -- раньше
	# TORCH_SPACING был константой, глубина в расстановке не участвовала.
	var wear: float = clamp(float(GameState.depth - 1) / 12.0, 0.0, 1.0)
	var spacing: float = TORCH_SPACING * (1.0 + wear * 0.7)

	var placed: Array = []   # Vector3(world_x, world_z, ...) центров факелов
	for c in candidates:
		var wall_dir := _wall_dir(c.x, c.y)
		if wall_dir == Vector2i.ZERO:
			continue
		var wx: float = c.x + 0.5 + wall_dir.x * 0.48
		var wz: float = c.y + 0.5 + wall_dir.y * 0.48
		var ok := true
		for p in placed:
			if Vector2(wx, wz).distance_to(Vector2(p.x, p.y)) < spacing:
				ok = false
				break
		if not ok:
			continue
		var torch := TORCH_SCENE.instantiate()
		torch_root.add_child(torch)
		torch.position = Vector3(wx, 0, wz)
		torch.look_at(torch.position + Vector3(wall_dir.x, 0, wall_dir.y), Vector3.UP)
		torches.append(torch)
		placed.append(Vector2(wx, wz))

## какая соседняя клетка -- стена (см. wall_dir в gen.c). Возвращает
## направление к ближайшей стене или Vector2i.ZERO, если такой нет.
func _wall_dir(x: int, y: int) -> Vector2i:
	if not is_open(x + 1, y): return Vector2i(1, 0)
	if not is_open(x - 1, y): return Vector2i(-1, 0)
	if not is_open(x, y + 1): return Vector2i(0, 1)
	if not is_open(x, y - 1): return Vector2i(0, -1)
	return Vector2i.ZERO

## Ключи в сундуках (порт reset_level из gen.c): 3 на первом этаже, плюс
## один за каждые три этажа, максимум MAX_KEYS. Раскладываются по центрам
## комнат, кроме стартовой. Выход -- в комнате, самой дальней от старта.
func _place_keys_and_exit() -> void:
	for c in chests:
		c.mesh.queue_free()
	chests.clear()
	if exit_door_pivot:
		exit_door_pivot.queue_free()   # тащит exit_mesh за собой -- он теперь его ребёнок
		exit_door_pivot = null
		exit_mesh = null
	for child in props_root.get_children():
		child.queue_free()
	_shrine_player = null   # тоже был ребёнком props_root -- та же чистка

	num_keys = min(3 + (GameState.depth - 1) / 3, MAX_KEYS)
	keys_left = num_keys

	var start: Rect2i = rooms[0]
	var start_center := Vector2(start.position.x + start.size.x / 2.0, start.position.y + start.size.y / 2.0)

	# самая дальняя от старта комната -- выход
	var exit_room_idx := 0
	var best_d := -1.0
	for i in range(1, rooms.size()):
		var r: Rect2i = rooms[i]
		var c := Vector2(r.position.x + r.size.x / 2.0, r.position.y + r.size.y / 2.0)
		var d := c.distance_squared_to(start_center)
		if d > best_d:
			best_d = d
			exit_room_idx = i

	var chest_mat := StandardMaterial3D.new()
	chest_mat.albedo_texture = _chest_texture()
	chest_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	chest_mat.emission_enabled = true
	chest_mat.emission = Color(0.5, 0.35, 0.05)
	chest_mat.emission_energy_multiplier = 0.18   # чуть светится в темноте -- манит подойти

	var placed_keys := 0
	for i in range(1, rooms.size()):
		if placed_keys >= num_keys:
			break
		if i == exit_room_idx:
			continue
		var r: Rect2i = rooms[i]
		var cx: float = r.position.x + r.size.x / 2.0
		var cy: float = r.position.y + r.size.y / 2.0
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.55, 0.34, 0.36)   # приземистый сундук-коффер, не куб
		mesh.material_override = chest_mat
		mesh.position = Vector3(cx, 0.22, cy)
		props_root.add_child(mesh)
		chests.append({"pos": Vector2(cx, cy), "active": true, "mesh": mesh})
		placed_keys += 1

	var er: Rect2i = rooms[exit_room_idx]
	exit_pos = Vector2(er.position.x + er.size.x / 2.0, er.position.y + er.size.y / 2.0)
	_place_exit_door(exit_pos)
	if keys_left == 0:
		_open_exit_door()

	_place_lockers(exit_room_idx)
	_place_doors()

## Дверь выхода -- прежде была просто цветной коробкой посреди комнаты.
## Теперь это свободностоящая рама (железные столбы + притолока), а плита
## (та же exit_mesh, что и раньше -- по ней переключается цвет замка/выхода)
## навешена на левый столб как на петлю, чтобы её можно было распахнуть.
func _place_exit_door(pos: Vector2) -> void:
	var iron_mat := StandardMaterial3D.new()
	iron_mat.albedo_texture = _door_iron_texture()
	iron_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	iron_mat.metallic = 0.4
	iron_mat.roughness = 0.5

	var half := 0.55
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		post.mesh = BoxMesh.new()
		post.mesh.size = Vector3(0.12, 2.0, 0.12)
		post.material_override = iron_mat
		post.position = Vector3(pos.x + side * half, 1.0, pos.y)
		props_root.add_child(post)
	var lintel := MeshInstance3D.new()
	lintel.mesh = BoxMesh.new()
	lintel.mesh.size = Vector3(half * 2.0 + 0.12, 0.14, 0.14)
	lintel.material_override = iron_mat
	lintel.position = Vector3(pos.x, 1.95, pos.y)
	props_root.add_child(lintel)

	var exit_red := StandardMaterial3D.new()
	exit_red.albedo_color = Color(1.0, 0.25, 0.25)
	exit_red.emission_enabled = true
	exit_red.emission = Color(0.6, 0.1, 0.1)
	exit_mesh = MeshInstance3D.new()
	exit_mesh.mesh = BoxMesh.new()
	exit_mesh.mesh.size = Vector3(0.9, 1.8, 0.08)
	exit_mesh.material_override = exit_red
	# пивот-петля стоит у левого столба; плита -- его ребёнок, смещённая
	# так, что её левый край совпадает с петлёй -- поворот пивота по Y
	# распахивает её, как настоящую дверь, а не просто телепортирует цвет.
	exit_door_pivot = Node3D.new()
	exit_door_pivot.position = Vector3(pos.x - half + 0.06, 0.0, pos.y)
	props_root.add_child(exit_door_pivot)
	exit_mesh.position = Vector3(0.45, 0.9, 0.0)
	exit_door_pivot.add_child(exit_mesh)
	exit_door_open = false

## Распахнуть дверь выхода -- вызывается один раз, как только собран
## последний ключ (а не мгновенная смена цвета плиты, как было раньше).
## Скрип двери -- assets/creak.wav, до этого лежавший неиспользованным
## (портирован из C, но никогда не подключался к Godot-порту).
func _open_exit_door() -> void:
	if exit_door_open or exit_door_pivot == null:
		return
	exit_door_open = true
	exit_mesh.get_active_material(0).albedo_color = Color(0.3, 1.0, 0.5)
	var creak := AudioStreamPlayer3D.new()
	creak.stream = load("res://assets/creak.wav")
	creak.unit_size = 4.0
	creak.max_distance = 14.0
	exit_door_pivot.add_child(creak)
	creak.play()
	var tw := create_tween()
	tw.tween_property(exit_door_pivot, "rotation:y", -deg_to_rad(100.0), 1.1) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

## Дверные проёмы там, где коридор входит в комнату -- порт того, что в
## подземелье раньше вообще не было дверей: комнаты просто перетекали в
## коридор голым разрывом стены. Ищем клетки пола сразу за границей каждой
## комнаты (там, где коридор её касается) и ставим раму: деревянный косяк
## по бокам прохода + притолока сверху. Чисто декор, без коллизии -- проход
## остаётся свободным, как и был.
func _place_doors() -> void:
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_texture = _door_wood_texture()
	wood_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	wood_mat.roughness = 1.0

	var seen: Dictionary = {}
	for r in rooms:
		for entry in _room_doorway_cells(r):
			var key: Vector2i = entry.pos
			if seen.has(key):
				continue
			seen[key] = true
			_build_door_frame(entry.pos, entry.dir, wood_mat)

## клетки пола сразу за одной из четырёх границ комнаты, где начинается
## коридор -- направление (dir) смотрит НАРУЖУ из комнаты, вдоль коридора.
func _room_doorway_cells(r: Rect2i) -> Array:
	var out: Array = []
	var x0: int = r.position.x
	var y0: int = r.position.y
	var x1: int = x0 + r.size.x - 1
	var y1: int = y0 + r.size.y - 1
	for x in range(x0, x1 + 1):
		if is_open(x, y0 - 1):
			out.append({"pos": Vector2i(x, y0 - 1), "dir": Vector2i(0, -1)})
		if is_open(x, y1 + 1):
			out.append({"pos": Vector2i(x, y1 + 1), "dir": Vector2i(0, 1)})
	for y in range(y0, y1 + 1):
		if is_open(x0 - 1, y):
			out.append({"pos": Vector2i(x0 - 1, y), "dir": Vector2i(-1, 0)})
		if is_open(x1 + 1, y):
			out.append({"pos": Vector2i(x1 + 1, y), "dir": Vector2i(1, 0)})
	return out

func _build_door_frame(cell: Vector2i, dir: Vector2i, wood_mat: StandardMaterial3D) -> void:
	var cx: float = cell.x + 0.5
	var cz: float = cell.y + 0.5
	# косяк идёт поперёк прохода: если проём смотрит по X (dir.x != 0),
	# косяки стоят по бокам вдоль Z, и наоборот
	var perp := Vector2(0.0, 1.0) if dir.x != 0 else Vector2(1.0, 0.0)
	var half := 0.46
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		post.mesh = BoxMesh.new()
		post.mesh.size = Vector3(0.08, float(WALL_H), 0.08)
		post.material_override = wood_mat
		post.position = Vector3(cx + perp.x * half * side, WALL_H / 2.0, cz + perp.y * half * side)
		props_root.add_child(post)
	var lintel := MeshInstance3D.new()
	lintel.mesh = BoxMesh.new()
	var span: float = half * 2.0 + 0.10
	# длинная сторона притолоки идёт вдоль той же оси, что и косяки (perp)
	lintel.mesh.size = Vector3(0.12, 0.12, span) if dir.x != 0 else Vector3(span, 0.12, 0.12)
	lintel.material_override = wood_mat
	lintel.position = Vector3(cx, float(WALL_H) - 0.15, cz)
	props_root.add_child(lintel)

## шкафчики, где можно спрятаться -- порт locker-плейсмента из reset_level
## (gen.c): по одному на комнату, не в стартовой/финальной.
func _place_lockers(exit_room_idx: int) -> void:
	player.lockers.clear()
	var locker_mat := StandardMaterial3D.new()
	locker_mat.albedo_texture = _locker_texture()
	locker_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var candidates: Array = range(1, rooms.size()).filter(func(i): return i != exit_room_idx)
	candidates.shuffle()
	for i in candidates:
		if player.lockers.size() >= NUM_LOCKERS:
			break
		var r: Rect2i = rooms[i]
		var cx: float = r.position.x + 0.5 + randi() % max(r.size.x - 1, 1)
		var cy: float = r.position.y + 0.5 + randi() % max(r.size.y - 1, 1)
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.5, 1.8, 0.5)
		mesh.material_override = locker_mat
		mesh.position = Vector3(cx, 0.9, cy)
		props_root.add_child(mesh)
		player.lockers.append(mesh)

func _spawn_player() -> void:
	if rooms.is_empty() or player == null:
		return
	var start: Rect2i = rooms[0]
	var cx: float = start.position.x + start.size.x / 2.0
	var cy: float = start.position.y + start.size.y / 2.0
	# y=0.9 -- пол в подземелье без коллизии (гравитация 0), поэтому высоту
	# ставим руками: центр капсулы на 0.9 => глаз камеры (+0.6) на ~1.5 м,
	# нормальный рост взрослого, а не пригнувшийся вид с 0.1
	player.position = Vector3(cx, 0.9, cy)
	player.rotation.y = _spawn_facing(int(cx), int(cy))
	player.reset_look()

	# dev-хук NIGHTFALL_SHOWEXIT: сразу перед дверью выхода со всеми
	# собранными ключами -- удобно смотреть/скриншотить открытие двери,
	# не проходя весь этаж.
	if OS.get_environment("NIGHTFALL_SHOWEXIT") != "":
		keys_left = 0
		player.position = Vector3(exit_pos.x, 0.9, exit_pos.y - 2.5)
		player.look_at(Vector3(exit_pos.x, 0.9, exit_pos.y), Vector3.UP)
		hud_changed.emit()
		_open_exit_door()

## сориентировать игрока в самую открытую из четырёх сторон -- считаем,
## сколько клеток пола подряд тянется от спавна, и смотрим туда (иначе
## игрок нередко утыкается носом в ближнюю стену на старте)
func _spawn_facing(sx: int, sy: int) -> float:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var best_dir := Vector2i(0, 1)
	var best_open := -1
	for d in dirs:
		var run := 0
		var nx: int = sx + d.x
		var ny: int = sy + d.y
		while is_open(nx, ny) and run < 20:
			run += 1
			nx += d.x
			ny += d.y
		if run > best_open:
			best_open = run
			best_dir = d
	return atan2(-float(best_dir.x), -float(best_dir.y))
