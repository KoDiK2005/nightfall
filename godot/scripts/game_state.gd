extends Node
## Автозагружаемый синглтон (см. project.godot [autoload]) -- то немногое,
## что должно пережить пересборку уровня: текущий этаж и рекорд глубины.
## Порт depth/best_depth из main.c.

var depth: int = 1
var best_depth: int = 1

func advance_floor() -> void:
	depth += 1
	if depth > best_depth:
		best_depth = depth

func reset() -> void:
	depth = 1
	best_depth = 1
