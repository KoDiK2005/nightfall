extends Node3D
## Настенный факел: тёплый точечный свет + мерцание, портировано из
## render.c (place_torches/add_torch) и audio.c-подобной случайной
## дрожи пламени. Пламя -- порт процедурного спрайта 4 из build_sprites
## (лижущий язык, сужающийся к острию, с лёгким изгибом) вместо плоской
## залитой коробки; текстура одна на все факелы, строится один раз и
## кешируется в статике.

const TEX := 64
static var _flame_tex: ImageTexture = null

@onready var light: OmniLight3D = $OmniLight3D
@onready var flame: MeshInstance3D = $Flame

var _t: float = randf() * 10.0
var base_energy: float = 1.4

func _ready() -> void:
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
	# резкие проседания яркости ("power surge").
	var n := sin(_t * 9.0) * 0.15 + sin(_t * 2.3) * 0.1
	var surge := 1.0
	if randf() < 0.01:
		surge = 0.2 + randf() * 0.3
	light.light_energy = base_energy * (0.85 + n) * surge
	flame.scale = Vector3.ONE * (0.9 + n * 0.6)
