extends RefCounted
class_name Biomes
## Порт таблицы биомов из gen.c: каждый этаж перекрашивается в один из
## шести, по кругу от глубины. Меняет материалы стен/пола прямо в общей
## MeshLibrary (tiles.tres), которой пользуются оба GridMap.

const BIOMES := [
	{ "name": "КАТАКОМБЫ", "wall": Color(0.62, 0.58, 0.50), "floor": Color(0.35, 0.32, 0.30) },
	{ "name": "ЗАТОПЛЕННЫЙ ЯРУС", "wall": Color(0.40, 0.55, 0.52), "floor": Color(0.22, 0.34, 0.32) },
	{ "name": "ГОРНИЛО", "wall": Color(0.55, 0.30, 0.22), "floor": Color(0.32, 0.18, 0.13) },
	{ "name": "КОСТЯНОЙ СКЛЕП", "wall": Color(0.60, 0.57, 0.46), "floor": Color(0.34, 0.30, 0.22) },
	{ "name": "МЁРЗЛЫЙ ЧЕРТОГ", "wall": Color(0.48, 0.56, 0.66), "floor": Color(0.26, 0.32, 0.38) },
	{ "name": "БЕЗДНА", "wall": Color(0.36, 0.30, 0.44), "floor": Color(0.18, 0.15, 0.24) },
]

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

static func apply(depth: int) -> String:
	var b: Dictionary = BIOMES[(depth - 1) % BIOMES.size()]
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
