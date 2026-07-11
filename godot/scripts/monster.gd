extends CharacterBody3D
## Порт мозга трёх ужасов из ai.c. Общий костяк -- три состояния
## (WANDER/SEARCH/HUNT) и волновой поиск (BFS) по сетке уровня (как gdist
## в C-версии); восприятие разное по типу:
##  STALKER  -- зрение (луч+дистанция) и слух, рвётся ближе на подходе
##  LISTENER -- слепой, но с намного более острым слухом
##  WATCHER  -- замирает, пока игрок на него смотрит, иначе мчится

enum State { WANDER, SEARCH, HUNT }
enum MonType { STALKER, LISTENER, WATCHER }

const SEE_RANGE := 7.0
const HEAR_WALK := 3.0
const HEAR_RUN := 6.5
const LISTENER_HEAR_WALK := 7.2   # HEAR_WALK * 2.4, как в ai.c
const LISTENER_HEAR_RUN := 12.4
const CATCH_DIST := 0.6
const CHECK_DIST := 1.0   # на таком расстоянии оно "проверяет" шкафчик
## было 1.55 (MONSTER_SPD из game.h) -- общее замедление темпа вместе с
## player.gd::walk_speed/run_speed (см. комментарий там). Монстр остаётся
## медленнее игрока на ходьбе/беге почти везде -- опасность не в том, что
## оно вас перегонит, а в том, что оно неотступно идёт и не устаёт.
const SPEED := 1.3
const WATCHER_RUSH_MULT := 2.3   # совпадает с render.c

## "с каждым этажом вниз оно быстрее и чутче" (см. README) -- раньше
## depth нигде, кроме выбора типа монстра и числа ключей, не участвовал:
## скорость и все дальности восприятия были фиксированными константами
## независимо от глубины. wear() -- та же кривая 0..1 к этажу ~13, что уже
## используется для износа текстур (Biomes) и утечки рассудка (player.gd).
static func wear() -> float:
	return clamp(float(GameState.depth - 1) / 12.0, 0.0, 1.0)

var mon_type: MonType = MonType.STALKER
var state: State = State.WANDER
var target_cell: Vector2i = Vector2i.ZERO
var dist_grid: Array = []   # BFS-дистанции от target_cell, как gdist в C
var last_known: Vector2 = Vector2.ZERO
var search_time: float = 0.0

var level_gen: Node = null
var player: CharacterBody3D = null
var frozen: bool = false   # dev-хук NIGHTFALL_SHOWMON: стоит на месте для скриншота

## Раньше тело было плоским billboard-квадом с нарисованным пиксель-артом --
## "плоский призрак", который выдавал себя силуэтом-карточкой при взгляде
## сбоку. Теперь это настоящий объёмный риг из капсул/сфер/конусов (торс,
## голова, две асимметричные руки с локтем и когтями, две ноги), собранный
## процедурно в _build_rig() -- то же самое "высокий сутулый силуэт с впалым
## лицом и тонкими когтистыми руками" (порт THE STALKER из render.c), но
## читаемое с любого ракурса, не только анфас. Кожа -- триплэйнарная
## процедурная текстура (шрамы/вены/кровоподтёки, _build_flesh_texture()),
## общая на все виды, тонированная по типу и раскрытая иначе для каждого:
## Слухач слеп -- без светящихся глаз, зато с чуткими ушами-рожками;
## Наблюдатель -- неестественно крупные немигающие глаза.
@onready var body: Node3D = $Body
static var _flesh_tex: ImageTexture = null
var flesh_mat: StandardMaterial3D = null
var eye_mat: StandardMaterial3D = null

## каждый вид носит свой оттенок -- дешёвый способ различить силуэты,
## не рисуя три разных модели (см. "each kind wears its own pallor")
const TYPE_TINT := {
	0: Color(1.0, 1.0, 1.0),     # STALKER -- как нарисовано
	1: Color(0.7, 0.78, 0.92),   # LISTENER -- бледнее, холодный синеватый
	2: Color(0.62, 0.2, 0.62),   # WATCHER -- неестественный лиловый
}
const EYE_COLOR := {
	0: Color(1.0, 0.28, 0.05),   # STALKER -- тлеющий оранжево-красный
	2: Color(0.85, 0.2, 0.95),   # WATCHER -- холодный лиловый, немигающий
}

## узлы рига, на которые опирается процедурная анимация (_animate_walk,
## _process) -- заполняются в _build_rig(), нужны как отдельные Node3D-пивоты
## (а не сразу MeshInstance3D), чтобы вращать конечности вокруг сустава,
## а не вокруг их геометрического центра
var torso_node: Node3D = null
var head_node: Node3D = null
var hip_l: Node3D = null
var hip_r: Node3D = null
var shoulder_l: Node3D = null
var shoulder_r: Node3D = null
var _torso_base_pos: Vector3 = Vector3.ZERO
var _stutter_timer: float = 0.0

