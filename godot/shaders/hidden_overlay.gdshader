shader_type canvas_item;

// Порт draw_hidden_overlay из hud.c: "look out through a locker's
// horizontal vents" -- тёмные жалюзи-полосы с редкими светлыми щелями,
// плюс затемнение к краям экрана. Раньше прятка в шкафчике не давала на
// экране вообще никакой обратной связи -- ни намёка, что вы спрятались,
// ни как из этого выйти.
void fragment() {
	vec2 c = UV - vec2(0.5);
	float r = dot(c, c) * 2.0;
	r = min(r, 1.0);
	float edge = clamp((r - 0.5) * 2.0 * 0.6, 0.0, 0.6);
	bool slat = mod(FRAGCOORD.y, 46.0) > 34.0;
	float a = slat ? 0.92 : clamp(0.16 + edge, 0.0, 1.0);
	COLOR = vec4(0.0, 0.0, 0.0, a);
}
