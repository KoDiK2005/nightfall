extends CharacterBody3D
## Порт мозга трёх ужасов из ai.c. Общий костяк -- три состояния
## (WANDER/SEARCH/HUNT) и волновой поиск (BFS) по сетке уровня (как gdist
## в C-версии); восприятие разное по типу:
##  STALKER  -- зрение (луч+дистанция) и слух, рвётся ближе на подходе
##  LISTENER -- слепой, но с намного более острым слухом
##  WATCHER  -- замирает, пока игрок на него смотрит, иначе мчится

enum State { WANDER, SEARCH, HUNT }
enum MonType { STALKER, LISTENER, WATCHER }

const SEE_RANGE := 7.0
const HEAR_WALK := 3.0
const HEAR_RUN := 6.5
const LISTENER_HEAR_WALK := 7.2   # HEAR_WALK * 2.4, как в ai.c
const LISTENER_HEAR_RUN := 12.4
const CATCH_DIST := 0.6
const CHECK_DIST := 1.0   # на таком расстоянии оно "проверяет" шкафчик
const SPEED := 1.55   # MONSTER_SPD в game.h
const WATCHER_RUSH_MULT := 2.3   # совпадает с render.c

## "с каждым этажом вниз оно быстрее и чутче" (см. README) -- раньше
## depth нигде, кроме выбора типа монстра и числа ключей, не участвовал:
## скорость и все дальности восприятия были фиксированными константами
## независимо от глубины. wear() -- та же кривая 0..1 к этажу ~13, что уже
## используется для износа текстур (Biomes) и утечки рассудка (player.gd).
static func wear() -> float:
	return clamp(float(GameState.depth - 1) / 12.0, 0.0, 1.0)

var mon_type: MonType = MonType.STALKER
var state: State = State.WANDER
var target_cell: Vector2i = Vector2i.ZERO
var dist_grid: Array = []   # BFS-дистанции от target_cell, как gdist в C
var last_known: Vector2 = Vector2.ZERO
var search_time: float = 0.0

var level_gen: Node = null
var player: CharacterBody3D = null
var frozen: bool = false   # dev-хук NIGHTFALL_SHOWMON: стоит на месте для скриншота

## Порт сприта 0 (THE STALKER) из build_sprites (render.c): высокий сутулый
## силуэт с впалым бледным лицом, тонкими когтистыми руками и горящими
## глазами -- раньше тело было просто чёрной капсулой с двумя отдельными
## сферами-глазами. Теперь это billboard-плоскость (сам движок держит её
## лицом к камере -- ручной _face_player() для этого больше не нужен, но
## оставлен: он же используется в watcher-логике "видит ли игрок монстра").
const TEX := 64
@onready var body: MeshInstance3D = $Body
static var _albedo_tex: ImageTexture = null
static var _emission_tex: ImageTexture = null

## каждый вид носит свой оттенок -- дешёвый способ различить силуэты,
## не рисуя три разных сприта (см. "each kind wears its own pallor")
const TYPE_TINT := {
	0: Color(1.0, 1.0, 1.0),     # STALKER -- как нарисовано
	1: Color(0.75, 0.8, 0.95),   # LISTENER -- бледнее, holodный синеватый
	2: Color(0.55, 0.15, 0.55),  # WATCHER -- неестественный лиловый
}

func _build_body_material() -> StandardMaterial3D:
	if _albedo_tex == null:
		var pair := _build_stalker_textures()
		_albedo_tex = pair[0]
		_emission_tex = pair[1]
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _albedo_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.emission_enabled = true
	mat.emission_texture = _emission_tex
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color = TYPE_TINT.get(mon_type, Color.WHITE)
	return mat