## тайловая текстура рваной, шрамированной плоти -- рёбра, вены, кровавые
## и костяные вкрапления, крупные открытые раны. Используется через
## triplanar-проекцию (mat.uv1_triplanar), поэтому один и тот же тайл
## ложится без ручной UV-развёртки на любую капсулу/сферу рига -- ни швов,
## ни растяжения. Раньше была почти однотонная (база 0.15 ± 0.05, мелкий
## масштаб повторов) -- вблизи читалась просто как шумной серый ком, без
## различимых деталей. Теперь контраст в разы выше (рёбра светлее, раны
## темнее, крупнее сами пятна), плюс сгенерированная normal-карта из того же
## рельефа (_build_flesh_normal) -- рёбра/трещины реально выступают под
## светом факела, а не только раскрашены плоским цветом.
static func _build_flesh_texture() -> ImageTexture:
	if _flesh_tex != null:
		return _flesh_tex
	const N := 192
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var base_n := FastNoiseLite.new()
	base_n.seed = 1337
	base_n.frequency = 0.045
	var vein_n := FastNoiseLite.new()
	vein_n.seed = 91
	vein_n.frequency = 0.1
	vein_n.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var rib_n := FastNoiseLite.new()
	rib_n.seed = 53
	rib_n.frequency = 0.045
	for y in range(N):
		for x in range(N):
			var base: float = 0.12 + base_n.get_noise_2d(x, y) * 0.06
			var col := Color(base * 0.85, base, base * 0.75, 1.0)
			var vein: float = vein_n.get_noise_2d(x, y)
			if vein > 0.45:
				col = col.darkened(0.7)   # глубокие трещины/вены
			elif vein > 0.25:
				col = col.darkened(0.35)
			# рёбра/кость -- редкие неровные пятна обнажённой кости из
			# одного шумового поля (не периодическая волна -- та давала
			# ровные "зебровые" полосы по всему телу, читалось как ткань,
			# а не как редкие проступающие кости)
			var rib_v: float = rib_n.get_noise_2d(x, y * 0.6)
			if rib_v > 0.5:
				var bone: float = 0.48 + randf() * 0.12
				col = Color(bone, bone * 0.93, bone * 0.82, 1.0)
			var speck := randf()
			if speck > 0.982:
				col = Color(0.35, 0.03, 0.03, 1.0)    # кровавая крапинка
			elif speck > 0.965:
				col = Color(0.5, 0.45, 0.35, 1.0)     # бледный костяной скол
			img.set_pixel(x, y, col)
	# несколько крупных открытых ран поверх шумовой базы -- заметно крупнее
	# и темнее прежних, читаются с нескольких метров, а не только вплотную
	for _i in range(7):
		var wx := randi() % N
		var wy := randi() % N
		var wr: int = 6 + randi() % 10
		for dy in range(-wr, wr):
			for dx in range(-wr, wr):
				var px := wx + dx
				var py := wy + dy
				if px < 0 or py < 0 or px >= N or py >= N:
					continue
				if dx * dx + dy * dy < wr * wr:
					var edge: float = float(dx * dx + dy * dy) / float(wr * wr)
					img.set_pixel(px, py, Color(0.28, 0.02, 0.02, 1.0).lerp(Color(0.04, 0.006, 0.006, 1.0), edge))
	_flesh_tex = ImageTexture.create_from_image(img)
	return _flesh_tex

## normal-карта, построенная градиентом яркости той же текстуры (грубый
## Собель) -- рёбра и трещины получают настоящий рельеф под источником
## света вместо плоской раскраски, которая в почти чёрном подземелье
## (см. комментарий в _setup_dungeon_env про почти-чёрный этаж) едва
## читалась без прямого света в упор.
static var _flesh_normal: ImageTexture = null
static func _build_flesh_normal() -> ImageTexture:
	if _flesh_normal != null:
		return _flesh_normal
	var src := _build_flesh_texture().get_image()
	var n := src.get_width()
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in range(n):
		for x in range(n):
			var l := src.get_pixel(x, y).v
			var lx := src.get_pixel((x + 1) % n, y).v
			var ly := src.get_pixel(x, (y + 1) % n).v
			var dx: float = (l - lx) * 3.0
			var dy: float = (l - ly) * 3.0
			var nrm := Vector3(dx, dy, 1.0).normalized()
			img.set_pixel(x, y, Color(nrm.x * 0.5 + 0.5, nrm.y * 0.5 + 0.5, nrm.z * 0.5 + 0.5, 1.0))
	_flesh_normal = ImageTexture.create_from_image(img)
	return _flesh_normal

func _build_flesh_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _build_flesh_texture()
	mat.uv1_triplanar = true
	mat.uv1_triplanar_sharpness = 2.5
	mat.uv1_scale = Vector3(1.3, 1.3, 1.3)
	mat.normal_enabled = true
	mat.normal_texture = _build_flesh_normal()
	mat.normal_scale = 1.6
	mat.roughness = 0.82
	mat.metallic = 0.0
	mat.albedo_color = TYPE_TINT.get(mon_type, Color.WHITE)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# лёгкое ободковое свечение -- читается как контражур в темноте, а не
	# просто чёрный силуэт, даже без прямого света на нём
	mat.rim_enabled = true
	mat.rim = 0.4
	mat.rim_tint = 0.7
	return mat

func _build_eye_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var c: Color = EYE_COLOR.get(mon_type, Color(1.0, 0.28, 0.05))
	mat.albedo_color = c
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 6.0
	return mat

