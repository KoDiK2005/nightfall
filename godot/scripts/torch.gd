extends Node3D
## Настенный факел: тёплый точечный свет + мерцание, портировано из
## render.c (place_torches/add_torch) и audio.c-подобной случайной
## дрожи пламени. Сама "коробка-пламя" -- временный плейсхолдер вместо
## процедурного спрайта из C-версии (см. TODO по текстурам).

@onready var light: OmniLight3D = $OmniLight3D
@onready var flame: MeshInstance3D = $Flame

var _t: float = randf() * 10.0
var base_energy: float = 1.4

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