static func _build_stalker_textures() -> Array:
	var albedo := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	var emission := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		for x in range(TEX):
			var nx: float = x - 32.0
			var part := 0   # 1 = тёмная плоть, 2 = бледное лицо
			var hy: float = y - 11.0
			var he: float = (nx * nx) / (5.5 * 5.5) + (hy * hy) / (8.0 * 8.0)
			if he < 1.0:
				part = 2
			if y >= 17 and y <= 20 and abs(nx) < 2.3 and part == 0:
				part = 1
			if y >= 19 and y <= 47:
				var tt: float = (y - 19) / 28.0
				var hw: float = 9.5 - tt * 6.0
				if abs(nx) < hw and part == 0:
					part = 1
			if y >= 20 and y <= 60:
				# руки длиннее и тянутся ниже колен -- пропорции чуть "неправильные",
				# читается тревожнее правдоподобно-человеческих рук
				var ax: float = 8.0 + (y - 20) * 0.22
				if abs(abs(nx) - ax) < 2.1 and part == 0:
					part = 1
				if y >= 50 and abs(nx) - ax > -1.5 and abs(nx) - ax < 5.5 and (x % 2 == 0) and part == 0:
					part = 1   # растопыренные когтистые пальцы, ещё длиннее
			if y >= 46 and y <= 63 and abs(abs(nx) - 3.5) < 2.0 and part == 0:
				part = 1
			# рваная тряпка на бёдрах -- всё, что осталось от одежды
			var rag: bool = y >= 44 and y <= 50 and abs(nx) < 8.5 and part == 0
			if rag:
				part = 1
			if part == 1:
				var v: float = (6.0 + randf() * 7.0) / 255.0
				if randf() < 0.04:
					v += 22.0 / 255.0
				var c1 := Color(v, v, v + 2.0 / 255.0, 1.0)
				# рёбра/кости, проступающие через рваную плоть на торсе --
				# бледные горизонтальные полосы редкими рядами
				if y >= 22 and y <= 42 and (int(y) % 5) < 1 and abs(nx) < 7.0 and randf() < 0.55:
					var bone: float = (110.0 + randf() * 20.0) / 255.0
					c1 = Color(bone, bone * 0.95, bone * 0.88, 1.0)
				# синюшные кровоподтёки/язвы, разбросанные по коже -- реже,
				# чем кость, тёмное бурое пятно с нечётким краем
				var sore: float = sin(x * 0.9 + 7.0 * sin(y * 0.5)) * 0.5 + 0.5
				if sore > 0.93:
					c1 = Color(32 / 255.0, 8 / 255.0, 14 / 255.0, 1.0)
				if rag:
					# сама тряпка -- пыльно-серая мешковина, а не плоть
					var rv: float = (30.0 + randf() * 10.0) / 255.0
					if (int(x + y) % 5) < 1:
						rv -= 10.0 / 255.0   # складки/дыры на ткани
					c1 = Color(rv * 1.1, rv, rv * 0.85, 1.0)
				albedo.set_pixel(x, y, c1)
			elif part == 2:
				var edge: float = abs(nx) / 5.5
				var v2: float = (64.0 - edge * 42.0) / 255.0 + randf() * 6.0 / 255.0
				albedo.set_pixel(x, y, Color(v2, v2 * 0.92, v2 * 0.86, 1.0))
	# впалые глазницы, горящие глаза и клыкастая пасть -- второй проход
	# поверх тела, только в верхней полосе (лицо)
	for y in range(4, 46):
		for x in range(TEX):
			var lex: float = x - 27.5
			var ley: float = y - 10.0
			var le: float = lex * lex + ley * ley
			var rex: float = x - 36.5
			# правый глаз заметно мельче левого -- несимметричное лицо
			# тревожит сильнее, чем зеркально одинаковое
			var re: float = (rex * rex + ley * ley) * 1.6
			if le < 10.0 or re < 10.0:
				var q: float = (min(le, re)) / 10.0
				var c := Color(1.0, (90.0 - q * 60.0) / 255.0, (30.0 - q * 22.0) / 255.0, 1.0)
				albedo.set_pixel(x, y, c)
				emission.set_pixel(x, y, c)
			elif le < 22.0 or re < 22.0:
				albedo.set_pixel(x, y, Color(120 / 255.0, 12 / 255.0, 8 / 255.0, 1.0))
				emission.set_pixel(x, y, Color(120 / 255.0, 12 / 255.0, 8 / 255.0, 1.0))
			elif le < 40.0 or re < 40.0:
				albedo.set_pixel(x, y, Color(4 / 255.0, 2 / 255.0, 2 / 255.0, 1.0))
			# кровавые дорожки из глаз тянутся дальше вниз по телу, не
			# обрываются сразу под подбородком -- читается свежее и хуже
			if (x == 27 or x == 37) and y > 12 and y < 45 and ((y + x) % 3) != 0:
				albedo.set_pixel(x, y, Color(70 / 255.0, 6 / 255.0, 6 / 255.0, 1.0))
			# рваная рана на груди, чуть ниже шеи, с собственным потёком крови
			var wound: float = (x - 32.0) * (x - 32.0) / 4.0 + (y - 28.0) * (y - 28.0) / 9.0
			if wound < 1.0 and y > 24:
				var wd: bool = ((x * 3 + y) % 4) < 2
				albedo.set_pixel(x, y, Color(40 / 255.0, 3 / 255.0, 4 / 255.0, 1.0) if wd else Color(85 / 255.0, 8 / 255.0, 6 / 255.0, 1.0))
			elif x == 32 and y >= 33 and y < 45 and (y % 3) != 0:
				albedo.set_pixel(x, y, Color(60 / 255.0, 5 / 255.0, 5 / 255.0, 1.0))
			# пасть шире и глубже прежней -- неестественно растянутый
			# оскал, а не аккуратный человеческий рот
			var m: float = (x - 32.0) * (x - 32.0) / 9.0 + (y - 19.0) * (y - 19.0) / 7.5
			if m < 1.0:
				var fang: bool
				if y < 19:
					fang = ((x * 5) % 4) < 2 and y > 15
				else:
					fang = ((x * 5 + 2) % 4) < 2 and y < 23
				if fang:
					var fc := Color(205 / 255.0, 195 / 255.0, 175 / 255.0, 1.0)
					albedo.set_pixel(x, y, fc)
					emission.set_pixel(x, y, fc)
				else:
					albedo.set_pixel(x, y, Color(5 / 255.0, 2 / 255.0, 3 / 255.0, 1.0))
	return [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(emission)]

