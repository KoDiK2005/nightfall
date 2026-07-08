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

static func apply(depth: int) -> String:
	var b: Dictionary = BIOMES[(depth - 1) % BIOMES.size()]
	var wall_mat: StandardMaterial3D = load("res://resources/wall_material.tres")
	var floor_mat: StandardMaterial3D = load("res://resources/floor_material.tres")
	wall_mat.albedo_color = b.wall
	floor_mat.albedo_color = b.floor
	return b.name
