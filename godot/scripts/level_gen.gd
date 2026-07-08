extends Node
## Порт генерации уровня из gen.c (generate_rooms): несколько случайных
## непересекающихся прямоугольных комнат, соединённых Г-образными
## коридорами. Заполняет две GridMap (стены/пол) получившейся сеткой.
## Дальше сюда же лягут темы комнат/биомы -- пока только форма уровня.

const MW := 29
const MH := 21
const WALL_ITEM := 0
const FLOOR_ITEM := 1

var map: Array = []   # map[y][x] == true, если клетка открыта (пол)
var rooms: Array = [] # Rect2i(x, y, w, h) на каждую комнату

@onready var wall_map: GridMap = $"../WallGridMap"
@onready var floor_map: GridMap = $"../FloorGridMap"
@onready var player: CharacterBody3D = $"../Player"

func _ready() -> void:
	randomize()
	_generate()
	_paint()
	_spawn_player()
	if OS.get_environment("NIGHTFALL_GDTRACE") != "":
		print("GDTRACE rooms=%d player_pos=%s wall_items=%d floor_items=%d" % [
			rooms.size(), player.position, wall_map.get_used_cells().size(), floor_map.get_used_cells().size()])

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

func _spawn_player() -> void:
	if rooms.is_empty() or player == null:
		return
	var start: Rect2i = rooms[0]
	var cx: float = start.position.x + start.size.x / 2.0
	var cy: float = start.position.y + start.size.y / 2.0
	player.position = Vector3(cx, 0.1, cy)
