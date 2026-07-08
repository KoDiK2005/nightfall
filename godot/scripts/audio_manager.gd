extends Node
## Автозагружаемый синглтон -- порт audio.c: фоновый гул, сердцебиение
## (громче и чаще, когда монстр охотится), и шаги игрока. Профессиональный
## позиционный звук (play_positional в C-версии) добавим отдельно, когда
## дойдём до рычания монстра из конкретной точки в 3D.

@onready var ambient: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var heartbeat: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var footsteps: AudioStreamPlayer = AudioStreamPlayer.new()

var heart_timer: float = 0.0
var step_timer: float = 0.0

var player: CharacterBody3D = null

func _ready() -> void:
	add_child(ambient)
	add_child(heartbeat)
	add_child(footsteps)
	ambient.stream = load("res://assets/ambient.wav")
	ambient.volume_db = -14.0
	heartbeat.stream = load("res://assets/heartbeat.wav")
	footsteps.stream = load("res://assets/step.wav")
	GameState.state_changed.connect(_on_state_changed)

func _on_state_changed(new_state: GameState.State) -> void:
	if new_state == GameState.State.PLAY:
		if not ambient.playing:
			ambient.play()
	else:
		ambient.stop()

func _process(delta: float) -> void:
	if GameState.state != GameState.State.PLAY or player == null or player.monster == null:
		return

	var hunting: bool = player.monster.state == player.monster.State.HUNT
	var d: float = Vector2(player.position.x, player.position.z) \
		.distance_to(Vector2(player.monster.position.x, player.monster.position.z))

	# сердцебиение чаще и громче, чем ближе монстр и чем он тревожнее
	heart_timer -= delta
	if heart_timer <= 0.0:
		var closeness: float = clamp(1.0 - d / 10.0, 0.0, 1.0)
		var urgency: float = closeness + (0.4 if hunting else 0.0)
		heartbeat.volume_db = linear_to_db(clamp(0.15 + urgency * 0.7, 0.0, 1.0))
		heartbeat.play()
		heart_timer = max(0.35, 1.1 - urgency * 0.7)

	# шаги под ноги игроку, пока он реально идёт
	var moving: bool = Vector2(player.velocity.x, player.velocity.z).length() > 0.3
	if moving and not player.hidden:
		step_timer -= delta
		if step_timer <= 0.0:
			footsteps.play()
			var sprinting: bool = Vector2(player.velocity.x, player.velocity.z).length() > (player.walk_speed + 0.3)
			step_timer = 0.28 if sprinting else 0.42
	else:
		step_timer = 0.0
