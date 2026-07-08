extends CanvasLayer
## Всплывающие субтитры сюжетного режима -- и для "вспомнил по пути", и
## для реплик матери. Плавное появление/исчезание, как в C-версии.

@onready var label: Label = $Label

var remain: float = 0.0
var total: float = 1.0

func show_lines(lines: Array, dur: float) -> void:
	label.text = "\n".join(lines)
	remain = dur
	total = dur
	label.visible = true

func hide_line() -> void:
	remain = 0.0
	label.visible = false

func _process(delta: float) -> void:
	if remain <= 0.0:
		return
	remain -= delta
	if remain <= 0.0:
		label.visible = false
		return
	var fade_in := 0.5
	var fade_out := 0.8
	var a := 1.0
	if total - remain < fade_in:
		a = (total - remain) / fade_in
	elif remain < fade_out:
		a = remain / fade_out
	label.modulate.a = a
