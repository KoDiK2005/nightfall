/*
 * NIGHTFALL — a first-person horror game for Linux (real-3D OpenGL build).
 *
 * The maze is now genuine 3D geometry rendered through an OpenGL 3.3 core
 * pipeline: textured wall/floor/ceiling quads, a perspective camera with
 * free mouse-look (yaw AND pitch), a fragment-shader flashlight + fog, and
 * camera-facing billboards for the Stalker, keys, exit and lockers.
 *
 * All the gameplay — procedural maze, the Stalker's perception AI, stealth,
 * lockers, stamina, sanity/dread and the procedural audio — is shared with
 * the original raycasting build. The HUD, menus and jumpscare are still drawn
 * into a software buffer and composited over the 3D scene as a 2D overlay.
 *
 * Build:  make            (needs SDL2 + SDL2_mixer + OpenGL)
 * Run:    ./nightfall
 * Classic raycaster fallback:  make run-classic
 *
 * Controls:  W/A/S/D move   Mouse look   Shift run   E hide   Esc quit
 */

#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <SDL2/SDL_opengl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ------------------------------------------------------------------ config */
#define SCREEN_W 1024
#define SCREEN_H 576
#define TEX      64

#define MW 29
#define MH 21
#define NUM_KEYS 3
#define NUM_LOCKERS 5
#define NUM_NOTES 2
#define MAX_ROOMS 14

#define PLAYER_WALK 3.1
#define PLAYER_RUN  4.7
#define MONSTER_SPD 2.15
#define CATCH_DIST  0.55
#define PICKUP_DIST 0.55
#define HIDE_DIST   1.0
#define CHECK_DIST  0.8

#define SEE_RANGE   9.0
#define HEAR_WALK   3.0
#define HEAR_RUN    6.5
#define STAM_DRAIN  0.34
#define STAM_REGEN  0.22

#define MOUSE_SENS  0.0022
#define AMBIENT     0.015   /* almost black; all real light comes from torches */
#define FOG_K       0.10
#define MAX_TORCHES 48

/* ------------------------------------------------------------------- state */
enum { ST_TITLE, ST_PLAY, ST_CAUGHT, ST_WIN, ST_READING };

static char   map[MH][MW + 1];
static double posX, posY;               /* position on the floor plane       */
static double yaw = 0.0, pitch = 0.0;   /* look direction                    */
static double monX, monY;
static int    gdist[MH][MW];
static double stamina = 1.0;
static int    exhausted = 0;
static int    hidden = 0;
static double sanity = 1.0;
static int    mon_sees = 0;
static double whisper_timer = 0.0, event_timer = 0.0, surge = 0.0;

enum { AI_HUNT, AI_SEARCH, AI_WANDER };
static int    mon_state = AI_WANDER;
static int    tgtX, tgtY;
static double lastKnownX, lastKnownY;
static double hunt_recalc = 0.0, search_time = 0.0;

typedef struct { double x, y; int active; } Key;
static Key    keys[NUM_KEYS];
static int    keys_left;
static double exitX, exitY;

typedef struct { double x, y; } Locker;
static Locker lockers[NUM_LOCKERS];
static int    near_locker = -1;

typedef struct { double x, y; int active, text; } Note;
static Note   notes[NUM_NOTES];
static int    reading_note = 0;         /* which lore note is on screen       */

static int    depth = 1;                /* current floor (1 = topmost)        */
static double mon_speed = MONSTER_SPD;  /* scales with depth                  */
static double upX, upY;                 /* stairs back up (only when depth>1) */
static int    has_up = 0;

/* the floor is built from themed rectangular rooms joined by corridors,
 * instead of a featureless maze. Each room's theme decides what it holds. */
enum { RM_ENTRANCE, RM_KEY, RM_STORAGE, RM_LIBRARY, RM_HALL, RM_EXIT };
typedef struct { int x, y, w, h, theme; } Room;
static Room   rooms[MAX_ROOMS];
static int    room_count = 0;
static int    startX, startY;           /* player spawn cell (entrance room)  */
#define MAX_PILLARS 24
static int    pcellX[MAX_PILLARS], pcellY[MAX_PILLARS];   /* pillar candidates  */
static int    pillar_count = 0;
static double pedX[NUM_KEYS], pedZ[NUM_KEYS];             /* altar pedestals    */

static int    game_state = ST_TITLE;
static double state_time = 0.0;
static double tension = 0.0, flicker = 1.0;

/* 2D overlay software buffer (ARGB, alpha = coverage over the 3D scene) */
static uint32_t fb[SCREEN_W * SCREEN_H];

/* CPU-side procedural pixels, later uploaded as GL textures */
static uint32_t tex[3][TEX * TEX];         /* 0 wall, 1 floor, 2 ceiling     */
static uint32_t lockmetal[TEX * TEX];      /* opaque steel for locker boxes  */
static uint32_t brackmetal[TEX * TEX];     /* dark iron for torch brackets   */
static uint32_t spr_rgba[7][TEX * TEX];    /* 0 mon,1 key,2 down,3 loc,4 flame,5 note,6 up */

/* torches fixed to walls: warm point lights that flicker */
static float  torchX[MAX_TORCHES], torchZ[MAX_TORCHES];   /* flame world pos  */
static float  torchNx[MAX_TORCHES], torchNz[MAX_TORCHES]; /* into-corridor dir*/
static int    torch_count = 0;
/* torch geometry: a wooden handle mounted on the wall (base) angling up and
 * out into the corridor to a tip, where the burning rag + flame sit.        */
#define TORCH_BASE_Y 0.40f     /* where the handle meets the wall            */
#define TORCH_TIP_Y  0.56f     /* the far, upper end of the handle           */
#define TORCH_REACH  0.26f     /* how far the tip protrudes from the wall    */
#define TORCH_Y      0.66f     /* flame / point-light centre height          */

/* per-locker orientation: unit vector from cell centre toward its backing wall */
static double lockWX[NUM_LOCKERS], lockWY[NUM_LOCKERS];

/* audio */
static Mix_Chunk *snd_ambient, *snd_heart, *snd_scare, *snd_pickup, *snd_step, *snd_whisper;
static double heart_timer = 0.0, step_timer = 0.0;

/* ------------------------------------------------------------- GL functions */
/* Loaded via SDL_GL_GetProcAddress so we depend only on libGL + SDL. */
static PFNGLCREATESHADERPROC            glCreateShader_;
static PFNGLSHADERSOURCEPROC            glShaderSource_;
static PFNGLCOMPILESHADERPROC           glCompileShader_;
static PFNGLGETSHADERIVPROC             glGetShaderiv_;
static PFNGLGETSHADERINFOLOGPROC        glGetShaderInfoLog_;
static PFNGLCREATEPROGRAMPROC           glCreateProgram_;
static PFNGLATTACHSHADERPROC            glAttachShader_;
static PFNGLLINKPROGRAMPROC             glLinkProgram_;
static PFNGLGETPROGRAMIVPROC            glGetProgramiv_;
static PFNGLGETPROGRAMINFOLOGPROC       glGetProgramInfoLog_;
static PFNGLUSEPROGRAMPROC              glUseProgram_;
static PFNGLDELETESHADERPROC            glDeleteShader_;
static PFNGLGENVERTEXARRAYSPROC         glGenVertexArrays_;
static PFNGLBINDVERTEXARRAYPROC         glBindVertexArray_;
static PFNGLGENBUFFERSPROC              glGenBuffers_;
static PFNGLBINDBUFFERPROC              glBindBuffer_;
static PFNGLBUFFERDATAPROC              glBufferData_;
static PFNGLVERTEXATTRIBPOINTERPROC     glVertexAttribPointer_;
static PFNGLENABLEVERTEXATTRIBARRAYPROC glEnableVertexAttribArray_;
static PFNGLGETUNIFORMLOCATIONPROC      glGetUniformLocation_;
static PFNGLUNIFORMMATRIX4FVPROC        glUniformMatrix4fv_;
static PFNGLUNIFORM3FPROC               glUniform3f_;
static PFNGLUNIFORM1FPROC               glUniform1f_;
static PFNGLUNIFORM1IPROC               glUniform1i_;
static PFNGLUNIFORM2FPROC               glUniform2f_;
static PFNGLUNIFORM3FVPROC              glUniform3fv_;
static PFNGLUNIFORM1FVPROC              glUniform1fv_;
static PFNGLACTIVETEXTUREPROC           glActiveTexture_;

static void load_gl(void) {
    glCreateShader_            = (PFNGLCREATESHADERPROC)            SDL_GL_GetProcAddress("glCreateShader");
    glShaderSource_            = (PFNGLSHADERSOURCEPROC)            SDL_GL_GetProcAddress("glShaderSource");
    glCompileShader_          = (PFNGLCOMPILESHADERPROC)           SDL_GL_GetProcAddress("glCompileShader");
    glGetShaderiv_            = (PFNGLGETSHADERIVPROC)             SDL_GL_GetProcAddress("glGetShaderiv");
    glGetShaderInfoLog_      = (PFNGLGETSHADERINFOLOGPROC)        SDL_GL_GetProcAddress("glGetShaderInfoLog");
    glCreateProgram_          = (PFNGLCREATEPROGRAMPROC)           SDL_GL_GetProcAddress("glCreateProgram");
    glAttachShader_           = (PFNGLATTACHSHADERPROC)            SDL_GL_GetProcAddress("glAttachShader");
    glLinkProgram_            = (PFNGLLINKPROGRAMPROC)             SDL_GL_GetProcAddress("glLinkProgram");
    glGetProgramiv_          = (PFNGLGETPROGRAMIVPROC)            SDL_GL_GetProcAddress("glGetProgramiv");
    glGetProgramInfoLog_     = (PFNGLGETPROGRAMINFOLOGPROC)       SDL_GL_GetProcAddress("glGetProgramInfoLog");
    glUseProgram_             = (PFNGLUSEPROGRAMPROC)              SDL_GL_GetProcAddress("glUseProgram");
    glDeleteShader_           = (PFNGLDELETESHADERPROC)            SDL_GL_GetProcAddress("glDeleteShader");
    glGenVertexArrays_        = (PFNGLGENVERTEXARRAYSPROC)         SDL_GL_GetProcAddress("glGenVertexArrays");
    glBindVertexArray_        = (PFNGLBINDVERTEXARRAYPROC)         SDL_GL_GetProcAddress("glBindVertexArray");
    glGenBuffers_             = (PFNGLGENBUFFERSPROC)              SDL_GL_GetProcAddress("glGenBuffers");
    glBindBuffer_             = (PFNGLBINDBUFFERPROC)              SDL_GL_GetProcAddress("glBindBuffer");
    glBufferData_             = (PFNGLBUFFERDATAPROC)              SDL_GL_GetProcAddress("glBufferData");
    glVertexAttribPointer_    = (PFNGLVERTEXATTRIBPOINTERPROC)     SDL_GL_GetProcAddress("glVertexAttribPointer");
    glEnableVertexAttribArray_= (PFNGLENABLEVERTEXATTRIBARRAYPROC) SDL_GL_GetProcAddress("glEnableVertexAttribArray");
    glGetUniformLocation_    = (PFNGLGETUNIFORMLOCATIONPROC)      SDL_GL_GetProcAddress("glGetUniformLocation");
    glUniformMatrix4fv_      = (PFNGLUNIFORMMATRIX4FVPROC)        SDL_GL_GetProcAddress("glUniformMatrix4fv");
    glUniform3f_             = (PFNGLUNIFORM3FPROC)               SDL_GL_GetProcAddress("glUniform3f");
    glUniform1f_             = (PFNGLUNIFORM1FPROC)               SDL_GL_GetProcAddress("glUniform1f");
    glUniform1i_             = (PFNGLUNIFORM1IPROC)               SDL_GL_GetProcAddress("glUniform1i");
    glUniform2f_             = (PFNGLUNIFORM2FPROC)               SDL_GL_GetProcAddress("glUniform2f");
    glUniform3fv_            = (PFNGLUNIFORM3FVPROC)              SDL_GL_GetProcAddress("glUniform3fv");
    glUniform1fv_            = (PFNGLUNIFORM1FVPROC)              SDL_GL_GetProcAddress("glUniform1fv");
    glActiveTexture_          = (PFNGLACTIVETEXTUREPROC)           SDL_GL_GetProcAddress("glActiveTexture");
}

