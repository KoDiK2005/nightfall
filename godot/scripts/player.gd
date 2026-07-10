extends CharacterBody3D
## Игрок от первого лица -- WASD, свободный обзор мышью, Shift бег с
## выносливостью, E прячется в шкафчик. Порт соответствующих кусков
## main.c (движение/стамина) и E-хендлинга для шкафчиков (gen.c).

@export var walk_speed: float = 3.1   # совпадает с PLAYER_WALK в game.h
@export var run_speed: float = 4.7    # совпадает с PLAYER_RUN
@export var mouse_sens: float = 0.0025

const STAM_DRAIN := 0.34
const STAM_REGEN := 0.22 / 3.0   # втрое медленнее -- см. память про C-версию
const HIDE_DIST := 1.0
const ACCEL := 11.0   # порт "eased accel (11/s start, 14/s stop)" из C -- разгон/торможение,
const DECEL := 14.0   # а не мгновенная смена скорости, как было раньше

@onready var camera: Camera3D = $Camera3D

var pitch: float = 0.0
var stamina: float = 1.0
var exhausted: bool = false
var hidden: bool = false
var near_locker: Node3D = null
var lockers: Array = []   # заполняется level_gen'ом после генерации уровня
var sanity: float = 1.0
var tension: float = 0.0   # см. _update_sanity -- непрерывная тревога по дистанции до монстра
var monster: CharacterBody3D = null   # level_gen проставляет после спавна
var level_gen: Node = null            # level_gen проставляет после спавна
var story_speed_mult: float = 1.0     # сюжетный режим -- медленный подход, заморозка на месте
var lit_by_match: bool = false        # items.gd проставляет пока горит спичка -- монстр видит дальше
var muffled: bool = false             # items.gd проставляет пока действуют обмотки -- монстр слышит хуже

var _camera_base_pos: Vector3 = Vector3.ZERO
var _bob_phase: float = 0.0

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.state)
	_camera_base_pos = camera.position

## баг "в какой-то момент шёл только вправо": если окно теряет фокус
## (alt-tab, клик мимо игры) с зажатой клавишей, ОС не всегда шлёт её
## отпускание движку, и Input запоминает клавишу "зажатой" навсегда --
## движение залипает в её сторону, даже когда рука давно её отпустила.
## Явно отпускаем все игровые клавиши при потере фокуса окна.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		for action in ["move_left", "move_right", "move_forward", "move_back", "run", "interact"]:
			if InputMap.has_action(action):
				Input.action_release(action)

func _on_state_changed(new_state: GameState.State) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if new_state == GameState.State.PLAY else Input.MOUSE_MODE_VISIBLE
	if new_state == GameState.State.PLAY:
		stamina = 1.0
		exhausted = false
		hidden = false
		# monster.gd может сбросить hidden напрямую при поимке в шкафчике
		# (в обход _try_interact, где обычно возвращается маска) -- без
		# этого сброса игрок после рестарта до конца забега не сталкивался
		# бы с мебелью на слое 8.
		set_collision_mask_value(8, true)

## сбросить вертикальный наклон камеры (level_gen зовёт при спавне, чтобы
## новый этаж не унаследовал задранную/опущенную голову с прошлого)
func reset_look() -> void:
	pitch = 0.0
	if camera:
		camera.rotation.x = 0.0
		camera.position = _camera_base_pos
	_bob_phase = 0.0

func _unhandled_input(event: InputEvent) -> void:
	if GameState.state != GameState.State.PLAY:
		return
	if event is InputEventMouseMotion and not hidden:
		rotate_y(-event.relative.x * mouse_sens)
		pitch = clamp(pitch - event.relative.y * mouse_sens, -1.45, 1.45)
		camera.rotation.x = pitch
	if event is InputEventAction and event.action == "interact" and event.pressed:
		_try_interact()

func _try_interact() -> void:
	if hidden:
		hidden = false
		set_collision_mask_value(8, true)   # шкафчики (слой 8) снова блокируют
		return
	if near_locker:
		hidden = true
		# шкафчики теперь имеют настоящую коллизию (см. level_gen.gd::
		# _add_prop_collision), а прятка телепортирует игрока ровно на
		# позицию своего же шкафчика -- без этого игрок застревал бы
		# внутри собственной солидной мебели. Возвращается выше при выходе.
		set_collision_mask_value(8, false)
		global_position = near_locker.global_position

