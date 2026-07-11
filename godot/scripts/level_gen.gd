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
const CEIL_ITEMS := [5, 6]      # два варианта текстуры потолка, см. Biomes.CEIL_RESOURCES
const WALL_H := 2   # стены в две клетки высотой -- иначе игрок видит поверх них
const TORCH_SPACING := 2.6   # совпадает с TORCH_SPACING в render.c
const TORCH_SCENE := preload("res://scenes/torch.tscn")
const PICKUP_DIST := 0.9
const ITEM_PICKUP_DIST := 0.55   # PICKUP_DIST в main.c -- спички/камни подбираются на ходу, без E
const EXIT_DIST := 0.7
const MAX_KEYS := 6
const MONSTER_SCENE := preload("res://scenes/monster.tscn")
const NUM_LOCKERS := 5
## зазор между низом декоративного меша и полом (y=0, см. tiles.tres::
## item/1,4 -- верхняя грань пола ровно на нуле). Щебень/подобранные камни/
## ящики раньше садились впритык, низ меша копланарен полу -- классический
## z-fighting, мерцающий на глаз как "битая текстура" именно там, где стоят
## эти объекты ("часто проблемы с текстурками на полу" -- баг-репорт). У
## сундука/костей такой отступ уже был, здесь -- не было.
const FLOOR_CLEARANCE := 0.01

static var _chest_tex: ImageTexture = null
static var _locker_tex: ImageTexture = null
static var _door_wood_tex: ImageTexture = null
static var _door_iron_tex: ImageTexture = null
static var _rubble_tex: ImageTexture = null
static var _crate_tex: ImageTexture = null
static var _bone_tex: ImageTexture = null
static var _web_tex: ImageTexture = null
static var _matchbox_tex: ImageTexture = null
static var _rockpick_tex: ImageTexture = null
static var _flarepick_tex: ImageTexture = null
static var _wrappick_tex: ImageTexture = null
static var _key_icon_tex: ImageTexture = null
static var _cage_tex: ImageTexture = null
static var _blood_tex: ImageTexture = null

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

## Золотой значок ключа, парящий над сундуком -- раньше "ключ" был чистой
## абстракцией (счётчик на HUD), сам предмет-цель выглядел как сундук, а не
## как ключ. Пиксель-арт силуэт: кольцо-бородка сверху, стержень вниз, два
## зубца у основания -- читается однозначно на любом фоне, т.к. рисуется
## как billboard с альфа-прозрачностью, а не текстура на кубе.
static func _key_icon_texture() -> ImageTexture:
	if _key_icon_tex:
		return _key_icon_tex
	const TEX := 32
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		for x in range(TEX):
			var dx: float = x - 15.5
			var dy: float = y - 8.0
			var ring: bool = abs(dx * dx + dy * dy - 25.0) < 9.0   # кольцо-бородка
			var shaft: bool = abs(dx) < 1.6 and y > 10 and y < 27  # стержень
			var tooth1: bool = x > 15 and x < 21 and y > 19 and y < 23
			var tooth2: bool = x > 15 and x < 19 and y > 24 and y < 27
			if ring or shaft or tooth1 or tooth2:
				var shade: float = 0.85 + randf() * 0.12
				img.set_pixel(x, y, Color(0.95 * shade, 0.78 * shade, 0.25 * shade, 1.0))
	_key_icon_tex = ImageTexture.create_from_image(img)
	return _key_icon_tex

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

## колотый камень для куч щебня -- заваленные комнаты вместо пустых коробок.
static func _rubble_texture() -> ImageTexture:
	if _rubble_tex:
		return _rubble_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var n: float = sin(x * 0.3 + y * 0.17) * 0.05 + sin(y * 0.41) * 0.04
			var v: float = 0.28 + n + randf() * 0.04
			var crack: bool = (x * 5 + y * 7) % 37 < 2
			if crack:
				v -= 0.12
			v = max(v, 0.03)
			img.set_pixel(x, y, Color(v, v * 0.97, v * 0.93))
	_rubble_tex = ImageTexture.create_from_image(img)
	return _rubble_tex

## грубый дощатый ящик -- для куч барахла по комнатам, отличный от косяка
## двери тёмными металлическими обвязками по краям.
static func _crate_texture() -> ImageTexture:
	if _crate_tex:
		return _crate_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var plank: bool = (x % 11) < 1
			var band: bool = y < 6 or y > 57
			var wood: float = 0.24 + randf() * 0.03 - (0.08 if plank else 0.0)
			var c: Color = Color(0.15, 0.14, 0.13) if band \
				else Color(wood + 0.10, wood * 0.75 + 0.02, wood * 0.35)
			img.set_pixel(x, y, c)
	_crate_tex = ImageTexture.create_from_image(img)
	return _crate_tex

## обглоданная кость -- для россыпей по полу тёмных комнат.
static func _bone_texture() -> ImageTexture:
	if _bone_tex:
		return _bone_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var v: float = 0.60 + randf() * 0.08
			if randf() < 0.06:
				v -= 0.22   # грязные пятна
			img.set_pixel(x, y, Color(v, v * 0.94, v * 0.82))
	_bone_tex = ImageTexture.create_from_image(img)
	return _bone_tex

## полупрозрачная паутина -- радиальные нити от угла, гаснущие к краю.
static func _web_texture() -> ImageTexture:
	if _web_tex:
		return _web_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		for x in range(TEX):
			var dx: float = x - 2.0
			var dy: float = y - 2.0
			var dist: float = sqrt(dx * dx + dy * dy)
			var ang: float = atan2(dy, dx) + PI
			var radial: bool = fmod(ang, PI / 8.0) < 0.09
			var ring: bool = fmod(dist, 7.0) < 0.9
			var a: float = 0.0
			if (radial or ring) and dist < 60.0:
				a = clamp(0.55 - dist / 90.0, 0.0, 0.55)
			img.set_pixel(x, y, Color(0.85, 0.85, 0.82, a))
	_web_tex = ImageTexture.create_from_image(img)
	return _web_tex

## ржавое железо прута клетки -- тёмный металл с редкими рыжими потёками.
static func _cage_texture() -> ImageTexture:
	if _cage_tex:
		return _cage_tex
	const TEX := 32
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var v: float = 0.16 + randf() * 0.05
			var rust: bool = (sin(x * 0.7 + y * 1.3) * 0.5 + 0.5) > 0.82
			var c: Color
			if rust:
				c = Color(v * 1.8, v * 0.9, v * 0.35)
			else:
				c = Color(v, v * 0.97, v * 0.95)
			img.set_pixel(x, y, c)
	_cage_tex = ImageTexture.create_from_image(img)
	return _cage_tex

## лужа крови на полу -- неровное тёмно-бурое пятно с рваным затухающим
## краем (шум по радиусу вместо идеального круга), не заливка на всю клетку.
static func _blood_texture() -> ImageTexture:
	if _blood_tex:
		return _blood_tex
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		for x in range(TEX):
			var dx: float = x - 32.0
			var dy: float = y - 32.0
			var ang: float = atan2(dy, dx)
			var wobble: float = 1.0 + 0.30 * sin(ang * 5.0 + 1.7) + 0.15 * sin(ang * 11.0)
			var dist: float = sqrt(dx * dx + dy * dy) / wobble
			if dist > 27.0:
				continue
			var a: float = clamp(0.75 - dist / 27.0, 0.0, 0.75)
			var v: float = 0.10 + randf() * 0.03
			img.set_pixel(x, y, Color(v * 1.6, v * 0.35, v * 0.30, a))
	_blood_tex = ImageTexture.create_from_image(img)
	return _blood_tex

## коробок спичек -- тёмно-красная крышка с полоской для чирка сбоку.
static func _matchbox_texture() -> ImageTexture:
	if _matchbox_tex:
		return _matchbox_tex
	const TEX := 32
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var strike: bool = y > 12 and y < 18
			var v: float = 0.55 + randf() * 0.06
			var c: Color = Color(0.15, 0.13, 0.11) if strike else Color(v * 0.75, v * 0.14, v * 0.10)
			img.set_pixel(x, y, c)
	_matchbox_tex = ImageTexture.create_from_image(img)
	return _matchbox_tex

## подобранный камень для броска -- та же заготовка щебня, но однотонней и
## заметно светлее: щебень-декор рядом (_rubble_texture, ~0.28-0.34) и
## камень-подбор были почти одного тона на почти чёрном полу -- на практике
## не видно вовсе, приходилось спотыкаться, чтобы найти.
static func _rockpick_texture() -> ImageTexture:
	if _rockpick_tex:
		return _rockpick_tex
	const TEX := 32
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var n: float = sin(x * 0.4 + y * 0.23) * 0.04
			var v: float = 0.58 + n + randf() * 0.05
			img.set_pixel(x, y, Color(v, v * 0.97, v * 0.92))
	_rockpick_tex = ImageTexture.create_from_image(img)
	return _rockpick_tex

## сигнальная шашка на полу, ещё не поднятая -- бумажная гильза, красная,
## как и все сигнальные ракеты, с торцевой полоской запала потемнее.
static func _flarepick_texture() -> ImageTexture:
	if _flarepick_tex:
		return _flarepick_tex
	const TEX := 32
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var tip: bool = y < 6
			var v: float = 0.5 + randf() * 0.06
			var c: Color = Color(0.12, 0.11, 0.10) if tip else Color(v * 0.85, v * 0.12, v * 0.08)
			img.set_pixel(x, y, c)
	_flarepick_tex = ImageTexture.create_from_image(img)
	return _flarepick_tex