/* --------------------------------------------------------------- utilities */
static inline int clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static inline uint32_t packa(int r, int g, int b, int a) {
    return ((uint32_t)clamp8(a) << 24) | (clamp8(r) << 16) | (clamp8(g) << 8) | clamp8(b);
}
static inline uint32_t pack(int r, int g, int b) { return packa(r, g, b, 255); }
static double frand(void) { return rand() / (double)RAND_MAX; }

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
};
static int glyph(char c) {
    if (c >= 'a' && c <= 'z') c -= 32;
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= '0' && c <= '9') return 26 + (c - '0');
    switch (c) { case ' ': return 36; case '/': return 37; case ':': return 38;
                 case '!': return 39; case '.': return 40; case '-': return 41; }
    return 36;
}
static void draw_char(int x, int y, int s, char c, uint32_t col) {
    const unsigned char *g = FONT[glyph(c)];
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
static void draw_text(int x, int y, int s, const char *t, uint32_t col) {
    for (; *t; t++) { draw_char(x, y, s, *t, col); x += 6 * s; }
}
static void draw_text_c(int y, int s, const char *t, uint32_t col) {
    int w = (int)strlen(t) * 6 * s;
    draw_text((SCREEN_W - w) / 2, y, s, t, col);
}
static void fill_rect(int x, int y, int w, int h, uint32_t c) {
    for (int j = y; j < y + h; j++)
        for (int i = x; i < x + w; i++)
            if (i >= 0 && i < SCREEN_W && j >= 0 && j < SCREEN_H)
                fb[j * SCREEN_W + i] = c;
}

/* ------------------------------------------------------------ texture build */
static void build_textures(void) {
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            int i = y * TEX + x;
            int brick_h = 16, brick_w = 32, row = y / brick_h;
            int ox = (row & 1) ? brick_w / 2 : 0;
            int mortar = ((x + ox) % brick_w < 2) || (y % brick_h < 2);
            int base = 52 + (int)(frand() * 18);
            if (mortar) tex[0][i] = pack(base * 0.30, base * 0.32, base * 0.36);
            else {
                /* cold grey-brown stone; picks up warmth from the torches */
                int r = base * 0.92, g = base * 0.86, b = base * 0.80;
                if (frand() < 0.05) { r -= 16; g -= 16; b -= 14; }   /* dark stains */
                tex[0][i] = pack(r, g, b);
            }
            int f = 30 + (int)(frand() * 14);
            int crack = ((x * 7 + y * 3) % 29 < 2);
            tex[1][i] = crack ? pack(8, 9, 10) : pack(f, f, f + 4);
            int c = 12 + (int)(frand() * 6);
            tex[2][i] = pack(c, c, c + 2);
            /* opaque steel for the locker cabinets */
            int m = 74 + (int)(frand() * 10);
            int seam = (x % 21 < 2);
            int slat = (y > 8 && y < 34 && (y % 6 < 2));
            int handle = (x >= 48 && x <= 54 && y >= 30 && y <= 40);
            int mv = m; if (seam) mv -= 22; if (slat) mv -= 28;
            lockmetal[i] = handle ? pack(180, 168, 120) : pack(mv, mv + 4, mv + 9);
            /* wooden torch handle: warm brown with vertical grain streaks */
            int grain = (int)(6.0 * sin(x * 0.9) + 4.0 * sin(x * 2.7));
            int wb = 48 + grain + (int)(frand() * 6);
            brackmetal[i] = pack(wb, wb * 0.60, wb * 0.32);
        }
}

/* sprite pixels: rgb + alpha where a encodes lighting mode
 *   a = 0   transparent (discarded)
 *   a = 128 shaded by the flashlight
 *   a = 255 self-lit glow                                                    */
static uint8_t spr_flg[7][TEX * TEX];
static void put_spr(int t, int x, int y, uint32_t col, uint8_t flg) {
    if (x < 0 || x >= TEX || y < 0 || y >= TEX) return;
    spr_flg[t][y * TEX + x] = flg;
    spr_rgba[t][y * TEX + x] = col;
}
static void build_sprites(void) {
    memset(spr_flg, 0, sizeof(spr_flg));
    memset(spr_rgba, 0, sizeof(spr_rgba));
    /* 0: THE STALKER — a tall, gaunt, hunched figure with a pale sunken face,
     * spindly reaching arms and burning eyes. Drawn on a tall narrow billboard
     * so it looms in the corridor rather than reading as a post.            */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            double nx = x - 32.0;
            int part = 0;                                  /* 1 = dark flesh, 2 = pale face */
            /* gaunt head/face */
            double hy = y - 11.0, he = (nx * nx) / (5.5 * 5.5) + (hy * hy) / (8.0 * 8.0);
            if (he < 1.0) part = 2;
            /* thin neck */
            if (y >= 17 && y <= 20 && fabs(nx) < 2.3) part = part ? part : 1;
            /* hunched torso, tapering to a narrow waist */
            if (y >= 19 && y <= 47) {
                double tt = (y - 19) / 28.0, hw = 9.5 - tt * 6.0;
                if (fabs(nx) < hw) part = part ? part : 1;
            }
            /* long spindly arms angling outward to clawed hands */
            if (y >= 20 && y <= 55) {
                double ax = 8.0 + (y - 20) * 0.16;
                if (fabs(fabs(nx) - ax) < 2.1) part = part ? part : 1;
                if (y >= 50 && fabs(nx) - ax > -1.5 && fabs(nx) - ax < 4.5 && (x % 2 == 0))
                    part = part ? part : 1;            /* splayed claw fingers */
            }
            /* two thin legs */
            if (y >= 46 && y <= 63 && fabs(fabs(nx) - 3.5) < 2.0) part = part ? part : 1;
            if (part == 1) {
                int v = 6 + (int)(frand() * 7);
                if (frand() < 0.04) v += 22;               /* sickly pale flecks */
                put_spr(0, x, y, pack(v, v, v + 2), 1);
            } else if (part == 2) {
                double edge = fabs(nx) / 5.5;              /* darker sunken cheeks */
                int v = (int)(64 - edge * 42) + (int)(frand() * 6);
                put_spr(0, x, y, pack(v, (int)(v * 0.92), (int)(v * 0.86)), 1);
            }
        }
    /* dark eye sockets + burning eyes, and a gaping mouth */
    for (int y = 6; y <= 22; y++)
        for (int x = 0; x < TEX; x++) {
            double le = (x - 28.0) * (x - 28.0) + (y - 10.0) * (y - 10.0);
            double re = (x - 36.0) * (x - 36.0) + (y - 10.0) * (y - 10.0);
            if (le < 4.0 || re < 4.0) put_spr(0, x, y, pack(255, 55, 25), 2);      /* glow */
            else if (le < 8.0 || re < 8.0) put_spr(0, x, y, pack(90, 8, 6), 1);    /* socket */
            double m = (x - 32.0) * (x - 32.0) / 9.0 + (y - 17.5) * (y - 17.5) / 3.0;
            if (m < 1.0) put_spr(0, x, y, pack(6, 4, 5), 1);                       /* mouth */
        }
    /* 1: KEY */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            double dx = x - 32.0, dy = y - 26.0, r = sqrt(dx * dx + dy * dy);
            if (r < 8) put_spr(1, x, y, pack(255, 210, 30), 2);
            else if (r < 11) put_spr(1, x, y, pack(150, 110, 15), 2);
            if (x >= 30 && x <= 33 && y >= 30 && y <= 46) put_spr(1, x, y, pack(255, 210, 30), 2);
            if (y >= 40 && y <= 46 && x >= 33 && x <= 39 && (y % 4 < 2)) put_spr(1, x, y, pack(255, 210, 30), 2);
        }
    /* 2: EXIT */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            int frame = (x >= 16 && x <= 47 && y >= 6 && y <= 60);
            int edge = frame && (x <= 19 || x >= 44 || y <= 9);
            int inner = (x >= 22 && x <= 41 && y >= 12 && y <= 60);
            if (edge) put_spr(2, x, y, pack(60, 255, 130), 2);
            else if (inner) { int g = 40 + (60 - y) * 2; put_spr(2, x, y, pack(10, g < 0 ? 0 : g, 40), 2); }
        }
    /* 3: LOCKER */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            if (x < 18 || x > 46 || y < 2 || y > 63) continue;
            int body = 70 + (int)(frand() * 12), rust = (frand() < 0.06) ? -30 : 0;
            int door_edge = (x == 18 || x == 46 || y == 2);
            int slat = (y > 8 && y < 40 && (y % 5 < 2));
            int handle = (x >= 41 && x <= 44 && y >= 34 && y <= 42);
            int v = body + rust; if (door_edge) v -= 25; if (slat) v -= 34;
            if (handle) put_spr(3, x, y, pack(180, 170, 120), 1);
            else put_spr(3, x, y, pack(v, v + 4, v + 8), 1);
        }
    /* 4: TORCH FLAME — a licking teardrop tongue for additive blending.
     * rgb IS the emitted light: a white-hot core low & centre, ramping out
     * through yellow and orange to a dim red at the flickering tips. The
     * silhouette narrows to a point at the top with a slight sideways lean
     * so it reads as fire, not a symmetric blob.                          */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            double fy = (54.0 - y) / 46.0;                 /* 0 base .. 1 tip */
            if (fy < 0.0 || fy > 1.0) continue;
            double lean = 3.2 * sin(fy * 2.1);             /* tongue leans/curls */
            double fx = (x - 32.0) - lean;
            double w = 13.0 * pow(1.0 - fy, 0.72);         /* taper to a point  */
            w *= 0.7 + 0.3 * sin(fy * 3.14159);            /* slight mid bulge  */
            if (w < 0.5 || fabs(fx) > w) continue;
            double r = fabs(fx) / w;                       /* 0 centre .. 1 edge */
            double heat = (1.0 - r * r) * (1.0 - 0.65 * fy);
            if (heat < 0.0) heat = 0.0;
            int R = (int)(255 * (0.35 + 0.75 * heat));
            int G = (int)(255 * (0.05 + 0.85 * heat * heat));
            int B = (int)(255 * (0.55 * heat * heat * heat));
            if (R > 255) R = 255;
            if (G > 255) G = 255;
            if (B > 255) B = 255;
            put_spr(4, x, y, pack(R, G, B), 2);
        }
    /* 5: NOTE — a pale glowing sheet of paper with faint writing */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            if (x < 20 || x > 44 || y < 12 || y > 54) continue;
            int edge = (x < 22 || x > 42 || y < 14 || y > 52);
            int line = (x > 24 && x < 40 && ((y - 18) % 6 < 1) && y < 50);
            if (edge) put_spr(5, x, y, pack(150, 140, 110), 2);
            else if (line) put_spr(5, x, y, pack(90, 80, 60), 2);
            else put_spr(5, x, y, pack(210, 200, 170), 2);
        }
    /* 6: STAIRS UP — a cold blue doorway of light (mirror of the exit) */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            int frame = (x >= 16 && x <= 47 && y >= 6 && y <= 60);
            int edge = frame && (x <= 19 || x >= 44 || y <= 9);
            int inner = (x >= 22 && x <= 41 && y >= 12 && y <= 60);
            if (edge) put_spr(6, x, y, pack(90, 170, 255), 2);
            else if (inner) { int b = 40 + (60 - y) * 2; put_spr(6, x, y, pack(30, 60, b < 0 ? 0 : b), 2); }
        }
    /* bake the flag into the alpha byte for the shader */
    for (int t = 0; t < 7; t++)
        for (int i = 0; i < TEX * TEX; i++) {
            int a = spr_flg[t][i] == 0 ? 0 : (spr_flg[t][i] == 1 ? 128 : 255);
            spr_rgba[t][i] = (spr_rgba[t][i] & 0x00FFFFFF) | ((uint32_t)a << 24);
        }
}

/* --------------------------------------------------------------- floor build */
static int is_open(int x, int y) { return x >= 0 && x < MW && y >= 0 && y < MH && map[y][x] != '#'; }

