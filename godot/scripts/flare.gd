extends Node3D
## Сигнальная шашка -- третий предмет-приманка после спички и камня, но с
## другим компромиссом: камень шумит один раз мгновенно, спичка светит, но
## свет висит на самом игроке и выдаёт его. Шашка воткнута в пол там, где
## игрока уже нет -- она сама шумит (make_noise раз в NOISE_PERIOD, пока
## горит) и светит, так что расследующий монстр идёт именно на неё, а не
## по следу игрока. Годится, чтобы разорвать погоню: бросил и свернул в
## другой коридор.

const DUR := 16.0
const NOISE_TTL := 2.5
const NOISE_PERIOD := 1.0
const TEX := 32

static var _glow_tex: ImageTexture = null

@onready var light: OmniLight3D = $OmniLight3D
@onready var flame: MeshInstance3D = $Flame

var level_gen: Node = null
var _life: float = DUR
var _noise_timer: float = 0.0
var _t: float = randf() * 10.0

func setup(p_level_gen: Node) -> void:
	level_gen = p_level_gen
	if _glow_tex == null:
		_glow_tex = _build_glow_texture()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _glow_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	flame.material_override = mat
	# первый щелчок-вспышка сама по себе тоже шум -- слышно, что что-то
	# упало и загорелось, ещё до первого периодического импульса ниже
	level_gen.make_noise(Vector2(position.x, position.z), NOISE_TTL)

## тёплое ядро с мягким спадом -- та же идея, что и дым/маячок в других
## файлах (torch.gd::_build_dust_texture, level_gen.gd::_add_beacon), но
## крупнее и краснее: сигнальная химия горит гуще и злее обычного пламени.
static func _build_glow_texture() -> ImageTexture:
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGBA8)
	for y in range(TEX):
		for x in range(TEX):
			var dx: float = x - 16.0
			var dy: float = y - 16.0
			var r2: float = dx * dx + dy * dy
			var g: float = exp(-r2 / 70.0)
			if g < 0.02:
				continue
			img.set_pixel(x, y, Color(1.0 * g, 0.35 * g, 0.08 * g, g))
	return ImageTexture.create_from_image(img)

func _process(delta: float) -> void:
	_t += delta
	_life -= delta
	_noise_timer -= delta
	if _noise_timer <= 0.0 and level_gen:
		level_gen.make_noise(Vector2(position.x, position.z), NOISE_TTL)
		_noise_timer = NOISE_PERIOD
	var n: float = sin(_t * 12.0) * 0.2 + sin(_t * 3.3) * 0.12
	# последние 2с гаснет вместо мгновенного обрыва -- читается как "догорела",
	# а не как пропавший объект
	var fade: float = clamp(_life / 2.0, 0.0, 1.0)
	light.light_energy = 2.6 * (0.85 + n) * fade
	flame.scale = Vector3.ONE * (0.9 + n * 0.5) * (0.5 + 0.5 * fade)
	if _life <= 0.0:
		queue_free()