## свёрток обмоток -- тусклая пыльная холстина с полосами бинтования,
## заметно бледнее камня/спички, чтобы силуэт узла читался, а не терялся
## пятном того же тона, что и щебень.
static func _wrappick_texture() -> ImageTexture:
	if _wrappick_tex:
		return _wrappick_tex
	const TEX := 32
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var band: bool = (int(x * 0.6 + y * 0.9)) % 6 < 2
			var v: float = (0.62 if band else 0.5) + randf() * 0.05
			img.set_pixel(x, y, Color(v * 0.92, v * 0.86, v * 0.72))
	_wrappick_tex = ImageTexture.create_from_image(img)
	return _wrappick_tex

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
var doors: Array = []   # {pivot: Node3D, pos: Vector2, dir: Vector2i, is_open: bool} -- дверные проёмы коридоров
var doorway_specs: Array = []   # [{pos: Vector2i, dir: Vector2i}] -- проёмы, записанные при генерации (см. _connect_rooms)
var monster: CharacterBody3D = null

var patrol_order: Array = []   # индексы rooms (кроме старта) в перемешанном порядке -- маршрут патруля
var patrol_pos: int = 0

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

## "props ... had no collision at all -- purely visual, walk-through"
## (main.c::prop_blocks) -- сундуки/шкафчики/ящики в подземелье были
## буквально сквозными, только пол под ними не пускал. Заворачивает
## мебельный меш в StaticBody3D с коробкой-коллизией на СВОЁМ физическом
## слое (8, не общий со стенами) -- монстр (маска 1, только стены) её
## по-прежнему не замечает и ходит как раньше по клеточной сетке, блокирует
## только игрока (см. Player.collision_mask в main.tscn). Возвращает
## добавленный корневой узел (StaticBody3D либо голый mesh для мелочи вроде
## костей) -- вызывающий код должен прятать/удалять именно его, не только
## внутренний mesh, иначе коллизия переживёт исчезновение картинки.
## mesh: обычно MeshInstance3D (сундук/шкафчик/ящик), но подходит любой
## Node3D -- см. _spawn_desk, где визуал стола собран из пяти отдельных
## мешей (столешница + 4 ножки) под одним общим родителем.
func _add_prop_collision(mesh: Node3D, pos: Vector3, size: Vector3) -> Node3D:
	if size.y < 0.10:
		mesh.position = pos
		props_root.add_child(mesh)
		return mesh
	var body := StaticBody3D.new()
	body.position = pos
	body.collision_layer = 8
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	mesh.position = Vector3.ZERO
	body.add_child(mesh)
	props_root.add_child(body)
	return body

@onready var wall_map: GridMap = $"../WallGridMap"
@onready var floor_map: GridMap = $"../FloorGridMap"
@onready var player: CharacterBody3D = $"../Player"
@onready var torch_root: Node3D = $"../Torches"
@onready var props_root: Node3D = $"../Props"
@onready var world_env: WorldEnvironment = $"../WorldEnvironment"
@onready var dir_light: DirectionalLight3D = $"../DirectionalLight3D"
@onready var fade_rect: ColorRect = $"../Fade/Black"
@onready var items: Node = $"../Items"

var matchpicks: Array = []   # {pos: Vector2, active: bool, mesh: MeshInstance3D} -- см. _place_pickups
var rockpicks: Array = []
var flarepicks: Array = []
var wrappicks: Array = []
var supply_crates: Array = []   # {pos: Vector2, active: bool, mesh: MeshInstance3D} -- см. _spawn_crate
var desk_note_spots: Array = []   # {pos: Vector2, y: float} -- поверхности столов, куда notes.gd может положить записку плашмя, см. _spawn_desk
var altar: Dictionary = {}   # {pos: Vector2, active: bool, mesh: MeshInstance3D} -- см. _place_altar/pray_at_altar, максимум один на этаж
var cage_spots: Array = []   # Vector2 -- позиции клеток "камерных" комнат, см. _dress_cell_room/_spawn_cage (чисто декор, только для dev-хука/тестов)

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
	_build_patrol_route()
	_place_pillars()
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
	# ключ подбирается наступанием на сундук, без E -- та же логика, что и у
	# спичек/камней/шашек/обмоток ниже (_collect_pickups), просто с открытием
	# крышки. Раньше требовался E, но подбор ключа концептуально ничем не
	# отличается от подбора остальных предметов на полу.
	try_pickup_nearby(p)
	_collect_pickups(p)
	if keys_left == 0 and p.distance_to(exit_pos) < EXIT_DIST:
		descend()
	_update_shrine_hum(delta, p)
	_update_phantom(delta)
	_update_doors(p)

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
		_phantom.eye_mat.emission_energy_multiplier = 6.0 * a
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
	_phantom._build_rig()
	_phantom_mat = _phantom.flesh_mat
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

## подобрать ключ из сундука, если игрок наступил на активный -- вынесено из
## _process, чтобы дёргать и из самотеста напрямую
func try_pickup_nearby(p: Vector2) -> bool:
	for c in chests:
		if not c.active:
			continue
		if p.distance_to(c.pos) < PICKUP_DIST:
			c.active = false
			# крышка распахивается (см. _build_chest/_open_chest_lid), сундук
			# остаётся на месте открытым ориентиром -- коллизия тоже остаётся
			# сплошной, теперь у неё есть видимое тело, которое её оправдывает.
			_open_chest_lid(c)
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
	# зазор между комнатами теперь минимум 2 клетки (было 1): коридоры идут
	# в этом зазоре, а не впритык к стене соседней комнаты. При зазоре в 1
	# клетку проходящий коридор открывал клетку прямо у чужой стены, и вся
	# стена читалась как один сплошной проём -- отсюда двери гроздьями по её
	# краю и слипшиеся в кляксу комнаты (см. жалобу на сломанную генерацию).
	var target: int = 6 + randi() % 3
	var attempts := 0
	while rooms.size() < target and attempts < 400:
		attempts += 1
		var w: int = 4 + randi() % 5
		var h: int = 3 + randi() % 4
		var x: int = 1 + randi() % (MW - w - 1)
		var y: int = 1 + randi() % (MH - h - 1)
		var ok := true
		for r in rooms:
			if x - 2 < r.position.x + r.size.x and x + w + 2 > r.position.x \
					and y - 2 < r.position.y + r.size.y and y + h + 2 > r.position.y:
				ok = false
				break
		if not ok:
			continue
		rooms.append(Rect2i(x, y, w, h))
		_carve_rect(x, y, w, h)

	_connect_rooms()

## Соединяет комнаты коридорами по остовному дереву (Prim, манхэттен между
## центрами) плюс пара петель -- вместо прежней цепочки "каждая с предыдущей
## в порядке расстановки", из-за которой коридоры тянулись через весь этаж и
## прорезали чужие комнаты. Каждое ребро входит в комнату ровно ОДНИМ проёмом
## на обращённой к соседу стене, и этот проём записывается тут же
## (doorway_specs), а не вылавливается потом сканом периметра, который плодил
## лишние двери гроздьями.
func _connect_rooms() -> void:
	doorway_specs.clear()
	var n := rooms.size()
	if n <= 1:
		return
	var centers: Array = []
	for r in rooms:
		centers.append(Vector2i(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2))
	# Prim: растим дерево от комнаты 0, каждый раз цепляя ближайшую снаружи
	var connected: Dictionary = {0: true}
	while connected.size() < n:
		var best_i := -1
		var best_j := -1
		var best_d := 1 << 30
		for i in connected:
			for j in range(n):
				if connected.has(j):
					continue
				var d: int = absi(centers[i].x - centers[j].x) + absi(centers[i].y - centers[j].y)
				if d < best_d:
					best_d = d
					best_i = i
					best_j = j
		connected[best_j] = true
		_carve_corridor(best_i, best_j)
	# петли: пара лишних коридоров между близкими комнатами -- этаж перестаёт
	# быть деревом-цепью, у погони появляются обходные пути
	for _k in range(1 + n / 4):
		var i := randi() % n
		var j := _nearest_room(i, centers)
		if j != -1:
			_carve_corridor(i, j)

func _nearest_room(i: int, centers: Array) -> int:
	var best := -1
	var best_d := 1 << 30
	for j in range(centers.size()):
		if j == i:
			continue
		var d: int = absi(centers[i].x - centers[j].x) + absi(centers[i].y - centers[j].y)
		if d < best_d:
			best_d = d
			best = j
	return best

## Прокладывает один коридор между комнатами i и j: берёт по клетке на
## обращённых друг к другу стенах, роет между ними Г-образный проход в
## один тайл шириной и записывает оба проёма.
func _carve_corridor(i: int, j: int) -> void:
	var a: Rect2i = rooms[i]
	var b: Rect2i = rooms[j]
	var ca := Vector2i(a.position.x + a.size.x / 2, a.position.y + a.size.y / 2)
	var cb := Vector2i(b.position.x + b.size.x / 2, b.position.y + b.size.y / 2)
	var da: Dictionary = _door_cell(a, cb)
	var db: Dictionary = _door_cell(b, ca)
	var pa: Vector2i = da.pos
	var pb: Vector2i = db.pos
	# клетки самих проёмов -- открыть (это клетки прохода сквозь стену)
	if _in_bounds(pa):
		map[pa.y][pa.x] = true
	if _in_bounds(pb):
		map[pb.y][pb.x] = true
	# Г-образный коридор между внешними клетками проёмов
	if randi() % 2 == 0:
		_carve_h(pa.x, pb.x, pa.y)
		_carve_v(pa.y, pb.y, pb.x)
	else:
		_carve_v(pa.y, pb.y, pa.x)
		_carve_h(pa.x, pb.x, pb.y)
	doorway_specs.append(da)
	doorway_specs.append(db)

