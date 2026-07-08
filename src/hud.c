/*
 * NIGHTFALL — the 2D software overlay: pixel font/text, the HUD, menus,
 * lore-note panel, hallucination images, and the jump-scare screens. All of
 * it draws into `fb`, which render.c then composites over the 3D scene.
 */
#include "game.h"

/* 2D overlay software buffer (ARGB, alpha = coverage over the 3D scene) */
uint32_t fb[SCREEN_W * SCREEN_H];

Vision visions[MAX_VISIONS];
int    nvisions = 0;
double vision_t = 0.0, vision_timer = 12.0;
int    vision_idx = 0;
/* the guaranteed jump-scare: a photo slammed full-screen when a chest opens */
double screamer_t = 0.0;
int    screamer_idx = 0;

/* ----------------------------------------------------- minimal PNG decoder */
/* Decodes 8-bit non-interlaced PNG (grey/RGB/palette/grey+alpha/RGBA) to RGBA
 * bytes, using zlib for the DEFLATE stage. Returns malloc'd w*h*4 or NULL.   */
static unsigned char *load_png(const char *path, int *out_w, int *out_h) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long fsz = ftell(f); fseek(f, 0, SEEK_SET);
    if (fsz < 8) { fclose(f); return NULL; }
    unsigned char *buf = malloc(fsz);
    if (!buf || fread(buf, 1, fsz, f) != (size_t)fsz) { free(buf); fclose(f); return NULL; }
    fclose(f);
    if (memcmp(buf, "\x89PNG\r\n\x1a\n", 8) != 0) { free(buf); return NULL; }
    int w = 0, h = 0, bd = 0, ct = 0, interlace = 0;
    unsigned char *idat = NULL; size_t idat_len = 0, idat_cap = 0;
    unsigned char pal[256 * 3]; int pal_n = 0;
    unsigned char trns[256]; int trns_n = 0; memset(trns, 255, sizeof(trns));
    size_t p = 8;
    while (p + 12 <= (size_t)fsz) {
        unsigned len = (buf[p] << 24) | (buf[p+1] << 16) | (buf[p+2] << 8) | buf[p+3];
        unsigned char *type = buf + p + 4, *data = buf + p + 8;
        if (p + 12 + (size_t)len > (size_t)fsz) break;
        if (!memcmp(type, "IHDR", 4)) {
            w = (data[0]<<24)|(data[1]<<16)|(data[2]<<8)|data[3];
            h = (data[4]<<24)|(data[5]<<16)|(data[6]<<8)|data[7];
            bd = data[8]; ct = data[9]; interlace = data[12];
        } else if (!memcmp(type, "PLTE", 4)) {
            pal_n = len / 3; if (pal_n > 256) pal_n = 256; memcpy(pal, data, pal_n * 3);
        } else if (!memcmp(type, "tRNS", 4)) {
            if (ct == 3) { trns_n = len > 256 ? 256 : (int)len; memcpy(trns, data, trns_n); }
        } else if (!memcmp(type, "IDAT", 4)) {
            if (idat_len + len > idat_cap) { idat_cap = (idat_len + len) * 2 + 4096;
                unsigned char *nb = realloc(idat, idat_cap); if (!nb) { free(idat); free(buf); return NULL; } idat = nb; }
            memcpy(idat + idat_len, data, len); idat_len += len;
        } else if (!memcmp(type, "IEND", 4)) break;
        p += 12 + len;
    }
    int ch = (ct==0)?1:(ct==2)?3:(ct==3)?1:(ct==4)?2:(ct==6)?4:0;
    if (bd != 8 || interlace != 0 || w <= 0 || h <= 0 || ch == 0 || !idat) {
        free(buf); free(idat); return NULL;
    }
    size_t stride = 1 + (size_t)w * ch, raw_sz = stride * h;
    unsigned char *raw = malloc(raw_sz);
    uLongf destlen = raw_sz;
    if (!raw || uncompress(raw, &destlen, idat, idat_len) != Z_OK || destlen != raw_sz) {
        free(buf); free(idat); free(raw); return NULL;
    }
    free(idat);
    unsigned char *img = malloc((size_t)w * ch * h); if (!img) { free(buf); free(raw); return NULL; }
    int bpp = ch;
    for (int y = 0; y < h; y++) {
        unsigned char ft = raw[y * stride];
        unsigned char *row = raw + y * stride + 1;
        unsigned char *out = img + (size_t)y * w * ch;
        unsigned char *prev = y > 0 ? img + (size_t)(y - 1) * w * ch : NULL;
        for (int x = 0; x < w * ch; x++) {
            int a = x >= bpp ? out[x - bpp] : 0;
            int b = prev ? prev[x] : 0;
            int c = (prev && x >= bpp) ? prev[x - bpp] : 0;
            int v = row[x];
            switch (ft) {
                case 1: v += a; break;
                case 2: v += b; break;
                case 3: v += (a + b) / 2; break;
                case 4: { int pp = a + b - c, pa = abs(pp-a), pb = abs(pp-b), pc = abs(pp-c);
                          v += (pa <= pb && pa <= pc) ? a : (pb <= pc) ? b : c; } break;
            }
            out[x] = (unsigned char)v;
        }
    }
    free(raw);
    unsigned char *rgba = malloc((size_t)w * h * 4); if (!rgba) { free(buf); free(img); return NULL; }
    for (int i = 0; i < w * h; i++) {
        unsigned char *s = img + (size_t)i * ch, R, G, B, A = 255;
        if      (ct == 0) { R = G = B = s[0]; }
        else if (ct == 2) { R = s[0]; G = s[1]; B = s[2]; }
        else if (ct == 3) { int ix = s[0]; R = pal[ix*3]; G = pal[ix*3+1]; B = pal[ix*3+2]; A = ix < trns_n ? trns[ix] : 255; }
        else if (ct == 4) { R = G = B = s[0]; A = s[1]; }
        else              { R = s[0]; G = s[1]; B = s[2]; A = s[3]; }
        rgba[i*4] = R; rgba[i*4+1] = G; rgba[i*4+2] = B; rgba[i*4+3] = A;
    }
    free(img); free(buf);
    *out_w = w; *out_h = h;
    return rgba;
}

