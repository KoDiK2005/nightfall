extends CanvasLayer
## Экран смерти -- порт ST_CAUGHT/draw_jumpscare. R начинает заново.

@onready var best_label: Label = $BestLabel

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	visible = GameState.state == GameState.State.CAUGHT

func _on_state_changed(new_state: GameState.State) -> void:
	visible = new_state == GameState.State.CAUGHT
	if visible:
		best_label.text = "РЕКОРД: ЭТАЖ %d" % GameState.best_depth

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# physical_keycode -- раскладка ЙЦУКЕН (физическая R по keycode = кириллица);
	# рестарт в том же режиме, в котором поймали, а не всегда в бесконечный
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_R:
		GameState.start_new_game(GameState.mode)
