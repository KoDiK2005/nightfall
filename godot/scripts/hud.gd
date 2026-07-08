extends CanvasLayer
## Простой текстовый HUD -- порт draw_hud из hud.c: этаж, ключи, полоски
## сил и рассудка, и красная виньетка по краям экрана, когда монстр
## охотится (порт tension-виньетки, приближённой состоянием монстра --
## см. комментарий в player.gd про _update_sanity).

@onready var floor_label: Label = $FloorLabel
@onready var keys_label: Label = $KeysLabel
@onready var stamina_bar: ProgressBar = $StaminaBar
@onready var sanity_bar: ProgressBar = $SanityBar
@onready var vignette: ColorRect = $Vignette

var level_gen: Node = null
var player: CharacterBody3D = null

func _ready() -> void:
	level_gen = get_tree().get_root().find_child("LevelGen", true, false)
	player = get_tree().get_root().find_child("Player", true, false)
	if level_gen:
		level_gen.hud_changed.connect(_on_hud_changed)
		_on_hud_changed()

func _on_hud_changed() -> void:
	if level_gen == null:
		return
	floor_label.text = "ЭТАЖ %d" % GameState.depth
	keys_label.text = "КЛЮЧИ %d/%d" % [level_gen.num_keys - level_gen.keys_left, level_gen.num_keys]

func _process(_delta: float) -> void:
	if player == null:
		return
	stamina_bar.value = player.stamina * 100.0
	sanity_bar.value = player.sanity * 100.0
	var dread: float = 1.0 - player.sanity
	vignette.color.a = clamp(dread * 0.5, 0.0, 0.6)