/* Hallucination images the player drops into assets/visions/ — flashed on
 * screen as sanity collapses. Loaded once, downscaled to fit the overlay.   */

/* nearest-downscale an RGBA image so it fits inside maxw x maxh (no upscale) */
static unsigned char *fit_rgba(unsigned char *src, int w, int h, int maxw, int maxh, int *ow, int *oh) {
    if (w <= maxw && h <= maxh) { *ow = w; *oh = h; return src; }
    double sc = fmin((double)maxw / w, (double)maxh / h);
    int nw = (int)(w * sc), nh = (int)(h * sc);
    if (nw < 1) nw = 1;
    if (nh < 1) nh = 1;
    unsigned char *dst = malloc((size_t)nw * nh * 4);
    if (!dst) { *ow = w; *oh = h; return src; }
    for (int y = 0; y < nh; y++) {
        int sy = y * h / nh;
        for (int x = 0; x < nw; x++) {
            int sx = x * w / nw;
            memcpy(dst + ((size_t)y * nw + x) * 4, src + ((size_t)sy * w + sx) * 4, 4);
        }
    }
    free(src);
    *ow = nw; *oh = nh;
    return dst;
}

void load_visions(void) {
    DIR *d = opendir("assets/visions");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) && nvisions < MAX_VISIONS) {
        const char *nm = e->d_name;
        size_t l = strlen(nm);
        if (l < 5) continue;
        const char *ext = nm + l - 4;
        if (strcasecmp(ext, ".png") != 0) continue;
        char path[512];
        snprintf(path, sizeof(path), "assets/visions/%s", nm);
        int w, h;
        unsigned char *px = load_png(path, &w, &h);
        if (!px) { fprintf(stderr, "vision: could not load %s (needs 8-bit PNG)\n", nm); continue; }
        px = fit_rgba(px, w, h, SCREEN_W, SCREEN_H, &w, &h);
        visions[nvisions].w = w; visions[nvisions].h = h; visions[nvisions].px = px;
        nvisions++;
    }
    closedir(d);
    if (nvisions) fprintf(stderr, "loaded %d vision image(s)\n", nvisions);
}

