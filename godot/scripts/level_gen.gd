extends Node
## Порт генерации уровня из gen.c (generate_rooms): несколько случайных
## непересекающихся прямоугольных комнат, соединённых Г-образными
## коридорами. Заполняет две GridMap (стены/пол) получившейся сеткой.
## Дальше сюда же лягут темы комнат/биомы -- пока только форма уровня.

const MW := 29
const MH := 21
const WALL_ITEM := 0
const FLOOR_ITEM := 1
const TORCH_SPACING := 2.6   # совпадает с TORCH_SPACING в render.c
const TORCH_SCENE := preload("res://scenes/torch.tscn")
const PICKUP_DIST := 0.9
const EXIT_DIST := 0.7
const MAX_KEYS := 6
const MONSTER_SCENE := preload("res://scenes/monster.tscn")
const NUM_LOCKERS := 5

var map: Array = []   # map[y][x] == true, если клетка открыта (пол)
var rooms: Array = [] # Rect2i(x, y, w, h) на каждую комнату
var torches: Array = []   # Node3D-инстансы факелов этого уровня

var num_keys: int = 3
var keys_left: int = 3
var chests: Array = []       # [{pos: Vector2, active: bool, mesh: MeshInstance3D}]
var exit_pos: Vector2 = Vector2.ZERO
var exit_mesh: MeshInstance3D = null
var monster: CharacterBody3D = null

signal hud_changed

@onready var wall_map: GridMap = $"../WallGridMap"
@onready var floor_map: GridMap = $"../FloorGridMap"
@onready var player: CharacterBody3D = $"../Player"
@onready var torch_root: Node3D = $"../Torches"
@onready var props_root: Node3D = $"../Props"

func _ready() -> void:
	randomize()
	_build_level()
	GameState.state_changed.connect(_on_state_changed)
	if OS.get_environment("NIGHTFALL_GDTRACE") != "":
		print("GDTRACE rooms=%d player_pos=%s wall_items=%d floor_items=%d torches=%d keys=%d" % [
			rooms.size(), player.position, wall_map.get_used_cells().size(),
			floor_map.get_used_cells().size(), torches.size(), num_keys])

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY:
		_build_level()

func _build_level() -> void:
	_generate()
	_paint()
	_place_torches()
	_place_keys_and_exit()
	_spawn_player()
	_spawn_monster()
	hud_changed.emit()

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
	monster.setup(self, player)
	player.monster = monster
	player.sanity = 1.0

func _process(_delta: float) -> void:
	if GameState.state != GameState.State.PLAY:
		return
	var p := Vector2(player.position.x, player.position.z)
	for c in chests:
		if not c.active:
			continue
		if p.distance_to(c.pos) < PICKUP_DIST and Input.is_action_just_pressed("interact"):
			c.active = false
			c.mesh.visible = false
			keys_left -= 1
			hud_changed.emit()
			if keys_left == 0:
				exit_mesh.get_active_material(0).albedo_color = Color(0.3, 1.0, 0.5)
	if keys_left == 0 and p.distance_to(exit_pos) < EXIT_DIST:
		GameState.advance_floor()
		_build_level()

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
				floor_map.set_cell_item(Vector3i(x, 0, y), FLOOR_ITEM)
			else:
				# стена рисуется, только если рядом есть открытая клетка --
				# как в build_world_mesh (render.c): по одной грани на
				# открытого соседа, а не сплошной блок камня повсюду.
				var neighbours_open: bool = is_open(x + 1, y) or is_open(x - 1, y) \
					or is_open(x, y + 1) or is_open(x, y - 1)
				if neighbours_open:
					wall_map.set_cell_item(Vector3i(x, 0, y), WALL_ITEM)

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

	var placed: Array = []   # Vector3(world_x, world_z, ...) центров факелов
	for c in candidates:
		var wall_dir := _wall_dir(c.x, c.y)
		if wall_dir == Vector2i.ZERO:
			continue
		var wx: float = c.x + 0.5 + wall_dir.x * 0.48
		var wz: float = c.y + 0.5 + wall_dir.y * 0.48
		var ok := true
		for p in placed:
			if Vector2(wx, wz).distance_to(Vector2(p.x, p.y)) < TORCH_SPACING:
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
	if exit_mesh:
		exit_mesh.queue_free()
		exit_mesh = null
	for child in props_root.get_children():
		child.queue_free()

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

	var key_gold := StandardMaterial3D.new()
	key_gold.albedo_color = Color(0.95, 0.8, 0.2)
	key_gold.emission_enabled = true
	key_gold.emission = Color(0.6, 0.45, 0.05)

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
		mesh.mesh.size = Vector3(0.3, 0.3, 0.3)
		mesh.material_override = key_gold
		mesh.position = Vector3(cx, 0.4, cy)
		props_root.add_child(mesh)
		chests.append({"pos": Vector2(cx, cy), "active": true, "mesh": mesh})
		placed_keys += 1

	var er: Rect2i = rooms[exit_room_idx]
	exit_pos = Vector2(er.position.x + er.size.x / 2.0, er.position.y + er.size.y / 2.0)
	var exit_red := StandardMaterial3D.new()
	exit_red.albedo_color = Color(1.0, 0.25, 0.25)
	exit_red.emission_enabled = true
	exit_red.emission = Color(0.6, 0.1, 0.1)
	exit_mesh = MeshInstance3D.new()
	exit_mesh.mesh = BoxMesh.new()
	exit_mesh.mesh.size = Vector3(0.8, 1.6, 0.15)
	exit_mesh.material_override = exit_red
	exit_mesh.position = Vector3(exit_pos.x, 0.8, exit_pos.y)
	props_root.add_child(exit_mesh)
	if keys_left == 0:
		exit_mesh.get_active_material(0).albedo_color = Color(0.3, 1.0, 0.5)

	_place_lockers(exit_room_idx)

## шкафчики, где можно спрятаться -- порт locker-плейсмента из reset_level
## (gen.c): по одному на комнату, не в стартовой/финальной.
func _place_lockers(exit_room_idx: int) -> void:
	player.lockers.clear()
	var locker_mat := StandardMaterial3D.new()
	locker_mat.albedo_color = Color(0.25, 0.28, 0.3)

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
	player.position = Vector3(cx, 0.1, cy)
