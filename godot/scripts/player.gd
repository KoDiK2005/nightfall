extends CharacterBody3D
## Первый шаг порта на Godot: игрок от первого лица с теми же ощущениями,
## что и в C-версии (src/main.c) -- WASD ходьба, свободный обзор мышью
## (yaw и pitch), Shift для бега. Пока без выносливости/подкрадывания --
## это только каркас движения, остальное перенесём следующими шагами.

@export var walk_speed: float = 3.1   # совпадает с PLAYER_WALK в game.h
@export var run_speed: float = 4.7    # совпадает с PLAYER_RUN
@export var mouse_sens: float = 0.0025

@onready var camera: Camera3D = $Camera3D

var pitch: float = 0.0

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.state)

func _on_state_changed(new_state: GameState.State) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if new_state == GameState.State.PLAY else Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if GameState.state != GameState.State.PLAY:
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sens)
		pitch = clamp(pitch - event.relative.y * mouse_sens, -1.45, 1.45)
		camera.rotation.x = pitch

func _physics_process(_delta: float) -> void:
	if GameState.state != GameState.State.PLAY:
		velocity = Vector3.ZERO
		return
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	)
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var speed := run_speed if Input.is_action_pressed("run") else walk_speed
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	velocity.y = 0.0
	move_and_slide()