## Рёв при входе в погоню и рваное рычание, пока она длится -- порт
## соответствующего куска update_ai (ai.c). До этого фикса звуки лежали в
## assets/ неиспользованными: монстр был совершенно немым даже во время
## погони, отсюда и жалоба "не страшно, не интересно" -- его не слышно.
## Позиционный AudioStreamPlayer3D сам даёт затухание по расстоянию вместо
## ручной формулы громкости из C.
const GROWL_MIN := 1.8
const GROWL_MAX := 4.2
const ROAR_BREATHE_MIN := 5.5
const ROAR_BREATHE_MAX := 7.5
var growl_timer: float = 0.0
var roar_player: AudioStreamPlayer3D = null
var growl_player: AudioStreamPlayer3D = null

## точная мировая точка, куда идти внутри клетки-цели, а не только сама
## клетка -- см. _move(): без этого монстр останавливался в центре клетки,
## как только заходил в ту же клетку, что и игрок, даже если реальное
## расстояние до игрока ещё больше CATCH_DIST -- зависал вплотную, так и не
## доводя поимку до конца (та самая жалоба "не нападает").
var aim_point: Vector2 = Vector2.ZERO

func setup(p_level_gen: Node, p_player: CharacterBody3D) -> void:
	level_gen = p_level_gen
	player = p_player
	mon_type = _pick_type()
	pick_wander()
	_setup_voice()
	body.material_override = _build_body_material()
	GameState.note_encounter(mon_type)

func _setup_voice() -> void:
	roar_player = AudioStreamPlayer3D.new()
	roar_player.stream = load("res://assets/roar.wav")
	roar_player.unit_size = 4.0
	roar_player.max_distance = 16.0
	add_child(roar_player)
	growl_player = AudioStreamPlayer3D.new()
	growl_player.stream = load("res://assets/growl.wav")
	growl_player.unit_size = 4.0
	growl_player.max_distance = 16.0
	add_child(growl_player)