## Клетка ПРЯМО ЗА стеной комнаты, обращённой к цели toward, плюс наружное
## направление -- будущий дверной проём. Сторона выбирается по тому, куда
## дальше до цели (по X или по Y), координата вдоль стены прижата к её отрезку.
func _door_cell(room: Rect2i, toward: Vector2i) -> Dictionary:
	var left: int = room.position.x
	var right: int = room.position.x + room.size.x - 1
	var top: int = room.position.y
	var bottom: int = room.position.y + room.size.y - 1
	var cx: int = (left + right) / 2
	var cy: int = (top + bottom) / 2
	if absi(toward.x - cx) >= absi(toward.y - cy):
		var row: int = clampi(toward.y, top, bottom)
		if toward.x >= cx:
			return {"pos": Vector2i(right + 1, row), "dir": Vector2i(1, 0)}
		return {"pos": Vector2i(left - 1, row), "dir": Vector2i(-1, 0)}
	var col: int = clampi(toward.x, left, right)
	if toward.y >= cy:
		return {"pos": Vector2i(col, bottom + 1), "dir": Vector2i(0, 1)}
	return {"pos": Vector2i(col, top - 1), "dir": Vector2i(0, -1)}

func _in_bounds(c: Vector2i) -> bool:
	return c.x > 0 and c.x < MW - 1 and c.y > 0 and c.y < MH - 1

## "shuffle every non-entrance room into a beat the monster loops while
## wandering, so idle movement reads as a patrol through the halls rather
## than picking a fresh random cell each time" (gen.c) -- этой структуры не
## было в Godot-порте вовсе: monster.pick_wander() просто кидал монстра в
## случайную открытую клетку карты (плюс отдельный 50%-шанс зайти к
## сундуку) -- блуждание читалось как дрожащий случайный телепорт по этажу,
## а не обход по своему маршруту. Перемешивается один раз на этаж.
func _build_patrol_route() -> void:
	patrol_order.clear()
	for i in range(1, rooms.size()):
		patrol_order.append(i)
	patrol_order.shuffle()
	patrol_pos = (randi() % patrol_order.size()) if patrol_order.size() > 0 else 0

## "pillar candidates in the larger halls (columns for cover)" (gen.c) --
## этой части не было в Godot-порте вовсе: большие залы стояли совершенно
## пустыми открытыми коробками, без единого укрытия во время погони.
## Закрываем одну-две клетки на кандидата (не в самом центре комнаты, где
## позже встанет сундук/выход, а у боковых стен на полувысоте -- как в
## C) как обычную стену: остальная отрисовка (_paint) уже рисует
## свободностоящую стеновую колонну сама, раз у клетки все соседи открыты,
## коллизия и текстура те же, что у обычной стены. Откатываем закрытие,
## если оно разрывает связность этажа (тот же reach_ok из C).
func _place_pillars() -> void:
	if rooms.is_empty():
		return
	var start: Rect2i = rooms[0]
	var start_cell := Vector2i(start.position.x + start.size.x / 2, start.position.y + start.size.y / 2)
	for i in range(1, rooms.size()):
		var r: Rect2i = rooms[i]
		if r.size.x < 6 or r.size.y < 5:
			continue
		var py: int = r.position.y + r.size.y / 2
		var candidates: Array = [Vector2i(r.position.x + 1, py), Vector2i(r.position.x + r.size.x - 2, py)]
		for c in candidates:
			if not is_open(c.x, c.y):
				continue
			map[c.y][c.x] = false
			if not _reach_ok(start_cell):
				map[c.y][c.x] = true

## связность этажа целиком: все ещё открытые клетки должны быть достижимы
## от start_cell -- порт reach_ok из gen.c, используется, чтобы откатить
## клетку-кандидат под колонну, если её закрытие отрезало часть уровня.
func _reach_ok(start_cell: Vector2i) -> bool:
	var dist: Array = flood_from(start_cell)
	for y in range(MH):
		for x in range(MW):
			if map[y][x] and dist[y][x] >= (1 << 20):
				return false
	return true

func _paint() -> void:
	wall_map.clear()
	floor_map.clear()
	for y in range(MH):
		for x in range(MW):
			if is_open(x, y):
				floor_map.set_cell_item(Vector3i(x, 0, y), FLOOR_ITEMS[randi() % FLOOR_ITEMS.size()])
				# потолок над каждой открытой клеткой -- замыкает пространство
				# сверху, чтобы небо не проглядывало. Раньше это был тот же
				# самый пол, просто поднятый на высоту стен -- смотрящий вверх
				# видел ровно те же половицы, что и под ногами. Свой набор
				# item'ов (балки+копоть, см. Biomes) -- потолок больше не
				# зеркалит пол.
				floor_map.set_cell_item(Vector3i(x, WALL_H, y), CEIL_ITEMS[randi() % CEIL_ITEMS.size()])
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
	# меши сундуков/шкафчиков/ящиков теперь могут быть завёрнуты в
	# StaticBody3D-коллизию (см. _add_prop_collision) -- их всё равно
	# подчищает общая петля по props_root чуть ниже, отдельно очищать
	# c.mesh тут больше не нужно (и посвободило бы только визуал, оставив
	# сиротский коллайдер до конца кадра).
	chests.clear()
	matchpicks.clear()   # меши -- дети props_root, чистятся общей петлёй ниже
	rockpicks.clear()
	flarepicks.clear()
	wrappicks.clear()
	supply_crates.clear()
	desk_note_spots.clear()
	altar = {}
	cage_spots.clear()
	if exit_door_pivot:
		exit_door_pivot.queue_free()   # тащит exit_mesh за собой -- он теперь его ребёнок
		exit_door_pivot = null
		exit_mesh = null
	for child in props_root.get_children():
		child.queue_free()
	_shrine_player = null   # тоже был ребёнком props_root -- та же чистка

	num_keys = min(3 + (GameState.depth - 1) / 3, MAX_KEYS)

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

	# сундуков не больше, чем комнат под них (все, кроме стартовой и выходной):
	# иначе на глубоком этаже с малым числом комнат ключей требовалось бы
	# больше, чем помещается сундуков, и дверь выхода не открылась бы никогда
	# (софт-лок). keys_left ставим уже после этого предела.
	num_keys = mini(num_keys, maxi(0, rooms.size() - 2))
	keys_left = num_keys

	var chest_mat := StandardMaterial3D.new()
	chest_mat.albedo_texture = _chest_texture()
	chest_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	chest_mat.emission_enabled = true
	chest_mat.emission = Color(0.5, 0.35, 0.05)
	chest_mat.emission_energy_multiplier = 0.18   # чуть светится в темноте -- манит подойти

	# "нормальные ключи" -- раньше ключ был чистой абстракцией (счётчик на
	# HUD), а цель на полу выглядела как безликий сундук. Золотой значок
	# ключа парит над каждым сундуком -- billboard, всегда лицом к камере.
	var key_icon_mat := StandardMaterial3D.new()
	key_icon_mat.albedo_texture = _key_icon_texture()
	key_icon_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	key_icon_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	key_icon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	key_icon_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	key_icon_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	key_icon_mat.emission_enabled = true
	key_icon_mat.emission = Color(1.0, 0.8, 0.3)
	key_icon_mat.emission_energy_multiplier = 0.9

	var placed_keys := 0
	for i in range(1, rooms.size()):
		if placed_keys >= num_keys:
			break
		if i == exit_room_idx:
			continue
		var r: Rect2i = rooms[i]
		var cx: float = r.position.x + r.size.x / 2.0
		var cy: float = r.position.y + r.size.y / 2.0
		chests.append(_build_chest(Vector2(cx, cy), chest_mat, key_icon_mat))
		placed_keys += 1

	var er: Rect2i = rooms[exit_room_idx]
	exit_pos = Vector2(er.position.x + er.size.x / 2.0, er.position.y + er.size.y / 2.0)
	_place_exit_door(exit_pos)
	if keys_left == 0:
		_open_exit_door()

	# двери -- ДО шкафчиков и клатера: и те, и другие теперь сверяются со
	# списком doors, чтобы не встать своей коллизией в горловину прохода
	# (см. _place_lockers/_place_room_dressing) -- раньше _place_doors шёл
	# после _place_lockers, и шкафчик мог сесть прямо в дверной проём.
	_place_doors()
	_place_lockers(exit_room_idx)
	_place_altar(exit_room_idx, start)
	_place_room_dressing(exit_room_idx)
	_place_pickups(start.position + Vector2i(start.size.x / 2, start.size.y / 2))
	_place_room_theme_lights(exit_room_idx, start)

## Сундук -- раньше был цельным боксом, который при подборе ключа мгновенно
## пропадал (mesh.visible = false) без всякой анимации: с виду -- будто
## нажатие E ничего не сделало, пока не посмотришь на счётчик ключей на
## HUD ("не получается осмотреть сундук"). Теперь тело и крышка -- отдельные
## меши, крышка на пивоте у заднего верхнего ребра (тот же приём "пивот +
## смещённый ребёнок", что и у двери выхода, см. _open_exit_door) -- E
## реально распахивает крышку с тем же скрипом, а сундук остаётся на месте
## как открытый ориентир, а не исчезает целиком.
func _build_chest(pos: Vector2, chest_mat: StandardMaterial3D, key_icon_mat: StandardMaterial3D) -> Dictionary:
	const CHEST_SIZE := Vector3(0.55, 0.34, 0.36)
	const LID_FRAC := 0.42   # доля общей высоты, которая приходится на крышку
	var lid_h: float = CHEST_SIZE.y * LID_FRAC
	var body_h: float = CHEST_SIZE.y - lid_h

	var root := Node3D.new()
	var body := MeshInstance3D.new()
	body.mesh = BoxMesh.new()
	body.mesh.size = Vector3(CHEST_SIZE.x, body_h, CHEST_SIZE.z)
	body.material_override = chest_mat
	body.position = Vector3(0, -CHEST_SIZE.y / 2.0 + body_h / 2.0, 0)
	root.add_child(body)

	var lid_pivot := Node3D.new()
	lid_pivot.position = Vector3(0, CHEST_SIZE.y / 2.0 - lid_h, -CHEST_SIZE.z / 2.0)
	root.add_child(lid_pivot)
	var lid := MeshInstance3D.new()
	lid.mesh = BoxMesh.new()
	lid.mesh.size = Vector3(CHEST_SIZE.x, lid_h, CHEST_SIZE.z)
	lid.material_override = chest_mat
	lid.position = Vector3(0, lid_h / 2.0, CHEST_SIZE.z / 2.0)
	lid_pivot.add_child(lid)

	var key_icon := MeshInstance3D.new()
	key_icon.mesh = QuadMesh.new()
	key_icon.mesh.size = Vector2(0.3, 0.3)
	key_icon.material_override = key_icon_mat
	key_icon.position = Vector3(0, 0.55, 0)
	root.add_child(key_icon)

	_add_beacon(root, Color(1.0, 0.75, 0.35), 0.55, 2.4, 0.3)
	var chest_root := _add_prop_collision(root, Vector3(pos.x, 0.22, pos.y), CHEST_SIZE)
	return {"pos": pos, "active": true, "mesh": root, "root": chest_root, "key_icon": key_icon, "lid_pivot": lid_pivot}