/* ----------------------------------------------------------- 5x7 pixel font */
static const unsigned char FONT[][7] = {
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},{0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E},
    {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
    {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F},{0x11,0x11,0x11,0x1F,0x11,0x11,0x11},
    {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},{0x07,0x02,0x02,0x02,0x02,0x12,0x0C},
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11},{0x10,0x10,0x10,0x10,0x10,0x10,0x1F},
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},{0x11,0x11,0x19,0x15,0x13,0x11,0x11},
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10},
    {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11},
    {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04,0x04,0x04},
    {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},{0x11,0x11,0x11,0x11,0x11,0x0A,0x04},
    {0x11,0x11,0x11,0x15,0x15,0x1B,0x11},{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11},
    {0x11,0x11,0x0A,0x04,0x04,0x04,0x04},{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F},
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
    {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00},{0x01,0x02,0x02,0x04,0x08,0x08,0x10},
    {0x00,0x04,0x04,0x00,0x00,0x04,0x04},{0x04,0x04,0x04,0x04,0x04,0x00,0x04},
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C},{0x00,0x00,0x00,0x1F,0x00,0x00,0x00},
    /* --- Cyrillic uppercase, indices 42.. : А Б В Г Д Е Ж З И Й К Л М Н О П
       Р С Т У Ф Х Ц Ч Ш Щ Ъ Ы Ь Э Ю Я Ё --- */
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}, /*А*/ {0x1F,0x10,0x10,0x1E,0x11,0x11,0x1E}, /*Б*/
    {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}, /*В*/ {0x1F,0x10,0x10,0x10,0x10,0x10,0x10}, /*Г*/
    {0x0E,0x0A,0x0A,0x0A,0x0A,0x1F,0x11}, /*Д*/ {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}, /*Е*/
    {0x15,0x15,0x0E,0x04,0x0E,0x15,0x15}, /*Ж*/ {0x0E,0x11,0x01,0x06,0x01,0x11,0x0E}, /*З*/
    {0x11,0x11,0x13,0x15,0x19,0x11,0x11}, /*И*/ {0x0A,0x11,0x13,0x15,0x19,0x11,0x11}, /*Й*/
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11}, /*К*/ {0x0E,0x0A,0x0A,0x0A,0x0A,0x0A,0x1A}, /*Л*/
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11}, /*М*/ {0x11,0x11,0x11,0x1F,0x11,0x11,0x11}, /*Н*/
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E}, /*О*/ {0x1F,0x11,0x11,0x11,0x11,0x11,0x11}, /*П*/
    {0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}, /*Р*/ {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E}, /*С*/
    {0x1F,0x04,0x04,0x04,0x04,0x04,0x04}, /*Т*/ {0x11,0x11,0x11,0x0F,0x01,0x02,0x0C}, /*У*/
    {0x04,0x0E,0x15,0x15,0x15,0x0E,0x04}, /*Ф*/ {0x11,0x11,0x0A,0x04,0x0A,0x11,0x11}, /*Х*/
    {0x11,0x11,0x11,0x11,0x11,0x1F,0x01}, /*Ц*/ {0x11,0x11,0x11,0x0F,0x01,0x01,0x01}, /*Ч*/
    {0x15,0x15,0x15,0x15,0x15,0x15,0x1F}, /*Ш*/ {0x15,0x15,0x15,0x15,0x15,0x1F,0x01}, /*Щ*/
    {0x18,0x08,0x08,0x0E,0x09,0x09,0x0E}, /*Ъ*/ {0x11,0x11,0x19,0x15,0x15,0x19,0x11}, /*Ы*/
    {0x10,0x10,0x10,0x1E,0x11,0x11,0x1E}, /*Ь*/ {0x0E,0x11,0x01,0x07,0x01,0x11,0x0E}, /*Э*/
    {0x12,0x15,0x15,0x1D,0x15,0x15,0x12}, /*Ю*/ {0x0F,0x11,0x11,0x0F,0x05,0x09,0x11}, /*Я*/
    {0x0A,0x1F,0x10,0x1E,0x10,0x10,0x1F}, /*Ё*/
    {0x00,0x00,0x00,0x00,0x0C,0x04,0x08}, /*,*/ {0x0E,0x11,0x01,0x02,0x04,0x00,0x04}, /*?*/
};
#define GLYPH_CYR  42          /* first Cyrillic glyph (А); Ё at +32          */
#define GLYPH_COMMA 75
#define GLYPH_QUEST 76
static int glyph(char c) {
    if (c >= 'a' && c <= 'z') c -= 32;
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= '0' && c <= '9') return 26 + (c - '0');
    switch (c) { case ' ': return 36; case '/': return 37; case ':': return 38;
                 case '!': return 39; case '.': return 40; case '-': return 41;
                 case ',': return GLYPH_COMMA; case '?': return GLYPH_QUEST; }
    return 36;
}
/* decode one UTF-8 codepoint; returns bytes consumed */
static int utf8_next(const char *t, unsigned *cp) {
    unsigned char c = (unsigned char)t[0];
    if (c < 0x80) { *cp = c; return 1; }
    if ((c & 0xE0) == 0xC0 && t[1]) { *cp = ((c & 0x1F) << 6) | (t[1] & 0x3F); return 2; }
    if ((c & 0xF0) == 0xE0 && t[1] && t[2]) { *cp = ((c & 0x0F) << 12) | ((t[1] & 0x3F) << 6) | (t[2] & 0x3F); return 3; }
    *cp = '?'; return 1;
}
/* map a Unicode codepoint to a FONT glyph index (ASCII + Russian, either case) */
static int glyph_cp(unsigned cp) {
    if (cp < 128) return glyph((char)cp);
    if (cp == 0x401 || cp == 0x451) return GLYPH_CYR + 32;           /* Ё / ё */
    if (cp >= 0x410 && cp <= 0x42F) return GLYPH_CYR + (cp - 0x410); /* А..Я  */
    if (cp >= 0x430 && cp <= 0x44F) return GLYPH_CYR + (cp - 0x430); /* а..я  */
    return 36;                                                      /* space */
}
static void draw_glyph(int x, int y, int s, int gi, uint32_t col) {
    const unsigned char *g = FONT[gi];
    for (int row = 0; row < 7; row++)
        for (int cx = 0; cx < 5; cx++)
            if (g[row] & (1 << (4 - cx)))
                for (int py = 0; py < s; py++)
                    for (int px = 0; px < s; px++) {
                        int X = x + cx * s + px, Y = y + row * s + py;
                        if (X >= 0 && X < SCREEN_W && Y >= 0 && Y < SCREEN_H)
                            fb[Y * SCREEN_W + X] = col;
                    }
}
/* number of printable glyphs in a UTF-8 string (for centring) */
static int text_len(const char *t) {
    int n = 0; unsigned cp;
    while (*t) { t += utf8_next(t, &cp); n++; }
    return n;
}
static void draw_text(int x, int y, int s, const char *t, uint32_t col) {
    unsigned cp;
    while (*t) { t += utf8_next(t, &cp); draw_glyph(x, y, s, glyph_cp(cp), col); x += 6 * s; }
}
static void draw_text_c(int y, int s, const char *t, uint32_t col) {
    int w = text_len(t) * 6 * s;
    draw_text((SCREEN_W - w) / 2, y, s, t, col);
}
static void fill_rect(int x, int y, int w, int h, uint32_t c) {
    for (int j = y; j < y + h; j++)
        for (int i = x; i < x + w; i++)
            if (i >= 0 && i < SCREEN_W && j >= 0 && j < SCREEN_H)
                fb[j * SCREEN_W + i] = c;
}

