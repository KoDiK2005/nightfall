extends CanvasLayer
## Экран заголовка -- порт draw_title из hud.c, плюс выбор режима
## (Бесконечный спуск / Сюжет), которого в C-версии нет отдельным
## экраном, но добавлен там же для того же выбора.

@onready var endless_label: Label = $EndlessLabel
@onready var story_label: Label = $StoryLabel

var sel: int = 0   # 0 = бесконечный, 1 = сюжет

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	visible = GameState.state == GameState.State.TITLE
	_update_labels()

func _on_state_changed(new_state: GameState.State) -> void:
	visible = new_state == GameState.State.TITLE

func _update_labels() -> void:
	var on := Color(0.86, 0.86, 0.86, 1)
	var off := Color(0.45, 0.45, 0.5, 1)
	endless_label.text = "> БЕСКОНЕЧНЫЙ СПУСК <" if sel == 0 else "БЕСКОНЕЧНЫЙ СПУСК"
	endless_label.modulate = on if sel == 0 else off
	story_label.text = "> СЮЖЕТ <" if sel == 1 else "СЮЖЕТ"
	story_label.modulate = on if sel == 1 else off

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_UP or event.keycode == KEY_DOWN or event.keycode == KEY_W or event.keycode == KEY_S:
			sel = 1 - sel
			_update_labels()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_SPACE:
			GameState.start_new_game(GameState.Mode.STORY if sel == 1 else GameState.Mode.ENDLESS)