## Распахнуть крышку конкретного сундука -- тот же tween-приём и звук
## (creak.wav), что и у двери выхода, но короче и на другой оси (крышка
## запрокидывается назад по X, а не поворачивается по Y, как дверная плита).
func _open_chest_lid(c: Dictionary) -> void:
	c.key_icon.visible = false
	var creak := AudioStreamPlayer3D.new()
	creak.stream = load("res://assets/creak.wav")
	creak.unit_size = 3.0
	creak.max_distance = 10.0
	c.lid_pivot.add_child(creak)
	creak.play()
	var tw := create_tween()
	tw.tween_property(c.lid_pivot, "rotation:x", -deg_to_rad(100.0), 0.5) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

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

## Ставит дверную раму в каждый проём, записанный при генерации коридоров
## (doorway_specs, см. _connect_rooms) -- один проём на связь между комнатами,
## ровно там, где коридор пронзает стену. Раньше двери вылавливались сканом
## периметра каждой комнаты и липли гроздьями к любой открытой границе; теперь
## места проёмов известны заранее. Рама: деревянный косяк по бокам прохода +
## притолока сверху, и сама панель -- она распахивается при приближении игрока
## и закрывается за спиной (см. _update_doors), чисто визуально, без коллизии.
func _place_doors() -> void:
	doors.clear()
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_texture = _door_wood_texture()
	wood_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	wood_mat.roughness = 1.0

	# тот же материал, что и у обычных стен (не дерево двери) -- кусок
	# кладки над проёмом должен выглядеть и, главное, освещаться так же,
	# как соседняя стена: горизонтальный потолочный тайл почти не ловит
	# свет от факелов (они бьют в основном вбок, не вниз) и остаётся
	# тёмным пятном прямо над дверью, даже когда геометрия там есть --
	# со стороны это неотличимо от настоящей дыры. Вертикальная кладка
	# ловит тот же свет, что и стены рядом.
	var wall_mat: StandardMaterial3D = load("res://resources/wall_material.tres")

	var seen: Dictionary = {}
	for spec in doorway_specs:
		var cell: Vector2i = spec.pos
		if seen.has(cell):
			continue
		# проём у самого края карты мог не прорезаться (_carve_* режет только
		# внутренние клетки) -- строим дверь лишь там, где проход реально открыт
		if not is_open(cell.x, cell.y):
			continue
		# дверь -- только в НАСТОЯЩЕМ проёме: клетка-однотайловый проход сквозь
		# стену. Позиции проёмов пишутся при генерации (_door_cell), но
		# Г-образные коридоры и петли (_connect_rooms) потом открывают соседние
		# клетки, съедая косяк, а иногда клетка проёма вовсе попадает в другую
		# комнату -- и дверь оказывается стоящей боком посреди открытого пола
		# ("двери криво в комнате"). Пропускаем такие: у настоящего проёма
		# по бокам (perp) должна быть глухая стена -- косяки, к которым дверь
		# крепится -- и открытые клетки спереди и сзади (сквозь неё проходят).
		var dir: Vector2i = spec.dir
		var perp := Vector2i(0, 1) if dir.x != 0 else Vector2i(1, 0)
		var jamb_a: bool = not is_open(cell.x + perp.x, cell.y + perp.y)
		var jamb_b: bool = not is_open(cell.x - perp.x, cell.y - perp.y)
		var front_open: bool = is_open(cell.x + dir.x, cell.y + dir.y)
		var back_open: bool = is_open(cell.x - dir.x, cell.y - dir.y)
		if not (jamb_a and jamb_b and front_open and back_open):
			continue
		seen[cell] = true
		_build_door_frame(cell, spec.dir, wood_mat, wall_mat)

## открывает дверь при приближении игрока и закрывает за спиной, с
## гистерезисом между порогами (иначе дверь дребезжала бы туда-сюда прямо
## на границе одного расстояния).
const DOOR_OPEN_DIST := 1.3   # была 2.2 -- открывалась на подходе издалека, до жалобы "далеко открывается"
const DOOR_CLOSE_DIST := 2.4
func _update_doors(p: Vector2) -> void:
	for d in doors:
		var dist: float = p.distance_to(d.pos)
		if dist < DOOR_OPEN_DIST and not d.is_open:
			d.is_open = true
			var tw := create_tween()
			tw.tween_property(d.pivot, "rotation:y", -deg_to_rad(95.0), 0.4) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		elif dist > DOOR_CLOSE_DIST and d.is_open:
			d.is_open = false
			var tw2 := create_tween()
			tw2.tween_property(d.pivot, "rotation:y", 0.0, 0.5) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

func _build_door_frame(cell: Vector2i, dir: Vector2i, wood_mat: StandardMaterial3D, wall_mat: StandardMaterial3D) -> void:
	var cx: float = cell.x + 0.5
	var cz: float = cell.y + 0.5
	# косяк идёт поперёк прохода: если проём смотрит по X (dir.x != 0),
	# косяки стоят по бокам вдоль Z, и наоборот
	var perp := Vector2(0.0, 1.0) if dir.x != 0 else Vector2(1.0, 0.0)
	var jamb_half := 0.46
	# ВЫСОТА ПРОЁМА. Комната всего WALL_H=2.0 высотой, а камера игрока -- на
	# 1.5 (замерено). Значит проём должен доходить почти до потолка: если
	# опустить его к 1.5, игрок "бьётся головой" о стену над дверью прямо на
	# уровне глаз, а сама дверь смотрится вдавленной в пол. Верх проёма на
	# 1.78 (0.28 запаса над глазами -- как и было в исходной версии до всех
	# правок, там на это не жаловались), над ним лишь тонкая полоса стены до
	# потолка.
	var leaf_h: float = 1.73
	var leaf_top: float = leaf_h + 0.05   # = 1.78

	# СТЕНА НАД ДВЕРЬЮ -- сплошной блок кладки на ВСЮ клетку (1x1 в плане),
	# от верха проёма до потолка, тем же материалом, что и соседние стены.
	# Именно full-cell (не тонкий брусок) закрывает дыру ПОЛНОСТЬЮ, со всех
	# ракурсов: раньше притолока была 0.12 толщиной вдоль прохода и не
	# заполняла клетку в глубину -- сбоку над дверью было видно насквозь
	# ("дыра над дверью"). Полоса тонкая (потолок низкий), но глухая -- проём
	# читается как проход, прорезанный в сплошной стене.
	var header := MeshInstance3D.new()
	header.mesh = BoxMesh.new()
	var header_h: float = float(WALL_H) - leaf_top + 0.12   # нахлёст в потолок и на верх проёма
	header.mesh.size = Vector3(1.0, header_h, 1.0)
	header.material_override = wall_mat
	header.position = Vector3(cx, leaf_top + header_h / 2.0 - 0.06, cz)
	props_root.add_child(header)

	# деревянная дверная коробка -- два косяка по бокам проёма и перемычка
	# поверх полотна, только на высоту двери (выше уже кладка). Чистая
	# рамочная отделка, чтобы проём читался как дверь, а не голый пролом.
	for side in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		post.mesh = BoxMesh.new()
		post.mesh.size = Vector3(0.08, leaf_top, 0.14) if dir.x != 0 else Vector3(0.14, leaf_top, 0.08)
		post.material_override = wood_mat
		post.position = Vector3(cx + perp.x * jamb_half * side, leaf_top / 2.0, cz + perp.y * jamb_half * side)
		props_root.add_child(post)
	var trim := MeshInstance3D.new()
	trim.mesh = BoxMesh.new()
	var trim_span: float = jamb_half * 2.0 + 0.14
	trim.mesh.size = Vector3(0.14, 0.1, trim_span) if dir.x != 0 else Vector3(trim_span, 0.1, 0.14)
	trim.material_override = wood_mat
	trim.position = Vector3(cx, leaf_top - 0.05, cz)
	props_root.add_child(trim)

	# сама панель -- навешена на "минус"-косяк как на петлю (тот же приём,
	# что и у двери выхода): пивот стоит у петли, панель -- его ребёнок,
	# смещённая так, что её край совпадает с петлёй.
	var leaf := MeshInstance3D.new()
	leaf.mesh = BoxMesh.new()
	var leaf_span: float = jamb_half * 2.0 - 0.05
	leaf.mesh.size = Vector3(0.05, leaf_h, leaf_span) if dir.x != 0 else Vector3(leaf_span, leaf_h, 0.05)
	leaf.material_override = wood_mat
	var pivot := Node3D.new()
	pivot.position = Vector3(cx - perp.x * jamb_half, 0.0, cz - perp.y * jamb_half)
	props_root.add_child(pivot)
	leaf.position = Vector3(perp.x * jamb_half, leaf_h / 2.0 + 0.05, perp.y * jamb_half)
	pivot.add_child(leaf)
	doors.append({"pivot": pivot, "pos": Vector2(cx, cz), "dir": dir, "is_open": false})

