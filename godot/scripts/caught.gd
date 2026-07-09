extends CanvasLayer
## Экран смерти -- порт ST_CAUGHT/draw_jumpscare. R начинает заново.
## Раньше это была немая статичная красная плашка -- порт crash-звука и
## трясущегося экрана (draw_jumpscare: shake = 6*sin(t*90) первые 1.2с)
## делает саму поимку ощутимой, а не просто сменой цвета фона.

const SHAKE_DUR := 1.2
const SHAKE_MAG := 10.0

@onready var best_label: Label = $Shake/BestLabel
@onready var shake_root: Control = $Shake
var scare_player: AudioStreamPlayer = null
var shake_t: float = 0.0

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	visible = GameState.state == GameState.State.CAUGHT
	scare_player = AudioStreamPlayer.new()
	scare_player.stream = load("res://assets/scare.wav")
	add_child(scare_player)

func _on_state_changed(new_state: GameState.State) -> void:
	visible = new_state == GameState.State.CAUGHT
	if visible:
		best_label.text = "РЕКОРД: ЭТАЖ %d" % GameState.best_depth
		scare_player.play()
		shake_t = SHAKE_DUR

func _process(delta: float) -> void:
	if shake_t <= 0.0:
		shake_root.position = Vector2.ZERO
		return
	shake_t -= delta
	var mag: float = SHAKE_MAG * max(shake_t, 0.0) / SHAKE_DUR
	shake_root.position = Vector2(
		sin(shake_t * 90.0) * mag,
		cos(shake_t * 71.0) * mag * 0.6)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# physical_keycode -- раскладка ЙЦУКЕН (физическая R по keycode = кириллица);
	# рестарт в том же режиме, в котором поймали, а не всегда в бесконечный
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_R:
		GameState.start_new_game(GameState.mode)