static void room_center(const Room *r, int *cx, int *cy) { *cx = r->x + r->w / 2; *cy = r->y + r->h / 2; }

static void carve_rect(int x0, int y0, int w, int h) {
    for (int y = y0; y < y0 + h; y++)
        for (int x = x0; x < x0 + w; x++)
            if (x > 0 && x < MW - 1 && y > 0 && y < MH - 1) map[y][x] = '.';
}
static void carve_h(int x0, int x1, int y) {
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    for (int x = x0; x <= x1; x++) if (y > 0 && y < MH - 1 && x > 0 && x < MW - 1) map[y][x] = '.';
}
static void carve_v(int y0, int y1, int x) {
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    for (int y = y0; y <= y1; y++) if (x > 0 && x < MW - 1 && y > 0 && y < MH - 1) map[y][x] = '.';
}

/* Build the floor from non-overlapping rectangular rooms joined by L-shaped
 * corridors. Rooms are themed afterwards so each has a purpose. */
static void generate_rooms(void) {
    for (int y = 0; y < MH; y++) { for (int x = 0; x < MW; x++) map[y][x] = '#'; map[y][MW] = 0; }
    room_count = 0;
    int target = 7 + rand() % 4;                         /* 7..10 rooms         */
    for (int att = 0; att < 300 && room_count < target; att++) {
        int w = 4 + rand() % 5, h = 3 + rand() % 4;       /* 4..8 x 3..6        */
        int x = 1 + rand() % (MW - w - 1), y = 1 + rand() % (MH - h - 1);
        int ok = 1;
        for (int i = 0; i < room_count; i++) {            /* keep a 1-cell gap  */
            Room *r = &rooms[i];
            if (x - 1 < r->x + r->w && x + w + 1 > r->x &&
                y - 1 < r->y + r->h && y + h + 1 > r->y) { ok = 0; break; }
        }
        if (!ok) continue;
        rooms[room_count].x = x; rooms[room_count].y = y;
        rooms[room_count].w = w; rooms[room_count].h = h;
        rooms[room_count].theme = RM_HALL;
        room_count++;
        carve_rect(x, y, w, h);
    }
    /* connect each room to the previous one (guarantees full connectivity) */
    for (int i = 1; i < room_count; i++) {
        int ax, ay, bx, by;
        room_center(&rooms[i - 1], &ax, &ay);
        room_center(&rooms[i], &bx, &by);
        if (rand() & 1) { carve_h(ax, bx, ay); carve_v(ay, by, bx); }
        else            { carve_v(ay, by, ax); carve_h(ax, bx, by); }
    }
    /* -------- assign themes -------- */
    rooms[0].theme = RM_ENTRANCE;
    room_center(&rooms[0], &startX, &startY);
    /* exit = room whose centre is farthest from the entrance */
    int best = 0; long bestd = -1;
    for (int i = 1; i < room_count; i++) {
        int cx, cy; room_center(&rooms[i], &cx, &cy);
        long d = (long)(cx - startX) * (cx - startX) + (long)(cy - startY) * (cy - startY);
        if (d > bestd) { bestd = d; best = i; }
    }
    rooms[best].theme = RM_EXIT;
    /* the first few remaining rooms hold keys (shrines); then storage/library */
    int keyrooms = 0;
    for (int i = 1; i < room_count; i++) {
        if (rooms[i].theme != RM_HALL) continue;
        if (keyrooms < NUM_KEYS) { rooms[i].theme = RM_KEY; keyrooms++; }
        else rooms[i].theme = (i & 1) ? RM_STORAGE : RM_LIBRARY;
    }
    /* -------- pillar candidates in the larger halls (columns for cover) ----- */
    pillar_count = 0;
    for (int i = 0; i < room_count && pillar_count < MAX_PILLARS; i++) {
        Room *r = &rooms[i];
        if (r->theme == RM_ENTRANCE || r->theme == RM_EXIT) continue;
        if (r->w >= 6 && r->h >= 5) {                     /* big enough for cover */
            int px[2] = { r->x + 1, r->x + r->w - 2 };
            int py = r->y + r->h / 2;
            for (int k = 0; k < 2 && pillar_count < MAX_PILLARS; k++) {
                pcellX[pillar_count] = px[k]; pcellY[pillar_count] = py; pillar_count++;
            }
        }
    }
}

static void flood_from_cell(int sx, int sy) {
    for (int y = 0; y < MH; y++) for (int x = 0; x < MW; x++) gdist[y][x] = 1 << 20;
    int qx[MW * MH], qy[MW * MH], h = 0, t = 0;
    gdist[sy][sx] = 0; qx[t] = sx; qy[t] = sy; t++;
    int dx[] = {0, 0, -1, 1}, dy[] = {-1, 1, 0, 0};
    while (h < t) {
        int x = qx[h], y = qy[h]; h++;
        for (int k = 0; k < 4; k++) {
            int nx = x + dx[k], ny = y + dy[k];
            if (is_open(nx, ny) && gdist[ny][nx] > gdist[y][x] + 1) {
                gdist[ny][nx] = gdist[y][x] + 1; qx[t] = nx; qy[t] = ny; t++;
            }
        }
    }
}
static void set_target(int cx, int cy) { tgtX = cx; tgtY = cy; flood_from_cell(cx, cy); }
static void pick_wander(void) {
    for (int i = 0; i < 64; i++) {
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (is_open(x, y)) { set_target(x, y); return; }
    }
}
static int has_los(double ax, double ay, double bx, double by) {
    double dx = bx - ax, dy = by - ay, d = sqrt(dx * dx + dy * dy);
    int steps = (int)(d * 8) + 1;
    for (int i = 1; i < steps; i++) {
        double t = (double)i / steps;
        if (!is_open((int)(ax + dx * t), (int)(ay + dy * t))) return 0;
    }
    return 1;
}

/* Lore notes, shown when picked up. Each ends with a NULL line. */
static const char *NOTES[][6] = {
    {"THE TORCHES GUTTER AND DIE", "ON THEIR OWN NOW.", "I RELIGHT THEM.", "IT KNOWS I AM DOWN HERE.", NULL},
    {"THE STAIRS ONLY GO DOWN,", "THEY SAID.", "THEY LIED. THERE IS A WAY UP.", "IF YOU LIVE TO FIND IT.", NULL},
    {"DO NOT RUN.", "IT HEARS EVERYTHING.", "WALK. BREATHE SLOW.", "THE LOCKERS ARE YOUR FRIENDS.", NULL},
    {"THREE KEYS FOR EACH DOOR DOWN.", "WHY DOWN?", "WHAT IS IT KEEPING", "AT THE BOTTOM?", NULL},
    {"I COUNTED FOURTEEN FLOORS", "BEFORE MY LAMP FAILED.", "THE WHISPERING", "NEVER STOPPED.", NULL},
    {"IF YOU READ THIS,", "YOU ARE NOT THE FIRST.", "YOU WILL NOT BE THE LAST.", "IT IS NEVER FULL.", NULL},
};
static const int NOTE_POOL = 6;

/* flood from the entrance; true only if the exit and every key are reachable.
 * Used to reject any decorative pillar that would sever the floor.          */
static int reach_ok(void) {
    flood_from_cell(startX, startY);
    if (gdist[(int)exitY][(int)exitX] >= (1 << 20)) return 0;
    for (int i = 0; i < NUM_KEYS; i++)
        if (gdist[(int)keys[i].y][(int)keys[i].x] >= (1 << 20)) return 0;
    return 1;
}

static void reset_level(void) {
    generate_rooms();
    posX = startX + 0.5; posY = startY + 0.5; yaw = 0; pitch = 0;
    mon_speed = MONSTER_SPD + (depth - 1) * 0.10;
    if (mon_speed > 3.2) mon_speed = 3.2;

    /* stairs down live in the exit room; stairs up in a corner of the entrance */
    for (int i = 0; i < room_count; i++)
        if (rooms[i].theme == RM_EXIT) { int cx, cy; room_center(&rooms[i], &cx, &cy); exitX = cx + 0.5; exitY = cy + 0.5; }
    has_up = (depth > 1);
    int ux = rooms[0].x + 1, uy = rooms[0].y + 1;
    if (ux == startX && uy == startY) ux = rooms[0].x + rooms[0].w - 2;
    upX = ux + 0.5; upY = uy + 0.5;

    /* keys sit on pedestals at the heart of the shrine (RM_KEY) rooms */
    keys_left = NUM_KEYS;
    int ki = 0;
    for (int i = 0; i < room_count && ki < NUM_KEYS; i++) {
        if (rooms[i].theme != RM_KEY) continue;
        int cx, cy; room_center(&rooms[i], &cx, &cy);
        keys[ki].x = cx + 0.5; keys[ki].y = cy + 0.5; keys[ki].active = 1;
        pedX[ki] = cx + 0.5; pedZ[ki] = cy + 0.5; ki++;
    }
    while (ki < NUM_KEYS) {                                /* fallback scatter    */
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (!is_open(x, y) || (abs(x - startX) + abs(y - startY)) < 4) continue;
        keys[ki].x = x + 0.5; keys[ki].y = y + 0.5; keys[ki].active = 1;
        pedX[ki] = x + 0.5; pedZ[ki] = y + 0.5; ki++;
    }

    /* raise the candidate pillars into columns, skipping any that would block
     * a key, the exit, the spawn, or sever the floor's connectivity.        */
    for (int p = 0; p < pillar_count; p++) {
        int px = pcellX[p], py = pcellY[p];
        if (!is_open(px, py) || (px == startX && py == startY)) continue;
        if ((int)exitX == px && (int)exitY == py) continue;
        int skip = 0;
        for (int i = 0; i < NUM_KEYS; i++) if ((int)keys[i].x == px && (int)keys[i].y == py) skip = 1;
        if (skip) continue;
        map[py][px] = '#';
        if (!reach_ok()) map[py][px] = '.';               /* undo: it disconnects */
    }

    /* lockers line the walls of storage rooms (then anywhere, to fill quota) */
    int wdx[4] = {1, -1, 0, 0}, wdy[4] = {0, 0, 1, -1};
    int li = 0;
    for (int pass = 0; pass < 2 && li < NUM_LOCKERS; pass++)
        for (int i = 0; i < room_count && li < NUM_LOCKERS; i++) {
            if (pass == 0 && rooms[i].theme != RM_STORAGE) continue;
            Room *r = &rooms[i];
            for (int yy = r->y; yy < r->y + r->h && li < NUM_LOCKERS; yy++)
                for (int xx = r->x; xx < r->x + r->w && li < NUM_LOCKERS; xx++) {
                    if (!is_open(xx, yy) || abs(xx - startX) + abs(yy - startY) < 3) continue;
                    int wx = 0, wy = 0, found = 0;
                    for (int k = 0; k < 4; k++)
                        if (!is_open(xx + wdx[k], yy + wdy[k])) { wx = wdx[k]; wy = wdy[k]; found = 1; break; }
                    if (!found) continue;
                    int ok = 1;
                    for (int j = 0; j < li; j++)
                        if (fabs(lockers[j].x - (xx + 0.5)) + fabs(lockers[j].y - (yy + 0.5)) < 2) ok = 0;
                    for (int j = 0; j < NUM_KEYS; j++)
                        if (fabs(keys[j].x - (xx + 0.5)) + fabs(keys[j].y - (yy + 0.5)) < 1.5) ok = 0;
                    if (!ok) continue;
                    lockers[li].x = xx + 0.5; lockers[li].y = yy + 0.5;
                    lockWX[li] = wx; lockWY[li] = wy; li++;
                }
        }

    /* lore notes rest in the library rooms (then anywhere) */
    int ni = 0;
    for (int pass = 0; pass < 2 && ni < NUM_NOTES; pass++)
        for (int i = 0; i < room_count && ni < NUM_NOTES; i++) {
            if (pass == 0 && rooms[i].theme != RM_LIBRARY) continue;
            int cx, cy; room_center(&rooms[i], &cx, &cy);
            if (!is_open(cx, cy) || abs(cx - startX) + abs(cy - startY) < 3) continue;
            int dup = 0;
            for (int j = 0; j < ni; j++) if (fabs(notes[j].x - (cx + 0.5)) < 0.1 && fabs(notes[j].y - (cy + 0.5)) < 0.1) dup = 1;
            if (dup) continue;
            notes[ni].x = cx + 0.5; notes[ni].y = cy + 0.5; notes[ni].active = 1;
            notes[ni].text = rand() % NOTE_POOL; ni++;
        }
    while (ni < NUM_NOTES) {
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (!is_open(x, y)) continue;
        notes[ni].x = x + 0.5; notes[ni].y = y + 0.5; notes[ni].active = 1;
        notes[ni].text = rand() % NOTE_POOL; ni++;
    }

    /* the Stalker starts as far from the entrance as the floor allows */
    { int bx = startX, by = startY; long bd = -1;
      for (int y = 1; y < MH - 1; y++)
          for (int x = 1; x < MW - 1; x++)
              if (is_open(x, y)) {
                  long d = (long)(x - startX) * (x - startX) + (long)(y - startY) * (y - startY);
                  if (d > bd) { bd = d; bx = x; by = y; }
              }
      monX = bx + 0.5; monY = by + 0.5; }

    tension = 0; flicker = 1;
    heart_timer = step_timer = 0;
    stamina = 1.0; exhausted = 0; hidden = 0; near_locker = -1;
    sanity = 1.0; mon_sees = 0; surge = 0;
    whisper_timer = 8.0; event_timer = 14.0;
    mon_state = AI_WANDER; lastKnownX = posX; lastKnownY = posY;
    hunt_recalc = search_time = 0;
    pick_wander();
}