/* --------------------------------------------------- 2D overlay (into fb) */
void ov_clear(void) { memset(fb, 0, sizeof(fb)); }

void draw_hidden_overlay(void) {
    /* look out through a locker's horizontal vents: wide clear bands between
     * thin slats, so you can actually watch the corridor. */
    int cx = SCREEN_W / 2, cy = SCREEN_H / 2;
    for (int y = 0; y < SCREEN_H; y++) {
        int slat = (y % 46) > 34;                         /* thin dark louvre  */
        for (int x = 0; x < SCREEN_W; x++) {
            double dx = (x - cx) / (double)cx, dy = (y - cy) / (double)cy;
            double r = dx * dx + dy * dy;
            int edge = (int)(150 * (r > 0.5 ? (r - 0.5) * 2 : 0)); /* dark frame edges */
            int a = slat ? 236 : (40 + edge);
            if (a > 255) a = 255;
            fb[y * SCREEN_W + x] = packa(0, 0, 0, a);
        }
    }
    draw_text_c(SCREEN_H - 60, 3, "ТЫ СПРЯТАЛСЯ   E - ВЫЙТИ", pack(190, 190, 200));
}
void draw_sanity_fx(void) {
    if (sanity > 0.9) return;
    double dread = 1.0 - sanity;
    /* the tunnel breathes with your pulse and closes further as dread grows */
    double pulse = 0.6 + 0.4 * sin(state_time * (2.0 + dread * 5.0));
    double edge = 0.95 * dread * (0.55 + 0.45 * pulse);
    double inner = 0.62 - 0.30 * dread;                  /* darkness reaches inward */
    int redt = (int)(dread * dread * 80);
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            double dx = (x - SCREEN_W / 2.0) / (SCREEN_W / 2.0);
            double dy = (y - SCREEN_H / 2.0) / (SCREEN_H / 2.0);
            double r = dx * dx + dy * dy; if (r > 1) r = 1;
            double v = (r - inner) / (1.0 - inner);       /* 0 at centre .. 1 at rim */
            if (v <= 0) continue;
            int a = (int)(255 * edge * v * v);
            if (a > 255) a = 255;
            if (a > 0) fb[y * SCREEN_W + x] = packa((int)(redt * v), 0, 0, a);
        }
}
/* flash a hallucination image over the scene as sanity collapses */
void draw_vision(void) {
    if (vision_t <= 0.0 || nvisions == 0) return;
    Vision *v = &visions[vision_idx];
    if (!v->px) return;
    double frac = vision_t / VIS_DUR;                    /* 1 -> 0 over the flash */
    double env = sin(frac * 3.14159265);                 /* arch: 0 -> 1 -> 0     */
    double dread = 1.0 - sanity;
    double gain = env * (0.55 + 0.45 * dread);
    if (((int)(state_time * 42)) & 1) gain *= 0.6;       /* unstable strobe       */
    if (gain <= 0.0) return;
    double sc = fmin((double)SCREEN_W / v->w, (double)SCREEN_H / v->h);
    int dw = (int)(v->w * sc), dh = (int)(v->h * sc);
    if (dw < 1 || dh < 1) return;
    int ox = (SCREEN_W - dw) / 2, oy = (SCREEN_H - dh) / 2;
    for (int y = 0; y < dh; y++) {
        int sy = y * v->h / dh, fy = oy + y;
        if (fy < 0 || fy >= SCREEN_H) continue;
        for (int x = 0; x < dw; x++) {
            int sx = x * v->w / dw, fx = ox + x;
            unsigned char *s = v->px + ((size_t)sy * v->w + sx) * 4;
            double al = (s[3] / 255.0) * gain;
            if (al <= 0.0) continue;
            if (al > 1.0) al = 1.0;
            fb[fy * SCREEN_W + fx] = packa(s[0], s[1], s[2], (int)(al * 255));
        }
    }
}
/* the chest jump-scare: a photo slammed edge-to-edge, jittering, then gone */
void draw_screamer(void) {
    if (screamer_t <= 0.0 || nvisions == 0) return;
    Vision *v = &visions[screamer_idx];
    if (!v->px) return;
    double frac = screamer_t / SCREAMER_DUR;             /* 1 -> 0 over the scare */
    double hold = frac > 0.7 ? 1.0 : frac / 0.7;         /* full-on, then fade    */
    /* violent frame-shake, hardest at the hit and easing off */
    int shx = (int)(((rand() % 21) - 10) * frac * 1.4);
    int shy = (int)(((rand() % 21) - 10) * frac * 1.4);
    /* fill the whole screen (crop, don't letterbox) for maximum dread */
    double sc = fmax((double)SCREEN_W / v->w, (double)SCREEN_H / v->h);
    int dw = (int)(v->w * sc), dh = (int)(v->h * sc);
    int ox = (SCREEN_W - dw) / 2 + shx, oy = (SCREEN_H - dh) / 2 + shy;
    int flash = (((int)(state_time * 50)) & 1);          /* red strobe over it    */
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            int sx = (x - ox) * v->w / dw, sy = (y - oy) * v->h / dh;
            int R, G, B;
            if (sx >= 0 && sx < v->w && sy >= 0 && sy < v->h) {
                unsigned char *s = v->px + ((size_t)sy * v->w + sx) * 4;
                R = s[0]; G = s[1]; B = s[2];
            } else { R = G = B = 0; }
            if (flash) { R = R + (255 - R) / 3; }         /* pulse toward blood    */
            int a = (int)(255 * hold);
            fb[y * SCREEN_W + x] = packa(R, G, B, a > 255 ? 255 : a);
        }
}
/* the parchment panel shown while reading a lore note */
void draw_note(void) {
    for (int i = 0; i < SCREEN_W * SCREEN_H; i++) fb[i] = packa(0, 0, 0, 150);
    int pw = 560, ph = 300, px = (SCREEN_W - pw) / 2, py = (SCREEN_H - ph) / 2;
    fill_rect(px, py, pw, ph, packa(24, 22, 18, 240));
    fill_rect(px, py, pw, 4, packa(90, 80, 60, 255));
    fill_rect(px, py + ph - 4, pw, 4, packa(90, 80, 60, 255));
    draw_text_c(py + 26, 3, "КЛОЧОК БУМАГИ", pack(180, 160, 120));
    const char **lines = NOTES[reading_note];
    int ty = py + 90;
    for (int i = 0; i < 6 && lines[i]; i++) { draw_text_c(ty, 3, lines[i], pack(210, 200, 175)); ty += 34; }
    draw_text_c(py + ph - 34, 2, "E - ПОЛОЖИТЬ ОБРАТНО", pack(130, 120, 100));
}

