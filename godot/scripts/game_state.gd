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
	elif OS.get_environment("NIGHTFALL_AUTOPLAY") != "":
		# сразу в бесконечный режим, минуя титульный экран -- удобно для
		# скриншотов/тестов (порт NIGHTFALL_AUTOPLAY из C-версии)
		call_deferred("start_new_game", Mode.ENDLESS)
	_fps_debug = OS.get_environment("NIGHTFALL_FPS") != ""

var _fps_debug: bool = false
var _fps_accum: float = 0.0
func _process(delta: float) -> void:
	# dev-хук NIGHTFALL_FPS: раз в секунду печатает FPS в stdout -- следим за
	# производительностью (слабый Intel UHD 620, десятки факелов-источников)
	if not _fps_debug:
		return
	_fps_accum += delta
	if _fps_accum >= 1.0:
		_fps_accum = 0.0
		print("FPS ", Engine.get_frames_per_second())

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