/* ------------------------------------------------------------------ physics */
static void try_move(double nx, double ny, double r) {
    if (is_open((int)(nx + (nx > posX ? r : -r)), (int)posY)) posX = nx;
    if (is_open((int)posX, (int)(ny + (ny > posY ? r : -r)))) posY = ny;
}
static void update_monster(double dt) {
    int cx = (int)monX, cy = (int)monY, best = gdist[cy][cx], bx = cx, by = cy;
    int dx[] = {0, 0, -1, 1}, dy[] = {-1, 1, 0, 0};
    for (int k = 0; k < 4; k++) {
        int nx = cx + dx[k], ny = cy + dy[k];
        if (is_open(nx, ny) && gdist[ny][nx] < best) { best = gdist[ny][nx]; bx = nx; by = ny; }
    }
    double tx = bx + 0.5, ty = by + 0.5, vx = tx - monX, vy = ty - monY;
    double len = sqrt(vx * vx + vy * vy);
    if (len > 1e-4) { double step = mon_speed * dt; if (step > len) step = len;
        monX += vx / len * step; monY += vy / len * step; }
}
static void update_ai(double dt, int moving, int sprinting) {
    double d = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
    int sensed = 0; mon_sees = 0;
    if (!hidden) {
        if (d < SEE_RANGE && has_los(monX, monY, posX, posY)) { sensed = 1; mon_sees = 1; }
        else if (moving && d < HEAR_WALK) sensed = 1;
        else if (sprinting && moving && d < HEAR_RUN) sensed = 1;
    }
    if (sensed) {
        mon_state = AI_HUNT; lastKnownX = posX; lastKnownY = posY;
        hunt_recalc -= dt;
        if (hunt_recalc <= 0 || tgtX != (int)posX || tgtY != (int)posY) {
            set_target((int)posX, (int)posY); hunt_recalc = 0.2;
        }
    } else {
        if (mon_state == AI_HUNT) {
            mon_state = AI_SEARCH; search_time = 8.0;
            int tx = (int)lastKnownX, ty = (int)lastKnownY; double bestd = 3.0;
            for (int i = 0; i < NUM_LOCKERS; i++) {
                double ld = fabs(lockers[i].x - lastKnownX) + fabs(lockers[i].y - lastKnownY);
                if (ld < bestd) { bestd = ld; tx = (int)lockers[i].x; ty = (int)lockers[i].y; }
            }
            set_target(tx, ty);
        }
        if (mon_state == AI_SEARCH) {
            search_time -= dt;
            if (((int)monX == tgtX && (int)monY == tgtY) || search_time <= 0) { mon_state = AI_WANDER; pick_wander(); }
        } else if (mon_state == AI_WANDER) {
            if ((int)monX == tgtX && (int)monY == tgtY) pick_wander();
        }
    }
    update_monster(dt);
}

/* ------------------------------------------------------------------- audio */
static void update_audio(double dt, int moving) {
    double d = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
    double target = d < 9 ? (1.0 - d / 9.0) : 0.0;
    tension += (target - tension) * fmin(1.0, dt * 3);
    Mix_Volume(0, (int)(50 + 60 * tension));
    if (game_state == ST_PLAY && tension > 0.1) {
        double bpm = 55 + tension * 115;
        heart_timer -= dt;
        if (heart_timer <= 0) {
            Mix_VolumeChunk(snd_heart, (int)(30 + 98 * tension));
            Mix_PlayChannel(1, snd_heart, 0); heart_timer = 60.0 / bpm;
        }
    }
    if (moving && game_state == ST_PLAY) {
        step_timer -= dt;
        if (step_timer <= 0) { Mix_VolumeChunk(snd_step, 60); Mix_PlayChannel(2, snd_step, 0); step_timer = 0.42; }
    }
}
static void update_fear(double dt) {
    double drain = 0.004 + tension * 0.05 + (mon_state == AI_HUNT ? 0.03 : 0.0) + (mon_sees ? 0.10 : 0.0);
    if (tension < 0.12 && mon_state != AI_HUNT) sanity += dt * 0.02;
    sanity -= dt * drain;
    if (sanity < 0) sanity = 0;
    if (sanity > 1) sanity = 1;
    double dread = 1.0 - sanity;
    whisper_timer -= dt;
    if (whisper_timer <= 0) {
        if (snd_whisper) { Mix_VolumeChunk(snd_whisper, (int)(25 + 80 * dread + 20 * tension));
            Mix_PlayChannel(5, snd_whisper, 0); }
        whisper_timer = 3.0 + sanity * 16.0 - tension * 4.0 + frand() * 4.0;
        if (whisper_timer < 2.0) whisper_timer = 2.0;
    }
    if (surge > 0) surge -= dt;
    event_timer -= dt;
    if (event_timer <= 0) {
        surge = 0.35 + frand() * 0.5;
        event_timer = 6.0 + sanity * 18.0 - tension * 5.0 + frand() * 6.0;
        if (event_timer < 3.0) event_timer = 3.0;
    }
}

/* ================================================================ 3D layer */
/* Small column-major 4x4 matrix maths (OpenGL convention). */
static void mat_mul(float *o, const float *a, const float *b) {
    float r[16];
    for (int c = 0; c < 4; c++)
        for (int rI = 0; rI < 4; rI++) {
            float s = 0;
            for (int k = 0; k < 4; k++) s += a[k * 4 + rI] * b[c * 4 + k];
            r[c * 4 + rI] = s;
        }
    memcpy(o, r, sizeof(r));
}
static void mat_perspective(float *m, float fovy, float aspect, float zn, float zf) {
    float f = 1.0f / tanf(fovy * 0.5f);
    memset(m, 0, 16 * sizeof(float));
    m[0] = f / aspect; m[5] = f;
    m[10] = (zf + zn) / (zn - zf); m[11] = -1;
    m[14] = (2 * zf * zn) / (zn - zf);
}
static void mat_lookat(float *m, float ex, float ey, float ez,
                       float cx, float cy, float cz, float ux, float uy, float uz) {
    float fx = cx - ex, fy = cy - ey, fz = cz - ez;
    float fl = sqrtf(fx * fx + fy * fy + fz * fz); fx /= fl; fy /= fl; fz /= fl;
    float sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
    float sl = sqrtf(sx * sx + sy * sy + sz * sz); sx /= sl; sy /= sl; sz /= sl;
    float ux2 = sy * fz - sz * fy, uy2 = sz * fx - sx * fz, uz2 = sx * fy - sy * fx;
    m[0] = sx;  m[4] = sy;  m[8]  = sz;  m[12] = -(sx * ex + sy * ey + sz * ez);
    m[1] = ux2; m[5] = uy2; m[9]  = uz2; m[13] = -(ux2 * ex + uy2 * ey + uz2 * ez);
    m[2] = -fx; m[6] = -fy; m[10] = -fz; m[14] =  (fx * ex + fy * ey + fz * ez);
    m[3] = 0;   m[7] = 0;   m[11] = 0;   m[15] = 1;
}

static const char *VSRC =
    "#version 330 core\n"
    "layout(location=0) in vec3 aPos;\n"
    "layout(location=1) in vec2 aUV;\n"
    "layout(location=2) in vec3 aN;\n"
    "uniform mat4 uMVP;\n"
    "out vec3 vW; out vec2 vUV; out vec3 vN;\n"
    "void main(){ vW=aPos; vUV=aUV; vN=aN; gl_Position=uMVP*vec4(aPos,1.0); }\n";
static const char *FSRC =
    "#version 330 core\n"
    "in vec3 vW; in vec2 vUV; in vec3 vN;\n"
    "uniform sampler2D uTex;\n"
    "uniform vec3 uCamPos; uniform vec3 uCamDir;\n"
    "uniform float uAmbient; uniform float uFogK; uniform float uFlicker;\n"
    "uniform vec3 uAmbTint; uniform vec2 uScreenSize;\n"
    "uniform int uMode;\n"                 /* 0 world, 1 sprite */
    "#define MAXT 48\n"
    "uniform int uTorchCount;\n"
    "uniform vec3 uTorchPos[MAXT];\n"
    "uniform float uTorchInt[MAXT];\n"
    "uniform vec3 uTorchCol;\n"
    "uniform sampler2D uMap;\n"            /* MWxMH wall grid (r>0.5 = wall) */
    "uniform vec2 uMapSize;\n"
    "uniform int uOccl;\n"                 /* 1 = shadow torches behind walls */
    "out vec4 frag;\n"
    /* march the floor-plane segment from the fragment to a torch; if it
     * crosses a wall cell the torch is occluded (no light-through-walls).
     * uMap is sampled with hardware bilinear filtering (not texelFetch),
     * so each map cell blends smoothly into its neighbours over the last
     * half-texel -- a single ray already reads a soft 0..1 value right at
     * a cell boundary instead of a hard yes/no, with no extra ray taps
     * (cheap, and immune to the corner light-leak a perpendicular offset
     * hack would risk).                                                  */
    "float occlusion(vec2 p, vec2 q){\n"
    "  vec2 d = q - p; float len = length(d);\n"
    "  int steps = int(len / 0.25) + 1; if(steps > 40) steps = 40;\n"
    "  float occ = 0.0;\n"
    "  for(int s = 1; s < steps; s++){\n"
    "    vec2 c = p + d * (float(s)/float(steps));\n"
    "    occ = max(occ, texture(uMap, c / uMapSize).r);\n"
    "    if(occ > 0.98) break;\n"
    "  }\n"
    "  return occ;\n"
    "}\n"
    "void main(){\n"
    "  vec4 t = texture(uTex, vUV);\n"
    "  float emissive = 0.0;\n"
    "  if(uMode==1){ if(t.a < 0.25) discard; emissive = step(0.75, t.a); }\n"
    "  vec3 nrm = normalize(vN);\n"
    "  float dist = length(vW - uCamPos);\n"
    "  float fog = 1.0 / (1.0 + dist*dist*uFogK);\n"
    /* cool moonlight ambient so geometry is faintly readable in the dark, */
    /* plus warm torch point lights that carry the real illumination.      */
    "  vec3 lit = uAmbTint;\n"
    "  for(int i=0;i<uTorchCount;i++){\n"
    "    vec3 L = uTorchPos[i] - vW; float td = length(L);\n"
    "    float att = uTorchInt[i] / (1.0 + 0.35*td + 0.55*td*td);\n"
    "    if(att < 0.02) continue;\n"                 /* too dim to bother     */
    "    float lxz = length(L.xz);\n"
    /* nudge the ray start toward the torch AND off the surface along its
     * normal, so the march doesn't begin sitting exactly on a wall cell's
     * own boundary -- that grazing case is what caused shadow acne right
     * at corners where two walls meet.                                   */
    "    vec2 start = vW.xz + (lxz > 1e-3 ? L.xz/lxz : vec2(0.0)) * 0.06 + nrm.xz * 0.05;\n"
    "    float vis = 1.0;\n"
    "    if(uMode==0 && uOccl==1) vis = 1.0 - occlusion(start, uTorchPos[i].xz);\n"
    "    if(vis <= 0.0) continue;\n"                    /* fully in shadow       */
    "    float facing = (uMode==0) ? (0.35 + 0.65*max(dot(nrm, L/max(td,1e-3)), 0.0)) : 1.0;\n"
    "    lit += uTorchCol * att * facing * vis;\n"
    "  }\n"
    "  vec3 col = t.rgb * lit;\n"
    "  col = mix(col, t.rgb * (0.55 + 0.45*fog), emissive);\n"  /* glow ignores lighting */
    /* soft screen-space vignette: darkens the corners for a claustrophobic frame */
    "  vec2 vc = (gl_FragCoord.xy / uScreenSize) - 0.5;\n"
    "  float vig = 1.0 - 0.55 * smoothstep(0.25, 0.75, dot(vc, vc) * 2.0);\n"
    "  col *= vig;\n"
    "  frag = vec4(col, 1.0);\n"
    "}\n";
