extends Node
## Автозагружаемый синглтон (см. project.godot [autoload]) -- то немногое,
## что должно пережить пересборку уровня: текущий этаж, рекорд глубины и
## общее состояние игры (порт game_state/depth/best_depth из main.c).

enum State { TITLE, PLAY, CAUGHT }

signal state_changed(new_state: State)

var state: State = State.TITLE
var depth: int = 1
var best_depth: int = 1

func advance_floor() -> void:
	depth += 1
	if depth > best_depth:
		best_depth = depth

func start_new_game() -> void:
	depth = 1
	state = State.PLAY
	state_changed.emit(state)

func go_title() -> void:
	state = State.TITLE
	state_changed.emit(state)

func go_caught() -> void:
	if depth > best_depth:
		best_depth = depth
	state = State.CAUGHT
	state_changed.emit(state)