## шкафчики, где можно спрятаться -- порт locker-плейсмента из reset_level
## (gen.c): по одному на комнату, не в стартовой/финальной.
## "lockers line the walls of storage rooms" (gen.c) -- раньше шкафчик
## вставал в случайную клетку ИНТЕРЬЕРА комнаты, вообще без привязки к
## стене: плавающий в воздухе посреди пола ящик, который к тому же теперь
## неотличим от щебня/ящиков нового наполнения комнат (_place_room_dressing)
## -- отсюда и жалоба "не нашёл ни одного шкафа". Теперь шкафчик всегда
## стоит впритык к стене (тот же _wall_dir, что и у факелов), как настоящая
## мебель, а не абстрактный куб посреди пустоты.
func _place_lockers(exit_room_idx: int) -> void:
	player.lockers.clear()
	var locker_mat := StandardMaterial3D.new()
	locker_mat.albedo_texture = _locker_texture()
	locker_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# металл ловит блики факелов -- раньше шкафчик был совершенно матовым
	# и в темноте (почти весь этаж, кроме пятен света у факелов) сливался
	# со стеной в один и тот же тёмно-серый силуэт без единого блика.
	locker_mat.metallic = 0.45
	locker_mat.roughness = 0.4

	var start: Rect2i = rooms[0]
	var start_center := Vector2i(start.position.x + start.size.x / 2, start.position.y + start.size.y / 2)

	var candidates: Array = range(1, rooms.size()).filter(func(i): return i != exit_room_idx)
	candidates.shuffle()
	for i in candidates:
		if player.lockers.size() >= NUM_LOCKERS:
			break
		var r: Rect2i = rooms[i]
		var cells: Array = []
		for y in range(r.position.y, r.position.y + r.size.y):
			for x in range(r.position.x, r.position.x + r.size.x):
				cells.append(Vector2i(x, y))
		cells.shuffle()
		for c in cells:
			if player.lockers.size() >= NUM_LOCKERS:
				break
			if absi(c.x - start_center.x) + absi(c.y - start_center.y) < 3:
				continue
			var wall_dir := _wall_dir(c.x, c.y)
			if wall_dir == Vector2i.ZERO:
				continue
			var too_close := false
			var cand_pos := Vector2(c.x + 0.5, c.y + 0.5)
			for l in player.lockers:
				if cand_pos.distance_to(Vector2(l.position.x, l.position.z)) < 2.0:
					too_close = true
					break
			if too_close:
				continue
			# клетка у стены рядом с дверным проёмом -- шкафчик своей коллизией
			# (слой 8) перегородил бы единственный проход в дверь. doors уже
			# построены (см. порядок в _build), так что можем свериться. Держим
			# зазор и от самого проёма, и от его горловины уже ВНУТРИ комнаты
			# (d.pos сидит в стене снаружи -- см. _build_door_frame), иначе
			# шкафчик у стены впритык к проёму всё равно зажимал бы проход.
			var blocks_door := false
			for d in doors:
				var mouth: Vector2 = d.pos - Vector2(d.dir.x, d.dir.y)
				if cand_pos.distance_to(d.pos) < 1.2 or cand_pos.distance_to(mouth) < 1.2:
					blocks_door = true
					break
			if blocks_door:
				continue
			var wx: float = c.x + 0.5 + wall_dir.x * 0.22
			var wz: float = c.y + 0.5 + wall_dir.y * 0.22
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			var locker_size := Vector3(0.5, 1.8, 0.5)
			mesh.mesh.size = locker_size
			mesh.material_override = locker_mat
			# без источника света шкафчик был из той же серии жалоб "не
			# видно" -- у сундука/камня/спички уже есть маячок, у шкафчика
			# не было вовсе. Холодный тусклый белый -- под цвет металла, не
			# золотой, как у ключей/сундука, чтобы силуэт не путался с ними.
			_add_beacon(mesh, Color(0.65, 0.7, 0.78), 0.3, 1.7, 0.5)
			# физическая ручка + шов двери -- раньше единственным намёком на
			# "это шкаф, а не просто ящик" была плоская текстура; при слабом
			# освещении и с новыми ящиками-декором того же размера рядом
			# силуэт был неотличим. Ручка/шов -- уже настоящая геометрия,
			# не текстура, читается в темноте лучше.
			# передняя грань (в сторону от стены) -- локальные оси меша не
			# повёрнуты (look_at тут не звался), так что смещение считаем от
			# направления к стене явно, а не жёстко зашитой осью: для
			# шкафчика у стены по X передняя грань смотрит по Z, и наоборот.
			var front := Vector3(-wall_dir.x, 0, -wall_dir.y) * 0.26
			var side := Vector3(0, 1, 0) if wall_dir.x != 0 else Vector3(1, 0, 0)
			var seam := MeshInstance3D.new()
			seam.mesh = BoxMesh.new()
			seam.mesh.size = Vector3(0.03, locker_size.y - 0.14, 0.02) if wall_dir.x == 0 \
				else Vector3(0.02, locker_size.y - 0.14, 0.03)
			seam.material_override = locker_mat
			seam.position = front
			mesh.add_child(seam)
			var handle_mat := StandardMaterial3D.new()
			handle_mat.albedo_color = Color(0.72, 0.68, 0.5)
			handle_mat.metallic = 0.7
			handle_mat.roughness = 0.3
			var handle := MeshInstance3D.new()
			handle.mesh = BoxMesh.new()
			handle.mesh.size = Vector3(0.05, 0.16, 0.05)
			handle.material_override = handle_mat
			handle.position = front + side * 0.16 + Vector3(0, -0.05, 0)
			mesh.add_child(handle)
			# как и у сундука -- своя коллизия (см. _add_prop_collision), но
			# при входе в шкафчик игрок телепортируется ровно на его позицию
			# (см. player._try_interact): столкновение с СОБСТВЕННЫМ
			# шкафчиком на время прятки гасится через collision_mask, а не
			# отключением коллизии тут, иначе игрок застрянет в стене при
			# выходе из шкафчика раньше, чем коллизия успеет вернуться.
			var locker_root := _add_prop_collision(mesh, Vector3(wx, 0.9, wz), locker_size)
			player.lockers.append(locker_root)

## "a struck match doesn't survive the descent; scatter a few fresh ones" /
## "rocks to throw as a lure; a fresh handful each floor" (gen.c) -- этой
## части не было в Godot-порте вовсе: items.gd выдавал ровно 2 спички и
## 2 камня один раз на весь забег (сброс только на новую игру, НЕ на
## спуск), и подобрать добавочные было решительно негде -- level_gen ни
## разу не клал predметы на пол. 2-3 спички и 2-3 камня на этаж, не ближе
## 4 клеток (по Манхэттену) от старта -- как в C.
func _place_pickups(start_cell: Vector2i) -> void:
	# оба -- подбираемые предметы, а не декор (щебень/кости рядом), поэтому
	# оба чуть светятся, как и сундук -- иначе на почти чёрном полу вдали
	# от факелов их физически невозможно заметить, только споткнуться.
	var match_mat := StandardMaterial3D.new()
	match_mat.albedo_texture = _matchbox_texture()
	match_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	match_mat.emission_enabled = true
	match_mat.emission = Color(0.5, 0.16, 0.08)
	match_mat.emission_energy_multiplier = 0.22
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_texture = _rockpick_texture()
	rock_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	rock_mat.metallic = 0.15
	rock_mat.roughness = 0.55
	rock_mat.emission_enabled = true
	rock_mat.emission = Color(0.45, 0.45, 0.48)
	rock_mat.emission_energy_multiplier = 0.12

	var mp: int = 2 + randi() % 2
	var tries := 0
	while matchpicks.size() < mp and tries < 400:
		tries += 1
		var x: int = 1 + randi() % (MW - 2)
		var y: int = 1 + randi() % (MH - 2)
		if not is_open(x, y) or absi(x - start_cell.x) + absi(y - start_cell.y) < 4:
			continue
		var pos := Vector2(x + 0.5, y + 0.5)
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.16, 0.06, 0.10)
		mesh.material_override = match_mat
		mesh.position = Vector3(pos.x, 0.06, pos.y)
		mesh.rotation.y = randf() * TAU
		_add_beacon(mesh, Color(1.0, 0.35, 0.15), 0.4, 1.8, 0.12)
		props_root.add_child(mesh)
		matchpicks.append({"pos": pos, "active": true, "mesh": mesh})

	tries = 0
	var rp: int = 2 + randi() % 2
	while rockpicks.size() < rp and tries < 400:
		tries += 1
		var x: int = 1 + randi() % (MW - 2)
		var y: int = 1 + randi() % (MH - 2)
		if not is_open(x, y) or absi(x - start_cell.x) + absi(y - start_cell.y) < 4:
			continue
		var pos := Vector2(x + 0.5, y + 0.5)
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.20, 0.17, 0.20)   # чуть крупнее -- раньше терялся на полу
		mesh.material_override = rock_mat
		mesh.position = Vector3(pos.x, 0.085 + FLOOR_CLEARANCE, pos.y)
		mesh.rotation.y = randf() * TAU
		_add_beacon(mesh, Color(0.8, 0.8, 0.9), 0.35, 1.8, 0.15)
		props_root.add_child(mesh)
		rockpicks.append({"pos": pos, "active": true, "mesh": mesh})

	# шашка -- редкий предмет: не каждый этаж, максимум одна за раз, в
	# отличие от 2-3 спичек/камней. Приманка сильная (тянет монстра на
	# 16с непрерывно), поэтому не должна быть таким же расходником.
	if randf() < 0.6:
		var flare_mat := StandardMaterial3D.new()
		flare_mat.albedo_texture = _flarepick_texture()
		flare_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		flare_mat.emission_enabled = true
		flare_mat.emission = Color(0.55, 0.1, 0.05)
		flare_mat.emission_energy_multiplier = 0.22
		tries = 0
		while flarepicks.size() < 1 and tries < 400:
			tries += 1
			var x: int = 1 + randi() % (MW - 2)
			var y: int = 1 + randi() % (MH - 2)
			if not is_open(x, y) or absi(x - start_cell.x) + absi(y - start_cell.y) < 4:
				continue
			var pos := Vector2(x + 0.5, y + 0.5)
			var mesh := MeshInstance3D.new()
			mesh.mesh = CylinderMesh.new()
			mesh.mesh.top_radius = 0.05
			mesh.mesh.bottom_radius = 0.05
			mesh.mesh.height = 0.22
			mesh.material_override = flare_mat
			mesh.position = Vector3(pos.x, 0.11, pos.y)
			mesh.rotation.y = randf() * TAU
			mesh.rotation.x = deg_to_rad(90)   # лежит на боку, как выроненная гильза
			_add_beacon(mesh, Color(1.0, 0.35, 0.1), 0.4, 1.8, 0.12)
			props_root.add_child(mesh)
			flarepicks.append({"pos": pos, "active": true, "mesh": mesh})

	# обмотки -- тоже редкие и максимум одни за раз, как шашка: защитный
	# предмет, а не расходник вроде спичек/камней.
	if randf() < 0.55:
		var wrap_mat := StandardMaterial3D.new()
		wrap_mat.albedo_texture = _wrappick_texture()
		wrap_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		wrap_mat.roughness = 1.0
		wrap_mat.emission_enabled = true
		wrap_mat.emission = Color(0.3, 0.28, 0.22)
		wrap_mat.emission_energy_multiplier = 0.15
		tries = 0
		while wrappicks.size() < 1 and tries < 400:
			tries += 1
			var x: int = 1 + randi() % (MW - 2)
			var y: int = 1 + randi() % (MH - 2)
			if not is_open(x, y) or absi(x - start_cell.x) + absi(y - start_cell.y) < 4:
				continue
			var pos := Vector2(x + 0.5, y + 0.5)
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.22, 0.09, 0.16)
			mesh.material_override = wrap_mat
			mesh.position = Vector3(pos.x, 0.075, pos.y)
			mesh.rotation.y = randf() * TAU
			_add_beacon(mesh, Color(0.75, 0.7, 0.6), 0.3, 1.6, 0.1)
			props_root.add_child(mesh)
			wrappicks.append({"pos": pos, "active": true, "mesh": mesh})

