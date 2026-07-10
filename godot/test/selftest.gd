extends SceneTree
## Headless-самотест игрового цикла бесконечного режима. Не эмулирует ввод
## и рендер -- инстанцирует главную сцену, строит уровень и дёргает те же
## методы, что и геймплей (try_pickup_nearby/descend, ловля монстром), чтобы
## убедиться, что логика подбора ключей, спуска и поимки не сломана.
## Запуск:  godot4 --headless -s test/selftest.gd
##
## В режиме -s автозагрузки не видны как глобальные идентификаторы на этапе
## компиляции, поэтому GameState берём через дерево, а значения enum'ов --
## числами: Mode { ENDLESS=0, STORY=1 }, State { TITLE=0, PLAY=1, CAUGHT=2 }.

const MODE_ENDLESS := 0
const STATE_CAUGHT := 2

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
	if gs == null:
		printerr("GameState autoload не найден -- самотест не может идти")
		quit(1)
		return

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	gs.start_new_game(MODE_ENDLESS)
	for _i in range(5):
		await process_frame

	var lg: Node = main.get_node("LevelGen")
	var player: Node = main.get_node("Player")

	print("[gen] rooms=%d keys=%d torches=%d" % [lg.rooms.size(), lg.num_keys, lg.torches.size()])
	check(lg.rooms.size() >= 2, "уровень имеет минимум 2 комнаты")
	check(lg.num_keys >= 1 and lg.num_keys <= lg.MAX_KEYS, "число ключей в допустимом диапазоне")
	check(lg.chests.size() == lg.num_keys, "сундуков ровно столько же, сколько ключей")
	check(lg.keys_left == lg.num_keys, "в начале собрано 0 ключей")
	check(player.monster != null, "монстр заспавнен")

	# 1) связность: BFS от старта достаёт до выхода и до каждого сундука
	var start_cell := Vector2i(int(player.position.x), int(player.position.z))
	var dist: Array = lg.flood_from(start_cell)
	var exit_cell := Vector2i(int(lg.exit_pos.x), int(lg.exit_pos.y))
	check(dist[exit_cell.y][exit_cell.x] < (1 << 20), "выход достижим от старта")
	var all_chests_reachable := true
	for c in lg.chests:
		var cc := Vector2i(int(c.pos.x), int(c.pos.y))
		if dist[cc.y][cc.x] >= (1 << 20):
			all_chests_reachable = false
	check(all_chests_reachable, "все сундуки достижимы от старта")

	# 2) подбор ключей: телепортируемся на каждый сундук и дёргаем подбор
	var picked := 0
	var expected_keys: int = lg.num_keys
	for c in lg.chests.duplicate():
		player.position = Vector3(c.pos.x, 0.1, c.pos.y)
		var before: int = lg.keys_left
		var ok: bool = lg.try_pickup_nearby(Vector2(c.pos.x, c.pos.y))
		if ok and lg.keys_left == before - 1:
			picked += 1
	check(picked == expected_keys, "подобраны все ключи (%d/%d)" % [picked, expected_keys])
	check(lg.keys_left == 0, "keys_left обнулился после сбора всех ключей")
	check(lg.exit_door_open, "дверь выхода открылась после последнего ключа")
	for _i in range(20):
		await process_frame
	check(abs(lg.exit_door_pivot.rotation.y) > 0.1, "дверь выхода реально повернулась (анимация идёт)")

	# 3) спуск: на выходе с нулём ключей глубина растёт и строится новый уровень
	var depth_before: int = gs.depth
	player.sanity = 0.42   # накопленный страх не должен стираться спуском на новый этаж
	lg.descend()
	for _i in range(5):
		await process_frame
	check(gs.depth == depth_before + 1, "глубина выросла после спуска")
	check(lg.keys_left == lg.num_keys, "новый этаж выдал свежий набор ключей")
	check(player.sanity < 0.9, "рассудок не сбрасывается спуском на новый этаж (%.3f)" % player.sanity)

	# 4) шашка: втыкается на месте игрока, тратит счётчик, тянет noise на себя
	var items: Node = main.get_node("Items")
	check(items.flare_count == 1, "стартовый запас шашек -- 1")
	var flare_pos := Vector3(player.position.x, 0.02, player.position.z)
	player.position = flare_pos
	var flares_before: int = lg.props_root.get_child_count()
	lg.noise_t = 0.0   # старый шум (от сбора ключей выше) не должен маскировать шум шашки
	items._drop_flare()
	check(items.flare_count == 0, "бросок шашки тратит счётчик")
	check(lg.props_root.get_child_count() == flares_before + 1, "шашка добавлена в сцену")
	check(lg.noise_t > 0.0, "шашка сразу создаёт шум на своей позиции")
	var flare_noise_pos: Vector2 = lg.noise_pos
	check(flare_noise_pos.distance_to(Vector2(flare_pos.x, flare_pos.z)) < 0.01, "шум шашки -- ровно на месте броска")

	# 5) поимка: ставим игрока вплотную к монстру -- физика должна поймать
	var mon: Node = player.monster
	player.hidden = false
	player.position = mon.position
	for _i in range(8):
		await physics_frame
	check(gs.state == STATE_CAUGHT, "монстр вплотную = экран поимки")

	print("=== SELFTEST %s (%d провалов) ===" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(failures)
