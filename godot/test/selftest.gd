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

	# 1b) проходимость дверей: ни один prop с коллизией (StaticBody3D на слое
	# 8 -- сундук/шкафчик/ящик) не должен стоять в горловине дверного проёма,
	# иначе он физически перегораживает единственный путь в дверь (жалоба
	# "некоторые вещи не дают пройти в двери"). Игрок -- капсула r=0.35,
	# проём -- клетка 1.0, так что коллайдер (полуразмер ~0.25) ближе ~0.6 к
	# центру горловины уже не пропускает. Перебираем несколько свежих этажей,
	# чтобы поймать редкий неудачный расклад, а не только текущую генерацию.
	var doorway_clear := true
	for _f in range(6):
		lg._build_level()
		await process_frame
		for d in lg.doors:
			var mouth := Vector2(d.pos.x - d.dir.x, d.pos.y - d.dir.y)
			for body in lg.props_root.get_children():
				if not (body is StaticBody3D and body.collision_layer == 8):
					continue
				var bp := Vector2(body.position.x, body.position.z)
				if bp.distance_to(mouth) < 0.6 or bp.distance_to(d.pos) < 0.6:
					doorway_clear = false
	check(doorway_clear, "ни один коллайдер не стоит в горловине дверного проёма")

	# 1c) генерация на разной глубине: этаж строится остовным деревом коридоров
	# (см. level_gen.gd::_connect_rooms), и на глубоких этажах с малым числом
	# комнат легко нарваться на два дефекта -- отрезанный карман пола (BFS не
	# достаёт) и нехватку комнат под ключи (сундуков меньше, чем нужно ключей,
	# => дверь выхода не откроется никогда, софт-лок). Гоняем несколько глубин.
	var gen_ok := true
	var supply_ok := true
	for depth in [4, 8, 12]:
		gs.depth = depth
		for _rep in range(4):
			gs.state = 1
			lg._build_level()
			await process_frame
			var sc := Vector2i(int(player.position.x), int(player.position.z))
			var fd: Array = lg.flood_from(sc)
			for yy in range(lg.MH):
				for xx in range(lg.MW):
					if lg.is_open(xx, yy) and fd[yy][xx] >= (1 << 20):
						gen_ok = false
			if lg.chests.size() != lg.keys_left or lg.keys_left != lg.num_keys:
				supply_ok = false
	check(gen_ok, "на всех глубинах нет отрезанных от старта клеток пола")
	check(supply_ok, "на всех глубинах сундуков ровно под запас ключей (нет софт-лока)")
	# вернуть чистый этаж глубины 1 для остальных секций
	gs.depth = 1
	lg._build_level()
	await process_frame

	# 2) подбор ключей: реальный путь -- просто наступаем на сундук, без E
	# (жалоба "хочу, чтобы ключ подбирался наступанием, а не по E"; см.
	# level_gen.gd::_process, try_pickup_nearby(p) теперь вызывается каждый
	# кадр безусловно, тем же приёмом, что и подбор спичек/камней). Двигаем
	# игрока и просто ждём кадр -- _process сработает сам, без единого
	# нажатия клавиши, в отличие от прежней версии теста.
	var first_chest: Dictionary = lg.chests[0]
	check(rad_to_deg(first_chest.lid_pivot.rotation.x) == 0.0, "крышка сундука закрыта до подбора")
	check(first_chest.key_icon.visible, "значок ключа виден на закрытом сундуке")
	var picked := 0
	var expected_keys: int = lg.num_keys
	for c in lg.chests.duplicate():
		player.position = Vector3(c.pos.x, 0.1, c.pos.y)
		var before: int = lg.keys_left
		await process_frame
		if lg.keys_left == before - 1:
			picked += 1
	check(picked == expected_keys, "ключи подобраны наступанием, без E (%d/%d)" % [picked, expected_keys])
	check(lg.keys_left == 0, "keys_left обнулился после сбора всех ключей")
	check(lg.exit_door_open, "дверь выхода открылась после последнего ключа")
	check(not first_chest.key_icon.visible, "значок ключа спрятан после подбора")
	for _i in range(20):
		await process_frame
	check(abs(lg.exit_door_pivot.rotation.y) > 0.1, "дверь выхода реально повернулась (анимация идёт)")
	check(abs(first_chest.lid_pivot.rotation.x) > 0.1, "крышка сундука реально распахнулась (анимация идёт)")
	check(first_chest.active == false, "сундук помечен неактивным, но объект остаётся в сцене (не спрятан целиком)")

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

	# 5) спичка: периодически "мерцает" шумом-приманкой, пока горит, даже
	# без прямой видимости монстра (см. items.gd::_process, MATCH_GLOW_PERIOD)
	check(items.match_count == 2, "стартовый запас спичек -- 2")
	items._strike_match()
	check(items.match_count == 1, "чирк тратит счётчик")
	await process_frame
	check(player.lit_by_match, "чирк выставляет player.lit_by_match")
	lg.noise_t = 0.0   # снимаем шум самого чирка -- проверяем именно периодическое мерцание
	items._match_glow_timer = 0.0
	await process_frame
	check(lg.noise_t > 0.0, "горящая спичка периодически шумит сама по себе")

	# 6) обмотки: тратят счётчик, выставляют player.muffled на время действия
	check(items.wrap_count == 1, "стартовый запас обмоток -- 1")
	items._wrap_feet()
	check(items.wrap_count == 0, "использование обмоток тратит счётчик")
	await process_frame
	check(player.muffled, "обмотки выставляют player.muffled")
	items.wrap_burn = 0.0
	await process_frame
	check(not player.muffled, "player.muffled снимается, когда обмотки догорели")

	# 7) обыскиваемый ящик: даёт ровно один расходник и деактивируется --
	# спавн реальных supply_crates рандомный (макс. 2 на этаж), поэтому тут
	# подсовываем фиктивную запись напрямую в search_crate, а не полагаемся
	# на то, что этому конкретно сгенерированному этажу повезло с ящиком.
	var dummy_mesh := MeshInstance3D.new()
	var fake_crate := {"pos": Vector2(lg.exit_pos.x, lg.exit_pos.y), "active": true, "mesh": dummy_mesh}
	var total_before: int = items.match_count + items.rock_count + items.flare_count + items.wrap_count
	lg.search_crate(fake_crate)
	check(not fake_crate.active, "обыск ящика деактивирует запись")
	var total_after: int = items.match_count + items.rock_count + items.flare_count + items.wrap_count
	check(total_after == total_before + 1, "обыск ящика выдаёт ровно один расходник")
	lg.search_crate(fake_crate)
	var total_repeat: int = items.match_count + items.rock_count + items.flare_count + items.wrap_count
	check(total_repeat == total_after, "повторный обыск того же ящика ничего не даёт")

	# 7b) реальный путь ввода E, а не прямой вызов метода: раньше player.gd/
	# notes.gd/story_level.gd проверяли "event is InputEventAction", а
	# физическое нажатие клавиши в Godot всегда приходит как InputEventKey
	# -- условие никогда не выполнялось в настоящей игре (E не открывал
	# шкафчик/ящик/алтарь/записку), но самотесты этого не ловили, потому что
	# дёргали try_pickup_nearby/search_crate/pray_at_altar напрямую в обход
	# _unhandled_input. Строим настоящий InputEventKey и гоняем его через
	# реальный обработчик записки, чтобы этот класс бага больше не проходил
	# незамеченным (тот же приём, что уже использует selftest_pause.gd).
	var notes_node: Node = main.find_child("Notes", true, false)
	if notes_node and not notes_node.notes.is_empty():
		var note: Dictionary = notes_node.notes[0]
		player.position = Vector3(note.pos.x, 0.1, note.pos.y)
		await process_frame
		check(not notes_node.near_note.is_empty(), "игрок у записки -- near_note выставлен")
		var e_key := InputEventKey.new()
		e_key.physical_keycode = KEY_E
		e_key.pressed = true
		notes_node._unhandled_input(e_key)
		check(notes_node.reading, "настоящее нажатие E (InputEventKey) открывает записку")
		notes_node._unhandled_input(e_key)
		check(not notes_node.reading, "повторное нажатие E закрывает записку")

	# 8) алтарь: один гарантированный на этаж, молитва один раз поднимает
	# рассудок и гасит себя
	check(not lg.altar.is_empty(), "алтарь сгенерирован на этаже")
	if not lg.altar.is_empty():
		check(lg.altar.active, "свежий алтарь активен")
		player.sanity = 0.3
		lg.pray_at_altar()
		check(not lg.altar.active, "молитва деактивирует алтарь")
		check(absf(player.sanity - 0.65) < 0.001, "молитва поднимает рассудок на 0.35 (%.3f)" % player.sanity)
		var sanity_after_first: float = player.sanity
		lg.pray_at_altar()
		check(absf(player.sanity - sanity_after_first) < 0.001, "повторная молитва у того же алтаря ничего не даёт")
		player.sanity = 0.9
		lg.altar.active = true
		lg.pray_at_altar()
		check(player.sanity <= 1.0, "молитва не поднимает рассудок выше 1.0 (%.3f)" % player.sanity)

	# 9) камерная комната: генерация редкая (22%/комнату), поэтому тут не
	# полагаемся на удачу с конкретным этажом -- дёргаем сами builder-функции
	# напрямую и проверяем, что они не падают и действительно кладут объекты.
	var dummy_cage_mat := StandardMaterial3D.new()
	var dummy_blood_mat := StandardMaterial3D.new()
	var props_before: int = lg.props_root.get_child_count()
	var cage_spots_before: int = lg.cage_spots.size()
	lg._spawn_cage(Vector2(lg.exit_pos.x, lg.exit_pos.y), Vector2i(1, 0), dummy_cage_mat)
	lg._spawn_blood_pool(Vector2(lg.exit_pos.x, lg.exit_pos.y), dummy_blood_mat)
	check(lg.cage_spots.size() == cage_spots_before + 1, "_spawn_cage регистрирует позицию в cage_spots")
	check(lg.props_root.get_child_count() == props_before + 2, "клетка и лужа крови добавлены в сцену")

	# 9b2) регресс: сенс во время pause_timer ("прислушивается" в SEARCH) не
	# должен намертво замораживать монстра на весь HUNT -- баг был именно
	# в этом: state переключался в HUNT, а pause_timer оставался > 0
	# навсегда, потому что декремент живёт только в ветке SEARCH.
	var pmon: Node = player.monster
	pmon.mon_type = pmon.MonType.STALKER
	pmon.state = pmon.State.SEARCH
	pmon.pause_timer = 1.0
	pmon.position = Vector3(2.0, 0.1, 0.0)
	player.position = Vector3(2.0, 0.9, 0.0)   # вплотную -- гарантированный sensed
	player.hidden = false
	pmon._sense(0.016)
	check(pmon.state == pmon.State.HUNT, "сенс во время паузы всё равно переводит в HUNT")
	check(pmon.pause_timer == 0.0, "переход в HUNT сбрасывает pause_timer -- монстр не застревает навсегда")
	pmon.state = pmon.State.WANDER
	pmon.pick_wander()

	# 9c) красться: присед глушит слух. Берём Слухача (слепого -- зрение не
	# мешает), ставим игрока в 5 клетках и "идущим" (velocity шага). Идущего
	# он слышит (радиус ~7.2), крадущегося на том же месте -- нет (радиус
	# ужат множителем ~0.45). Разница только в player.crouched.
	var lmon: Node = player.monster
	lmon.mon_type = lmon.MonType.LISTENER
	player.hidden = false
	player.sanity = 1.0
	player.velocity = Vector3(2.6, 0, 0)     # шаг: >0.5 и <3.5 => WALK-слух
	lmon.position = Vector3(0.0, 0.1, 0.0)
	player.position = Vector3(5.0, 0.9, 0.0)
	lg.noise_t = 0.0
	check(not player.crouched, "по умолчанию не крадёшься")
	check(player.crouch_speed < player.walk_speed, "красться медленнее ходьбы")

	lmon.state = lmon.State.WANDER
	player.crouched = false
	lmon._sense(0.016)
	check(lmon.state == lmon.State.HUNT, "идущего игрока Слухач слышит за 5 клеток")

	lmon.state = lmon.State.WANDER
	lg.noise_t = 0.0
	player.crouched = true
	lmon._sense(0.016)
	check(lmon.state != lmon.State.HUNT, "крадущегося на тех же 5 клетках Слухач НЕ слышит")
	player.crouched = false
	player.velocity = Vector3.ZERO

	# 10) поимка: ставим игрока вплотную к монстру -- физика должна поймать
	var mon: Node = player.monster
	player.hidden = false
	player.position = mon.position
	for _i in range(8):
		await physics_frame
	check(gs.state == STATE_CAUGHT, "монстр вплотную = экран поимки")

	print("=== SELFTEST %s (%d провалов) ===" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(failures)