## подбор спичек/камней/шашек/обмоток на ходу, без E (см. PICKUP_DIST в
## main.c) -- звук тот же pickup.wav, что и у ключей.
func _collect_pickups(p: Vector2) -> void:
	for m in matchpicks:
		if not m.active:
			continue
		if p.distance_to(m.pos) < ITEM_PICKUP_DIST:
			m.active = false
			m.mesh.visible = false
			items.match_count += 1
			_play_pickup_sound(m.pos)
	for r in rockpicks:
		if not r.active:
			continue
		if p.distance_to(r.pos) < ITEM_PICKUP_DIST:
			r.active = false
			r.mesh.visible = false
			items.rock_count += 1
			_play_pickup_sound(r.pos)
	for fl in flarepicks:
		if not fl.active:
			continue
		if p.distance_to(fl.pos) < ITEM_PICKUP_DIST:
			fl.active = false
			fl.mesh.visible = false
			items.flare_count += 1
			_play_pickup_sound(fl.pos)
	for wr in wrappicks:
		if not wr.active:
			continue
		if p.distance_to(wr.pos) < ITEM_PICKUP_DIST:
			wr.active = false
			wr.mesh.visible = false
			items.wrap_count += 1
			_play_pickup_sound(wr.pos)

## "маячок" на подбираемых предметах -- этаж намеренно почти чёрный всюду,
## кроме пятен света у факелов (см. _setup_dungeon_env), и одной лишь
## подсветки материала эмиссией (см. rock_mat/match_mat/chest_mat выше)
## оказалось мало: "камней не видно, ключей нет" -- жалоба на то, что сами
## предметы физически неразличимы в темноте между факелами, не просто
## тусклые. Даёт маленький источник света, который виден издалека, как и
## сами факелы -- вешается на mesh (а не на обёртку с коллизией), чтобы
## гаснуть вместе с ним при mesh.visible=false на подборе/открытии.
func _add_beacon(mesh: Node3D, color: Color, energy: float, beacon_range: float, y_off: float) -> void:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = beacon_range
	light.shadow_enabled = false
	light.position = Vector3(0, y_off, 0)
	mesh.add_child(light)

func _play_pickup_sound(pos: Vector2) -> void:
	var snd := AudioStreamPlayer3D.new()
	snd.stream = load("res://assets/pickup.wav")
	snd.unit_size = 3.0
	snd.max_distance = 12.0
	snd.position = Vector3(pos.x, 0.3, pos.y)
	props_root.add_child(snd)
	snd.play()
	snd.finished.connect(snd.queue_free)

## "качественное наполнение комнат" -- раньше кроме сундука/шкафчиков
## комнаты были пустыми коробками, разве что стены и пол. Раскидывает по
## каждой комнате 2-5 куч щебня/ящиков/костей на свободных местах, плюс
## паутину по углам у потолка -- декоративно, без коллизии (как и у
## сундуков/шкафчиков выше), монстр по-прежнему ходит по клеточной сетке.
## доля комнат (кроме старта и выхода), которые вместо обычного набора
## декора (щебень/ящик/стол/кости) становятся "камерами" -- клетки вдоль
## стен, лужи крови на полу. Было в самой первой C-сборке (RM_CELLS,
## commit 53b774f) -- в Godot-порт так и не попало, комнаты этого вида
## тут никогда не существовали.
const CELL_ROOM_CHANCE := 0.22

func _place_room_dressing(exit_room_idx: int) -> void:
	var rubble_mat := StandardMaterial3D.new()
	rubble_mat.albedo_texture = _rubble_texture()
	rubble_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var crate_mat := StandardMaterial3D.new()
	crate_mat.albedo_texture = _crate_texture()
	crate_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var bone_mat := StandardMaterial3D.new()
	bone_mat.albedo_texture = _bone_texture()
	bone_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# стол -- та же изношенная древесина, что у ящика (_crate_texture), но
	# тонированная теплее, под столешницу, а не тарный горбыль
	var desk_mat := StandardMaterial3D.new()
	desk_mat.albedo_texture = _crate_texture()
	desk_mat.albedo_color = Color(0.62, 0.46, 0.3)
	desk_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var web_mat := StandardMaterial3D.new()
	web_mat.albedo_texture = _web_texture()
	web_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	web_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	web_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	web_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	web_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cage_mat := StandardMaterial3D.new()
	cage_mat.albedo_texture = _cage_texture()
	cage_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	cage_mat.metallic = 0.3
	cage_mat.roughness = 0.55
	var blood_mat := StandardMaterial3D.new()
	blood_mat.albedo_texture = _blood_texture()
	blood_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	blood_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	blood_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# уже занятые места -- сундуки, шкафчики, дверь выхода, дверные проёмы
	# коридоров -- клатер их не перекрывает. Раньше дверные проёмы вообще
	# не учитывались: ящик мог встать прямо у прохода, физически (после
	# того как мебель получила коллизию) перегораживая единственный путь
	# в дверь -- жалоба "коробки мешают пройти в дверь".
	var occupied: Array = []
	for c in chests:
		occupied.append(c.pos)
	for l in player.lockers:
		occupied.append(Vector2(l.position.x, l.position.z))
	for d in doors:
		occupied.append(d.pos)
		# и клетка сразу ВНУТРИ комнаты у этого проёма: d.pos сидит в стене
		# снаружи, поэтому проверки на 1.3 от него не хватало, чтобы удержать
		# ящик/стол от посадки ровно в горловину прохода. dir смотрит наружу,
		# так что вычитаем его, чтобы шагнуть внутрь комнаты.
		occupied.append(d.pos - Vector2(d.dir.x, d.dir.y))
	occupied.append(exit_pos)
	if not altar.is_empty():
		occupied.append(altar.pos)

	for ri in range(rooms.size()):
		var r: Rect2i = rooms[ri]
		if ri != 0 and ri != exit_room_idx and randf() < CELL_ROOM_CHANCE:
			_dress_cell_room(r, cage_mat, blood_mat, occupied)
			if randf() < 0.6:
				var cell_corners := [
					Vector2(r.position.x + 0.35, r.position.y + 0.35),
					Vector2(r.position.x + r.size.x - 0.35, r.position.y + 0.35),
					Vector2(r.position.x + 0.35, r.position.y + r.size.y - 0.35),
					Vector2(r.position.x + r.size.x - 0.35, r.position.y + r.size.y - 0.35),
				]
				var cell_corner: Vector2 = cell_corners[randi() % cell_corners.size()]
				_spawn_cobweb(cell_corner.x, cell_corner.y, web_mat)
			continue
		var n: int = 2 + randi() % 4
		var placed := 0
		var tries := 0
		while placed < n and tries < n * 6:
			tries += 1
			var cx: float = r.position.x + 0.7 + randf() * max(r.size.x - 1.4, 0.1)
			var cy: float = r.position.y + 0.7 + randf() * max(r.size.y - 1.4, 0.1)
			var pos := Vector2(cx, cy)
			var clash := false
			for o in occupied:
				if pos.distance_to(o) < 1.3:
					clash = true
					break
			if clash:
				continue
			occupied.append(pos)
			placed += 1
			var roll := randf()
			if roll < 0.35:
				_spawn_rubble(pos, rubble_mat)
			elif roll < 0.6:
				# не каждый ящик стоит обыскивать -- иначе "обыщи всё подряд"
				# обесценивает саму находку. Максимум 2 обыскиваемых на этаж,
				# остальные -- чистый декор, как и раньше.
				var supply: bool = supply_crates.size() < 2 and randf() < 0.3
				_spawn_crate(pos, crate_mat, supply)
			elif roll < 0.8:
				_spawn_desk(pos, desk_mat)
			else:
				_spawn_bones(pos, bone_mat)
		# паутина в углу у потолка -- туда взгляд заходит редко, самое
		# место для детали, которая читается только если приглядеться
		if randf() < 0.6:
			var corners := [
				Vector2(r.position.x + 0.35, r.position.y + 0.35),
				Vector2(r.position.x + r.size.x - 0.35, r.position.y + 0.35),
				Vector2(r.position.x + 0.35, r.position.y + r.size.y - 0.35),
				Vector2(r.position.x + r.size.x - 0.35, r.position.y + r.size.y - 0.35),
			]
			var corner: Vector2 = corners[randi() % corners.size()]
			_spawn_cobweb(corner.x, corner.y, web_mat)