## Порт выбора ужаса по глубине из gen.c: первая встреча со Слухачом на
## 4 этаже, с Наблюдателем -- на 7, дальше вразнобой из уже открытых типов.
func _pick_type() -> MonType:
	var depth: int = GameState.depth
	if depth < 4:
		return MonType.STALKER
	elif depth == 4:
		return MonType.LISTENER
	elif depth == 7:
		return MonType.WATCHER
	else:
		var options: Array = [MonType.STALKER, MonType.LISTENER]
		if depth >= 7:
			options.append(MonType.WATCHER)
		return options[randi() % options.size()]

var _aitrace_t: float = 0.0

var _twitch_t: float = randf() * 10.0

## лёгкая нервная дрожь силуэта -- даже стоя на месте (WANDER, ждёт своего
## хода) он не читается как застывший кадр. Резче и чаще во время охоты,
## как будто на грани того, чтобы сорваться.
func _process(delta: float) -> void:
	_twitch_t += delta
	var jitter_speed: float = 14.0 if state == State.HUNT else 6.0
	var jitter_amp: float = 0.035 if state == State.HUNT else 0.015
	var jx: float = sin(_twitch_t * jitter_speed) * jitter_amp
	var jy: float = sin(_twitch_t * jitter_speed * 1.7 + 1.3) * jitter_amp * 0.6
	body.scale = Vector3(1.0 + jx, 1.0 + jy, 1.0)

func _physics_process(delta: float) -> void:
	if level_gen == null or player == null or GameState.state != GameState.State.PLAY:
		return
	_sense(delta)
	_move(delta)
	_face_player()

	if OS.get_environment("NIGHTFALL_AITRACE") != "":
		_aitrace_t -= delta
		if _aitrace_t <= 0.0:
			_aitrace_t = 1.0
			print("AITRACE type=%d state=%d pos=%s target=%s vel=%s frozen=%s" % [
				mon_type, state, position, target_cell, velocity, frozen])

	if player.hidden:
		# спрятался -- поймать может, только если оно рядом ищет/охотится
		# и оказалось у самого шкафчика (см. CHECK_DIST в main.c)
		if (state == State.HUNT or state == State.SEARCH) and player.lockers.size() > 0:
			var mypos2d := Vector2(position.x, position.z)
			var ppos2d := Vector2(player.position.x, player.position.z)
			if mypos2d.distance_to(ppos2d) < CHECK_DIST:
				player.hidden = false
				GameState.go_caught()
		return

	var d: float = Vector2(position.x, position.z).distance_to(Vector2(player.position.x, player.position.z))
	if d < CATCH_DIST:
		GameState.go_caught()

## развернуть тело лицом к игроку по горизонтали -- меш не крутится от
## движения сам, а так светящиеся глаза (см. monster.tscn) всегда смотрят
## на игрока: приближение читается как пара глаз, наплывающих из темноты
func _face_player() -> void:
	var t := player.global_position
	t.y = global_position.y
	if global_position.distance_to(t) > 0.2:
		look_at(t, Vector3.UP)

