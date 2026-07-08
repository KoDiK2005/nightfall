extends CanvasLayer
## Записки-лор -- порт NOTES/NUM_NOTES из gen.c и draw_note из hud.c.
## E рядом с запиской открывает панель с текстом; E ещё раз закрывает.

const NUM_NOTES := 2
const PICKUP_DIST := 0.9

const NOTE_TEXTS := [
	["ФАКЕЛЫ ГАСНУТ САМИ.", "Я ЗАЖИГАЮ ИХ СНОВА.", "ОНО ЗНАЕТ ЧТО Я ЗДЕСЬ.", "ВНИЗУ."],
	["НЕ БЕГИ.", "ОНО СЛЫШИТ КАЖДЫЙ ШАГ.", "ИДИ МЕДЛЕННО.", "ДЫШИ ТИХО."],
	["ТРИ КЛЮЧА НА КАЖДУЮ ДВЕРЬ.", "ЗАЧЕМ ВНИЗ?", "ЧТО ОНИ ДЕРЖАТ", "НА САМОМ ДНЕ?"],
]

@onready var panel: Control = $Panel
@onready var text_label: Label = $Panel/TextLabel

var level_gen: Node = null
var player: CharacterBody3D = null
var notes: Array = []   # [{pos: Vector2, text: Array, mesh: MeshInstance3D}]
var reading: bool = false
var near_note: Dictionary = {}

func _ready() -> void:
	level_gen = get_tree().get_root().find_child("LevelGen", true, false)
	player = get_tree().get_root().find_child("Player", true, false)
	panel.visible = false
	if level_gen:
		level_gen.hud_changed.connect(_place_notes)

func _place_notes() -> void:
	for n in notes:
		n.mesh.queue_free()
	notes.clear()
	reading = false
	panel.visible = false

	var note_mat := StandardMaterial3D.new()
	note_mat.albedo_color = Color(0.82, 0.78, 0.66)
	note_mat.emission_enabled = true
	note_mat.emission = Color(0.3, 0.28, 0.2)

	var candidates: Array = range(1, level_gen.rooms.size())
	candidates.shuffle()
	for i in candidates:
		if notes.size() >= NUM_NOTES:
			break
		var r: Rect2i = level_gen.rooms[i]
		var cx: float = r.position.x + 0.5 + randi() % max(r.size.x - 1, 1)
		var cy: float = r.position.y + 0.5 + randi() % max(r.size.y - 1, 1)
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		mesh.mesh.size = Vector3(0.3, 0.4, 0.03)
		mesh.material_override = note_mat
		mesh.position = Vector3(cx, 1.0, cy)
		level_gen.props_root.add_child(mesh)
		notes.append({"pos": Vector2(cx, cy), "text": NOTE_TEXTS[randi() % NOTE_TEXTS.size()], "mesh": mesh})

func _unhandled_input(event: InputEvent) -> void:
	if GameState.state != GameState.State.PLAY:
		return
	if event is InputEventAction and event.action == "interact" and event.pressed:
		if reading:
			reading = false
			panel.visible = false
		elif not near_note.is_empty():
			reading = true
			text_label.text = "\n".join(near_note.text)
			panel.visible = true

func _process(_delta: float) -> void:
	if GameState.state != GameState.State.PLAY or player == null or reading:
		return
	near_note = {}
	var p := Vector2(player.position.x, player.position.z)
	for n in notes:
		if p.distance_to(n.pos) < PICKUP_DIST:
			near_note = n
			break
