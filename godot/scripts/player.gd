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

@onready var camera: Camera3D = $Camera3D

var pitch: float = 0.0
var stamina: float = 1.0
var exhausted: bool = false
var hidden: bool = false
var near_locker: Node3D = null
var lockers: Array = []   # заполняется level_gen'ом после генерации уровня
var sanity: float = 1.0
var monster: CharacterBody3D = null   # level_gen проставляет после спавна
var level_gen: Node = null            # level_gen проставляет после спавна
var story_speed_mult: float = 1.0     # сюжетный режим -- медленный подход, заморозка на месте
var lit_by_match: bool = false        # items.gd проставляет пока горит спичка -- монстр видит дальше

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.state)

func _on_state_changed(new_state: GameState.State) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if new_state == GameState.State.PLAY else Input.MOUSE_MODE_VISIBLE
	if new_state == GameState.State.PLAY:
		stamina = 1.0
		exhausted = false
		hidden = false

## сбросить вертикальный наклон камеры (level_gen зовёт при спавне, чтобы
## новый этаж не унаследовал задранную/опущенную голову с прошлого)
func reset_look() -> void:
	pitch = 0.0
	if camera:
		camera.rotation.x = 0.0

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
		return
	if near_locker:
		hidden = true
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
		velocity = Vector3.ZERO
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
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	velocity.y = 0.0
	move_and_slide()

	# бег громкий -- освежает шумовой след под ногами, который монстр
	# расследует, даже если не увидел и не услышал тебя напрямую
	if sprinting and level_gen:
		level_gen.make_noise(Vector2(global_position.x, global_position.z), 1.3)

	stamina += (-STAM_DRAIN if sprinting else STAM_REGEN) * delta
	stamina = clamp(stamina, 0.0, 1.0)
	if stamina <= 0.02:
		exhausted = true
	if stamina >= 0.30:
		exhausted = false

	_update_sanity(delta)

## Порт update_fear из ai.c: рассудок тает быстрее, когда монстр охотится
## (и особенно, когда оно тебя видит), медленнее восстанавливается в тишине.
## "tension" в C-версии приходит из мерцания факелов -- тут грубо
## приближаем его состоянием монстра, пока не перенесли ту систему целиком.
func _update_sanity(delta: float) -> void:
	if monster == null:
		return
	var dd: float = min(GameState.depth - 1, 12)
	var hunting: bool = monster.state == monster.State.HUNT
	var tension: float = 1.0 if hunting else (0.4 if monster.state == monster.State.SEARCH else 0.0)
	var drain: float = 0.004 + dd * 0.0025 + tension * 0.05 + (0.03 if hunting else 0.0) + (0.10 if hunting else 0.0)
	if tension < 0.12 and not hunting:
		sanity += delta * 0.02
	sanity -= delta * drain
	sanity = clamp(sanity, 0.0, 1.0)
