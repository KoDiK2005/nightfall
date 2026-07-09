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
@onready var warning_label: Label = $WarningLabel
@onready var vision_flash: TextureRect = $VisionFlash
@onready var postfx: ColorRect = $PostFX
@onready var hidden_overlay: ColorRect = $HiddenOverlay
@onready var hidden_label: Label = $HiddenLabel

var level_gen: Node = null
var player: CharacterBody3D = null
var items: Node = null
var _dungeon_hud: bool = false   # compass.visible сам гасится/зажигается по сундукам, этим не проверить режим

## "твои собственные галлюцинации" (README): PNG из assets/visions/
## вспыхивают на доли секунды поверх экрана, когда рассудок низкий --
## порт load_visions/draw_vision из main.c/hud.c, которого в Godot-порте
## не было вовсе (не просто неподключённый ассет -- целая система).
## Image.load_from_file грузит PNG прямо с диска в обход импорт-пайплайна,
## так что новые файлы подхватываются без переоткрытия проекта в редакторе --
## как и в C-версии, где просто "положил файлы -> make -> запустил".
const VISIONS_DIR := "res://assets/visions"
const VISION_MAX_SIDE := 900
const VISION_MAX_COUNT := 24
var vision_textures: Array = []
var vision_timer: float = 8.0

## обе вспышки (случайная по низкому рассудку и гарантированная на сундуке)
## в C-версии сопровождались звуком (Mix_PlayChannel(4, snd_scare, ...) --
## громче на сундуке, тише на случайной вспышке). В Godot-порте scare.wav
## был подключён только к экрану поимки (см. caught.gd) -- сами вспышки
## оставались немыми.
var scare_player: AudioStreamPlayer = null

## "screen-shake that spikes on scares... and as a frayed mind bleeds the
## colour apart" (render.c) -- порт постобработки финального кадра, которого
## в Godot-порте не было вовсе: хроматическая аберрация/зерно/тряска росли с
## dread и испугом только в C-версии, тут кадр шёл необработанным. Таймеры
## ниже -- Godot-эквивалент C-шных screamer_t/vision_t, приводящих scare
## к 0..1 в шейдере (см. shaders/postfx.gdshader).
const SCREAMER_DUR := 0.9
const VIS_FLASH_DUR := 0.4
var _screamer_t: float = 0.0
var _vision_scare_t: float = 0.0