func _sphere(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	return m

## растянутый неестественно широкий оскал с редкими кривыми клыками --
## порт того же приёма из старого пиксель-арта (fang-паттерн в build_sprites/
## render.c), но нарисован на прозрачной нашлёпке поверх головы, а не
## запечён в общую кожу: у Слухача/Наблюдателя рот тоже есть (хищник есть
## хищник), просто не подписан явным "лицом" отдельно.
static var _face_tex: ImageTexture = null
static func _build_face_texture() -> ImageTexture:
	if _face_tex != null:
		return _face_tex
	const FW := 96
	const FH := 80
	var img := Image.create(FW, FH, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx: float = FW / 2.0
	# тень переносицы -- мягкий тёмный клин над рваным ртом
	for y in range(int(FH * 0.15), int(FH * 0.55)):
		for x in range(FW):
			var nx: float = (x - cx) / (FW * 0.14)
			var ny: float = (y - FH * 0.15) / (FH * 0.4)
			if abs(nx) < 1.0 - ny * 0.5:
				var a: float = clamp(0.35 - abs(nx) * 0.3, 0.0, 0.35)
				img.set_pixel(x, y, Color(0.02, 0.01, 0.01, a))
	# рот -- широкий рваный оскал в нижней трети, шире прежнего, неровные края
	var mouth_y0 := int(FH * 0.58)
	var mouth_y1 := int(FH * 0.92)
	for y in range(mouth_y0, mouth_y1):
		var t: float = float(y - mouth_y0) / float(mouth_y1 - mouth_y0)
		var half_w: float = (FW * 0.42) * sin(t * PI) + FW * 0.03
		for x in range(FW):
			var nx: float = x - cx
			if abs(nx) < half_w:
				img.set_pixel(x, y, Color(0.03, 0.008, 0.01, 0.95))
	# клыки -- кривые бледные треугольники, торчащие сверху и снизу рта,
	# неровный шаг вместо идеального ряда
	var fang_mat_c := Color(0.78, 0.74, 0.62, 1.0)
	var fx := -FW * 0.32
	while fx < FW * 0.32:
		var flen: float = 5.0 + randf() * 6.0
		var fw: float = 2.0 + randf() * 1.5
		var top: bool = randf() < 0.6
		var by: float = mouth_y0 + 2.0 if top else mouth_y1 - 2.0
		var dir: float = 1.0 if top else -1.0
		for i in range(int(flen)):
			var row_w: float = fw * (1.0 - float(i) / flen)
			var py := int(by + dir * i)
			if py < 0 or py >= FH:
				continue
			for dx in range(-int(row_w), int(row_w) + 1):
				var px := int(cx + fx + dx)
				if px < 0 or px >= FW:
					continue
				img.set_pixel(px, py, fang_mat_c)
		fx += 5.0 + randf() * 4.0
	_face_tex = ImageTexture.create_from_image(img)
	return _face_tex

func _build_face_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _build_face_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = TYPE_TINT.get(mon_type, Color.WHITE)
	mat.emission_enabled = true
	mat.emission_texture = _build_face_texture()
	mat.emission_energy_multiplier = 0.5   # лёгкий блик на клыках, не самосвет
	return mat

func _add_pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n

func _add_mesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

## собирает объёмный риг с нуля -- вызывается и из setup() (боевой монстр),
## и напрямую из level_gen.gd для "фантома" (галлюцинация на низком
## рассудке, см. _spawn_phantom): фантому не нужны сенсы/движение, только
## видимое тело с тем же материалом, который потом мерцает альфой.
## заметно выше игрока (капсула игрока -- 1.7, см. scenes/main.tscn) --
## "чувствовать беспомощность" в комнате с ним: снизу вверх смотришь на
## что-то нависающее, а не вровень с собой. Раньше рост был почти равен
## росту игрока, и вблизи оно читалось скорее как "ещё один человек", а не
## как непропорциональная угроза.
const RIG_SCALE := 1.3

func _build_rig() -> void:
	for c in body.get_children():
		c.queue_free()
	body.scale = Vector3.ONE * RIG_SCALE
	flesh_mat = _build_flesh_material()
	eye_mat = _build_eye_material()

	# ноги: пивот в бедре на высоте 1.0 -- капсула свисает вниз до земли
	var leg_mesh := CapsuleMesh.new()
	leg_mesh.radius = 0.07
	leg_mesh.height = 0.95
	hip_l = _add_pivot(body, Vector3(-0.12, 1.0, 0.0))
	_add_mesh(hip_l, leg_mesh, flesh_mat, Vector3(0, -0.475, 0))
	hip_r = _add_pivot(body, Vector3(0.12, 1.0, 0.0))
	_add_mesh(hip_r, leg_mesh, flesh_mat, Vector3(0, -0.475, 0))

	# торс: узкая вытянутая капсула, чуть сужена к бёдрам -- через scale.x/z
	torso_node = _add_pivot(body, Vector3(0, 1.0, 0))
	_torso_base_pos = torso_node.position
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = 0.16
	torso_mesh.height = 0.58
	var torso_mi := _add_mesh(torso_node, torso_mesh, flesh_mat, Vector3(0, 0.29, 0))
	torso_mi.scale = Vector3(1.0, 1.0, 0.72)

	# голова: приплюснутая сфера на пивоте у основания шеи, чтобы вращать
	# отдельно от торса (кивки/повороты в _animate_walk)
	head_node = _add_pivot(torso_node, Vector3(0, 0.58, 0))
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.14
	head_mesh.height = 0.28
	var head_mi := _add_mesh(head_node, head_mesh, flesh_mat, Vector3(0, 0.14, 0.01))
	head_mi.scale = Vector3(0.92, 1.12, 0.88)

	if mon_type == MonType.LISTENER:
		# слеп -- глаз нет вовсе, зато торчащие уши-рожки ловят каждый звук
		var ear_mesh := CylinderMesh.new()
		ear_mesh.top_radius = 0.0
		ear_mesh.bottom_radius = 0.04
		ear_mesh.height = 0.16
		_add_mesh(head_node, ear_mesh, flesh_mat, Vector3(-0.11, 0.24, 0), Vector3(0, 0, -20))
		_add_mesh(head_node, ear_mesh.duplicate(), flesh_mat, Vector3(0.11, 0.24, 0), Vector3(0, 0, 20))
	elif mon_type == MonType.WATCHER:
		# неестественно крупные, симметричные, немигающие глаза
		_add_mesh(head_node, _sphere(0.05), eye_mat, Vector3(-0.065, 0.15, -0.115))
		_add_mesh(head_node, _sphere(0.05), eye_mat, Vector3(0.065, 0.15, -0.115))
	else:
		# асимметричное лицо тревожит сильнее зеркального -- правый глаз
		# заметно мельче левого (тот же перекос, что был в старом пиксель-арте)
		_add_mesh(head_node, _sphere(0.032), eye_mat, Vector3(-0.06, 0.15, -0.115))
		_add_mesh(head_node, _sphere(0.022), eye_mat, Vector3(0.06, 0.155, -0.11))

	# лицевая пластина -- рот с клыками и тень переносицы, приклеены плоской
	# нашлёпкой чуть впереди сферы головы (z чуть меньше, чем у глаз, чтобы
	# не пересекаться с ней по глубине). Раньше, кроме глаз, на голове не
	# было вообще ничего -- сфера с двумя точками читалась как "что-то", а
	# не как лицо; клыкастый оскал возвращает узнаваемый силуэт старого
	# пиксель-арта.
	var face_mesh := PlaneMesh.new()
	face_mesh.size = Vector2(0.15, 0.12)
	var face_mi := _add_mesh(head_node, face_mesh, _build_face_material(), Vector3(0, 0.045, -0.124), Vector3(-90, 0, 0))
	face_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# руки: две капсулы на сустав (плечо -> локоть -> кисть), тянутся ниже
	# колен -- те самые "неестественно длинные когтистые руки" из старого
	# силуэта, но теперь читаются с любого ракурса, не только анфас
	for side in [-1.0, 1.0]:
		var shoulder := _add_pivot(torso_node, Vector3(0.19 * side, 0.56, 0))
		# слегка разведены в стороны от торса -- иначе капсулы рук сливаются
		# с торсом в один нечитаемый ком, особенно на средней дистанции
		shoulder.rotation.z = deg_to_rad(10.0 * side)
		var upper_mesh := CapsuleMesh.new()
		upper_mesh.radius = 0.05
		upper_mesh.height = 0.42
		_add_mesh(shoulder, upper_mesh, flesh_mat, Vector3(0, -0.21, 0))
		var elbow := _add_pivot(shoulder, Vector3(0, -0.42, 0))
		var fore_mesh := CapsuleMesh.new()
		fore_mesh.radius = 0.042
		fore_mesh.height = 0.5
		_add_mesh(elbow, fore_mesh, flesh_mat, Vector3(0, -0.25, 0))
		# растопыренные когтистые пальцы -- три тонких конуса веером на кисти
		var claw_mesh := CylinderMesh.new()
		claw_mesh.top_radius = 0.0
		claw_mesh.bottom_radius = 0.016
		claw_mesh.height = 0.11
		for cf in [-1, 0, 1]:
			_add_mesh(elbow, claw_mesh.duplicate(), flesh_mat, Vector3(cf * 0.03, -0.52, -0.02), Vector3(8.0 * cf, 0, 0))
		if side < 0.0:
			shoulder_l = shoulder
		else:
			shoulder_r = shoulder

## Рёв при входе в погоню и рваное рычание, пока она длится -- порт
## соответствующего куска update_ai (ai.c). До этого фикса звуки лежали в
## assets/ неиспользованными: монстр был совершенно немым даже во время
## погони, отсюда и жалоба "не страшно, не интересно" -- его не слышно.
## Позиционный AudioStreamPlayer3D сам даёт затухание по расстоянию вместо
## ручной формулы громкости из C.
const GROWL_MIN := 1.8
const GROWL_MAX := 4.2
const ROAR_BREATHE_MIN := 5.5
const ROAR_BREATHE_MAX := 7.5
var growl_timer: float = 0.0
var roar_player: AudioStreamPlayer3D = null
var growl_player: AudioStreamPlayer3D = null

## точная мировая точка, куда идти внутри клетки-цели, а не только сама
## клетка -- см. _move(): без этого монстр останавливался в центре клетки,
## как только заходил в ту же клетку, что и игрок, даже если реальное
## расстояние до игрока ещё больше CATCH_DIST -- зависал вплотную, так и не
## доводя поимку до конца (та самая жалоба "не нападает").
var aim_point: Vector2 = Vector2.ZERO

func setup(p_level_gen: Node, p_player: CharacterBody3D) -> void:
	level_gen = p_level_gen
	player = p_player
	mon_type = _pick_type()
	pick_wander()
	_setup_voice()
	_build_rig()
	GameState.note_encounter(mon_type)

func _setup_voice() -> void:
	roar_player = AudioStreamPlayer3D.new()
	roar_player.stream = load("res://assets/roar.wav")
	roar_player.unit_size = 4.0
	roar_player.max_distance = 16.0
	add_child(roar_player)
	growl_player = AudioStreamPlayer3D.new()
	growl_player.stream = load("res://assets/growl.wav")
	growl_player.unit_size = 4.0
	growl_player.max_distance = 16.0
	add_child(growl_player)

## Порт выбора ужаса по глубине из gen.c: первая встреча со Слухачом на
## 4 этаже, с Наблюдателем -- на 7, дальше вразнобой из уже открытых типов.
func _pick_type() -> MonType:
	var depth: int = GameState.depth
	if depth < 4:
		return MonType.STALKER
	elif depth == 4:
		return MonType.LISTENER
	elif depth == 7:
		return MonType.WATCHER
	else:
		var options: Array = [MonType.STALKER, MonType.LISTENER]
		if depth >= 7:
			options.append(MonType.WATCHER)
		return options[randi() % options.size()]

var _aitrace_t: float = 0.0

var _twitch_t: float = randf() * 10.0
var _walk_t: float = 0.0
var pause_timer: float = 0.0   # "прислушивается" -- см. _sense() SEARCH-ветку

## лёгкая нервная дрожь -- даже стоя на месте (WANDER, ждёт своего хода) он
## не читается как застывший кадр. Резче и чаще во время охоты, как будто
## на грани того, чтобы сорваться. Раньше дрожь была равномерным scale()
## всего плоского спрайта -- на объёмном риге вместо этого чуть трясутся
## торс/голова по отдельности, читается объёмнее и меньше похоже на баг.
## Наблюдатель -- особый случай: пока на него смотрят, он абсолютно
## неподвижен (ни следа дрожи, см. _move()), а стоит отвести взгляд --
## дёргается рвано и часто, как будто едва сдерживался.
func _process(delta: float) -> void:
	_twitch_t += delta
	var watched: bool = mon_type == MonType.WATCHER and _player_watching()
	var jitter_speed: float = 14.0 if state == State.HUNT else 6.0
	var jitter_amp: float = 0.06 if state == State.HUNT else 0.025
	if mon_type == MonType.WATCHER:
		if watched:
			jitter_amp = 0.0
		else:
			jitter_speed = 24.0
			jitter_amp = 0.11
	var jx: float = sin(_twitch_t * jitter_speed) * jitter_amp
	var jy: float = sin(_twitch_t * jitter_speed * 1.7 + 1.3) * jitter_amp * 0.6
	if torso_node:
		torso_node.rotation.z = jx
	if head_node:
		head_node.rotation.z = jy * 0.6
		# Слухач слеп -- вместо взгляда медленно "обшаривает" комнату слухом,
		# голова плавно ходит из стороны в сторону, пока не взял след
		if mon_type == MonType.LISTENER and state != State.HUNT:
			head_node.rotation.y = sin(_twitch_t * 0.6) * 0.55
		else:
			head_node.rotation.y = lerp(head_node.rotation.y, 0.0, delta * 3.0)

func _physics_process(delta: float) -> void:
	if level_gen == null or player == null or GameState.state != GameState.State.PLAY:
		return
	_sense(delta)
	_move(delta)
	_face_player()
	_animate_walk(delta)

	if OS.get_environment("NIGHTFALL_AITRACE") != "":
		_aitrace_t -= delta
		if _aitrace_t <= 0.0:
			_aitrace_t = 1.0
			print("AITRACE type=%d state=%d pos=%s target=%s vel=%s frozen=%s" % [
				mon_type, state, position, target_cell, velocity, frozen])

	if player.hidden:
		# спрятался -- поймать может, только если оно рядом ищет/охотится
		# и оказалось у самого шкафчика (см. CHECK_DIST в main.c)
		if (state == State.HUNT or state == State.SEARCH) and player.lockers.size() > 0:
			var mypos2d := Vector2(position.x, position.z)
			var ppos2d := Vector2(player.position.x, player.position.z)
			if mypos2d.distance_to(ppos2d) < CHECK_DIST:
				player.hidden = false
				GameState.go_caught()
		return

	var d: float = Vector2(position.x, position.z).distance_to(Vector2(player.position.x, player.position.z))
	if d < CATCH_DIST:
		GameState.go_caught()

## развернуть тело лицом к игроку по горизонтали -- меш не крутится от
## движения сам, а так светящиеся глаза (см. monster.tscn) всегда смотрят
## на игрока: приближение читается как пара глаз, наплывающих из темноты
func _face_player() -> void:
	var t := player.global_position
	t.y = global_position.y
	if global_position.distance_to(t) > 0.2:
		look_at(t, Vector3.UP)

## походка рига -- ноги/руки качаются от скорости, а не по фактическому
## направлению движения (тело и так всегда развёрнуто на игрока, см.
## _face_player() -- кинематически точная походка потребовала бы разворота
## ног независимо от торса, лишняя сложность ради малозаметной детали).
## Раньше это был чистый sin() в противофазе -- плавно и предсказуемо
## читалось скорее как аниматроник, чем как что-то живое-но-неправильное.
## Теперь три слоя поверх этого:
##  1) фаза ноги искажена вторым, более быстрым колебанием -- шаг то
##     ускоряется, то тормозит внутри одного цикла, а не идёт ровно;
##  2) руки качаются НЕ в противофазе ногам, а на собственной, чуть иной
##     частоте -- рассинхрон между руками и ногами читается как "нарушенная
##     координация", а не просто быстрая ходьба;
##  3) редкие микро-заедания (_stutter_timer) -- шаг на долю секунды
##     замирает и тут же продолжает с того же места, будто сбоящая марионетка
##     потеряла и тут же поймала кадр. Чаще и резче во время охоты.
## Вертикальный лурч (torso подпрыгивает дважды за шаг) и сутулость на
## охоте -- как и раньше, корпус/голова подаются вперёд.
func _animate_walk(delta: float) -> void:
	if not (torso_node and hip_l and hip_r and shoulder_l and shoulder_r):
		return
	var creeping: bool = mon_type == MonType.WATCHER and _player_watching()
	var speed: float = Vector2(velocity.x, velocity.z).length()
	var hunting: bool = state == State.HUNT
	var moving: bool = speed > 0.05 and not frozen and pause_timer <= 0.0 and not creeping

	if _stutter_timer > 0.0:
		_stutter_timer -= delta
		moving = false   # заело -- поза держится, пока не отпустит
	elif moving:
		var stutter_chance: float = 0.01 if hunting else 0.003
		if randf() < stutter_chance:
			_stutter_timer = 0.05 + randf() * 0.13

	if moving:
		_walk_t += delta * (4.0 + speed * 2.2)

	var amp: float = clamp(speed / SPEED, 0.0, 1.6) * (0.7 if hunting else 0.55)
	if creeping or pause_timer > 0.0 or _stutter_timer > 0.0:
		amp = 0.0

	# рваная, неровная фаза ноги -- вместо чистой синусоиды
	var leg_phase: float = _walk_t + sin(_walk_t * 2.7) * 0.35
	var swing: float = sin(leg_phase)
	hip_l.rotation.x = swing * amp
	hip_r.rotation.x = -swing * amp

	# руки на собственной, рассинхронизированной частоте -- не зеркалят ноги
	var arm_phase: float = _walk_t * 1.35 + 0.6 + sin(_walk_t * 1.9) * 0.5
	var arm_swing: float = sin(arm_phase)
	shoulder_l.rotation.x = arm_swing * amp * 0.9
	shoulder_r.rotation.x = -arm_swing * amp * 0.9

	if mon_type != MonType.WATCHER:
		hip_l.rotation.z = sin(_walk_t * 0.5) * 0.08   # лёгкая хромота

	# двойной подскок торса за цикл шага -- тяжёлый, кривой лурч, а не
	# ровное скольжение
	var bob: float = absf(sin(leg_phase)) * amp * 0.05
	torso_node.position = _torso_base_pos + Vector3(0, bob, 0)

	var hunch_target: float = 0.4 if hunting else 0.15
	torso_node.rotation.x = lerp(torso_node.rotation.x, hunch_target, delta * 3.0)
	head_node.rotation.x = lerp(head_node.rotation.x, hunch_target * 1.4, delta * 3.0)

func _sense(delta: float) -> void:
	if player.hidden:
		return
	var mypos := Vector2(position.x, position.z)
	var ppos := Vector2(player.position.x, player.position.z)
	var d := mypos.distance_to(ppos)
	var sensed := false
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	var w: float = wear()   # чувства острее с глубиной, до +30-35% на дне
	# "low sanity = ragged panic breathing: the Stalker hears you from
	# farther" (ai.c) -- раньше слух зависел только от глубины, страх самого
	# игрока никак его не подводил ближе, хотя рассудок уже тает от охоты.
	var dread: float = 1.0 - player.sanity
	# обмотки (items.gd::_wrap_feet) -- единственный прямой контрприём
	# против Слухача, у которого зрение не участвует вовсе: приглушают
	# собственные шаги, а не пытаются перекричать его слух приманкой.
	var muffle: float = 0.35 if player.muffled else 1.0

	if mon_type == MonType.LISTENER:
		# слепой -- зрение не участвует вовсе, только гораздо более острый слух
		var hear := (LISTENER_HEAR_RUN if speed > 3.5 else LISTENER_HEAR_WALK) * (1.0 + w * 0.3) * (1.0 + dread * 0.4) * muffle
		if speed > 0.5 and d < hear:
			sensed = true
	elif mon_type == MonType.WATCHER:
		# знает про игрока всегда -- просто не может сдвинуться, пока
		# игрок на него смотрит (см. _move)
		sensed = true
	else:
		# порт "see_range *= 1.9" из ai.c: горящая спичка выдаёт тебя
		# Сталкеру издалека -- та половина сделки "свет против того, чтобы
		# быть увиденным", которую раньше никто не подключал.
		var see_range: float = SEE_RANGE * (1.0 + w * 0.3) * (1.9 if player.lit_by_match else 1.0)
		if d < see_range and _has_los(ppos):
			sensed = true
		else:
			var hear := (HEAR_RUN if speed > 3.5 else HEAR_WALK) * (1.0 + w * 0.3) * (1.0 + dread * 0.5) * muffle
			if speed > 0.5 and d < hear:
				sensed = true

	if sensed:
		if state != State.HUNT and mon_type != MonType.WATCHER:
			# только что взяло след -- долгий рёв, потом пауза, чтобы он отыграл
			roar_player.play()
			growl_timer = ROAR_BREATHE_MIN + randf() * (ROAR_BREATHE_MAX - ROAR_BREATHE_MIN)
		state = State.HUNT
		last_known = ppos
		set_target(Vector2i(int(ppos.x), int(ppos.y)))
		aim_point = ppos   # внутри клетки-цели идти точно на игрока, не в её центр
		if mon_type != MonType.WATCHER:
			growl_timer -= delta
			if growl_timer <= 0.0:
				growl_player.play()
				growl_timer = GROWL_MIN + randf() * (GROWL_MAX - GROWL_MIN)
	elif state == State.HUNT:
		state = State.SEARCH
		search_time = 8.0
		# порт из ai.c: теряя след, оно первым делом проверяет ближайший к
		# месту потери шкафчик, а не просто идёт в пустую точку -- прятки
		# сразу после разрыва видимости не гарантия безопасности, если
		# шкафчик был слишком близко к тому месту, где оно вас видело
		# в последний раз. Раньше вообще не учитывалось: SEARCH всегда шёл
		# ровно в last_known, шкафчики никак не участвовали.
		var tgt := Vector2i(int(last_known.x), int(last_known.y))
		var best_ld := 3.0
		for l in player.lockers:
			var ld: float = abs(l.position.x - last_known.x) + abs(l.position.z - last_known.y)
			if ld < best_ld:
				best_ld = ld
				tgt = Vector2i(int(l.position.x), int(l.position.z))
		set_target(tgt)
	elif state == State.SEARCH:
		if pause_timer > 0.0:
			pause_timer -= delta
		else:
			_check_noise()
			search_time -= delta
			# порт "оно замирает и прислушивается" -- редкая короткая пауза
			# посреди поиска, не только непрерывное шарканье по маршруту.
			# Слышателя не трогаем -- у него и так самый острый слух из
			# всех, дополнительная пауза ему без надобности.
			if mon_type != MonType.WATCHER and mon_type != MonType.LISTENER and randf() < 0.006:
				pause_timer = 0.7 + randf() * 0.9
		var here := Vector2i(int(position.x), int(position.z))
		if here == target_cell or search_time <= 0.0:
			state = State.WANDER
			pick_wander()
	elif state == State.WANDER:
		_check_noise()
		var here2 := Vector2i(int(position.x), int(position.z))
		if here2 == target_cell:
			pick_wander()

## порт шумовой приманки из ai.c: свежий шум (брошенный камень, зажжённая
## спичка, беготня) в пределах слышимости уводит его расследовать, даже
## если оно не видело и не слышало игрока напрямую.
func _check_noise() -> void:
	if level_gen.noise_t <= 0.0:
		return
	var mypos := Vector2(position.x, position.z)
	if mypos.distance_to(level_gen.noise_pos) < HEAR_RUN * 1.7:
		state = State.SEARCH
		search_time = 5.0
		set_target(Vector2i(int(level_gen.noise_pos.x), int(level_gen.noise_pos.y)))

## прямая видимость: луч игрок<->монстр не должен пересекать стены
## (см. has_los в gen.c, там -- пошаговая проверка по сетке; тут -- raycast)
func _has_los(ppos: Vector2) -> bool:
	var space := get_world_3d().direct_space_state
	var from := Vector3(position.x, 0.5, position.z)
	var to := Vector3(ppos.x, 0.5, ppos.y)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1   # стены (см. wall_map collision layer)
	# игрок и сам монстр -- на том же физическом слое, что и стены; без
	# исключения луч, нацеленный прямо в игрока, всегда попадал бы в его же
	# капсулу тела и засчитывался как "загорожено", так что Сталкер вообще
	# никогда не видел игрока по LOS (см. баг -- монстр только бродит,
	# никогда не переходит в HUNT, даже стоя вплотную).
	query.exclude = [self.get_rid(), player.get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty()

func set_target(cell: Vector2i) -> void:
	target_cell = cell
	dist_grid = level_gen.flood_from(cell)
	aim_point = Vector2(cell.x + 0.5, cell.y + 0.5)

## Порт pick_wander из gen.c: чаще всего -- следующая остановка на
## перемешанном маршруте патруля (level_gen.patrol_order), а не случайная
## клетка карты; изредка -- детур мимо ещё не открытого сундука (20%) или
## задержка у двери выхода (ещё 10%), чтобы блуждание временами задевало и
## цели игрока, а не только собственный обход. Раньше был только
## 50%-шанс на сундук поверх чистого случайного блуждания -- никакого
## маршрута, идущего по комнатам, не было вовсе.
func pick_wander() -> void:
	var roll := randf()
	if roll < 0.20 and level_gen.chests.size() > 0:
		var active_chests: Array = level_gen.chests.filter(func(c): return c.active)
		if not active_chests.is_empty():
			var c = active_chests[randi() % active_chests.size()]
			set_target(Vector2i(int(c.pos.x), int(c.pos.y)))
			return
	elif roll < 0.30:
		set_target(Vector2i(int(level_gen.exit_pos.x), int(level_gen.exit_pos.y)))
		return

	if level_gen.patrol_order.size() > 0:
		level_gen.patrol_pos = (level_gen.patrol_pos + 1) % level_gen.patrol_order.size()
		var ri: int = level_gen.patrol_order[level_gen.patrol_pos]
		var pr: Rect2i = level_gen.rooms[ri]
		var cx: int = pr.position.x + pr.size.x / 2
		var cy: int = pr.position.y + pr.size.y / 2
		if level_gen.is_open(cx, cy):
			set_target(Vector2i(cx, cy))
			return

	# резервный вариант -- как и раньше, случайная открытая клетка (если
	# маршрут почему-то не задан, напр. на этаже с одной комнатой)
	var mw: int = level_gen.MW
	var mh: int = level_gen.MH
	for _i in range(64):
		var x: int = 1 + randi() % (mw - 2)
		var y: int = 1 + randi() % (mh - 2)
		if level_gen.is_open(x, y):
			set_target(Vector2i(x, y))
			return

## смотрит ли игрок в его сторону сейчас (см. player_sees_monster в ai.c):
## внутри узкого конуса обзора и без стен между ними.
func _player_watching() -> bool:
	var to_mon := Vector2(position.x - player.position.x, position.z - player.position.z)
	var dist := to_mon.length()
	if dist < 0.7:
		return true
	var fwd := -player.transform.basis.z
	var fwd2d := Vector2(fwd.x, fwd.z).normalized()
	var facing: float = fwd2d.dot(to_mon.normalized())
	if facing < 0.42:   # вне ~65° конуса вперёд
		return false
	return _has_los(Vector2(player.position.x, player.position.z))

func _move(delta: float) -> void:
	if frozen or pause_timer > 0.0:
		velocity = Vector3.ZERO
		return
	var speed_mult := 1.0
	if mon_type == MonType.WATCHER:
		if _player_watching():
			# "SCP-173"-приём: не жёсткий стоп-кадр, а едва заметное
			# подкрадывание -- даже глядя на него в упор, за десяток секунд
			# оно окажется на полметра ближе, чем было. Стоит отвести взгляд
			# хоть на миг -- срывается в полноценный рывок (WATCHER_RUSH_MULT
			# ниже). Раньше был честный velocity=0, полностью статичный, пока
			# смотришь -- надёжно, но совсем не тревожит.
			speed_mult = 0.045
		else:
			speed_mult = WATCHER_RUSH_MULT
	elif state == State.HUNT:
		# "it surges when hunting you at close range -- a terrifying final
		# lunge" (ai.c) -- было в C-версии, потерялось при портировании:
		# Сталкер/Слухач шли одной и той же скоростью весь эпизод охоты,
		# без рывка на добивании, когда до игрока остаются считанные метры.
		var pd: float = Vector2(position.x, position.z).distance_to(Vector2(player.position.x, player.position.z))
		if pd < 3.0:
			speed_mult = 1.0 + (3.0 - pd) / 3.0 * 0.55

	var cx := int(position.x)
	var cz := int(position.z)
	if cx < 0 or cz < 0 or cz >= dist_grid.size() or cx >= dist_grid[0].size():
		return
	var best: int = dist_grid[cz][cx]
	var best_cell := Vector2i(cx, cz)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d in dirs:
		var nx: int = cx + d.x
		var nz: int = cz + d.y
		if level_gen.is_open(nx, nz) and nz < dist_grid.size() and nx < dist_grid[0].size() \
				and dist_grid[nz][nx] < best:
			best = dist_grid[nz][nx]
			best_cell = Vector2i(nx, nz)
	var target_pos: Vector3
	if best_cell == Vector2i(cx, cz):
		# в клетке-цели нет соседа с меньшей дистанцией -- мы дошли по сетке;
		# добираем последний отрезок точно до aim_point, а не до центра клетки
		target_pos = Vector3(aim_point.x, position.y, aim_point.y)
	else:
		target_pos = Vector3(best_cell.x + 0.5, position.y, best_cell.y + 0.5)
	var dir := (target_pos - position)
	dir.y = 0
	if dir.length() > 0.05:
		# +35% скорости на дне -- "с каждым этажом вниз оно быстрее" (README),
		# раньше SPEED был фиксированной константой независимо от depth
		velocity = dir.normalized() * SPEED * (1.0 + wear() * 0.35) * speed_mult
	else:
		velocity = Vector3.ZERO
	move_and_slide()