func _physics_process(delta: float) -> void:
	if GameState.state != GameState.State.PLAY:
		velocity = Vector3.ZERO
		return

	near_locker = null
	if not hidden:
		var p := Vector2(global_position.x, global_position.z)
		for l in lockers:
			if p.distance_to(Vector2(l.global_position.x, l.global_position.z)) < HIDE_DIST:
				near_locker = l
				break

	if hidden:
		# раньше ранний return тут обрывал кадр ДО _update_sanity() ниже --
		# рассудок в шкафчике не тает, но и не восстанавливается, просто
		# замирает. А ведь "улучите тихий момент" (см. README) -- прятки
		# должны быть именно таким моментом.
		velocity = Vector3.ZERO
		_bob_phase = 0.0
		camera.position = _camera_base_pos
		_update_sanity(delta)
		return

	var want_run := Input.is_action_pressed("run") and not exhausted and stamina > 0.05
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	)
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var moving := direction.length() > 0.1
	var sprinting := want_run and moving
	var speed := (run_speed if sprinting else walk_speed) * story_speed_mult
	# разгон/торможение вместо мгновенной смены скорости -- шаг ощущается
	# как у человека с весом, а не как телепорт между "стоит"/"идёт"
	var target_vel := Vector3(direction.x * speed, 0.0, direction.z * speed)
	var rate: float = ACCEL if moving else DECEL
	velocity.x = move_toward(velocity.x, target_vel.x, rate * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, rate * delta)
	velocity.y = 0.0
	move_and_slide()
	_update_head_bob(delta, moving)

	# бег громкий -- освежает шумовой след под ногами, который монстр
	# расследует, даже если не увидел и не услышал тебя напрямую. Обмотки
	# (см. items.gd::_wrap_feet) глушат этот след полностью, не только
	# ослабляют дальность слуха ниже в monster.gd::_sense.
	if sprinting and level_gen and not muffled:
		level_gen.make_noise(Vector2(global_position.x, global_position.z), 1.3)

	stamina += (-STAM_DRAIN if sprinting else STAM_REGEN) * delta
	stamina = clamp(stamina, 0.0, 1.0)
	if stamina <= 0.02:
		exhausted = true
	if stamina >= 0.30:
		exhausted = false

	_update_sanity(delta)

## "subtle head bob (bobY vertical, bobLat lateral) scaled by speed" --
## порт из C, которого раньше в Godot-порте не было вовсе: камера шла
## идеально ровно, как на рельсах, даже при беге. Смещение накладывается
## поверх исходной позиции камеры, не заменяет её.
func _update_head_bob(delta: float, moving: bool) -> void:
	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	if moving and horiz_speed > 0.2:
		var frac: float = clamp(horiz_speed / run_speed, 0.0, 1.0)
		_bob_phase += delta * (7.0 + frac * 5.0)
		var bob_y: float = sin(_bob_phase * 2.0) * 0.045 * frac
		var bob_x: float = sin(_bob_phase) * 0.03 * frac
		camera.position = camera.position.lerp(_camera_base_pos + Vector3(bob_x, bob_y, 0.0), delta * 14.0)
	else:
		_bob_phase = 0.0
		camera.position = camera.position.lerp(_camera_base_pos, delta * 10.0)

## Порт update_fear из ai.c: рассудок тает быстрее, когда монстр охотится
## (и особенно, когда оно тебя видит), медленнее восстанавливается в тишине.
## "tension" -- один общий глобал в C-версии (объявлен в main.c, считается в
## audio.c::update_audio: непрерывная величина по дистанции до монстра,
## 1 вплотную и 0 дальше 9 клеток, экспоненциально сглаженная), который
## питает и тряску рассудка (ai.c), и громкость эмбиента (audio.c), и шанс
## скачка мерцания факела (main.c). Раньше здесь была грубая state-based
## заглушка (HUNT=1.0/SEARCH=0.4/иначе 0) -- три ступеньки вместо плавной
## кривой, и AudioManager вообще не знал о тревоге, эмбиент играл на
## фиксированной громкости независимо от того, насколько близко монстр.
func _update_sanity(delta: float) -> void:
	if monster == null:
		return
	var dd: float = min(GameState.depth - 1, 12)
	# спрятался -- монстр тебя не видит и не может поймать (см. go_caught в
	# monster.gd), так что для рассудка это тихий момент, даже если оно всё
	# ещё где-то рыщет рядом в поиске: опасность конкретно для тебя сейчас
	# приостановлена.
	var hunting: bool = not hidden and monster.state == monster.State.HUNT
	var target: float = 0.0
	if not hidden:
		var d: float = global_position.distance_to(monster.global_position)
		target = clamp(1.0 - d / 9.0, 0.0, 1.0)
	tension = lerp(tension, target, clamp(delta * 3.0, 0.0, 1.0))
	var drain: float = 0.004 + dd * 0.0025 + tension * 0.05 + (0.03 if hunting else 0.0) + (0.10 if hunting else 0.0)
	if tension < 0.12 and not hunting:
		sanity += delta * 0.02
	sanity -= delta * drain
	sanity = clamp(sanity, 0.0, 1.0)