/* ---------------------------------------------------------- сюжетный режим */
/* Свой, урезанный HUD: без ключей/спичек/камней/рассудка -- в "Отрицании"
 * этого просто нет. Название этапа сверху, и всплывающие субтитры снизу
 * по центру -- и для "вспомнил по пути", и для реплик матери (обе идут
 * через story_subtitle_lines/story_subtitle_a, см. story.c). */
void draw_story_hud(void) {
    char buf[48];
    snprintf(buf, sizeof(buf), "УРОВЕНЬ %d: СЕМЬЯ", story_level);
    draw_text(16, 16, 3, buf, pack(150, 170, 220));
    draw_text(16, 44, 2, "ЭТАП: ОТРИЦАНИЕ", pack(200, 150, 90));

    if (story_subtitle_lines) {
        int a = (int)(255 * story_subtitle_a);
        int ty = SCREEN_H - 190;
        for (int i = 0; i < 4 && story_subtitle_lines[i]; i++) {
            draw_text_c(ty, 3, story_subtitle_lines[i], packa(220, 210, 190, a));
            ty += 34;
        }
    }
}

/* экран "этап пройден" -- заглушка до тех пор, пока не реализован Гнев */
void draw_story_end(void) {
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) fb[y * SCREEN_W + x] = pack(8, 7, 9);
    draw_text_c(200, 5, "ЭТАП: ОТРИЦАНИЕ - ПРОЙДЕН", pack(200, 150, 90));
    draw_text_c(270, 3, "ТЫ ГОВОРИШЬ СЕБЕ, ЧТО ВСЁ В ПОРЯДКЕ.", pack(170, 170, 180));
    draw_text_c(300, 3, "НО ЧТО-ТО ВНУТРИ УЖЕ ТРЕСКАЕТСЯ.", pack(170, 170, 180));
    draw_text_c(360, 2, "ДАЛЬШЕ: ГНЕВ (В РАЗРАБОТКЕ)", pack(120, 120, 140));
    if ((int)(state_time * 2) % 2) draw_text_c(420, 3, "ENTER / ESC - В ГЛАВНОЕ МЕНЮ", pack(220, 220, 220));
}

