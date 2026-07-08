extends SceneTree
## Headless-самотест паузы: Esc ставит/снимает паузу дерева и оверлей,
## Q на паузе выходит в главное меню. Гоняем обработчик ввода Pause-узла
## напрямую (в headless некому родить настоящий Esc).
## Запуск:  godot4 --headless -s test/selftest_pause.gd

const MODE_ENDLESS := 0
const STATE_TITLE := 0
const STATE_PLAY := 1

var failures: int = 0

func _initialize() -> void:
	_run()

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok: ", msg)
	else:
		failures += 1
		printerr("  FAIL: ", msg)

func _esc() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	return ev

func _q() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_Q
	ev.pressed = true
	return ev

func _run() -> void:
	var gs: Node = root.get_node("GameState")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	gs.start_new_game(MODE_ENDLESS)
	for _i in range(4):
		await process_frame

	var pause: Node = main.get_node("Pause")
	check(gs.state == STATE_PLAY, "стартовали в игре")
	check(not paused, "в игре пауза снята")

	# Esc -> пауза
	pause._unhandled_input(_esc())
	check(paused, "Esc ставит дерево на паузу")
	check(pause.visible, "оверлей паузы показан")

	# Esc -> снять паузу
	pause._unhandled_input(_esc())
	check(not paused, "второй Esc снимает паузу")
	check(not pause.visible, "оверлей паузы скрыт")

	# Esc -> пауза, Q -> в меню
	pause._unhandled_input(_esc())
	check(paused, "снова на паузе перед выходом")
	pause._unhandled_input(_q())
	check(not paused, "выход в меню снимает паузу")
	check(gs.state == STATE_TITLE, "Q возвращает на титульный экран")

	print("=== SELFTEST_PAUSE %s (%d провалов) ===" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(failures)
