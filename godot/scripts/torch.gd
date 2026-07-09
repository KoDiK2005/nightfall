extends Node3D
## Настенный факел: тёплый точечный свет + мерцание, портировано из
## render.c (place_torches/add_torch) и audio.c-подобной случайной
## дрожи пламени. Пламя -- порт процедурного спрайта 4 из build_sprites
## (лижущий язык, сужающийся к острию, с лёгким изгибом) вместо плоской
## залитой коробки; текстура одна на все факелы, строится один раз и
## кешируется в статике.

const TEX := 64
static var _flame_tex: ImageTexture = null
static var _wood_tex: ImageTexture = null
static var _iron_tex: ImageTexture = null

@onready var light: OmniLight3D = $OmniLight3D
@onready var flame: MeshInstance3D = $Flame
@onready var handle: MeshInstance3D = $Handle
@onready var bracket: MeshInstance3D = $Bracket

var _t: float = randf() * 10.0
var base_energy: float = 1.4
var _player: CharacterBody3D = null   # для "факелы чаще гаснут" по рассудку, см. _process

func _ready() -> void:
	_player = get_tree().get_root().find_child("Player", true, false)
	if _flame_tex == null:
		_flame_tex = _build_flame_texture()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _flame_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD   # горит, а не просто просвечивает
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	flame.material_override = mat

	# рукоять и крепление раньше были залиты плоским цветом -- последнее,
	# что осталось нетекстурированным в самом частом объекте подземелья
	# (десятки факелов на этаж).
	if _wood_tex == null:
		_wood_tex = _build_grain_texture(0.22, 0.14, 0.08)
	if _iron_tex == null:
		_iron_tex = _build_grain_texture(0.14, 0.13, 0.13)
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_texture = _wood_tex
	wood_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	wood_mat.roughness = 1.0
	handle.material_override = wood_mat
	var iron_mat := StandardMaterial3D.new()
	iron_mat.albedo_texture = _iron_tex
	iron_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	iron_mat.metallic = 0.3
	iron_mat.roughness = 0.6
	bracket.material_override = iron_mat

## общая заготовка волокна/зерна под данный базовый цвет -- переиспользуется
## и для дерева рукояти, и для железа крепления, только тон разный.
static func _build_grain_texture(r: float, g: float, b: float) -> ImageTexture:
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var grain: float = sin(y * 0.35 + x * 1.7) * 0.06 + sin(y * 0.9) * 0.04
			var mul: float = 1.0 + grain
			img.set_pixel(x, y, Color(clamp(r * mul, 0.0, 1.0), clamp(g * mul, 0.0, 1.0), clamp(b * mul, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)

## Порт пикселя-в-пиксель сприта 4 (render.c): тёплое ядро у основания,
## сужение к острию через жёлтый/оранжевый к тусклому красному на кончиках,
## с лёгким боковым изгибом языка (sin по высоте), чтобы читалось как огонь.
static func _build_flame_texture() -> ImageTexture:
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		var fy: float = (54.0 - y) / 46.0
		if fy < 0.0 or fy > 1.0:
			continue
		var lean: float = 3.2 * sin(fy * 2.1)
		for x in range(TEX):
			var fx: float = (x - 32.0) - lean
			var w: float = 13.0 * pow(1.0 - fy, 0.72)
			w *= 0.7 + 0.3 * sin(fy * PI)
			if w < 0.5 or abs(fx) > w:
				continue
			var r: float = abs(fx) / w
			var heat: float = (1.0 - r * r) * (1.0 - 0.65 * fy)
			heat = clamp(heat, 0.0, 1.0)
			var cr: float = clamp(0.35 + 0.75 * heat, 0.0, 1.0)
			var cg: float = clamp(0.05 + 0.85 * heat * heat, 0.0, 1.0)
			var cb: float = clamp(0.55 * heat * heat * heat, 0.0, 1.0)
			img.set_pixel(x, y, Color(cr, cg, cb, 1.0))
	return ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	_t += delta
	# та же идея, что и flicker в render.c: медленный шум плюс редкие
	# резкие проседания яркости ("power surge") -- порт "торчи чаще
	# гаснут" по мере падения рассудка (см. README): раньше шанс скачка
	# был фиксированным 1%, никак не завязанным на игрока.
	var n := sin(_t * 9.0) * 0.15 + sin(_t * 2.3) * 0.1
	var dread: float = 0.0
	if _player and "sanity" in _player:
		dread = 1.0 - _player.sanity
	var surge := 1.0
	if randf() < 0.01 + dread * 0.05:
		surge = max(0.2 + randf() * 0.3 - dread * 0.15, 0.05)   # проседает глубже, чем ниже рассудок
	light.light_energy = base_energy * (0.85 + n) * surge
	flame.scale = Vector3.ONE * (0.9 + n * 0.6)