/* the pause menu: dim the frozen scene and offer sensitivity + volume sliders */
void draw_pause(void) {
    for (int i = 0; i < SCREEN_W * SCREEN_H; i++) fb[i] = packa(0, 0, 0, 170);
    int pw = 540, ph = 330, px = (SCREEN_W - pw) / 2, py = (SCREEN_H - ph) / 2;
    fill_rect(px, py, pw, ph, packa(20, 20, 26, 235));
    fill_rect(px, py, pw, 4, packa(120, 110, 130, 255));
    fill_rect(px, py + ph - 4, pw, 4, packa(120, 110, 130, 255));
    draw_text_c(py + 28, 5, "ПАУЗА", pack(210, 200, 220));

    const char *labels[2] = {"ЧУВСТВИТЕЛЬНОСТЬ", "ГРОМКОСТЬ"};
    double frac[2] = {(sens_mult - 0.3) / (2.5 - 0.3), master_vol / 128.0};
    int bw = 300, bx = px + (pw - bw) / 2;
    for (int r = 0; r < 2; r++) {
        int ry = py + 110 + r * 74;
        int sel = (r == pause_sel);
        uint32_t lc = sel ? pack(255, 235, 150) : pack(150, 150, 165);
        draw_text_c(ry, 3, labels[r], lc);
        int by = ry + 30;
        fill_rect(bx - 2, by - 2, bw + 4, 18 + 4, pack(12, 12, 16));
        fill_rect(bx, by, (int)(bw * frac[r]), 18, sel ? pack(200, 180, 90) : pack(120, 110, 70));
        if (sel) {                                    /* a bright frame marks the active slider */
            fill_rect(bx - 4, by - 4, bw + 8, 2, pack(255, 235, 150));
            fill_rect(bx - 4, by + 20, bw + 8, 2, pack(255, 235, 150));
        }
    }
    /* a way to grab the bug-report log without hunting for the file:
     * copies nightfall_log.txt straight to the clipboard, ready to paste
     * into a GitHub issue. Flashes the result for a couple of seconds. */
    if (log_copy_flash > 0)
        draw_text_c(py + ph - 64, 2,
            log_copy_ok ? "СКОПИРОВАНО В БУФЕР ОБМЕНА" : "НЕ УДАЛОСЬ СКОПИРОВАТЬ ЛОГ",
            log_copy_ok ? pack(140, 220, 150) : pack(220, 130, 110));
    else
        draw_text_c(py + ph - 64, 2, "C - СКОПИРОВАТЬ ЛОГ ДЛЯ БАГ-РЕПОРТА", pack(140, 140, 150));
    draw_text_c(py + ph - 40, 2, "W/S - ВЫБОР   A/D - ИЗМЕНИТЬ", pack(140, 140, 150));
    draw_text_c(py + ph - 20, 2, "ESC - ПРОДОЛЖИТЬ   Q - В МЕНЮ", pack(140, 140, 150));
}

