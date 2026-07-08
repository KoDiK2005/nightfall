extends CanvasLayer
## Экран заголовка -- порт draw_title из hud.c. Enter начинает игру.

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	visible = GameState.state == GameState.State.TITLE

func _on_state_changed(new_state: GameState.State) -> void:
	visible = new_state == GameState.State.TITLE

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and (event.keycode == KEY_ENTER or event.keycode == KEY_SPACE):
		GameState.start_new_game()
