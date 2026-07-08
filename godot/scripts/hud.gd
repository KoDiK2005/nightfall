extends CanvasLayer
## Простой текстовый HUD -- порт верхней части draw_hud из hud.c.
## Пока только этаж и ключи; рассудок/выносливость/остальное добавим,
## когда перенесём соответствующие игровые системы.

@onready var floor_label: Label = $FloorLabel
@onready var keys_label: Label = $KeysLabel

func _ready() -> void:
	var level_gen := get_tree().get_root().find_child("LevelGen", true, false)
	if level_gen:
		level_gen.hud_changed.connect(_on_hud_changed.bind(level_gen))
		_on_hud_changed(level_gen)

func _on_hud_changed(level_gen: Node) -> void:
	floor_label.text = "ЭТАЖ %d" % GameState.depth
	keys_label.text = "КЛЮЧИ %d/%d" % [level_gen.num_keys - level_gen.keys_left, level_gen.num_keys]
