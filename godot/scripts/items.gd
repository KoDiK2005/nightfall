extends Node
## Спички и камни -- порт соответствующих кусков main.c/render.c.
## Спичка: F зажигает временный источник света, но выдаёт тебя монстру
## (see_range растёт). Камень: G бросает его по направлению взгляда,
## удар о стену создаёт шум, который слышит/расследует монстр (make_noise
## в gen.c/ai.c) -- удобная приманка в сторону от себя.

const MATCH_DUR := 6.0
const ROCK_MAX_RANGE := 6.0
const ROCK_FLY_DUR := 0.5
const ROCK_NOISE_TTL := 4.0

@onready var player: CharacterBody3D = $"../Player"
@onready var level_gen: Node = $"../LevelGen"
@onready var match_light: OmniLight3D = $"../Player/MatchLight"

var match_count: int = 2
var match_burn: float = 0.0
var rock_count: int = 2

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	match_light.visible = false

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY:
		match_count = 2
		rock_count = 2
		match_burn = 0.0
		match_light.visible = false

func _unhandled_input(event: InputEvent) -> void:
	if GameState.state != GameState.State.PLAY or player.hidden:
		return
	# physical_keycode, а не keycode -- у пользователя раскладка ЙЦУКЕН, и
	# по keycode физическая F/G отдавала бы кириллицу (см. память про
	# sdl-input-scancodes). Совпадает с тем, как заданы действия move_*/run.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F:
			_strike_match()
		elif event.physical_keycode == KEY_G:
			_throw_rock()

func _strike_match() -> void:
	if match_count <= 0 or match_burn > 0.0:
		return
	match_count -= 1
	match_burn = MATCH_DUR
	match_light.visible = true
	# зажжённая спичка -- тоже шум, монстр может пойти на щелчок
	level_gen.make_noise(Vector2(player.position.x, player.position.z), 2.0)

func _throw_rock() -> void:
	if rock_count <= 0:
		return
	rock_count -= 1
	var fwd := -player.transform.basis.z
	var landing := Vector2(player.position.x, player.position.z)
	var space := player.get_world_3d().direct_space_state
	var from := player.position
	var to := from + fwd * ROCK_MAX_RANGE
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		landing = Vector2(hit.position.x, hit.position.z)
	else:
		landing = Vector2(to.x, to.z)
	# удар о камень слышен через мгновение -- пока упрощаем до "сразу"
	await player.get_tree().create_timer(ROCK_FLY_DUR).timeout
	level_gen.make_noise(landing, ROCK_NOISE_TTL)
	# thud.wav из C-сборки (gen_audio.py make_thud) ещё не был скопирован в
	# Godot -- бросок камня был совсем беззвучным для самого игрока.
	# AudioStreamPlayer3D сам даёт затухание по расстоянию (see_range/hear в
	# ai.c делали это вручную).
	var thud := AudioStreamPlayer3D.new()
	thud.stream = load("res://assets/thud.wav")
	thud.unit_size = 3.0
	thud.max_distance = 16.0
	thud.position = Vector3(landing.x, 0.3, landing.y)
	level_gen.props_root.add_child(thud)
	thud.play()
	thud.finished.connect(thud.queue_free)

func _process(delta: float) -> void:
	if match_burn > 0.0:
		match_burn -= delta
		if match_burn <= 0.0:
			match_light.visible = false
	# порт "see_range *= 1.9" из ai.c -- горящая спичка светит удобно, но
	# выдаёт тебя монстру издалека. Раньше эта половина сделки не была
	# подключена вовсе: спичка просто светила без всякой цены.
	player.lit_by_match = match_burn > 0.0