static const char *OVS =
    "#version 330 core\n"
    "layout(location=0) in vec2 aPos; layout(location=1) in vec2 aUV;\n"
    "out vec2 vUV; void main(){ vUV=aUV; gl_Position=vec4(aPos,0.0,1.0); }\n";
static const char *OFS =
    "#version 330 core\n"
    "in vec2 vUV; uniform sampler2D uTex; out vec4 frag;\n"
    "void main(){ frag = texture(uTex, vUV); }\n";

static GLuint prog3d, progOv;
static GLint u_mvp, u_campos, u_camdir, u_amb, u_fogk, u_flick, u_mode;
static GLint u_ambtint, u_scrsize;
static GLint u_tcount, u_tpos, u_tint, u_tcol, u_tex, u_map, u_mapsize, u_occl;
static int   occl_on = 1;
static int   winW = SCREEN_W, winH = SCREEN_H;   /* actual drawable size (resize/fullscreen) */
static GLuint worldVAO, worldVBO, sprVAO, sprVBO, ovVAO, ovVBO;
static GLuint texWall, texFloor, texCeil, texLocker, texBracket, texSpr[7], texOverlay, texMap;
static int   floorStart, floorCount, ceilStart, ceilCount, wallCount;
static int   lockStart, lockCount, brkStart, brkCount;

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader_(type);
    glShaderSource_(s, 1, &src, NULL);
    glCompileShader_(s);
    GLint ok = 0; glGetShaderiv_(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog_(s, 1024, NULL, log);
        fprintf(stderr, "shader compile error: %s\n", log); }
    return s;
}
static GLuint link_prog(const char *vs, const char *fs) {
    GLuint p = glCreateProgram_();
    GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
    glAttachShader_(p, v); glAttachShader_(p, f); glLinkProgram_(p);
    GLint ok = 0; glGetProgramiv_(p, GL_LINK_STATUS, &ok);
    if (!ok) { char log[1024]; glGetProgramInfoLog_(p, 1024, NULL, log);
        fprintf(stderr, "program link error: %s\n", log); }
    glDeleteShader_(v); glDeleteShader_(f);
    return p;
}
static GLuint make_texture(const uint32_t *pixels) {
    GLuint id; glGenTextures(1, &id); glBindTexture(GL_TEXTURE_2D, id);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, TEX, TEX, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixels);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    return id;
}

/* one vertex = pos(3) uv(2) normal(3) */
static void push_v(float *buf, int *n, float x, float y, float z,
                   float u, float v, float nx, float ny, float nz) {
    float *p = buf + (*n) * 8;
    p[0] = x; p[1] = y; p[2] = z; p[3] = u; p[4] = v; p[5] = nx; p[6] = ny; p[7] = nz;
    (*n)++;
}
static void push_quad(float *buf, int *n, float a[3], float b[3], float c[3], float d[3],
                      float nx, float ny, float nz, float tile) {
    push_v(buf, n, a[0], a[1], a[2], 0, tile, nx, ny, nz);
    push_v(buf, n, b[0], b[1], b[2], tile, tile, nx, ny, nz);
    push_v(buf, n, c[0], c[1], c[2], tile, 0, nx, ny, nz);
    push_v(buf, n, a[0], a[1], a[2], 0, tile, nx, ny, nz);
    push_v(buf, n, c[0], c[1], c[2], tile, 0, nx, ny, nz);
    push_v(buf, n, d[0], d[1], d[2], 0, 0, nx, ny, nz);
}

/* A box whose back sits at (bx,bz) and which extends 'depth' into the corridor
 * along (dix,diz); front/left/right/top faces are emitted (back+bottom hidden). */
static void add_box(float *buf, int *n, double bx, double bz, double dix, double diz,
                    double hw, double depth, double y0, double y1) {
    double tdx = -diz, tdz = dix;                              /* wall tangent */
    double fx = bx + dix * depth, fz = bz + diz * depth;       /* front centre */
    float FL[3]={fx+tdx*hw,y0,fz+tdz*hw}, FR[3]={fx-tdx*hw,y0,fz-tdz*hw};
    float BL[3]={bx+tdx*hw,y0,bz+tdz*hw}, BR[3]={bx-tdx*hw,y0,bz-tdz*hw};
    float FLt[3]={FL[0],y1,FL[2]}, FRt[3]={FR[0],y1,FR[2]};
    float BLt[3]={BL[0],y1,BL[2]}, BRt[3]={BR[0],y1,BR[2]};
    push_quad(buf, n, FL, FR, FRt, FLt, dix, 0, diz, 1);       /* front        */
    push_quad(buf, n, BL, FL, FLt, BLt, tdx, 0, tdz, 1);       /* left         */
    push_quad(buf, n, FR, BR, BRt, FRt, -tdx, 0, -tdz, 1);     /* right        */
    push_quad(buf, n, FLt, FRt, BRt, BLt, 0, 1, 0, 1);         /* top          */
}
/* locker: back against the wall (wdir points from cell centre to the wall)   */
static void add_locker_box(float *buf, int *n, double cx, double cz, double wdx, double wdz) {
    add_box(buf, n, cx + wdx * 0.46, cz + wdz * 0.46, -wdx, -wdz, 0.30, 0.34, 0.0, 0.92);
}
/* a thin square-section beam between two arbitrary world points (radius hw).
 * Used for the angled wooden torch handle; four side faces + an end cap. */
static void add_beam(float *buf, int *n, float x0, float y0, float z0,
                     float x1, float y1, float z1, float hw) {
    float dx = x1 - x0, dy = y1 - y0, dz = z1 - z0;
    float len = sqrtf(dx * dx + dy * dy + dz * dz); if (len < 1e-4f) return;
    dx /= len; dy /= len; dz /= len;
    /* two unit perpendiculars to the axis */
    float rx, ry, rz;
    if (fabsf(dy) < 0.9f) { rx = dz; ry = 0.0f; rz = -dx; }   /* cross(d, up) */
    else                  { rx = 1.0f; ry = 0.0f; rz = 0.0f; }
    float rl = sqrtf(rx * rx + ry * ry + rz * rz); rx /= rl; ry /= rl; rz /= rl;
    float sx = dy * rz - dz * ry, sy = dz * rx - dx * rz, sz = dx * ry - dy * rx;
    float g1[4] = {1, -1, -1, 1}, g2[4] = {1, 1, -1, -1};
    float base[4][3], tip[4][3];
    for (int c = 0; c < 4; c++) {
        float ox = rx * hw * g1[c] + sx * hw * g2[c];
        float oy = ry * hw * g1[c] + sy * hw * g2[c];
        float oz = rz * hw * g1[c] + sz * hw * g2[c];
        base[c][0] = x0 + ox; base[c][1] = y0 + oy; base[c][2] = z0 + oz;
        tip[c][0]  = x1 + ox; tip[c][1]  = y1 + oy; tip[c][2]  = z1 + oz;
    }
    for (int c = 0; c < 4; c++) {
        int d2 = (c + 1) & 3;
        float nxv = (base[c][0] - x0) + (base[d2][0] - x0);
        float nyv = (base[c][1] - y0) + (base[d2][1] - y0);
        float nzv = (base[c][2] - z0) + (base[d2][2] - z0);
        push_quad(buf, n, base[c], base[d2], tip[d2], tip[c], nxv, nyv, nzv, 1);
    }
    push_quad(buf, n, tip[0], tip[1], tip[2], tip[3], dx, dy, dz, 1);   /* end cap */
}

/* a freestanding centred box (4 sides + top): altar pedestals, plinths */
static void add_prop_box(float *buf, int *n, double cx, double cz, double hw, double y0, double y1) {
    float x0 = cx - hw, x1 = cx + hw, z0 = cz - hw, z1 = cz + hw;
    float A[3]={x0,y0,z0}, B[3]={x1,y0,z0}, C[3]={x1,y0,z1}, D[3]={x0,y0,z1};
    float At[3]={x0,y1,z0}, Bt[3]={x1,y1,z0}, Ct[3]={x1,y1,z1}, Dt[3]={x0,y1,z1};
    push_quad(buf, n, A, B, Bt, At, 0, 0, -1, 1);
    push_quad(buf, n, B, C, Ct, Bt, 1, 0, 0, 1);
    push_quad(buf, n, C, D, Dt, Ct, 0, 0, 1, 1);
    push_quad(buf, n, D, A, At, Dt, -1, 0, 0, 1);
    push_quad(buf, n, At, Bt, Ct, Dt, 0, 1, 0, 1);
}

/* a wooden wall torch: a handle angling up into the corridor with a fatter
 * wrapped rag bundle at the tip (where the flame billboard is drawn).      */
static void add_torch(float *buf, int *n, double tx, double tz, double dix, double diz) {
    float bx = (float)tx, bz = (float)tz;                              /* on the wall */
    float ttx = (float)(tx + dix * TORCH_REACH);
    float ttz = (float)(tz + diz * TORCH_REACH);
    add_beam(buf, n, bx, TORCH_BASE_Y, bz, ttx, TORCH_TIP_Y, ttz, 0.032f);   /* handle */
    /* the rag bundle: a short, fatter segment at the tip                          */
    add_beam(buf, n, ttx, TORCH_TIP_Y, ttz,
             (float)(tx + dix * (TORCH_REACH + 0.03)), TORCH_TIP_Y + 0.05f,
             (float)(tz + diz * (TORCH_REACH + 0.03)), 0.055f);
}

/* Evenly scatter wall torches (Poisson-disc): shuffle every wall-adjacent
 * cell, then place a torch only where none is already within TORCH_SPACING.
 * Trying every candidate guarantees full coverage (no cell is more than
 * TORCH_SPACING from a torch) while the spacing rule prevents clustering. */
#define TORCH_SPACING 2.6f
static void place_torches(void) {
    torch_count = 0;
    int dx[] = {1, -1, 0, 0}, dy[] = {0, 0, 1, -1};
    /* gather wall-adjacent open cells */
    int cx[MW * MH], cy[MW * MH], nc = 0;
    for (int y = 1; y < MH - 1; y++)
        for (int x = 1; x < MW - 1; x++) {
            if (!is_open(x, y)) continue;
            for (int k = 0; k < 4; k++)
                if (!is_open(x + dx[k], y + dy[k])) { cx[nc] = x; cy[nc] = y; nc++; break; }
        }
    /* shuffle so placement isn't biased to one corner */
    for (int i = nc - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        int tx = cx[i]; cx[i] = cx[j]; cx[j] = tx;
        int ty = cy[i]; cy[i] = cy[j]; cy[j] = ty;
    }
    float sp2 = TORCH_SPACING * TORCH_SPACING;
    for (int i = 0; i < nc && torch_count < MAX_TORCHES; i++) {
        int x = cx[i], y = cy[i];
        float ccx = x + 0.5f, ccz = y + 0.5f;
        int ok = 1;
        for (int j = 0; j < torch_count; j++) {
            float ddx = ccx - (torchX[j] + torchNx[j] * 0.48f);   /* torch cell centre */
            float ddz = ccz - (torchZ[j] + torchNz[j] * 0.48f);
            if (ddx * ddx + ddz * ddz < sp2) { ok = 0; break; }
        }
        if (!ok) continue;
        for (int k = 0; k < 4; k++) {                              /* pick a wall face */
            if (is_open(x + dx[k], y + dy[k])) continue;
            torchX[torch_count] = ccx + dx[k] * 0.48f;
            torchZ[torch_count] = ccz + dy[k] * 0.48f;
            torchNx[torch_count] = -dx[k]; torchNz[torch_count] = -dy[k];
            torch_count++;
            break;
        }
    }
}