## Порт tint_for из render.c: каждая тема комнаты (вход/выход/сокровищница)
## красит стены в свой оттенок поверх общей палитры биома -- вход тёплый
## "очаг", комната сундука золотисто-"алтарная", выход в нездоровый
## зеленоватый. В Godot-порте этого не было вовсе: все комнаты одного этажа
## делили ровно один и тот же материал стен/пола, ни одна не выделялась.
## GridMap не тонируется по клеткам так дёшево, как в C (там это простая
## вершинная покраска), поэтому вместо перекраски геометрии кладём мягкий
## цветной свет поверх комнаты -- тот же эффект "эта комната другая на
## вид", другим механизмом.
func _place_room_theme_lights(exit_room_idx: int, start: Rect2i) -> void:
	var start_pos := Vector2(start.position.x + start.size.x / 2.0, start.position.y + start.size.y / 2.0)
	_add_theme_light(start_pos, Color(1.0, 0.9, 0.74), max(start.size.x, start.size.y) * 0.9, 0.18)
	var er: Rect2i = rooms[exit_room_idx]
	_add_theme_light(exit_pos, Color(0.55, 1.15, 0.68), max(er.size.x, er.size.y) * 0.95, 0.22)
	for c in chests:
		_add_theme_light(c.pos, Color(1.25, 0.92, 0.48), 2.4, 0.14)

func _add_theme_light(pos: Vector2, color: Color, rng: float, energy: float) -> void:
	var light := OmniLight3D.new()
	light.position = Vector3(pos.x, 1.3, pos.y)
	light.light_color = color
	light.light_energy = energy
	light.omni_range = rng
	light.shadow_enabled = false
	props_root.add_child(light)

func _spawn_rubble(pos: Vector2, mat: StandardMaterial3D) -> void:
	var n := 2 + randi() % 2
	for _i in range(n):
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		var s := Vector3(0.18 + randf() * 0.22, 0.12 + randf() * 0.18, 0.18 + randf() * 0.22)
		mesh.mesh.size = s
		mesh.material_override = mat
		var off := Vector2(randf_range(-0.22, 0.22), randf_range(-0.22, 0.22))
		mesh.position = Vector3(pos.x + off.x, s.y / 2.0 + FLOOR_CLEARANCE, pos.y + off.y)
		mesh.rotation.y = randf() * TAU
		props_root.add_child(mesh)

## is_supply: часть ящиков (максимум 2 за этаж, см. вызов выше) прячут
## внутри бонусный расходник (спичка/камень/шашка/обмотки) -- обыскиваются
## по E, как шкафчик, но не занимают collision-слой шкафчиков (то же
## взаимодействие, другой набор объектов, см. player.gd::near_crate).
## Отмечены тёплым маячком, как сундук/подбираемые предметы -- иначе
## неотличимы от десятков чисто декоративных ящиков в комнате.
func _spawn_crate(pos: Vector2, mat: StandardMaterial3D, is_supply: bool = false) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var crate_size := Vector3(0.5, 0.5, 0.5)
	mesh.mesh.size = crate_size
	mesh.material_override = mat
	mesh.rotation.y = randf() * TAU
	# в отличие от щебня/костей рядом -- цельный ящик достаточно крупный,
	# чтобы об него было странно проходить насквозь; та же коллизия, что и
	# у сундука/шкафчика (см. _add_prop_collision)
	_add_prop_collision(mesh, Vector3(pos.x, 0.25 + FLOOR_CLEARANCE, pos.y), crate_size)
	if randf() < 0.35:
		var mesh2 := MeshInstance3D.new()
		mesh2.mesh = BoxMesh.new()
		mesh2.mesh.size = Vector3(0.38, 0.38, 0.38)
		mesh2.material_override = mat
		mesh2.position = Vector3(pos.x + randf_range(-0.06, 0.06), 0.5 + 0.19, pos.y + randf_range(-0.06, 0.06))
		mesh2.rotation.y = randf() * TAU
		props_root.add_child(mesh2)
	if is_supply:
		_add_beacon(mesh, Color(1.0, 0.82, 0.35), 0.4, 2.0, 0.32)
		supply_crates.append({"pos": pos, "active": true, "mesh": mesh})

## обыск ящика по E (см. player.gd::_try_interact/near_crate) -- гасит
## маячок и один раз выдаёт случайный расходник, тем же звуком, что и
## подбор на ходу.
func search_crate(entry: Dictionary) -> void:
	if not entry.active:
		return
	entry.active = false
	for child in entry.mesh.get_children():
		if child is OmniLight3D:
			child.visible = false
	var roll := randf()
	if roll < 0.4:
		items.match_count += 1
	elif roll < 0.7:
		items.rock_count += 1
	elif roll < 0.85:
		items.flare_count += 1
	else:
		items.wrap_count += 1
	_play_pickup_sound(entry.pos)

## Алтарь -- "shrine" из README и _update_shrine_hum (shrine.wav) до сих пор
## был только звуком у ближайшего сундука, без физического объекта. Один
## гарантированный на этаж (не в стартовой/выходной комнате, не впритык к
## сундуку/двери), с реальной коллизией. E рядом даёт разовое восстановление
## рассудка -- единственный источник "почти бесплатной" передышки помимо
## того, что и так копится в тишине (см. player.gd::_update_sanity).
func _place_altar(exit_room_idx: int, start: Rect2i) -> void:
	altar = {}
	var start_center := Vector2(start.position.x + start.size.x / 2.0, start.position.y + start.size.y / 2.0)
	var candidates: Array = range(1, rooms.size()).filter(func(i): return i != exit_room_idx)
	candidates.shuffle()
	for ri in candidates:
		var r: Rect2i = rooms[ri]
		var cx: float = r.position.x + 0.6 + randf() * max(r.size.x - 1.2, 0.1)
		var cy: float = r.position.y + 0.6 + randf() * max(r.size.y - 1.2, 0.1)
		var pos := Vector2(cx, cy)
		if pos.distance_to(start_center) < 3.0 or pos.distance_to(exit_pos) < 2.0:
			continue
		var clash := false
		for c in chests:
			if pos.distance_to(c.pos) < 1.4:
				clash = true
				break
		if not clash:
			for d in doors:
				# и проём, и его горловина внутри комнаты (d.pos сидит в стене
				# снаружи -- см. _build_door_frame): у алтаря настоящая коллизия,
				# в горловине он так же перегородил бы проход, как ящик/шкафчик.
				var mouth: Vector2 = d.pos - Vector2(d.dir.x, d.dir.y)
				if pos.distance_to(d.pos) < 1.2 or pos.distance_to(mouth) < 1.2:
					clash = true
					break
		if clash:
			continue
		_build_altar(pos)
		return

func _build_altar(pos: Vector2) -> void:
	const PED_SIZE := Vector3(0.5, 0.6, 0.5)
	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = Color(0.32, 0.30, 0.34)
	stone_mat.roughness = 1.0
	var pedestal := MeshInstance3D.new()
	pedestal.mesh = BoxMesh.new()
	pedestal.mesh.size = PED_SIZE
	pedestal.material_override = stone_mat
	var candle_mat := StandardMaterial3D.new()
	candle_mat.albedo_color = Color(0.9, 0.85, 0.6)
	candle_mat.emission_enabled = true
	candle_mat.emission = Color(1.0, 0.6, 0.2)
	candle_mat.emission_energy_multiplier = 1.6
	for i in range(3):
		var ang: float = TAU * i / 3.0
		var candle := MeshInstance3D.new()
		candle.mesh = BoxMesh.new()
		candle.mesh.size = Vector3(0.05, 0.16, 0.05)
		candle.material_override = candle_mat
		candle.position = Vector3(cos(ang) * 0.14, PED_SIZE.y / 2.0 + 0.08, sin(ang) * 0.14)
		pedestal.add_child(candle)
	_add_beacon(pedestal, Color(1.0, 0.65, 0.3), 0.6, 2.6, 0.5)
	_add_prop_collision(pedestal, Vector3(pos.x, PED_SIZE.y / 2.0 + FLOOR_CLEARANCE, pos.y), PED_SIZE)
	altar = {"pos": pos, "active": true, "mesh": pedestal}

## молитва у алтаря по E (см. player.gd::_try_interact/near_altar) -- гасит
## маячок, разовое восстановление рассудка, тот же звук, что и у подбора.
func pray_at_altar() -> void:
	if altar.is_empty() or not altar.active:
		return
	altar.active = false
	player.sanity = clamp(player.sanity + 0.35, 0.0, 1.0)
	for child in altar.mesh.get_children():
		if child is OmniLight3D:
			child.visible = false
	_play_pickup_sound(altar.pos)

