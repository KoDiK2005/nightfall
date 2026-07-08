extends CanvasLayer
## Пауза (порт паузы по Esc из main.c). Во время игры Esc замораживает
## сцену (get_tree().paused) и показывает оверлей; Esc ещё раз -- продолжить,
## Q -- выйти в главное меню. Узел работает всегда (PROCESS_MODE_ALWAYS),
## иначе, поставив дерево на паузу, он не смог бы поймать Esc для снятия.

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	GameState.state_changed.connect(_on_state_changed)

func _on_state_changed(new_state: GameState.State) -> void:
	# при любом уходе из игры (поимка, выход в меню) снимаем паузу и оверлей,
	# чтобы пауза не "залипла" на следующем экране
	if new_state != GameState.State.PLAY:
		_set_paused(false)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Esc -- keycode (не зависит от раскладки); переключает паузу в игре
	if event.keycode == KEY_ESCAPE and GameState.state == GameState.State.PLAY:
		_set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()
	# Q (physical -- раскладка ЙЦУКЕН) выходит в меню, только когда на паузе
	elif visible and event.physical_keycode == KEY_Q:
		_set_paused(false)
		GameState.go_title()
		get_viewport().set_input_as_handled()

func _set_paused(p: bool) -> void:
	get_tree().paused = p
	visible = p
	# в игре мышь захвачена, на паузе -- отпускаем, чтобы курсор был виден
	if GameState.state == GameState.State.PLAY:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if p else Input.MOUSE_MODE_CAPTURED