func _load_visions() -> void:
	var dir := DirAccess.open(VISIONS_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "" and vision_textures.size() < VISION_MAX_COUNT:
		if not dir.current_is_dir() and fname.get_extension().to_lower() == "png":
			var img := Image.load_from_file(VISIONS_DIR + "/" + fname)
			if img != null:
				var w := img.get_width()
				var h := img.get_height()
				if w > VISION_MAX_SIDE or h > VISION_MAX_SIDE:
					var s: float = float(VISION_MAX_SIDE) / max(w, h)
					img.resize(max(int(w * s), 1), max(int(h * s), 1))
				vision_textures.append(ImageTexture.create_from_image(img))
			else:
				push_warning("visions: не смог загрузить " + fname)
		fname = dir.get_next()
	dir.list_dir_end()

func _flash_vision(tex: ImageTexture) -> void:
	vision_flash.texture = tex
	vision_flash.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(vision_flash, "modulate:a", 0.85, 0.06)
	tw.tween_interval(0.12)
	tw.tween_property(vision_flash, "modulate:a", 0.0, 0.22)
	_vision_scare_t = VIS_FLASH_DUR
	scare_player.volume_db = linear_to_db(0.375)   # 48/128 в шкале громкости C-версии
	scare_player.play()

## "Every chest you open slams one of your photos edge-to-edge across the
## screen -- a guaranteed jump-scare" (старое C-README) -- в отличие от
## случайных вспышек по низкому рассудку выше, это не портировалось вовсе:
## открытие сундука в Godot до сих пор было только шумом. Сильнее и дольше
## обычной вспышки, плюс дребезг позиции -- "слэм", а не мерцание.
func trigger_chest_scare() -> void:
	if vision_textures.is_empty():
		return
	var tex = vision_textures[randi() % vision_textures.size()]
	vision_flash.texture = tex
	vision_flash.modulate.a = 0.0
	vision_flash.position = Vector2.ZERO
	var tw := create_tween()
	tw.tween_property(vision_flash, "modulate:a", 1.0, 0.03)
	for i in range(4):
		var mag: float = 16.0 * (1.0 - float(i) / 4.0)
		tw.tween_property(vision_flash, "position", Vector2(randf_range(-mag, mag), randf_range(-mag, mag)), 0.05)
	tw.tween_property(vision_flash, "position", Vector2.ZERO, 0.05)
	tw.tween_interval(0.2)
	tw.tween_property(vision_flash, "modulate:a", 0.0, 0.3)
	vision_timer = max(vision_timer, 6.0)   # обычная вспышка не наложится следом сразу
	_screamer_t = SCREAMER_DUR
	scare_player.volume_db = linear_to_db(0.9375)   # 120/128 -- громче, чем случайная вспышка
	scare_player.play()

## "затухающее предупреждение при входе учит правилу каждого" (README) --
## текста не было вовсе, игрок сталкивался со Слухачом/Наблюдателем без
## единого объяснения их правила.
const MONSTER_WARNINGS := {
	0: "ОНО ОХОТИТСЯ ПО ВЗГЛЯДУ И ЗВУКУ. НЕ ПОПАДАЙТЕСЬ ЕМУ НА ГЛАЗА, НЕ ШУМИТЕ.",
	1: "ОНО СЛЕПО, НО СЛЫШИТ КАЖДЫЙ ШАГ. ЗАМРИТЕ, КОГДА ОНО РЯДОМ.",
	2: "ОНО НЕ ДВИЖЕТСЯ, ПОКА ВЫ НА НЕГО СМОТРИТЕ. ОТВЕДЁТЕ ВЗГЛЯД -- РВАНЁТ.",
}

func _ready() -> void:
	level_gen = get_tree().get_root().find_child("LevelGen", true, false)
	player = get_tree().get_root().find_child("Player", true, false)
	items = get_tree().get_root().find_child("Items", true, false)
	if level_gen:
		level_gen.hud_changed.connect(_on_hud_changed)
		level_gen.chest_opened.connect(trigger_chest_scare)
		_on_hud_changed()
	GameState.mode_changed.connect(_on_mode_changed)
	_on_mode_changed(GameState.mode)
	# GameState.pending_warning уже мог быть выставлен ДО того, как этот
	# _ready() успел выполниться (LevelGen -- более ранний сосед в
	# main.tscn и строит первый этаж синхронно в своём _ready()) -- поэтому
	# не полагаемся на one-shot сигнал first_encounter, а опрашиваем ниже.
	if GameState.pending_warning != -1:
		_show_warning(GameState.pending_warning)
		GameState.pending_warning = -1

	scare_player = AudioStreamPlayer.new()
	scare_player.stream = load("res://assets/scare.wav")
	add_child(scare_player)

	_load_visions()
	# dev-хук NIGHTFALL_SHOWVISION=i (порт из C-версии): показать картинку
	# с индексом i и держать её на экране, а не мелькать долей секунды --
	# удобно для скриншотов/отладки без ожидания низкого рассудка
	var sv := OS.get_environment("NIGHTFALL_SHOWVISION")
	if sv != "" and sv.is_valid_int():
		var i: int = clampi(sv.to_int(), 0, max(vision_textures.size() - 1, 0))
		if vision_textures.size() > 0:
			vision_flash.texture = vision_textures[i]
			vision_flash.modulate.a = 0.85

func _show_warning(mon_type: int) -> void:
	if not MONSTER_WARNINGS.has(mon_type):
		return
	warning_label.text = MONSTER_WARNINGS[mon_type]
	warning_label.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(warning_label, "modulate:a", 1.0, 0.6)
	tw.tween_interval(3.5)
	tw.tween_property(warning_label, "modulate:a", 0.0, 1.2)

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

func _process(delta: float) -> void:
	if player == null:
		return
	# "look out through a locker's horizontal vents" (draw_hidden_overlay в
	# hud.c) -- раньше прятка не давала вообще никакой обратной связи на
	# экране: ни намёка, что вы спрятались, ни как выйти. Экран просто
	# замирал на виде из шкафчика, неотличимом от обычного зависания игры.
	hidden_overlay.visible = player.hidden
	hidden_label.visible = player.hidden
	stamina_bar.value = player.stamina * 100.0
	sanity_bar.value = player.sanity * 100.0
	var dread: float = 1.0 - player.sanity
	vignette.color.a = clamp(dread * 0.5, 0.0, 0.6)
	_screamer_t = max(_screamer_t - delta, 0.0)
	_vision_scare_t = max(_vision_scare_t - delta, 0.0)
	var scare: float = max(_screamer_t / SCREAMER_DUR, 0.6 * _vision_scare_t / VIS_FLASH_DUR)
	postfx.material.set_shader_parameter("dread", dread)
	postfx.material.set_shader_parameter("scare", scare)
	if items_label.visible and items:
		items_label.text = "СПИЧКИ %d   КАМНИ %d" % [items.match_count, items.rock_count]
	if _dungeon_hud and level_gen:
		_update_compass(dread)
	if GameState.pending_warning != -1:
		_show_warning(GameState.pending_warning)
		GameState.pending_warning = -1

	# "чем сильнее безумие, тем чаще и ярче" -- та же схема, что и у
	# шёпотов (dread>0.45), но короткая резкая вспышка вместо звука
	if dread > 0.45 and not vision_textures.is_empty():
		vision_timer -= delta
		if vision_timer <= 0.0:
			_flash_vision(vision_textures[randi() % vision_textures.size()])
			vision_timer = lerp(9.0, 2.5, clamp((dread - 0.45) / 0.55, 0.0, 1.0))
	else:
		vision_timer = max(vision_timer, 4.0)

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