## Стол -- первая мебель комнаты, которая не сундук/шкафчик/ящик: столешница
## + четыре ножки, с реальной коллизией (см. _add_prop_collision), как и
## остальная крупная мебель. С шансом 0.5 регистрирует свою столешницу в
## desk_note_spots -- notes.gd кладёт туда записку плашмя вместо того,
## чтобы всегда пришпиливать её к стене (см. notes.gd::_place_notes).
func _spawn_desk(pos: Vector2, mat: StandardMaterial3D) -> void:
	const TOP_H := 0.72
	const TOP_SIZE := Vector3(0.9, 0.06, 0.5)
	# _add_prop_collision зануляет position корневого узла и делает его
	# ребёнком StaticBody3D, стоящего в мировой точке pos (см. саму функцию)
	# -- поэтому все дочерние смещения ниже считаем относительно ЦЕНТРА
	# коллизионной коробки (мировой Y = TOP_H/2), а не относительно пола.
	var legs_parent := Node3D.new()
	legs_parent.rotation.y = randf() * TAU
	var top := MeshInstance3D.new()
	top.mesh = BoxMesh.new()
	top.mesh.size = TOP_SIZE
	top.material_override = mat
	top.position = Vector3(0, TOP_H / 2.0 + TOP_SIZE.y / 2.0, 0)
	legs_parent.add_child(top)
	for lx in [-1, 1]:
		for lz in [-1, 1]:
			var leg := MeshInstance3D.new()
			leg.mesh = BoxMesh.new()
			leg.mesh.size = Vector3(0.06, TOP_H, 0.06)
			leg.material_override = mat
			leg.position = Vector3(lx * (TOP_SIZE.x / 2.0 - 0.05), 0, lz * (TOP_SIZE.z / 2.0 - 0.05))
			legs_parent.add_child(leg)
	# коллизия на весь габарит стола разом -- проще и дешевле, чем отдельная
	# форма на каждую ножку, и всё равно не даёт пройти сквозь столешницу
	_add_prop_collision(legs_parent, Vector3(pos.x, TOP_H / 2.0, pos.y), Vector3(TOP_SIZE.x, TOP_H, TOP_SIZE.z))
	if randf() < 0.5:
		desk_note_spots.append({"pos": pos, "y": TOP_H + TOP_SIZE.y / 2.0})

func _spawn_bones(pos: Vector2, mat: StandardMaterial3D) -> void:
	var n := 3 + randi() % 3
	for _i in range(n):
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.32 + randf() * 0.14, 0.045, 0.06)
		mesh.material_override = mat
		var off := Vector2(randf_range(-0.28, 0.28), randf_range(-0.28, 0.28))
		mesh.position = Vector3(pos.x + off.x, 0.025, pos.y + off.y)
		mesh.rotation.y = randf() * TAU
		props_root.add_child(mesh)

func _spawn_cobweb(cx: float, cy: float, mat: StandardMaterial3D) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	mesh.mesh.size = Vector2(0.55, 0.55)
	mesh.material_override = mat
	mesh.position = Vector3(cx, float(WALL_H) - 0.32, cy)
	props_root.add_child(mesh)

## "камера" -- клетки вдоль стен вместо обычного щебня/ящиков/стола, лужи
## крови на полу между ними. occupied передаётся по ссылке (Array в
## GDScript -- reference type) и пополняется позициями клеток, чтобы
## последующие комнаты того же этажа их не перекрывали.
func _dress_cell_room(r: Rect2i, cage_mat: StandardMaterial3D, blood_mat: StandardMaterial3D, occupied: Array) -> void:
	var wall_cells: Array = []
	for y in range(r.position.y, r.position.y + r.size.y):
		for x in range(r.position.x, r.position.x + r.size.x):
			if is_open(x, y) and _wall_dir(x, y) != Vector2i.ZERO:
				wall_cells.append(Vector2i(x, y))
	wall_cells.shuffle()

	var cage_positions: Array = []
	var n_cages: int = 2 + randi() % 3
	for c in wall_cells:
		if cage_positions.size() >= n_cages:
			break
		var pos := Vector2(c.x + 0.5, c.y + 0.5)
		var clash := false
		for o in occupied:
			if pos.distance_to(o) < 1.1:
				clash = true
				break
		if not clash:
			for cp in cage_positions:
				if pos.distance_to(cp) < 1.3:
					clash = true
					break
		if clash:
			continue
		_spawn_cage(pos, _wall_dir(c.x, c.y), cage_mat)
		cage_positions.append(pos)
		occupied.append(pos)

	var n_blood: int = 2 + randi() % 2
	var placed := 0
	var tries := 0
	while placed < n_blood and tries < n_blood * 8:
		tries += 1
		var bx: float = r.position.x + 0.6 + randf() * max(r.size.x - 1.2, 0.1)
		var by: float = r.position.y + 0.6 + randf() * max(r.size.y - 1.2, 0.1)
		var pos := Vector2(bx, by)
		var clash := false
		for cp in cage_positions:
			if pos.distance_to(cp) < 0.9:
				clash = true
				break
		if clash:
			continue
		_spawn_blood_pool(pos, blood_mat)
		placed += 1

## прутья клетки, вжатой в стену -- пять вертикальных ржавых прутов + верхняя
## перекладина, тем же приёмом "сдвиг к стене + look_at по wall_dir", что и
## у записок/факелов (см. notes.gd::_place_notes) -- после look_at локальная
## X идёт вдоль стены, ровно то, что нужно для ряда прутьев.
func _spawn_cage(pos: Vector2, wall_dir: Vector2i, mat: StandardMaterial3D) -> void:
	const BAR_H := 1.7
	const WIDTH := 0.8
	var root := Node3D.new()
	root.position = Vector3(pos.x + wall_dir.x * 0.42, 0, pos.y + wall_dir.y * 0.42)
	# look_at требует, чтобы узел уже был в дереве сцены (иначе у него нет
	# глобального трансформа) -- как и mesh.look_at в notes.gd, добавляем в
	# props_root ДО look_at, а не после. Раньше был обратный порядок --
	# "Node not inside tree" в логе, ошибка на каждую клетку каждого этажа.
	props_root.add_child(root)
	root.look_at(root.position + Vector3(wall_dir.x, 0, wall_dir.y), Vector3.UP)
	for i in range(5):
		var t: float = (i / 4.0) - 0.5
		var bar := MeshInstance3D.new()
		bar.mesh = BoxMesh.new()
		bar.mesh.size = Vector3(0.04, BAR_H, 0.04)
		bar.material_override = mat
		bar.position = Vector3(t * WIDTH, BAR_H / 2.0, 0)
		root.add_child(bar)
	var rail := MeshInstance3D.new()
	rail.mesh = BoxMesh.new()
	rail.mesh.size = Vector3(WIDTH + 0.06, 0.05, 0.05)
	rail.material_override = mat
	rail.position = Vector3(0, BAR_H - 0.02, 0)
	root.add_child(rail)
	cage_spots.append(pos)

## лужа крови на полу -- плоская декаль, тем же базисом "плашмя + случайный
## поворот", что и записка на столе (см. notes.gd::_place_notes), и тем же
## FLOOR_CLEARANCE, что и у щебня/камней/ящиков -- иначе декаль ровно на
## y=0 копланарна полу и мерцает тем самым z-fighting'ом, который здесь уже
## однажды чинили.
func _spawn_blood_pool(pos: Vector2, mat: StandardMaterial3D) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = QuadMesh.new()
	var s: float = 0.7 + randf() * 0.6
	mesh.mesh.size = Vector2(s, s)
	mesh.material_override = mat
	mesh.position = Vector3(pos.x, FLOOR_CLEARANCE, pos.y)
	mesh.transform.basis = Basis(Vector3.UP, randf() * TAU) * Basis(Vector3.RIGHT, -PI / 2.0)
	props_root.add_child(mesh)

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

	# dev-хук NIGHTFALL_SHOWCRATE: встать перед первым обыскиваемым ящиком
	# этажа (см. _spawn_crate::is_supply) -- их максимум 2 на этаж и позиция
	# случайна, вручную дойти для скриншота неудобно.
	if OS.get_environment("NIGHTFALL_SHOWCRATE") != "" and not supply_crates.is_empty():
		var sc = supply_crates[0]
		player.position = Vector3(sc.pos.x - 0.9, 0.9, sc.pos.y)
		player.look_at(Vector3(sc.pos.x, 0.9, sc.pos.y), Vector3.UP)

	# dev-хук NIGHTFALL_SHOWDESK: встать над первым столом с запиской на
	# столешнице (см. _spawn_desk/desk_note_spots) -- удобно для скриншота,
	# не обходя весь этаж в поисках подходящей комнаты.
	if OS.get_environment("NIGHTFALL_SHOWDESK") != "" and not desk_note_spots.is_empty():
		var ds = desk_note_spots[0]
		player.position = Vector3(ds.pos.x, ds.y + 1.1, ds.pos.y + 0.01)
		player.look_at(Vector3(ds.pos.x, ds.y, ds.pos.y), Vector3.UP)

	# dev-хук NIGHTFALL_SHOWALTAR: встать перед алтарём (см. _place_altar) --
	# один на этаж, позиция случайна среди не-стартовых/не-выходных комнат.
	if OS.get_environment("NIGHTFALL_SHOWALTAR") != "" and not altar.is_empty():
		player.position = Vector3(altar.pos.x - 0.8, 0.9, altar.pos.y)
		player.look_at(Vector3(altar.pos.x, 0.7, altar.pos.y), Vector3.UP)

	# dev-хук NIGHTFALL_SHOWCELL: встать перед первой клеткой "камерной"
	# комнаты (см. _dress_cell_room) -- шанс 22% на комнату, не на каждом
	# этаже есть, удобнее подождать нужный этаж, чем обходить все комнаты.
	if OS.get_environment("NIGHTFALL_SHOWCELL") != "" and not cage_spots.is_empty():
		var cs: Vector2 = cage_spots[0]
		player.position = Vector3(cs.x, 0.9, cs.y - 1.2)
		player.look_at(Vector3(cs.x, 0.9, cs.y), Vector3.UP)

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
