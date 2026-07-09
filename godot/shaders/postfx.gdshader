shader_type canvas_item;

// Порт present_scene из render.c (C-версия): хроматическая аберрация +
// зерно плёнки + лёгкая тряска экрана, растущие с падением рассудка (dread)
// и резко подскакивающие на испугах (открытие сундука, вспышка-видение).
// В Godot-порте этого пост-эффекта не было вовсе -- финальный кадр шёл
// без обработки, только красная виньетка (ColorRect) поверх.
uniform float dread : hint_range(0.0, 1.0) = 0.0;
uniform float scare : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

void fragment() {
	float aber = 0.0028 + 0.012 * dread + 0.055 * scare;
	float grain = 0.045 + 0.10 * dread + 0.12 * scare;
	float smag = 0.012 * scare;
	vec2 shake = vec2(smag * sin(TIME * 57.0), smag * cos(TIME * 43.0));
	vec2 uv = SCREEN_UV + shake;
	vec2 dir = normalize(uv - vec2(0.5)) * aber;
	float r = texture(screen_tex, uv - dir).r;
	float g = texture(screen_tex, uv).g;
	float b = texture(screen_tex, uv + dir).b;
	vec3 col = vec3(r, g, b);
	float n = fract(sin(dot(uv * (TIME * 60.0 + 1.0), vec2(12.9898, 78.233))) * 43758.5453);
	col += (n - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}
