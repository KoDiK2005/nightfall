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
var _note_texture: ImageTexture = null

func _ready() -> void:
	level_gen = get_tree().get_root().find_child("LevelGen", true, false)
	player = get_tree().get_root().find_child("Player", true, false)
	panel.visible = false
	if level_gen:
		level_gen.hud_changed.connect(_place_notes)

## Порт спрайта 5 из build_textures (render.c): бледный лист с рамкой чуть
## темнее и рядами строчек текста -- вместо сплошного ящика читается как
## приколоченный к стене листок, а не мебель.
func _build_note_texture() -> ImageTexture:
	const TEX := 64
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		for x in range(TEX):
			if x < 20 or x > 44 or y < 12 or y > 54:
				continue
			var edge: bool = x < 22 or x > 42 or y < 14 or y > 52
			var line: bool = x > 24 and x < 40 and (y - 18) % 6 < 1 and y < 50
			var c: Color
			if edge:
				c = Color(150 / 255.0, 140 / 255.0, 110 / 255.0)
			elif line:
				c = Color(90 / 255.0, 80 / 255.0, 60 / 255.0)
			else:
				c = Color(210 / 255.0, 200 / 255.0, 170 / 255.0)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

## клетки пола рядом со стеной -- как и факелы, записка пришпилена к стене,
## а не парит посреди комнаты (порт wall_dir-выбора для notes[] в gen.c)
func _wall_candidates() -> Array:
	var out: Array = []
	for y in range(1, level_gen.MH - 1):
		for x in range(1, level_gen.MW - 1):
			if not level_gen.is_open(x, y):
				continue
			if level_gen._wall_dir(x, y) != Vector2i.ZERO:
				out.append(Vector2i(x, y))
	return out

func _place_notes() -> void:
	for n in notes:
		n.mesh.queue_free()
	notes.clear()
	reading = false
	panel.visible = false

	if _note_texture == null:
		_note_texture = _build_note_texture()

	var note_mat := StandardMaterial3D.new()
	note_mat.albedo_texture = _note_texture
	note_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	note_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	note_mat.emission_enabled = true
	note_mat.emission = Color(0.35, 0.32, 0.24)
	note_mat.emission_texture = _note_texture
	note_mat.emission_energy_multiplier = 0.6

	var start: Rect2i = level_gen.rooms[0]
	var start_center := Vector2(start.position.x + start.size.x / 2.0, start.position.y + start.size.y / 2.0)

	# столы (level_gen.gd::_spawn_desk) дают вторую, не пришпиленную к стене
	# позу для записки -- лежит плашмя на столешнице. Разбираем их первыми,
	# остаток NUM_NOTES как раньше уходит на стены, чтобы не все записки
	# этажа выглядели одинаково развешанными.
	var desk_spots: Array = level_gen.desk_note_spots.duplicate()
	desk_spots.shuffle()
	for d in desk_spots:
		if notes.size() >= NUM_NOTES:
			break
		if Vector2(d.pos).distance_to(start_center) < 3.0:
			continue
		var mesh := MeshInstance3D.new()
		mesh.mesh = QuadMesh.new()
		mesh.mesh.size = Vector2(0.34, 0.40)
		mesh.material_override = note_mat
		mesh.position = Vector3(d.pos.x, d.y, d.pos.y)
		# базис явно, а не mesh.rotation.x/.z по отдельности -- Euler-порядок
		# Node3D.rotation неочевиден, компоновка через Basis однозначна:
		# сперва положить плашмя (тик вокруг своей X), потом уже произвольный
		# поворот "как её кто-то бросил на стол" вокруг мировой вертикали.
		mesh.transform.basis = Basis(Vector3.UP, randf() * TAU) * Basis(Vector3.RIGHT, -PI / 2.0)
		level_gen.props_root.add_child(mesh)
		notes.append({"pos": d.pos, "text": NOTE_TEXTS[randi() % NOTE_TEXTS.size()], "mesh": mesh})

	var candidates: Array = _wall_candidates()
	candidates.shuffle()
	for c in candidates:
		if notes.size() >= NUM_NOTES:
			break
		if Vector2(c).distance_to(start_center) < 3.0:
			continue
		var wall_dir: Vector2i = level_gen._wall_dir(c.x, c.y)
		var cx: float = c.x + 0.5
		var cy: float = c.y + 0.5
		var too_close := false
		for n in notes:
			if Vector2(cx, cy).distance_to(n.pos) < 2.0:
				too_close = true
				break
		if too_close:
			continue
		var nx: float = cx + wall_dir.x * 0.44
		var nz: float = cy + wall_dir.y * 0.44
		var mesh := MeshInstance3D.new()
		mesh.mesh = QuadMesh.new()
		mesh.mesh.size = Vector2(0.34, 0.40)
		mesh.material_override = note_mat
		mesh.position = Vector3(nx, 1.0, nz)
		level_gen.props_root.add_child(mesh)
		mesh.look_at(mesh.position + Vector3(wall_dir.x, 0, wall_dir.y), Vector3.UP)
		notes.append({"pos": Vector2(cx, cy), "text": NOTE_TEXTS[randi() % NOTE_TEXTS.size()], "mesh": mesh})

func _unhandled_input(event: InputEvent) -> void:
	if GameState.state != GameState.State.PLAY:
		return
	if event.is_action_pressed("interact"):
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
