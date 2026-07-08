extends Node
## Автозагружаемый синглтон (см. project.godot [autoload]) -- то немногое,
## что должно пережить пересборку уровня: текущий этаж, рекорд глубины и
## общее состояние игры (порт game_state/depth/best_depth из main.c).

enum State { TITLE, PLAY, CAUGHT }
enum Mode { ENDLESS, STORY }

signal state_changed(new_state: State)
signal mode_changed(new_mode: Mode)

var state: State = State.TITLE
var mode: Mode = Mode.ENDLESS
var depth: int = 1
var best_depth: int = 1

func _ready() -> void:
	if OS.get_environment("NIGHTFALL_STORY") != "":
		# ставим mode сразу (синхронно), чтобы LevelGen._ready() (запускается
		# позже, при построении дерева сцены) не успел собрать подземелье
		# для ENDLESS раньше, чем режим реально переключится на STORY --
		# сам переход состояния (сигналы/спавн) всё равно откладываем.
		mode = Mode.STORY
		call_deferred("start_new_game", Mode.STORY)

func advance_floor() -> void:
	depth += 1
	if depth > best_depth:
		best_depth = depth

func start_new_game(p_mode: Mode = Mode.ENDLESS) -> void:
	mode = p_mode
	depth = 1
	state = State.PLAY
	mode_changed.emit(mode)
	state_changed.emit(state)

func go_title() -> void:
	state = State.TITLE
	state_changed.emit(state)

func go_caught() -> void:
	if depth > best_depth:
		best_depth = depth
	state = State.CAUGHT
	state_changed.emit(state)
