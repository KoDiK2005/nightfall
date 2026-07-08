extends SceneTree
## Headless-самотест сюжетного режима (уровень 1, "Отрицание"). Проверяет,
## что дом строится и что сценарий проходит все фазы: подход к двери ->
## встреча с матерью -> своя комната наверху -> лестница между этажами.
## Запуск:  godot4 --headless -s test/selftest_story.gd

const MODE_STORY := 1
const PHASE_APPROACH := 0
const PHASE_CONFRONT := 1
const PHASE_AFTERMATH := 2

var failures: int = 0

func _initialize() -> void:
	_run()

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: ", msg)
	else:
		failures += 1
		printerr("  FAIL: ", msg)

func _run() -> void:
	var gs: Node = root.get_node("GameState")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	gs.start_new_game(MODE_STORY)
	for _i in range(5):
		await process_frame

	var story: Node = main.get_node("StoryWorld")
	var player: Node = main.get_node("Player")
	var wall_map: GridMap = main.get_node("WallGridMap")
	var floor_map: GridMap = main.get_node("FloorGridMap")

	print("[house] walls=%d floor=%d phase=%d" % [
		wall_map.get_used_cells().size(), floor_map.get_used_cells().size(), story.phase])
	check(wall_map.get_used_cells().size() > 100, "стены дома выставлены в GridMap")
	check(floor_map.get_used_cells().size() > 100, "пол дома выставлен в GridMap")
	check(story.phase == PHASE_APPROACH, "старт в фазе подхода")
	# по XZ, а не по всей точке: коллизия двора поднимает капсулу на "рост"
	# (пол-плоскость двора под ногами), так что Y после кадра физики уходит
	var spawn_xz := Vector2(story.SPAWN_POS.x, story.SPAWN_POS.z)
	var player_xz := Vector2(player.global_position.x, player.global_position.z)
	check(player_xz.distance_to(spawn_xz) < 0.5, "игрок на точке спавна у дороги")
	check(player.monster == null, "в отрицании нет монстра")

	# подход: дом стоит на плоской карте, дверь достижима от спавна по полу
	var start_cell := Vector2i(int(player.global_position.x), int(player.global_position.z))
	var dist: Array = _flood(story, start_cell)
	var door_cell := Vector2i(int(story.DOOR_POS.x), int(story.DOOR_POS.z))
	check(_reachable(dist, door_cell), "дверь дома достижима от спавна")

	# доводим игрока до двери -> должна начаться сцена с матерью
	player.global_position = story.DOOR_POS
	for _i in range(4):
		await process_frame
	check(story.phase == PHASE_CONFRONT, "у двери начинается сцена с матерью")
	check(story.mother != null and story.mother.visible, "мать появилась и видима")

	# прощёлкиваем все реплики матери -> он оказывается в своей комнате наверху
	var guard := 0
	while story.phase == PHASE_CONFRONT and guard < 40:
		story.skip_line()
		await process_frame
		guard += 1
	check(story.phase == PHASE_AFTERMATH, "после отповеди -- фаза свободного обхода")
	check(player.global_position.distance_to(story.KID1_POS) < 1.0, "игрок перенесён в детскую наверху")
	check(not story.mother.visible, "мать скрыта после сцены")

	# лестница вниз: у клетки STAIRS_DN должно перекинуть к STAIRS_DN_TO
	story.stairs_cooldown = 0.0
	player.global_position = Vector3(story.STAIRS_DN.x, 0.1, story.STAIRS_DN.y)
	for _i in range(4):
		await process_frame
	check(player.global_position.distance_to(story.STAIRS_DN_TO) < 1.0, "лестница вниз переносит на первый этаж")

	print("=== SELFTEST_STORY %s (%d провалов) ===" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(failures)

## локальный BFS по карте дома (story.is_open), чтобы не тянуть level_gen
func _flood(story: Node, target: Vector2i) -> Array:
	var mw: int = story.MW
	var mh: int = story.MH
	var dist: Array = []
	for _y in range(mh):
		var row: Array = []
		row.resize(mw)
		row.fill(1 << 20)
		dist.append(row)
	if not story.is_open(target.x, target.y):
		return dist
	dist[target.y][target.x] = 0
	var queue: Array = [target]
	var head := 0
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in dirs:
			var n: Vector2i = c + d
			if story.is_open(n.x, n.y) and dist[n.y][n.x] > dist[c.y][c.x] + 1:
				dist[n.y][n.x] = dist[c.y][c.x] + 1
				queue.append(n)
	return dist

func _reachable(dist: Array, cell: Vector2i) -> bool:
	if cell.y < 0 or cell.y >= dist.size() or cell.x < 0 or cell.x >= dist[0].size():
		return false
	return dist[cell.y][cell.x] < (1 << 20)