void draw_hud(void) {
    char buf[32];
    snprintf(buf, sizeof(buf), "ЭТАЖ %d", depth);
    draw_text(16, 16, 3, buf, pack(150, 170, 220));
    snprintf(buf, sizeof(buf), "КЛЮЧИ %d/%d", num_keys - keys_left, num_keys);
    draw_text(16, 44, 3, buf, pack(230, 210, 120));
    draw_text(16, 72, 2, BIOMES[biome % NBIOMES].name, pack(120, 120, 140));
    snprintf(buf, sizeof(buf), "СПИЧКИ %d", match_count);
    draw_text(16, 96, 2, buf, match_burn > 0.0 ? pack(255, 170, 80) : pack(150, 138, 108));
    snprintf(buf, sizeof(buf), "КАМНИ %d", rock_count);
    draw_text(16, 116, 2, buf, pack(150, 148, 140));

    /* contextual stair prompts */
    double ed = fabs(posX - exitX) + fabs(posY - exitY);
    if (ed < 1.6) draw_text_c(SCREEN_H - 150, 3,
        keys_left == 0 ? "ДВЕРЬ - ВОЙДИ ЧТОБЫ СПУСТИТЬСЯ" : "ДВЕРЬ ЗАПЕРТА - НАЙДИ КЛЮЧИ", pack(90, 255, 150));

    int bw = 220, bh = 16, bx = 16, by = SCREEN_H - 80;
    fill_rect(bx - 2, by - 2, bw + 4, bh + 4, pack(20, 20, 24));
    int fillw = (int)(bw * stamina);
    uint32_t sc = exhausted ? pack(150, 40, 30) : pack(70 + (int)(120 * (1 - stamina)), 160, 90);
    fill_rect(bx, by, fillw, bh, sc);
    draw_text(bx, by - 22, 2, "СИЛЫ", pack(120, 130, 130));

    int my = by + 26;
    fill_rect(bx - 2, my - 2, bw + 4, bh + 4, pack(20, 20, 24));
    fill_rect(bx, my, (int)(bw * sanity), bh,
              pack(120 + (int)(120 * (1 - sanity)), 60 + (int)(40 * sanity), 130 * sanity + 40));
    draw_text(bx, my + bh + 4, 2, "РАССУДОК", pack(110, 100, 130));

    /* on entering a floor stalked by an unusual horror, warn how it hunts */
    if (reveal_t > 0.0 && !hidden) {
        int a = (int)(255 * (reveal_t > 5.0 ? (6.0 - reveal_t) : (reveal_t < 1.0 ? reveal_t : 1.0)));
        if (a > 255) a = 255;
        if (a < 0) a = 0;
        uint32_t warn = packa(230, 60, 50, a);
        if (mon_type == MON_LISTENER) {
            draw_text_c(120, 3, "ОНО СЛЕПОЕ. НО СЛЫШИТ КАЖДЫЙ ШАГ.", warn);
            draw_text_c(152, 2, "ЗАМРИ, КОГДА ОНО БЛИЗКО", packa(200, 180, 170, a));
        } else if (mon_type == MON_WATCHER) {
            draw_text_c(120, 3, "НЕ ОТВОДИ ОТ НЕГО ВЗГЛЯД.", warn);
            draw_text_c(152, 2, "ОНО ДВИЖЕТСЯ, ПОКА ТЫ НЕ СМОТРИШЬ", packa(200, 180, 170, a));
        }
    }
    if (near_chest >= 0 && !hidden)
        draw_text_c(SCREEN_H - 110, 3, "E - ОТКРЫТЬ СУНДУК", pack(230, 200, 90));
    else if (near_note >= 0 && !hidden)
        draw_text_c(SCREEN_H - 110, 3, "E - ПРОЧИТАТЬ ЗАПИСКУ", pack(200, 190, 160));
    else if (near_locker >= 0 && !hidden)
        draw_text_c(SCREEN_H - 110, 3, "E - СПРЯТАТЬСЯ", pack(200, 200, 160));
    else if (match_count > 0 && match_burn <= 0.0 && !hidden)
        draw_text_c(SCREEN_H - 110, 2, "F - ЗАЖЕЧЬ СПИЧКУ", pack(210, 150, 90));
    else if (rock_count > 0 && rockFlyT <= 0.0 && !hidden)
        draw_text_c(SCREEN_H - 110, 2, "G - БРОСИТЬ КАМЕНЬ", pack(160, 158, 150));

    /* key-sense compass: a golden tick slides along a top strip to point the
     * way to the nearest un-opened chest — brighter the closer you are. Fades
     * out as panic takes hold, so it guides without gutting the dread. */
    if (keys_left > 0 && !hidden) {
        int kb = -1; double kbd = 1e18;
        for (int i = 0; i < num_keys; i++)
            if (keys[i].active) {
                double d2 = (posX - keys[i].x) * (posX - keys[i].x) + (posY - keys[i].y) * (posY - keys[i].y);
                if (d2 < kbd) { kbd = d2; kb = i; }
            }
        if (kb >= 0) {
            double kx = keys[kb].x - posX, ky = keys[kb].y - posY;
            double fwd = kx * cos(yaw) + ky * sin(yaw);
            double rgt = -kx * sin(yaw) + ky * cos(yaw);
            double bearing = atan2(rgt, fwd);            /* 0 = dead ahead, +right */
            double n = bearing / (3.14159265 / 2.0);     /* map ±90° across strip  */
            if (n < -1) n = -1;
            if (n >  1) n =  1;
            double dist = sqrt(kbd);
            double clarity = 0.35 + 0.65 * sanity;        /* mind fogs under dread   */
            int sw = 260, sx = (SCREEN_W - sw) / 2, sy = 30;
            for (int x = 0; x < sw; x++)                  /* faint baseline */
                fb[sy * SCREEN_W + sx + x] = packa(120, 105, 60, (int)(70 * clarity));
            int tx = sx + (int)((0.5 + n * 0.5) * sw);
            int close_by = dist < 4.5;
            uint32_t tc = close_by ? pack(255, 225, 110) : pack(210, 180, 90);
            int ta = (int)((close_by ? 255 : 150) * clarity);
            for (int dyv = -5; dyv <= 5; dyv++)           /* the tick */
                for (int dxv = -2; dxv <= 2; dxv++) {
                    int px = tx + dxv, py = sy + dyv;
                    if (px >= 0 && px < SCREEN_W && py >= 0 && py < SCREEN_H)
                        fb[py * SCREEN_W + px] = packa((tc >> 16) & 255, (tc >> 8) & 255, tc & 255, ta);
                }
            if (close_by) draw_text_c(sy + 14, 2,
                dist < 1.8 ? "СУНДУК ЗДЕСЬ" : "СУНДУК БЛИЗКО", tc);
        }
    }

    if (tension > 0.4) {                                  /* red edge bleed */
        int a = (int)((tension - 0.4) * 150);
        for (int y = 0; y < SCREEN_H; y++)
            for (int x = 0; x < SCREEN_W; x++) {
                double dx = (x - SCREEN_W / 2.0) / (SCREEN_W / 2.0);
                double dy = (y - SCREEN_H / 2.0) / (SCREEN_H / 2.0);
                if (dx * dx + dy * dy > 0.62) {
                    uint32_t c = fb[y * SCREEN_W + x];
                    int ea = (c >> 24) & 255, na = ea > a ? ea : a;
                    fb[y * SCREEN_W + x] = packa(150, 20, 16, na);
                }
            }
        if (tension > 0.75 && ((int)(state_time * 8) % 2)) draw_text_c(90, 3, "ОНО РЯДОМ", pack(255, 40, 30));
    }
}
void draw_title(void) {
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            double v = 6 + 5 * sin(x * 0.01 + state_time) * sin(y * 0.017 - state_time * 0.7);
            fb[y * SCREEN_W + x] = pack((int)v, (int)v, (int)(v + 3));
        }
    uint32_t red = pack(190 + (int)(40 * sin(state_time * 3)), 20, 16);
    draw_text_c(150, 9, "NIGHTFALL", red);
    draw_text_c(270, 3, "ЧТО-ТО В ТЕМНОТЕ ПРОСНУЛОСЬ.", pack(150, 150, 160));
    draw_text_c(305, 3, "СОБЕРИ КЛЮЧИ. НАЙДИ ДВЕРЬ.", pack(120, 120, 130));
    /* выбор режима: W/S переключают title_sel, Enter подтверждает (main.c) */
    uint32_t on = pack(220, 220, 220), off = pack(120, 120, 130);
    draw_text_c(370, 4, title_sel == 0 ? "> БЕСКОНЕЧНЫЙ СПУСК <" : "БЕСКОНЕЧНЫЙ СПУСК",
                title_sel == 0 ? on : off);
    draw_text_c(410, 4, title_sel == 1 ? "> СЮЖЕТ <" : "СЮЖЕТ",
                title_sel == 1 ? on : off);
    if ((int)(state_time * 2) % 2) draw_text_c(452, 3, "НАЖМИ ENTER", pack(220, 220, 220));
    draw_text_c(SCREEN_H - 84, 2, "КЛАВИШИ ПО РАСКЛАДКЕ - ЕСЛИ НЕ РАБОТАЮТ, ВКЛЮЧИ ENG", pack(150, 120, 60));
    draw_text_c(SCREEN_H - 60, 2, "WASD - ХОДИТЬ   МЫШЬ - ОБЗОР   SHIFT - БЕГ   E - ПРЯТАТЬСЯ   ESC - ВЫХОД", pack(90, 90, 100));
}
void draw_jumpscare(void) {
    double t = state_time, shake = (t < 1.2) ? 6 * sin(t * 90) : 0;
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            double nx = (x + shake - SCREEN_W / 2.0) / (SCREEN_H / 2.0);
            double ny = (y - SCREEN_H / 2.0) / (SCREEN_H / 2.0);
            uint32_t c = pack(4, 0, 0);
            double e1 = (nx + 0.42) * (nx + 0.42) + (ny + 0.15) * (ny + 0.15);
            double e2 = (nx - 0.42) * (nx - 0.42) + (ny + 0.15) * (ny + 0.15);
            if (e1 < 0.05 || e2 < 0.05) {
                double p = (e1 < 0.05 ? e1 : e2) / 0.05;
                c = pack((int)(255 * (1 - p * 0.5)), (int)(40 * (1 - p)), (int)(20 * (1 - p)));
                if (e1 < 0.006 || e2 < 0.006) c = pack(10, 0, 0);
            }
            if (ny > 0.28 && ny < 0.52 && fabs(nx) < 0.55) {
                double teeth = fabs(sin(nx * 26));
                if (ny < 0.30 + teeth * 0.16) c = pack(230, 225, 210);
            }
            fb[y * SCREEN_W + x] = c;                     /* opaque: hides 3D */
        }
    if (t > 1.4) {
        char b[48];
        draw_text_c(SCREEN_H / 2 - 52, 6, "ОНО НАШЛО ТЕБЯ", pack(255, 30, 20));
        snprintf(b, sizeof(b), "ТЫ ДОШЁЛ ДО ЭТАЖА %d", depth);
        draw_text_c(SCREEN_H / 2 + 132, 3, b, pack(210, 195, 175));
        snprintf(b, sizeof(b), "РЕКОРД - ЭТАЖ %d", best_depth);
        draw_text_c(SCREEN_H / 2 + 168, 2, b, pack(150, 140, 130));
        draw_text_c(SCREEN_H / 2 + 210, 3, "R - ВЕРНУТЬСЯ", pack(180, 180, 180));
    }
}
