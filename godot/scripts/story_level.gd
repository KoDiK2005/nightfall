extends Node3D
## Сюжетный режим, первый срез (по мотивам story.c, но с нуля и заметно
## проще -- как и в C-версии, сначала одна комната, потом дом целиком).
## Двор без стен (открытая лужайка), дом-коробка с дверью, дорога от
## забора к порогу. Три воспоминания всплывают субтитрами по пути; у
## двери героя встречает мать без лица, отчитывает, и он оказывается
## в своей комнате.

const HOUSE_CENTER := Vector3(0, 0, 15)
const HOUSE_SIZE := Vector3(8, 2.5, 6)          # ширина, высота стен, глубина
const DOOR_POS := Vector3(0, 0, 12)             # порог -- южная стена дома
const SPAWN_POS := Vector3(0, 0.1, 2)
const MOTHER_POS := Vector3(0, 0, 13.0)   # чуть перед сплошной коробкой дома, а не внутри неё
const ROOM_POS := Vector3(15, 0.1, 15)

const MEMORY_Z := [5.0, 8.0, 11.0]
const MEMORY_TEXTS := [
	["МАТЬ КРИЧИТ ИЗ-ЗА РАЗБИТОЙ ТАРЕЛКИ.", "ЭТО НЕ ЗЛОСТЬ. ЭТО ВОСПИТАНИЕ.", "У ВСЕХ ТАК В СЕМЬЕ."],
	["ОТЕЦ СНОВА ЗАСНУЛ ПЕРЕД ТЕЛЕВИЗОРОМ.", "БУТЫЛКА НА ПОЛУ -- ОБЫЧНОЕ ДЕЛО.", "ЗНАЧИТ ВСЁ НОРМАЛЬНО."],
	["Я ЗАКРЫВАЮ ДВЕРЬ И НЕ ПЛАЧУ.", "НАДО ПРОСТО ВЫРАСТИ.", "ЗАБЫТЬ ОБ ЭТОМ."],
]
const MOTHER_LINES := [
	"ГДЕ ТЫ ШЛЯЛСЯ?",
	"ОПЯТЬ ОДНИ ПРОБЛЕМЫ ИЗ-ЗА ТЕБЯ.",
	"МАРШ В КОМНАТУ. НЕ ПОПАДАЙСЯ МНЕ НА ГЛАЗА.",
]
const MOTHER_LINE_DUR := 3.5
const MEMORY_POPUP_DUR := 6.0
const APPROACH_SPEED_MULT := 0.3

enum Phase { APPROACH, CONFRONT, AFTERMATH }
var phase: Phase = Phase.APPROACH
var memory_seen: Array = [false, false, false]
var mother: Node3D = null
var mother_line_idx: int = 0
var mother_line_timer: float = 0.0

@onready var player: CharacterBody3D = $"../Player"
@onready var subtitle: CanvasLayer = $"../StorySubtitle"

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	GameState.mode_changed.connect(_on_mode_changed)
	visible = GameState.mode == GameState.Mode.STORY

func _unhandled_input(event: InputEvent) -> void:
	if GameState.mode != GameState.Mode.STORY or GameState.state != GameState.State.PLAY:
		return
	if event is InputEventAction and event.action == "interact" and event.pressed:
		skip_line()

func _on_mode_changed(new_mode: GameState.Mode) -> void:
	visible = new_mode == GameState.Mode.STORY
	set_process(visible)
	set_physics_process(visible)

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY and GameState.mode == GameState.Mode.STORY:
		_start_denial()

func _start_denial() -> void:
	phase = Phase.APPROACH
	memory_seen = [false, false, false]
	player.velocity = Vector3.ZERO
	player.global_position = SPAWN_POS
	player.rotation.y = 0.0
	player.stamina = 1.0
	player.exhausted = false
	player.hidden = false
	player.monster = null   # без монстра -- этап "Отрицание" тихий
	if mother:
		mother.visible = false
	subtitle.hide_line()

func _process(delta: float) -> void:
	if GameState.state != GameState.State.PLAY or GameState.mode != GameState.Mode.STORY:
		return
	match phase:
		Phase.APPROACH:
			_process_approach(delta)
		Phase.CONFRONT:
			_process_confront(delta)
		Phase.AFTERMATH:
			pass   # он в своей комнате -- дальше следующий шаг порта

func _process_approach(_delta: float) -> void:
	# совсем медленный, тяжёлый шаг -- время прочитать всплывающие воспоминания
	player.story_speed_mult = APPROACH_SPEED_MULT
	var pz := player.global_position.z
	for i in range(MEMORY_Z.size()):
		if not memory_seen[i] and pz > MEMORY_Z[i] - 1.2 and pz < MEMORY_Z[i] + 1.2:
			memory_seen[i] = true
			subtitle.show_lines(MEMORY_TEXTS[i], MEMORY_POPUP_DUR)
	if player.global_position.distance_to(DOOR_POS) < 1.3:
		_begin_confront()

func _begin_confront() -> void:
	phase = Phase.CONFRONT
	player.story_speed_mult = 0.0
	if mother == null:
		mother = _make_mother()
		add_child(mother)
	mother.visible = true
	mother.global_position = MOTHER_POS
	mother_line_idx = 0
	mother_line_timer = MOTHER_LINE_DUR
	subtitle.show_lines([MOTHER_LINES[0]], MOTHER_LINE_DUR + 0.6)

func _process_confront(delta: float) -> void:
	mother_line_timer -= delta
	if mother_line_timer <= 0.0:
		mother_line_idx += 1
		if mother_line_idx >= MOTHER_LINES.size():
			_end_confront()
		else:
			mother_line_timer = MOTHER_LINE_DUR
			subtitle.show_lines([MOTHER_LINES[mother_line_idx]], MOTHER_LINE_DUR + 0.6)

func skip_line() -> void:
	if phase == Phase.CONFRONT:
		mother_line_timer = 0.0

func _end_confront() -> void:
	mother.visible = false
	player.story_speed_mult = 1.0
	player.global_position = ROOM_POS
	phase = Phase.AFTERMATH
	subtitle.hide_line()

func _make_mother() -> Node3D:
	var body := CharacterBody3D.new()
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.1, 0.12)
	mesh.mesh = capsule
	mesh.material_override = mat
	mesh.position = Vector3(0, 0.9, 0)
	body.add_child(mesh)
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.16
	head_mesh.height = 0.32
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.75, 0.72, 0.68)
	head.mesh = head_mesh
	head.material_override = head_mat
	head.position = Vector3(0, 1.75, 0)
	body.add_child(head)
	return body
