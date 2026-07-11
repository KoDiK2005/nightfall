extends Node
## Спички, камни, сигнальные шашки и обмотки -- порт соответствующих кусков
## main.c/render.c плюс два новых предмета (шашка, обмотки), которых в
## C-версии не было. Спичка: F зажигает временный источник света, но выдаёт
## тебя монстру -- see_range растёт при прямой видимости, и пока горит,
## сама периодически "мерцает" слабым шумом-приманкой даже без неё. Камень:
## G бросает его по направлению взгляда, удар о стену создаёт шум, который
## слышит/расследует монстр
## (make_noise в gen.c/ai.c) -- удобная приманка в сторону от себя. Шашка:
## H втыкает её в пол под ногами -- она сама шумит и светит, пока горит
## (см. flare.gd), так что расследующий монстр идёт на неё, а не по твоему
## следу. Обмотки: J на время глушит собственные шаги -- защитный предмет
## вместо приманки, единственный прямой контрприём против Слухача.

const MATCH_DUR := 6.0
const MATCH_GLOW_PERIOD := 1.4
const MATCH_GLOW_TTL := 1.6
const ROCK_MAX_RANGE := 6.0
const ROCK_FLY_DUR := 0.5
const ROCK_NOISE_TTL := 4.0
const FLARE_SCENE := preload("res://scenes/flare.tscn")
const WRAP_DUR := 14.0

@onready var player: CharacterBody3D = $"../Player"
@onready var level_gen: Node = $"../LevelGen"
@onready var match_light: OmniLight3D = $"../Player/MatchLight"

var match_count: int = 2
var match_burn: float = 0.0
var rock_count: int = 2
var flare_count: int = 1
var wrap_count: int = 1
var wrap_burn: float = 0.0
var _match_glow_timer: float = 0.0

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	match_light.visible = false

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY:
		match_count = 2
		rock_count = 2
		flare_count = 1
		wrap_count = 1
		match_burn = 0.0
		wrap_burn = 0.0
		_match_glow_timer = 0.0
		match_light.visible = false

func _unhandled_input(event: InputEvent) -> void:
	if GameState.state != GameState.State.PLAY or player.hidden:
		return
	# physical_keycode, а не keycode -- у пользователя раскладка ЙЦУКЕН, и
	# по keycode физическая F/G/H/J отдавала бы кириллицу (см. память про
	# sdl-input-scancodes). Совпадает с тем, как заданы действия move_*/run.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F:
			_strike_match()
		elif event.physical_keycode == KEY_G:
			_throw_rock()
		elif event.physical_keycode == KEY_H:
			_drop_flare()
		elif event.physical_keycode == KEY_J:
			_wrap_feet()

func _strike_match() -> void:
	if match_count <= 0 or match_burn > 0.0:
		return
	match_count -= 1
	match_burn = MATCH_DUR
	match_light.visible = true
	# зажжённая спичка -- тоже шум, монстр может пойти на щелчок
	level_gen.make_noise(Vector2(player.position.x, player.position.z), 2.0)

## камень, летящий по дуге от руки до места удара -- раньше бросок был
## чисто логическим (raycast + отложенный звук, без единого пикселя в
## кадре в момент броска), отсюда жалоба "камня не видно, когда кидаешь".
## Меш/материал одинаковы на каждый бросок -- кэшируем один раз (тот же
## приём, что и у monster.gd::_flesh_tex), а не пересобираем на ровном месте
## при каждом нажатии G.
static var _rock_mesh: SphereMesh = null
static var _rock_mat: StandardMaterial3D = null
static func _rock_mesh_mat() -> Array:
	if _rock_mesh == null:
		_rock_mesh = SphereMesh.new()
		_rock_mesh.radius = 0.045
		_rock_mesh.height = 0.09
		_rock_mesh.radial_segments = 6
		_rock_mesh.rings = 3
		_rock_mat = StandardMaterial3D.new()
		_rock_mat.albedo_color = Color(0.32, 0.29, 0.26)
		_rock_mat.roughness = 0.95
	return [_rock_mesh, _rock_mat]

const ROCK_RADIUS := 0.045
const ROCK_REST_Y := 0.05   # чуть над полом -- та же посадка, что у щебня/камней декора