func _sense(delta: float) -> void:
	if player.hidden:
		return
	var mypos := Vector2(position.x, position.z)
	var ppos := Vector2(player.position.x, player.position.z)
	var d := mypos.distance_to(ppos)
	var sensed := false
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	var w: float = wear()   # чувства острее с глубиной, до +30-35% на дне
	# "low sanity = ragged panic breathing: the Stalker hears you from
	# farther" (ai.c) -- раньше слух зависел только от глубины, страх самого
	# игрока никак его не подводил ближе, хотя рассудок уже тает от охоты.
	var dread: float = 1.0 - player.sanity

	if mon_type == MonType.LISTENER:
		# слепой -- зрение не участвует вовсе, только гораздо более острый слух
		var hear := (LISTENER_HEAR_RUN if speed > 3.5 else LISTENER_HEAR_WALK) * (1.0 + w * 0.3) * (1.0 + dread * 0.4)
		if speed > 0.5 and d < hear:
			sensed = true
	elif mon_type == MonType.WATCHER:
		# знает про игрока всегда -- просто не может сдвинуться, пока
		# игрок на него смотрит (см. _move)
		sensed = true
	else:
		# порт "see_range *= 1.9" из ai.c: горящая спичка выдаёт тебя
		# Сталкеру издалека -- та половина сделки "свет против того, чтобы
		# быть увиденным", которую раньше никто не подключал.
		var see_range: float = SEE_RANGE * (1.0 + w * 0.3) * (1.9 if player.lit_by_match else 1.0)
		if d < see_range and _has_los(ppos):
			sensed = true
		else:
			var hear := (HEAR_RUN if speed > 3.5 else HEAR_WALK) * (1.0 + w * 0.3) * (1.0 + dread * 0.5)
			if speed > 0.5 and d < hear:
				sensed = true

	if sensed:
		if state != State.HUNT and mon_type != MonType.WATCHER:
			# только что взяло след -- долгий рёв, потом пауза, чтобы он отыграл
			roar_player.play()
			growl_timer = ROAR_BREATHE_MIN + randf() * (ROAR_BREATHE_MAX - ROAR_BREATHE_MIN)
		state = State.HUNT
		last_known = ppos
		set_target(Vector2i(int(ppos.x), int(ppos.y)))
		aim_point = ppos   # внутри клетки-цели идти точно на игрока, не в её центр
		if mon_type != MonType.WATCHER:
			growl_timer -= delta
			if growl_timer <= 0.0:
				growl_player.play()
				growl_timer = GROWL_MIN + randf() * (GROWL_MAX - GROWL_MIN)
	elif state == State.HUNT:
		state = State.SEARCH
		search_time = 8.0
		# порт из ai.c: теряя след, оно первым делом проверяет ближайший к
		# месту потери шкафчик, а не просто идёт в пустую точку -- прятки
		# сразу после разрыва видимости не гарантия безопасности, если
		# шкафчик был слишком близко к тому месту, где оно вас видело
		# в последний раз. Раньше вообще не учитывалось: SEARCH всегда шёл
		# ровно в last_known, шкафчики никак не участвовали.
		var tgt := Vector2i(int(last_known.x), int(last_known.y))
		var best_ld := 3.0
		for l in player.lockers:
			var ld: float = abs(l.position.x - last_known.x) + abs(l.position.z - last_known.y)
			if ld < best_ld:
				best_ld = ld
				tgt = Vector2i(int(l.position.x), int(l.position.z))
		set_target(tgt)
	elif state == State.SEARCH:
		_check_noise()
		search_time -= delta
		var here := Vector2i(int(position.x), int(position.z))
		if here == target_cell or search_time <= 0.0:
			state = State.WANDER
			pick_wander()
	elif state == State.WANDER:
		_check_noise()
		var here2 := Vector2i(int(position.x), int(position.z))
		if here2 == target_cell:
			pick_wander()

## порт шумовой приманки из ai.c: свежий шум (брошенный камень, зажжённая
## спичка, беготня) в пределах слышимости уводит его расследовать, даже
## если оно не видело и не слышало игрока напрямую.
func _check_noise() -> void:
	if level_gen.noise_t <= 0.0:
		return
	var mypos := Vector2(position.x, position.z)
	if mypos.distance_to(level_gen.noise_pos) < HEAR_RUN * 1.7:
		state = State.SEARCH
		search_time = 5.0
		set_target(Vector2i(int(level_gen.noise_pos.x), int(level_gen.noise_pos.y)))

## прямая видимость: луч игрок<->монстр не должен пересекать стены
## (см. has_los в gen.c, там -- пошаговая проверка по сетке; тут -- raycast)
func _has_los(ppos: Vector2) -> bool:
	var space := get_world_3d().direct_space_state
	var from := Vector3(position.x, 0.5, position.z)
	var to := Vector3(ppos.x, 0.5, ppos.y)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1   # стены (см. wall_map collision layer)
	# игрок и сам монстр -- на том же физическом слое, что и стены; без
	# исключения луч, нацеленный прямо в игрока, всегда попадал бы в его же
	# капсулу тела и засчитывался как "загорожено", так что Сталкер вообще
	# никогда не видел игрока по LOS (см. баг -- монстр только бродит,
	# никогда не переходит в HUNT, даже стоя вплотную).
	query.exclude = [self.get_rid(), player.get_rid()]
	var hit := space.intersect_ray(query)
	return hit.is_empty()