/* Rebuild the world mesh for the current maze (walls, floor, ceiling, lockers). */
static void build_world_mesh(void) {
    static float buf[(MW * MH * 36 + NUM_LOCKERS * 24 + NUM_KEYS * 32 + MAX_TORCHES * 72 + 64) * 8];
    int n = 0;
    place_torches();
    /* walls: a face for every wall cell that borders an open cell */
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++) {
            if (is_open(x, y)) continue;
            /* +x neighbour open -> face on x+1 side facing -x, etc. World: (x, y_up, z=map y) */
            if (is_open(x + 1, y)) { float a[3]={x+1,0,y}, b[3]={x+1,0,y+1}, c[3]={x+1,1,y+1}, d[3]={x+1,1,y}; push_quad(buf,&n,a,b,c,d,-1,0,0,1); }
            if (is_open(x - 1, y)) { float a[3]={x,0,y+1}, b[3]={x,0,y}, c[3]={x,1,y}, d[3]={x,1,y+1}; push_quad(buf,&n,a,b,c,d, 1,0,0,1); }
            if (is_open(x, y + 1)) { float a[3]={x+1,0,y+1}, b[3]={x,0,y+1}, c[3]={x,1,y+1}, d[3]={x+1,1,y+1}; push_quad(buf,&n,a,b,c,d,0,0,-1,1); }
            if (is_open(x, y - 1)) { float a[3]={x,0,y}, b[3]={x+1,0,y}, c[3]={x+1,1,y}, d[3]={x,1,y}; push_quad(buf,&n,a,b,c,d,0,0,1,1); }
        }
    wallCount = n;
    /* floor */
    floorStart = n;
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++)
            if (is_open(x, y)) { float a[3]={x,0,y}, b[3]={x+1,0,y}, c[3]={x+1,0,y+1}, d[3]={x,0,y+1}; push_quad(buf,&n,a,b,c,d,0,1,0,1); }
    floorCount = n - floorStart;
    /* ceiling */
    ceilStart = n;
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++)
            if (is_open(x, y)) { float a[3]={x,1,y+1}, b[3]={x+1,1,y+1}, c[3]={x+1,1,y}, d[3]={x,1,y}; push_quad(buf,&n,a,b,c,d,0,-1,0,1); }
    ceilCount = n - ceilStart;
    /* locker cabinets + altar pedestals (both steel) */
    lockStart = n;
    for (int i = 0; i < NUM_LOCKERS; i++)
        add_locker_box(buf, &n, lockers[i].x, lockers[i].y, lockWX[i], lockWY[i]);
    for (int i = 0; i < NUM_KEYS; i++)
        add_prop_box(buf, &n, pedX[i], pedZ[i], 0.17, 0.0, 0.30);   /* shrine plinth */
    lockCount = n - lockStart;
    /* wooden torch handles */
    brkStart = n;
    for (int i = 0; i < torch_count; i++)
        add_torch(buf, &n, torchX[i], torchZ[i], torchNx[i], torchNz[i]);
    brkCount = n - brkStart;

    glBindVertexArray_(worldVAO);
    glBindBuffer_(GL_ARRAY_BUFFER, worldVBO);
    glBufferData_(GL_ARRAY_BUFFER, n * 8 * sizeof(float), buf, GL_STATIC_DRAW);
}

/* upload the current maze walls into the R8 occlusion map texture */
static void upload_map(void) {
    static unsigned char bytes[MW * MH];
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++)
            bytes[y * MW + x] = is_open(x, y) ? 0 : 255;
    glActiveTexture_(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, texMap);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);         /* rows aren't 4-byte aligned */
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, MW, MH, 0, GL_RED, GL_UNSIGNED_BYTE, bytes);
    /* linear: the occlusion shader samples this with texture() (not
     * texelFetch) so cell boundaries blend smoothly over the last
     * half-texel instead of an abrupt step.                             */
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glActiveTexture_(GL_TEXTURE0);
}

static void new_game(void) { reset_level(); build_world_mesh(); upload_map(); }

static void setup_attribs(void) {
    glVertexAttribPointer_(0, 3, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)0);
    glEnableVertexAttribArray_(0);
    glVertexAttribPointer_(1, 2, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)(3 * sizeof(float)));
    glEnableVertexAttribArray_(1);
    glVertexAttribPointer_(2, 3, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)(5 * sizeof(float)));
    glEnableVertexAttribArray_(2);
}
static void gl_init(void) {
    prog3d = link_prog(VSRC, FSRC);
    progOv = link_prog(OVS, OFS);
    u_mvp = glGetUniformLocation_(prog3d, "uMVP");
    u_campos = glGetUniformLocation_(prog3d, "uCamPos");
    u_camdir = glGetUniformLocation_(prog3d, "uCamDir");
    u_amb = glGetUniformLocation_(prog3d, "uAmbient");
    u_fogk = glGetUniformLocation_(prog3d, "uFogK");
    u_flick = glGetUniformLocation_(prog3d, "uFlicker");
    u_mode = glGetUniformLocation_(prog3d, "uMode");
    u_tcount = glGetUniformLocation_(prog3d, "uTorchCount");
    u_tpos = glGetUniformLocation_(prog3d, "uTorchPos");
    u_tint = glGetUniformLocation_(prog3d, "uTorchInt");
    u_tcol = glGetUniformLocation_(prog3d, "uTorchCol");
    u_tex = glGetUniformLocation_(prog3d, "uTex");
    u_map = glGetUniformLocation_(prog3d, "uMap");
    u_mapsize = glGetUniformLocation_(prog3d, "uMapSize");
    u_occl = glGetUniformLocation_(prog3d, "uOccl");
    u_ambtint = glGetUniformLocation_(prog3d, "uAmbTint");
    u_scrsize = glGetUniformLocation_(prog3d, "uScreenSize");
    /* bind samplers: surface texture on unit 0, wall-occlusion map on unit 1 */
    glUseProgram_(prog3d);
    glUniform1i_(u_tex, 0);
    glUniform1i_(u_map, 1);
    glUniform2f_(u_mapsize, (float)MW, (float)MH);

    glGenVertexArrays_(1, &worldVAO); glGenBuffers_(1, &worldVBO);
    glBindVertexArray_(worldVAO); glBindBuffer_(GL_ARRAY_BUFFER, worldVBO); setup_attribs();

    glGenVertexArrays_(1, &sprVAO); glGenBuffers_(1, &sprVBO);
    glBindVertexArray_(sprVAO); glBindBuffer_(GL_ARRAY_BUFFER, sprVBO); setup_attribs();

    /* fullscreen overlay quad: pos.xy + uv (v flipped so fb row 0 is on top) */
    float ov[] = { -1,-1, 0,1,   1,-1, 1,1,   1,1, 1,0,
                   -1,-1, 0,1,   1,1, 1,0,  -1,1, 0,0 };
    glGenVertexArrays_(1, &ovVAO); glGenBuffers_(1, &ovVBO);
    glBindVertexArray_(ovVAO); glBindBuffer_(GL_ARRAY_BUFFER, ovVBO);
    glBufferData_(GL_ARRAY_BUFFER, sizeof(ov), ov, GL_STATIC_DRAW);
    glVertexAttribPointer_(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
    glEnableVertexAttribArray_(0);
    glVertexAttribPointer_(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
    glEnableVertexAttribArray_(1);

    texWall = make_texture(tex[0]); texFloor = make_texture(tex[1]); texCeil = make_texture(tex[2]);
    texLocker = make_texture(lockmetal);
    texBracket = make_texture(brackmetal);
    for (int i = 0; i < 7; i++) texSpr[i] = make_texture(spr_rgba[i]);
    glGenTextures(1, &texMap);                 /* filled per-maze by upload_map */
    glActiveTexture_(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, texMap);      /* keep the occlusion map on unit 1 */
    glActiveTexture_(GL_TEXTURE0);
    glGenTextures(1, &texOverlay);
    glBindTexture(GL_TEXTURE_2D, texOverlay);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, SCREEN_W, SCREEN_H, 0, GL_BGRA, GL_UNSIGNED_BYTE, fb);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

/* camera direction including pitch */
static void cam_dir(float *dx, float *dy, float *dz) {
    *dx = (float)(cos(pitch) * cos(yaw));
    *dy = (float)sin(pitch);
    *dz = (float)(cos(pitch) * sin(yaw));
}

static void draw_billboard(double wx, double wz, double w, double h, double base, int type, float mvp[16]) {
    /* camera-facing quad in the floor plane's right/up basis */
    float rx = (float)-sin(yaw), rz = (float)cos(yaw);   /* screen-right on the ground */
    float hx = rx * (float)(w * 0.5), hz = rz * (float)(w * 0.5);
    float y0 = (float)base, y1 = (float)(base + h);
    float cx = (float)wx, cz = (float)wz;
    float buf[6 * 8]; int n = 0;
    /* two triangles; normal unused for sprites */
    push_v(buf, &n, cx - hx, y0, cz - hz, 0, 1, 0, 0, 0);
    push_v(buf, &n, cx + hx, y0, cz + hz, 1, 1, 0, 0, 0);
    push_v(buf, &n, cx + hx, y1, cz + hz, 1, 0, 0, 0, 0);
    push_v(buf, &n, cx - hx, y0, cz - hz, 0, 1, 0, 0, 0);
    push_v(buf, &n, cx + hx, y1, cz + hz, 1, 0, 0, 0, 0);
    push_v(buf, &n, cx - hx, y1, cz - hz, 0, 0, 0, 0, 0);
    glBindVertexArray_(sprVAO);
    glBindBuffer_(GL_ARRAY_BUFFER, sprVBO);
    glBufferData_(GL_ARRAY_BUFFER, n * 8 * sizeof(float), buf, GL_DYNAMIC_DRAW);
    glUniformMatrix4fv_(u_mvp, 1, GL_FALSE, mvp);
    glUniform1i_(u_mode, 1);
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texSpr[type]);
    glDrawArrays(GL_TRIANGLES, 0, 6);
}

static void render_3d(void) {
    glViewport(0, 0, winW, winH);
    glEnable(GL_DEPTH_TEST);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    float dxc, dyc, dzc; cam_dir(&dxc, &dyc, &dzc);
    float ex = (float)posX, ey = 0.5f, ez = (float)posY;
    float proj[16], view[16], mvp[16];
    mat_perspective(proj, 1.30f, (float)winW / winH, 0.05f, 40.0f);
    mat_lookat(view, ex, ey, ez, ex + dxc, ey + dyc, ez + dzc, 0, 1, 0);
    mat_mul(mvp, proj, view);

    glUseProgram_(prog3d);
    glUniformMatrix4fv_(u_mvp, 1, GL_FALSE, mvp);
    glUniform3f_(u_campos, ex, ey, ez);
    glUniform3f_(u_camdir, dxc, dyc, dzc);
    glUniform1f_(u_amb, (float)AMBIENT);
    /* deeper floors press in closer: fog thickens and the moonlight ambient
     * cools from a faint blue-grey toward a sickly, oppressive dim red.    */
    double dd = (depth - 1) < 12 ? (depth - 1) : 12;
    glUniform1f_(u_fogk, (float)(FOG_K * (1.0 + 0.08 * dd)));
    glUniform1f_(u_flick, (float)flicker);
    glUniform3f_(u_ambtint, (float)(0.075 + 0.010 * dd), (float)(0.08 - 0.005 * dd), (float)(0.10 - 0.008 * dd));
    glUniform2f_(u_scrsize, (float)winW, (float)winH);

    /* torch point lights: warm, individually flickering */
    static float tp[MAX_TORCHES * 3], ti[MAX_TORCHES];
    for (int i = 0; i < torch_count; i++) {
        /* the light lives at the flame -- the handle tip, out in the room.
         * Being off the wall face matters: a source sitting on the wall
         * plane barely lights that wall (normal ~perpendicular to L).     */
        tp[i * 3] = torchX[i] + torchNx[i] * TORCH_REACH; tp[i * 3 + 1] = TORCH_Y; tp[i * 3 + 2] = torchZ[i] + torchNz[i] * TORCH_REACH;
        double f = 1.15 + 0.22 * sin(state_time * 7.0 + i * 1.7) + (frand() - 0.5) * 0.12;
        ti[i] = (float)(f * 1.5 * flicker);       /* global flicker/surge affects torches now */
    }
    glUniform1i_(u_tcount, torch_count);
    if (torch_count > 0) {
        glUniform3fv_(u_tpos, torch_count, tp);
        glUniform1fv_(u_tint, torch_count, ti);
    }
    glUniform3f_(u_tcol, 1.0f, 0.52f, 0.18f);
    glUniform1i_(u_occl, occl_on);

    /* world */
    glUniform1i_(u_mode, 0);
    glBindVertexArray_(worldVAO);
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texWall);   glDrawArrays(GL_TRIANGLES, 0, wallCount);
    glBindTexture(GL_TEXTURE_2D, texFloor);  glDrawArrays(GL_TRIANGLES, floorStart, floorCount);
    glBindTexture(GL_TEXTURE_2D, texCeil);   glDrawArrays(GL_TRIANGLES, ceilStart, ceilCount);
    glBindTexture(GL_TEXTURE_2D, texLocker);  glDrawArrays(GL_TRIANGLES, lockStart, lockCount);
    glBindTexture(GL_TEXTURE_2D, texBracket); glDrawArrays(GL_TRIANGLES, brkStart, brkCount);

    /* opaque-ish sprites (billboards) — depth tested, alpha discarded */
    if (!hidden) {
        /* The Stalker: tall & narrow, filling the corridor height, with a
         * slow uneasy sway and bob so it never reads as a static post. */
        double sway = 0.03 * sin(state_time * 1.7);
        double bob  = 0.02 * sin(state_time * 2.3);
        draw_billboard(monX - sin(yaw) * sway, monY + cos(yaw) * sway,
                       0.66, 0.99 + bob, 0.0, 0, mvp);
    }
    for (int i = 0; i < NUM_KEYS; i++)
        if (keys[i].active) draw_billboard(keys[i].x, keys[i].y, 0.4, 0.4, 0.35, 1, mvp);
    for (int i = 0; i < NUM_NOTES; i++)
        if (notes[i].active) draw_billboard(notes[i].x, notes[i].y, 0.32, 0.32, 0.25, 5, mvp);
    draw_billboard(exitX, exitY, 0.95, 0.95, 0.02, 2, mvp);          /* stairs down */
    if (has_up) draw_billboard(upX, upY, 0.95, 0.95, 0.02, 6, mvp);  /* stairs up   */

    /* torch flames: additive glow so they read as fire, not flat sprites.
     * Two stacked billboards -- a broad tongue plus a smaller, brighter
     * inner core (additive, so the overlap reads as white-hot).          */
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glDepthMask(GL_FALSE);
    for (int i = 0; i < torch_count; i++) {
        double fl = 0.88 + 0.16 * sin(state_time * 9.0 + i * 2.1)
                         + 0.05 * sin(state_time * 23.0 + i);        /* fast jitter */
        double s = 0.27 * fl;
        double fx = torchX[i] + torchNx[i] * TORCH_REACH;
        double fz = torchZ[i] + torchNz[i] * TORCH_REACH;
        double base = TORCH_TIP_Y - 0.02;
        draw_billboard(fx, fz, s * 1.15, s * 1.7,  base,        4, mvp);   /* tongue */
        draw_billboard(fx, fz, s * 0.62, s * 1.05, base + 0.04, 4, mvp);   /* core   */
    }
    glDepthMask(GL_TRUE);
    glDisable(GL_BLEND);
}

