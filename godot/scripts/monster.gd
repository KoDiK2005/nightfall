extends CharacterBody3D
## Порт мозга Сталкера из ai.c: три состояния (HUNT/SEARCH/WANDER),
## восприятие по зрению (дистанция + луч на стены) и по слуху (дистанция,
## громче при беге), навигация -- волновой поиск (BFS) по той же сетке,
## что и уровень, как gdist в C-версии.

enum State { WANDER, SEARCH, HUNT }

const SEE_RANGE := 7.0
const HEAR_WALK := 3.0
const HEAR_RUN := 6.5
const CATCH_DIST := 0.6
const CHECK_DIST := 1.0   # на таком расстоянии оно "проверяет" шкафчик
const SPEED := 1.55   # MONSTER_SPD в game.h

var state: State = State.WANDER
var target_cell: Vector2i = Vector2i.ZERO
var dist_grid: Array = []   # BFS-дистанции от target_cell, как gdist в C
var last_known: Vector2 = Vector2.ZERO
var search_time: float = 0.0

var level_gen: Node = null
var player: CharacterBody3D = null

func setup(p_level_gen: Node, p_player: CharacterBody3D) -> void:
	level_gen = p_level_gen
	player = p_player
	pick_wander()

func _physics_process(delta: float) -> void:
	if level_gen == null or player == null or GameState.state != GameState.State.PLAY:
		return
	_sense(delta)
	_move(delta)

	if player.hidden:
		# спрятался -- поймать может, только если оно рядом ищет/охотится
		# и оказалось у самого шкафчика (см. CHECK_DIST в main.c)
		if (state == State.HUNT or state == State.SEARCH) and player.lockers.size() > 0:
			var mypos2d := Vector2(position.x, position.z)
			var ppos2d := Vector2(player.position.x, player.position.z)
			if mypos2d.distance_to(ppos2d) < CHECK_DIST:
				player.hidden = false
				GameState.go_caught()
		return

	var d: float = Vector2(position.x, position.z).distance_to(Vector2(player.position.x, player.position.z))
	if d < CATCH_DIST:
		GameState.go_caught()

func _sense(delta: float) -> void:
	if player.hidden:
		return
	var mypos := Vector2(position.x, position.z)
	var ppos := Vector2(player.position.x, player.position.z)
	var d := mypos.distance_to(ppos)
	var sensed := false

	if d < SEE_RANGE and _has_los(ppos):
		sensed = true
	else:
		var speed := Vector2(player.velocity.x, player.velocity.z).length()
		var hear := HEAR_RUN if speed > 3.5 else HEAR_WALK
		if speed > 0.5 and d < hear:
			sensed = true

	if sensed:
		state = State.HUNT
		last_known = ppos
		set_target(Vector2i(int(ppos.x), int(ppos.y)))
	elif state == State.HUNT:
		state = State.SEARCH
		search_time = 8.0
		set_target(Vector2i(int(last_known.x), int(last_known.y)))
	elif state == State.SEARCH:
		_check_noise()
		search_time -= delta
		var here := Vector2i(int(position.x), int(position.z))
		if here == target_cell or search_time <= 0.0:
			state = State.WANDER
			pick_wander()
	elif state == State.WANDER:
		_check_noise()
		var here2 := Vector2i(int(position.x), int(position.z))
		if here2 == target_cell:
			pick_wander()

## порт шумовой приманки из ai.c: свежий шум (брошенный камень, зажжённая
## спичка, беготня) в пределах слышимости уводит его расследовать, даже
## если оно не видело и не слышало игрока напрямую.
func _check_noise() -> void:
	if level_gen.noise_t <= 0.0:
		return
	var mypos := Vector2(position.x, position.z)
	if mypos.distance_to(level_gen.noise_pos) < HEAR_RUN * 1.7:
		state = State.SEARCH
		search_time = 5.0
		set_target(Vector2i(int(level_gen.noise_pos.x), int(level_gen.noise_pos.y)))

## прямая видимость: луч игрок<->монстр не должен пересекать стены
## (см. has_los в gen.c, там -- пошаговая проверка по сетке; тут -- raycast)
func _has_los(ppos: Vector2) -> bool:
	var space := get_world_3d().direct_space_state
	var from := Vector3(position.x, 0.5, position.z)
	var to := Vector3(ppos.x, 0.5, ppos.y)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1   # стены (см. wall_map collision layer)
	var hit := space.intersect_ray(query)
	return hit.is_empty()

func set_target(cell: Vector2i) -> void:
	target_cell = cell
	dist_grid = level_gen.flood_from(cell)

## Как pick_wander в gen.c: иногда мимо ещё не открытого сундука, иначе
## просто случайная открытая клетка.
func pick_wander() -> void:
	if level_gen.chests.size() > 0 and randf() < 0.5:
		var active_chests: Array = level_gen.chests.filter(func(c): return c.active)
		if not active_chests.is_empty():
			var c = active_chests[randi() % active_chests.size()]
			set_target(Vector2i(int(c.pos.x), int(c.pos.y)))
			return
	var mw: int = level_gen.MW
	var mh: int = level_gen.MH
	for _i in range(64):
		var x: int = 1 + randi() % (mw - 2)
		var y: int = 1 + randi() % (mh - 2)
		if level_gen.is_open(x, y):
			set_target(Vector2i(x, y))
			return

func _move(delta: float) -> void:
	var cx := int(position.x)
	var cz := int(position.z)
	if cx < 0 or cz < 0 or cz >= dist_grid.size() or cx >= dist_grid[0].size():
		return
	var best: int = dist_grid[cz][cx]
	var best_cell := Vector2i(cx, cz)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d in dirs:
		var nx: int = cx + d.x
		var nz: int = cz + d.y
		if level_gen.is_open(nx, nz) and nz < dist_grid.size() and nx < dist_grid[0].size() \
				and dist_grid[nz][nx] < best:
			best = dist_grid[nz][nx]
			best_cell = Vector2i(nx, nz)
	var target_pos := Vector3(best_cell.x + 0.5, position.y, best_cell.y + 0.5)
	var dir := (target_pos - position)
	dir.y = 0
	if dir.length() > 0.05:
		velocity = dir.normalized() * SPEED
	else:
		velocity = Vector3.ZERO
	move_and_slide()