func _throw_rock() -> void:
	if rock_count <= 0:
		return
	rock_count -= 1
	var fwd := -player.transform.basis.z
	var landing := Vector2(player.position.x, player.position.z)
	var space := player.get_world_3d().direct_space_state
	# бросок стартует от руки (чуть впереди и ниже глаз), не из центра
	# капсулы игрока -- иначе камень вылетал бы из груди.
	var from := player.position + Vector3(0, 0.35, 0) + fwd * 0.35
	var to := player.position + fwd * ROCK_MAX_RANGE
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		# точка удара -- ровно НА поверхности стены (raycast так и работает),
		# а бросок летел на высоте руки (~1.2м), не пола: без поправок камень
		# в конце полёта повисал вплотную к стене на высоте броска, а не падал
		# на пол ("камень клеится к стене"). Оттягиваем точку приземления от
		# стены вдоль её нормали на радиус камня, чтобы не втыкался в кладку,
		# и в любом случае садим финальную точку на пол, а не туда, где по
		# высоте случайно прошёл луч.
		var n: Vector3 = hit.normal
		landing = Vector2(hit.position.x + n.x * ROCK_RADIUS, hit.position.z + n.z * ROCK_RADIUS)
	else:
		landing = Vector2(to.x, to.z)
	var to3 := Vector3(landing.x, ROCK_REST_Y, landing.y)

	var mm := _rock_mesh_mat()
	var rock := MeshInstance3D.new()
	rock.mesh = mm[0]
	rock.material_override = mm[1]
	rock.position = from
	level_gen.props_root.add_child(rock)

	var tw := player.get_tree().create_tween()
	tw.tween_method(func(t: float):
		var p: Vector3 = from.lerp(to3, t)
		p.y += sin(t * PI) * 0.7   # дуга броска поверх прямой линии от -> на пол
		rock.position = p
	, 0.0, 1.0, ROCK_FLY_DUR)
	tw.finished.connect(func():
		level_gen.make_noise(landing, ROCK_NOISE_TTL)
		# thud.wav из C-сборки (gen_audio.py make_thud) ещё не был скопирован
		# в Godot -- бросок камня был совсем беззвучным для самого игрока.
		var thud := AudioStreamPlayer3D.new()
		thud.stream = load("res://assets/thud.wav")
		thud.unit_size = 3.0
		thud.max_distance = 16.0
		thud.position = Vector3(landing.x, 0.3, landing.y)
		level_gen.props_root.add_child(thud)
		thud.play()
		thud.finished.connect(thud.queue_free)
		# камень остаётся лежать секунду-другую, чтобы можно было заметить,
		# куда он упал, потом убираем -- не копить объекты на полу вечно
		rock.get_tree().create_timer(2.0).timeout.connect(rock.queue_free)
	)

func _drop_flare() -> void:
	if flare_count <= 0:
		return
	flare_count -= 1
	var flare := FLARE_SCENE.instantiate()
	flare.position = Vector3(player.position.x, 0.02, player.position.z)
	level_gen.props_root.add_child(flare)
	flare.setup(level_gen)

func _wrap_feet() -> void:
	if wrap_count <= 0 or wrap_burn > 0.0:
		return
	wrap_count -= 1
	wrap_burn = WRAP_DUR

func _process(delta: float) -> void:
	if match_burn > 0.0:
		match_burn -= delta
		if match_burn <= 0.0:
			match_light.visible = false
		# раньше горящая спичка выдавала себя только один раз в момент чирка
		# (см. _strike_match): если монстр не видел игрока напрямую и не был
		# рядом в тот самый миг, дальше спичка горела бесплатно -- весь риск
		# сделки "свет против того, чтобы быть увиденным" (см. monster.gd::
		# _sense, see_range*1.9) работал только при прямой видимости, стена
		# полностью гасила отсвет. Теперь горящая спичка сама периодически
		# "мерцает" шумом-приманкой, слабее и короче шашки (см. flare.gd) --
		# монстр может пойти проверить даже из-за угла, не увидев напрямую.
		_match_glow_timer -= delta
		if _match_glow_timer <= 0.0:
			level_gen.make_noise(Vector2(player.position.x, player.position.z), MATCH_GLOW_TTL)
			_match_glow_timer = MATCH_GLOW_PERIOD
	if wrap_burn > 0.0:
		wrap_burn -= delta
	# порт "see_range *= 1.9" из ai.c -- горящая спичка светит удобно, но
	# выдаёт тебя монстру издалека. Раньше эта половина сделки не была
	# подключена вовсе: спичка просто светила без всякой цены.
	player.lit_by_match = match_burn > 0.0
	# обмотки глушат сами шаги -- monster.gd ослабляет свои дальности слуха,
	# пока это выставлено, player.gd не шлёт make_noise от бега (см. там же).
	player.muffled = wrap_burn > 0.0
