extends RefCounted
class_name Biomes
## Порт таблицы биомов из gen.c: каждый этаж перекрашивается в один из
## шести, по кругу от глубины. Меняет материалы стен/пола прямо в общей
## MeshLibrary (tiles.tres), которой пользуются оба GridMap.

const BIOMES := [
	{ "name": "КАТАКОМБЫ", "wall": Color(0.62, 0.58, 0.50), "floor": Color(0.35, 0.32, 0.30), "torch": Color(1.0, 0.65, 0.35), "ceil": Color(0.24, 0.21, 0.17) },
	{ "name": "ЗАТОПЛЕННЫЙ ЯРУС", "wall": Color(0.40, 0.55, 0.52), "floor": Color(0.22, 0.34, 0.32), "torch": Color(0.55, 0.95, 0.75), "ceil": Color(0.14, 0.20, 0.19) },
	{ "name": "ГОРНИЛО", "wall": Color(0.55, 0.30, 0.22), "floor": Color(0.32, 0.18, 0.13), "torch": Color(1.0, 0.35, 0.12), "ceil": Color(0.22, 0.11, 0.08) },
	{ "name": "КОСТЯНОЙ СКЛЕП", "wall": Color(0.60, 0.57, 0.46), "floor": Color(0.34, 0.30, 0.22), "torch": Color(1.0, 0.92, 0.62), "ceil": Color(0.23, 0.20, 0.15) },
	{ "name": "МЁРЗЛЫЙ ЧЕРТОГ", "wall": Color(0.48, 0.56, 0.66), "floor": Color(0.26, 0.32, 0.38), "torch": Color(0.55, 0.75, 1.0), "ceil": Color(0.16, 0.19, 0.24) },
	{ "name": "БЕЗДНА", "wall": Color(0.36, 0.30, 0.44), "floor": Color(0.18, 0.15, 0.24), "torch": Color(0.75, 0.45, 1.0), "ceil": Color(0.11, 0.09, 0.16) },
]

## тон факелов, который torch.gd подхватывает при постройке этажа --
## раньше "сбрасывает... тон факелов" из README не работало вовсе: пламя и
## свет были фиксированным тёплым оранжевым независимо от биома.
static var current_torch_tint: Color = Color(1.0, 0.65, 0.35)

const TEX := 64

## три материала стены (wall_material[_2/_3].tres, зарегистрированы в
## tiles.tres как отдельные item -- см. level_gen.gd::_paint) вместо одного:
## одна и та же кладка, отштампованная на каждую грань подряд, читалась как
## явный повторяющийся тайл ("смешай текстуры стен"). Каждый вызов
## _build_wall_texture кладёт свой случайный шум/трещины, так что три
## материала выходят похожими, но не идентичными -- level_gen выбирает
## между ними вперемешку по клеткам.
const WALL_RESOURCES := [
	"res://resources/wall_material.tres",
	"res://resources/wall_material_2.tres",
	"res://resources/wall_material_3.tres",
]
const FLOOR_RESOURCES := [
	"res://resources/floor_material.tres",
	"res://resources/floor_material_2.tres",
]
const CEIL_RESOURCES := [
	"res://resources/ceiling_material.tres",
	"res://resources/ceiling_material_2.tres",
]

static func apply(depth: int) -> String:
	var b: Dictionary = BIOMES[(depth - 1) % BIOMES.size()]
	current_torch_tint = b.torch
	# порт build_textures (render.c): кладка с мортаром + трещины/пятна,
	# усиливающиеся с глубиной -- раньше это были голые залитые цветом
	# коробки без всякой текстуры. albedo_texture умножается на albedo_color
	# ниже, так что раскраска по биому остаётся той же системой, что и была.
	var wear: float = clamp(float(depth - 1) / 12.0, 0.0, 1.0)
	for path in WALL_RESOURCES:
		var wall_mat: StandardMaterial3D = load(path)
		wall_mat.albedo_color = b.wall
		wall_mat.albedo_texture = _build_wall_texture(wear)
		wall_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	for path in FLOOR_RESOURCES:
		var floor_mat: StandardMaterial3D = load(path)
		floor_mat.albedo_color = b.floor
		floor_mat.albedo_texture = _build_floor_texture(wear)
		floor_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# потолок раньше был просто тем же полом, поднятым наверх (тот же
	# item/материал), только с независимым случайным выбором варианта --
	# смотрящий вверх видел ровно ту же плитку, что и под ногами. Теперь у
	# него свой материал/текстура: балки и копоть от факелов, а не половицы.
	for path in CEIL_RESOURCES:
		var ceil_mat: StandardMaterial3D = load(path)
		ceil_mat.albedo_color = b.ceil
		ceil_mat.albedo_texture = _build_ceiling_texture(wear)
		ceil_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return b.name

static func _build_wall_texture(wear: float) -> ImageTexture:
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	var brick_h := 16
	var brick_w := 32
	for y in range(TEX):
		var row := y / brick_h
		var ox := (brick_w / 2) if (row % 2 == 1) else 0
		for x in range(TEX):
			var mortar: bool = ((x + ox) % brick_w) < 2 or (y % brick_h) < 2
			var base: float = 0.20 + randf() * 0.07
			var c: Color
			if mortar:
				c = Color(base * 0.30, base * 0.32, base * 0.36)
			else:
				var r: float = base * 0.92
				var g: float = base * 0.86
				var bl: float = base * 0.80
				if randf() < 0.05 + 0.22 * wear:
					r -= 0.06; g -= 0.06; bl -= 0.055   # тёмные пятна, хуже глубже
				# ветвящиеся трещины по камню, гуще с глубиной
				var ridge: float = abs(sin(x * 0.20 + 2.4 * sin(y * 0.11)))
				if ridge < 0.05 + 0.05 * wear:
					var d: float = 0.11 * (0.4 + wear)
					r -= d; g -= d; bl -= d
				# глубокие этажи "плачут" ржаво-кровавым по камню
				if wear > 0.35 and randf() < 0.05 * wear:
					r += 0.09 * wear; g -= 0.05; bl -= 0.03
				c = Color(max(r, 0.015), max(g, 0.012), max(bl, 0.012))
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

static func _build_floor_texture(wear: float) -> ImageTexture:
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var f: float = 0.12 + randf() * 0.055
			if randf() < 0.12 * wear:
				f -= 0.05   # копится грязь на глубоких этажах
			f = max(f, 0.025)
			var crack: bool = (x * 7 + y * 3) % 29 < 2
			var c: Color = Color(f * 0.35, f * 0.38, f * 0.42) if crack else Color(f, f, f * 1.08)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

## тёмные потолочные балки на ровном интервале + копоть от факелов вокруг
## них, густеющая с глубиной -- совсем другое прочтение, чем половицы пола
## под ногами, хоть геометрия тайла та же самая (тонкая плита).
static func _build_ceiling_texture(wear: float) -> ImageTexture:
	var img := Image.create(TEX, TEX, false, Image.FORMAT_RGB8)
	for y in range(TEX):
		for x in range(TEX):
			var beam: bool = (x % 21) < 3
			var base: float = 0.13 + randf() * 0.05
			var c: Color
			if beam:
				var wood: float = base * 0.55
				c = Color(wood + 0.04, wood * 0.8 + 0.02, wood * 0.45)
			else:
				var v: float = base
				if randf() < 0.08 + 0.22 * wear:
					v -= 0.06 * (0.5 + wear)   # копоть от факелов, гуще на глубоких этажах
				v = max(v, 0.018)
				c = Color(v * 0.92, v * 0.90, v * 0.86)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