/* --------------------------------------------------- 2D overlay (into fb) */
static void ov_clear(void) { memset(fb, 0, sizeof(fb)); }

static void draw_hidden_overlay(void) {
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
    draw_text_c(SCREEN_H - 60, 3, "HIDDEN   PRESS E TO STEP OUT", pack(190, 190, 200));
}
static void draw_sanity_fx(void) {
    if (sanity > 0.9) return;
    double dread = 1.0 - sanity;
    double pulse = 0.6 + 0.4 * sin(state_time * (2.0 + dread * 5.0));
    double edge = 0.7 * dread * (0.55 + 0.45 * pulse);
    int redt = (int)(dread * dread * 90);
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            double dx = (x - SCREEN_W / 2.0) / (SCREEN_W / 2.0);
            double dy = (y - SCREEN_H / 2.0) / (SCREEN_H / 2.0);
            double r = dx * dx + dy * dy; if (r > 1) r = 1;
            int a = (int)(255 * edge * r * r);
            if (a > 0) fb[y * SCREEN_W + x] = packa((int)(redt * r), 0, 0, a);
        }
}
/* the parchment panel shown while reading a lore note */
static void draw_note(void) {
    for (int i = 0; i < SCREEN_W * SCREEN_H; i++) fb[i] = packa(0, 0, 0, 150);
    int pw = 560, ph = 300, px = (SCREEN_W - pw) / 2, py = (SCREEN_H - ph) / 2;
    fill_rect(px, py, pw, ph, packa(24, 22, 18, 240));
    fill_rect(px, py, pw, 4, packa(90, 80, 60, 255));
    fill_rect(px, py + ph - 4, pw, 4, packa(90, 80, 60, 255));
    draw_text_c(py + 26, 3, "A SCRAP OF PAPER", pack(180, 160, 120));
    const char **lines = NOTES[reading_note];
    int ty = py + 90;
    for (int i = 0; i < 6 && lines[i]; i++) { draw_text_c(ty, 3, lines[i], pack(210, 200, 175)); ty += 34; }
    draw_text_c(py + ph - 34, 2, "PRESS E TO PUT IT DOWN", pack(130, 120, 100));
}

static void draw_hud(void) {
    char buf[32];
    snprintf(buf, sizeof(buf), "FLOOR %d", depth);
    draw_text(16, 16, 3, buf, pack(150, 170, 220));
    snprintf(buf, sizeof(buf), "KEYS %d/%d", NUM_KEYS - keys_left, NUM_KEYS);
    draw_text(16, 44, 3, buf, pack(230, 210, 120));

    /* contextual stair prompts */
    double ed = fabs(posX - exitX) + fabs(posY - exitY);
    if (ed < 1.4) draw_text_c(SCREEN_H - 150, 3,
        keys_left == 0 ? "STAIRS DOWN - STEP ON TO DESCEND" : "STAIRS DOWN - LOCKED, FIND THE KEYS", pack(90, 255, 150));
    if (has_up) {
        double ud = fabs(posX - upX) + fabs(posY - upY);
        if (ud < 1.4) draw_text_c(SCREEN_H - 150, 3, "STAIRS UP - STEP ON TO CLIMB", pack(120, 190, 255));
    }

    int bw = 220, bh = 16, bx = 16, by = SCREEN_H - 80;
    fill_rect(bx - 2, by - 2, bw + 4, bh + 4, pack(20, 20, 24));
    int fillw = (int)(bw * stamina);
    uint32_t sc = exhausted ? pack(150, 40, 30) : pack(70 + (int)(120 * (1 - stamina)), 160, 90);
    fill_rect(bx, by, fillw, bh, sc);
    draw_text(bx, by - 22, 2, "STAMINA", pack(120, 130, 130));

    int my = by + 26;
    fill_rect(bx - 2, my - 2, bw + 4, bh + 4, pack(20, 20, 24));
    fill_rect(bx, my, (int)(bw * sanity), bh,
              pack(120 + (int)(120 * (1 - sanity)), 60 + (int)(40 * sanity), 130 * sanity + 40));
    draw_text(bx, my + bh + 4, 2, "MIND", pack(110, 100, 130));

    if (near_locker >= 0 && !hidden) draw_text_c(SCREEN_H - 110, 3, "PRESS E TO HIDE", pack(200, 200, 160));

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
        if (tension > 0.75 && ((int)(state_time * 8) % 2)) draw_text_c(90, 3, "IT IS CLOSE", pack(255, 40, 30));
    }
}
static void draw_title(void) {
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            double v = 6 + 5 * sin(x * 0.01 + state_time) * sin(y * 0.017 - state_time * 0.7);
            fb[y * SCREEN_W + x] = pack((int)v, (int)v, (int)(v + 3));
        }
    uint32_t red = pack(190 + (int)(40 * sin(state_time * 3)), 20, 16);
    draw_text_c(150, 9, "NIGHTFALL", red);
    draw_text_c(270, 3, "SOMETHING IN THE DARK IS AWAKE.", pack(150, 150, 160));
    draw_text_c(305, 3, "FIND THREE KEYS. REACH THE EXIT.", pack(120, 120, 130));
    if ((int)(state_time * 2) % 2) draw_text_c(380, 4, "PRESS ENTER", pack(220, 220, 220));
    draw_text_c(SCREEN_H - 84, 2, "CONTROLS USE PHYSICAL KEYS - IF THEY FAIL, SWITCH TO ENGLISH LAYOUT", pack(150, 120, 60));
    draw_text_c(SCREEN_H - 60, 2, "WASD MOVE   MOUSE LOOK   SHIFT RUN   E HIDE   ESC QUIT", pack(90, 90, 100));
}
static void draw_jumpscare(void) {
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
        draw_text_c(SCREEN_H / 2 - 40, 6, "IT FOUND YOU", pack(255, 30, 20));
        draw_text_c(SCREEN_H / 2 + 40, 3, "PRESS R TO GO BACK IN", pack(180, 180, 180));
    }
}

/* Dump the current back buffer to a binary PPM (for dev screenshots). */
static void save_ppm(const char *path) {
    unsigned char *px = malloc(SCREEN_W * SCREEN_H * 3);
    if (!px) return;
    glReadPixels(0, 0, SCREEN_W, SCREEN_H, GL_RGB, GL_UNSIGNED_BYTE, px);
    FILE *f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H);
        for (int y = SCREEN_H - 1; y >= 0; y--)          /* flip: GL is bottom-up */
            fwrite(px + y * SCREEN_W * 3, 1, SCREEN_W * 3, f);
        fclose(f);
    }
    free(px);
}

static void present_overlay(void) {
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram_(progOv);
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texOverlay);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, SCREEN_W, SCREEN_H, 0, GL_BGRA, GL_UNSIGNED_BYTE, fb);
    glBindVertexArray_(ovVAO);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glDisable(GL_BLEND);
}

