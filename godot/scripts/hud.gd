extends CanvasLayer
## Простой текстовый HUD -- порт draw_hud из hud.c: этаж, ключи, полоски
## сил и рассудка, и красная виньетка по краям экрана, когда монстр
## охотится (порт tension-виньетки, приближённой состоянием монстра --
## см. комментарий в player.gd про _update_sanity).

@onready var floor_label: Label = $FloorLabel
@onready var keys_label: Label = $KeysLabel
@onready var biome_label: Label = $BiomeLabel
@onready var items_label: Label = $ItemsLabel
@onready var stamina_bar: ProgressBar = $StaminaBar
@onready var sanity_bar: ProgressBar = $SanityBar
@onready var vignette: ColorRect = $Vignette
@onready var compass: Label = $Compass

var level_gen: Node = null
var player: CharacterBody3D = null
var items: Node = null
var _dungeon_hud: bool = false   # compass.visible сам гасится/зажигается по сундукам, этим не проверить режим

func _ready() -> void:
	level_gen = get_tree().get_root().find_child("LevelGen", true, false)
	player = get_tree().get_root().find_child("Player", true, false)
	items = get_tree().get_root().find_child("Items", true, false)
	if level_gen:
		level_gen.hud_changed.connect(_on_hud_changed)
		_on_hud_changed()
	GameState.mode_changed.connect(_on_mode_changed)
	_on_mode_changed(GameState.mode)

func _on_mode_changed(new_mode: GameState.Mode) -> void:
	# этаж/ключи/биом относятся только к бесконечному спуску -- в сюжетке
	# их не из чего заполнить, и держать заглушку "ЭТАЖ 1" на экране незачем.
	var show_dungeon_hud := new_mode == GameState.Mode.ENDLESS
	_dungeon_hud = show_dungeon_hud
	floor_label.visible = show_dungeon_hud
	keys_label.visible = show_dungeon_hud
	biome_label.visible = show_dungeon_hud
	items_label.visible = show_dungeon_hud
	compass.visible = show_dungeon_hud

func _on_hud_changed() -> void:
	if level_gen == null:
		return
	floor_label.text = "ЭТАЖ %d" % GameState.depth
	keys_label.text = "КЛЮЧИ %d/%d" % [level_gen.num_keys - level_gen.keys_left, level_gen.num_keys]
	biome_label.text = level_gen.biome_name

func _process(_delta: float) -> void:
	if player == null:
		return
	stamina_bar.value = player.stamina * 100.0
	sanity_bar.value = player.sanity * 100.0
	var dread: float = 1.0 - player.sanity
	vignette.color.a = clamp(dread * 0.5, 0.0, 0.6)
	if items_label.visible and items:
		items_label.text = "СПИЧКИ %d   КАМНИ %d" % [items.match_count, items.rock_count]
	if _dungeon_hud and level_gen:
		_update_compass(dread)

## "золотой компас-чутьё на ключи... указывает на ближайший сундук, ярче
## чем ближе вы к нему и тусклее по мере помутнения рассудка" -- эта
## часть README для C-версии никогда не портировалась в Godot, HUD не
## знал о сундуках вообще ничего, кроме счётчика.
func _update_compass(dread: float) -> void:
	var nearest_pos := Vector2.ZERO
	var found := false
	var best_d := INF
	for c in level_gen.chests:
		if not c.active:
			continue
		var d: float = Vector2(player.position.x, player.position.z).distance_to(c.pos)
		if d < best_d:
			best_d = d
			nearest_pos = c.pos
			found = true
	if not found:
		compass.visible = false
		return
	compass.visible = true
	var fwd := -player.transform.basis.z
	var fwd_xz := Vector2(fwd.x, fwd.z)
	var to_chest: Vector2 = nearest_pos - Vector2(player.position.x, player.position.z)
	compass.rotation = fwd_xz.angle_to(to_chest)
	var closeness: float = clamp(1.0 - best_d / 14.0, 0.0, 1.0)
	var brightness: float = clamp(0.25 + closeness * 0.75 - dread * 0.5, 0.08, 1.0)
	compass.modulate = Color(1.0, 1.0, 1.0, brightness)