func set_target(cell: Vector2i) -> void:
	target_cell = cell
	dist_grid = level_gen.flood_from(cell)
	aim_point = Vector2(cell.x + 0.5, cell.y + 0.5)

## Как pick_wander в gen.c: иногда мимо ещё не открытого сундука, иначе
## просто случайная открытая клетка.
func pick_wander() -> void:
	if level_gen.chests.size() > 0 and randf() < 0.5:
		var active_chests: Array = level_gen.chests.filter(func(c): return c.active)
		if not active_chests.is_empty():
			var c = active_chests[randi() % active_chests.size()]
			set_target(Vector2i(int(c.pos.x), int(c.pos.y)))
			return
	var mw: int = level_gen.MW
	var mh: int = level_gen.MH
	for _i in range(64):
		var x: int = 1 + randi() % (mw - 2)
		var y: int = 1 + randi() % (mh - 2)
		if level_gen.is_open(x, y):
			set_target(Vector2i(x, y))
			return

## смотрит ли игрок в его сторону сейчас (см. player_sees_monster в ai.c):
## внутри узкого конуса обзора и без стен между ними.
func _player_watching() -> bool:
	var to_mon := Vector2(position.x - player.position.x, position.z - player.position.z)
	var dist := to_mon.length()
	if dist < 0.7:
		return true
	var fwd := -player.transform.basis.z
	var fwd2d := Vector2(fwd.x, fwd.z).normalized()
	var facing: float = fwd2d.dot(to_mon.normalized())
	if facing < 0.42:   # вне ~65° конуса вперёд
		return false
	return _has_los(Vector2(player.position.x, player.position.z))

func _move(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		return
	var speed_mult := 1.0
	if mon_type == MonType.WATCHER:
		if _player_watching():
			velocity = Vector3.ZERO
			return
		speed_mult = WATCHER_RUSH_MULT
	elif state == State.HUNT:
		# "it surges when hunting you at close range -- a terrifying final
		# lunge" (ai.c) -- было в C-версии, потерялось при портировании:
		# Сталкер/Слухач шли одной и той же скоростью весь эпизод охоты,
		# без рывка на добивании, когда до игрока остаются считанные метры.
		var pd: float = Vector2(position.x, position.z).distance_to(Vector2(player.position.x, player.position.z))
		if pd < 3.0:
			speed_mult = 1.0 + (3.0 - pd) / 3.0 * 0.55

	var cx := int(position.x)
	var cz := int(position.z)
	if cx < 0 or cz < 0 or cz >= dist_grid.size() or cx >= dist_grid[0].size():
		return
	var best: int = dist_grid[cz][cx]
	var best_cell := Vector2i(cx, cz)
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d in dirs:
		var nx: int = cx + d.x
		var nz: int = cz + d.y
		if level_gen.is_open(nx, nz) and nz < dist_grid.size() and nx < dist_grid[0].size() \
				and dist_grid[nz][nx] < best:
			best = dist_grid[nz][nx]
			best_cell = Vector2i(nx, nz)
	var target_pos: Vector3
	if best_cell == Vector2i(cx, cz):
		# в клетке-цели нет соседа с меньшей дистанцией -- мы дошли по сетке;
		# добираем последний отрезок точно до aim_point, а не до центра клетки
		target_pos = Vector3(aim_point.x, position.y, aim_point.y)
	else:
		target_pos = Vector3(best_cell.x + 0.5, position.y, best_cell.y + 0.5)
	var dir := (target_pos - position)
	dir.y = 0
	if dir.length() > 0.05:
		# +35% скорости на дне -- "с каждым этажом вниз оно быстрее" (README),
		# раньше SPEED был фиксированной константой независимо от depth
		velocity = dir.normalized() * SPEED * (1.0 + wear() * 0.35) * speed_mult
	else:
		velocity = Vector3.ZERO
	move_and_slide()