/* -------------------------------------------------------------------- main */
int main(int argc, char **argv) {
    (void)argc; (void)argv;
    srand(getenv("NIGHTFALL_SEED") ? (unsigned)atoi(getenv("NIGHTFALL_SEED")) : (unsigned)time(NULL));
    if (getenv("NIGHTFALL_NOOCCL")) occl_on = 0;
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    SDL_Window *win = SDL_CreateWindow("NIGHTFALL",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        SCREEN_W, SCREEN_H, SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
    if (!win) { fprintf(stderr, "window: %s\n", SDL_GetError()); return 1; }
    SDL_GLContext ctx = SDL_GL_CreateContext(win);
    if (!ctx) { fprintf(stderr, "GL context: %s\n", SDL_GetError()); return 1; }
    SDL_GL_SetSwapInterval(1);
    load_gl();

    if (Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 1024) < 0)
        fprintf(stderr, "audio disabled: %s\n", Mix_GetError());
    Mix_AllocateChannels(8);
    snd_ambient = Mix_LoadWAV("assets/ambient.wav");
    snd_heart   = Mix_LoadWAV("assets/heartbeat.wav");
    snd_scare   = Mix_LoadWAV("assets/scare.wav");
    snd_pickup  = Mix_LoadWAV("assets/pickup.wav");
    snd_step    = Mix_LoadWAV("assets/step.wav");
    snd_whisper = Mix_LoadWAV("assets/whisper.wav");
    if (!snd_ambient) fprintf(stderr, "warning: assets not found — run 'make audio'\n");
    if (snd_ambient) { Mix_Volume(0, 60); Mix_PlayChannel(0, snd_ambient, -1); }

    build_textures();
    build_sprites();
    gl_init();
    if (getenv("NIGHTFALL_DEPTH")) depth = atoi(getenv("NIGHTFALL_DEPTH"));
    new_game();
    if (getenv("NIGHTFALL_DUMPMAP")) {
        const char *tn[] = {"entrance","key","storage","library","hall","exit"};
        fprintf(stderr, "rooms=%d\n", room_count);
        for (int i = 0; i < room_count; i++)
            fprintf(stderr, "  room %d: %dx%d at (%d,%d) theme=%s\n",
                    i, rooms[i].w, rooms[i].h, rooms[i].x, rooms[i].y, tn[rooms[i].theme]);
        for (int y = 0; y < MH; y++) {
            char line[MW + 1];
            for (int x = 0; x < MW; x++) {
                char c = is_open(x, y) ? '.' : '#';
                if (x == startX && y == startY) c = '@';
                else if ((int)exitX == x && (int)exitY == y) c = 'X';
                else for (int k = 0; k < NUM_KEYS; k++) if ((int)keys[k].x == x && (int)keys[k].y == y) c = 'K';
                line[x] = c;
            }
            line[MW] = 0;
            fprintf(stderr, "%s\n", line);
        }
    }

    SDL_SetRelativeMouseMode(SDL_TRUE);
    const char *shotpath = getenv("NIGHTFALL_SHOT");
    int shot_frame = 0;
    if (getenv("NIGHTFALL_AUTOPLAY") || shotpath) { game_state = ST_PLAY; state_time = 0; }
    /* dev screenshot: stand in front of a torch looking at it */
    if (shotpath && torch_count > 0) {
        int bi = 0;                                     /* first torch */
        double cx = torchX[bi] + torchNx[bi] * 0.48, cz = torchZ[bi] + torchNz[bi] * 0.48;
        double tx = -torchNz[bi], tz = torchNx[bi];     /* along the wall */
        int rp = 0, rn = 0;
        for (int s = 1; s <= 4; s++) { if (is_open((int)(cx + tx * s), (int)(cz + tz * s))) rp++; else break; }
        for (int s = 1; s <= 4; s++) { if (is_open((int)(cx - tx * s), (int)(cz - tz * s))) rn++; else break; }
        double sgn = (rp >= rn) ? 1.0 : -1.0;
        posX = cx; posY = cz;
        double bx = cx - tx * sgn, bz = cz - tz * sgn;  /* step back so torch is ahead-side */
        if (is_open((int)bx, (int)bz)) { posX = bx; posY = bz; }
        yaw = atan2(tz * sgn, tx * sgn);
        pitch = -0.12;
        if (getenv("NIGHTFALL_SHOWMON")) {              /* park the Stalker in view */
            for (double s = 3.0; s >= 1.5; s -= 0.5) {
                double mx = posX + cos(yaw) * s, my = posY + sin(yaw) * s;
                if (is_open((int)mx, (int)my)) { monX = mx; monY = my; break; }
            }
            pitch = 0.02;
        }
        if (getenv("NIGHTFALL_SHOWKEY")) {              /* stand back from a shrine */
            double kx = pedX[0], kz = pedZ[0];
            for (double s = 2.5; s >= 1.5; s -= 0.5) {
                for (int d = 0; d < 4; d++) {
                    double ox = (d==0)-(d==1), oz = (d==2)-(d==3);
                    double px = kx + ox * s, pz = kz + oz * s;
                    if (is_open((int)px, (int)pz)) { posX = px; posY = pz;
                        yaw = atan2(kz - pz, kx - px); pitch = -0.05; }
                }
            }
        }
        fprintf(stderr, "torches=%d\n", torch_count);
    }
    Uint64 prev = SDL_GetPerformanceCounter();
    double freq = (double)SDL_GetPerformanceFrequency();
    int running = 1;
    int fullscreen = 0;
    SDL_GL_GetDrawableSize(win, &winW, &winH);

    while (running) {
        Uint64 now = SDL_GetPerformanceCounter();
        double dt = (now - prev) / freq; if (dt > 0.05) dt = 0.05; prev = now;
        state_time += dt;

        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            if (e.type == SDL_WINDOWEVENT &&
                (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED || e.window.event == SDL_WINDOWEVENT_RESIZED)) {
                SDL_GL_GetDrawableSize(win, &winW, &winH);
            }
            if (e.type == SDL_KEYDOWN) {
                SDL_Scancode k = e.key.keysym.scancode;
                if (k == SDL_SCANCODE_ESCAPE) running = 0;
                if (k == SDL_SCANCODE_F11) {
                    fullscreen = !fullscreen;
                    SDL_SetWindowFullscreen(win, fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
                    SDL_GL_GetDrawableSize(win, &winW, &winH);
                }
                if ((k == SDL_SCANCODE_RETURN || k == SDL_SCANCODE_KP_ENTER ||
                     k == SDL_SCANCODE_SPACE) && game_state == ST_TITLE) {
                    depth = 1; new_game(); game_state = ST_PLAY; state_time = 0;
                }
                if (k == SDL_SCANCODE_R && (game_state == ST_CAUGHT || game_state == ST_WIN)) {
                    depth = 1; new_game(); game_state = ST_PLAY; state_time = 0;
                }
                /* dismiss a note you're reading */
                if ((k == SDL_SCANCODE_E || k == SDL_SCANCODE_SPACE ||
                     k == SDL_SCANCODE_RETURN) && game_state == ST_READING) {
                    game_state = ST_PLAY;
                }
                if (k == SDL_SCANCODE_E && game_state == ST_PLAY) {
                    if (hidden) hidden = 0;
                    else if (near_locker >= 0) { hidden = 1; posX = lockers[near_locker].x; posY = lockers[near_locker].y; }
                }
            }
            if (e.type == SDL_MOUSEMOTION && game_state == ST_PLAY && !hidden) {
                yaw   += e.motion.xrel * MOUSE_SENS;
                pitch -= e.motion.yrel * MOUSE_SENS;
                if (pitch >  1.45) pitch =  1.45;
                if (pitch < -1.45) pitch = -1.45;
            }
        }

        if (game_state == ST_PLAY) {
            const Uint8 *ks = SDL_GetKeyboardState(NULL);
            int want_run = ks[SDL_SCANCODE_LSHIFT] && !exhausted && stamina > 0.05;
            int moving = 0;
            if (!hidden) {
                double spd = (want_run ? PLAYER_RUN : PLAYER_WALK) * dt;
                double fx = cos(yaw), fz = sin(yaw), rx = -sin(yaw), rz = cos(yaw);
                double nx = posX, ny = posY;
                if (ks[SDL_SCANCODE_W]) { nx += fx * spd; ny += fz * spd; moving = 1; }
                if (ks[SDL_SCANCODE_S]) { nx -= fx * spd; ny -= fz * spd; moving = 1; }
                if (ks[SDL_SCANCODE_D]) { nx += rx * spd; ny += rz * spd; moving = 1; }
                if (ks[SDL_SCANCODE_A]) { nx -= rx * spd; ny -= rz * spd; moving = 1; }
                if (ks[SDL_SCANCODE_LEFT])  yaw -= 1.8 * dt;
                if (ks[SDL_SCANCODE_RIGHT]) yaw += 1.8 * dt;
                if (moving) try_move(nx, ny, 0.15);
            }
            int sprinting = want_run && moving;
            stamina += (sprinting ? -STAM_DRAIN : STAM_REGEN) * dt;
            if (stamina < 0) stamina = 0;
            if (stamina > 1) stamina = 1;
            if (stamina <= 0.02) exhausted = 1;
            if (stamina >= 0.30) exhausted = 0;

            near_locker = -1;
            for (int i = 0; i < NUM_LOCKERS; i++)
                if (fabs(posX - lockers[i].x) + fabs(posY - lockers[i].y) < HIDE_DIST) { near_locker = i; break; }

            update_ai(dt, moving, sprinting);
            update_fear(dt);

            if (surge > 0) flicker = (((int)(surge * 34)) & 1) ? 0.9 : 0.06;
            else {
                double chance = 0.04 + tension * 0.15 + (1.0 - sanity) * 0.12;
                double depth  = 0.4 + tension * 0.4 + (1.0 - sanity) * 0.3;
                flicker = 1.0 - (frand() < chance ? frand() * depth : 0);
            }

            for (int i = 0; i < NUM_KEYS; i++)
                if (keys[i].active) {
                    double kd = (posX - keys[i].x) * (posX - keys[i].x) + (posY - keys[i].y) * (posY - keys[i].y);
                    if (kd < PICKUP_DIST * PICKUP_DIST) { keys[i].active = 0; keys_left--;
                        if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0); }
                }
            /* pick up and read a lore note */
            for (int i = 0; i < NUM_NOTES; i++)
                if (notes[i].active) {
                    double nd = (posX - notes[i].x) * (posX - notes[i].x) + (posY - notes[i].y) * (posY - notes[i].y);
                    if (nd < PICKUP_DIST * PICKUP_DIST) {
                        notes[i].active = 0; reading_note = notes[i].text;
                        game_state = ST_READING;
                        if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
                    }
                }
            /* descend once the floor's keys are collected */
            if (keys_left == 0) {
                double ed = (posX - exitX) * (posX - exitX) + (posY - exitY) * (posY - exitY);
                if (ed < 0.4) { depth++; new_game(); state_time = 0; }
            }
            /* climb back up */
            if (has_up) {
                double ud = (posX - upX) * (posX - upX) + (posY - upY) * (posY - upY);
                if (ud < 0.4) { depth--; new_game(); state_time = 0; }
            }
            double md = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
            int caught = (!hidden && md < CATCH_DIST && !shotpath);
            if (hidden && near_locker >= 0 && (mon_state == AI_HUNT || mon_state == AI_SEARCH)) {
                double ld = sqrt((monX - lockers[near_locker].x) * (monX - lockers[near_locker].x) +
                                 (monY - lockers[near_locker].y) * (monY - lockers[near_locker].y));
                if (ld < CHECK_DIST) { caught = 1; hidden = 0; }
            }
            if (caught) { game_state = ST_CAUGHT; state_time = 0;
                if (snd_scare) { Mix_VolumeChunk(snd_scare, 128); Mix_PlayChannel(4, snd_scare, 0); } }
            update_audio(dt, moving);
        } else {
            update_audio(dt, 0);
        }

        /* ---- render: 3D scene, then 2D overlay ---- */
        if (game_state == ST_TITLE || game_state == ST_CAUGHT) {
            glViewport(0, 0, winW, winH);
            glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        } else {
            render_3d();
        }

        /* dev screenshot: capture the pure 3D scene after a few settling frames */
        if (shotpath && game_state == ST_PLAY && ++shot_frame >= 24) {
            save_ppm(shotpath);
            running = 0;
        }

        ov_clear();
        if (game_state == ST_TITLE) draw_title();
        else if (game_state == ST_CAUGHT) draw_jumpscare();
        else if (game_state == ST_READING) { draw_hud(); draw_note(); }
        else {
            draw_sanity_fx();
            if (hidden) draw_hidden_overlay();
            draw_hud();
        }
        present_overlay();

        SDL_GL_SwapWindow(win);
    }

    if (snd_ambient) Mix_FreeChunk(snd_ambient);
    if (snd_heart)   Mix_FreeChunk(snd_heart);
    if (snd_scare)   Mix_FreeChunk(snd_scare);
    if (snd_pickup)  Mix_FreeChunk(snd_pickup);
    if (snd_step)    Mix_FreeChunk(snd_step);
    if (snd_whisper) Mix_FreeChunk(snd_whisper);
    Mix_CloseAudio();
    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
