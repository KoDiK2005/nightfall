/*
 * NIGHTFALL — real-3D OpenGL rendering.
 *
 * Procedural CPU-side textures/sprites uploaded as GL textures, a hand-rolled
 * mesh builder for the maze (walls/floor/ceiling/lockers/props/torches), a
 * per-fragment torch-light + soft-shadow shader, and a post-process pass
 * (chromatic aberration, film grain, screen-shake) that upscales the
 * offscreen scene to the window.
 */
#include "game.h"

/* CPU-side procedural pixels, later uploaded as GL textures */
uint32_t tex[3][TEX * TEX];         /* 0 wall, 1 floor, 2 ceiling     */
uint32_t lockmetal[TEX * TEX];      /* opaque steel for locker boxes  */
uint32_t brackmetal[TEX * TEX];     /* dark iron for torch brackets   */
uint32_t spr_rgba[11][TEX * TEX];   /* 0 mon,1 key,2 down,3 loc,4 flame,5 note,6 up,7 chest,8 dust,9 match,10 rock */

/* torches fixed to walls: warm point lights that flicker */
float torchX[MAX_TORCHES], torchZ[MAX_TORCHES];   /* flame world pos  */
float torchNx[MAX_TORCHES], torchNz[MAX_TORCHES]; /* into-corridor dir*/
int   torch_count = 0;
/* torch geometry: a wooden handle mounted on the wall (base) angling up and
 * out into the corridor to a tip, where the burning rag + flame sit.        */
#define TORCH_BASE_Y 0.40f     /* where the handle meets the wall            */
#define TORCH_TIP_Y  0.56f     /* the far, upper end of the handle           */
#define TORCH_REACH  0.26f     /* how far the tip protrudes from the wall    */
#define TORCH_Y      0.66f     /* flame / point-light centre height          */

/* per-locker orientation: unit vector from cell centre toward its backing wall */
double lockWX[NUM_LOCKERS], lockWY[NUM_LOCKERS];

int   occl_on = 1;
int   winW = SCREEN_W, winH = SCREEN_H;   /* actual drawable size (resize/fullscreen) */
/* the 3D scene renders into this offscreen buffer at a capped internal size,
 * then is upscaled to the window -- so fragment cost never scales with a huge
 * (e.g. fullscreen) window. The HUD overlay is still composited at native res. */
#define RENDER_CAP_W 1280
int   render_cap_w = RENDER_CAP_W;        /* override with NIGHTFALL_RCAP */

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
static PFNGLGENFRAMEBUFFERSPROC         glGenFramebuffers_;
static PFNGLBINDFRAMEBUFFERPROC         glBindFramebuffer_;
static PFNGLFRAMEBUFFERTEXTURE2DPROC    glFramebufferTexture2D_;
static PFNGLGENRENDERBUFFERSPROC        glGenRenderbuffers_;
static PFNGLBINDRENDERBUFFERPROC        glBindRenderbuffer_;
static PFNGLRENDERBUFFERSTORAGEPROC     glRenderbufferStorage_;
static PFNGLFRAMEBUFFERRENDERBUFFERPROC glFramebufferRenderbuffer_;
static PFNGLBLITFRAMEBUFFERPROC         glBlitFramebuffer_;
static PFNGLDELETEFRAMEBUFFERSPROC      glDeleteFramebuffers_;
static PFNGLDELETERENDERBUFFERSPROC     glDeleteRenderbuffers_;

void load_gl(void) {
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
    glGenFramebuffers_        = (PFNGLGENFRAMEBUFFERSPROC)         SDL_GL_GetProcAddress("glGenFramebuffers");
    glBindFramebuffer_        = (PFNGLBINDFRAMEBUFFERPROC)         SDL_GL_GetProcAddress("glBindFramebuffer");
    glFramebufferTexture2D_   = (PFNGLFRAMEBUFFERTEXTURE2DPROC)    SDL_GL_GetProcAddress("glFramebufferTexture2D");
    glGenRenderbuffers_       = (PFNGLGENRENDERBUFFERSPROC)        SDL_GL_GetProcAddress("glGenRenderbuffers");
    glBindRenderbuffer_       = (PFNGLBINDRENDERBUFFERPROC)        SDL_GL_GetProcAddress("glBindRenderbuffer");
    glRenderbufferStorage_    = (PFNGLRENDERBUFFERSTORAGEPROC)     SDL_GL_GetProcAddress("glRenderbufferStorage");
    glFramebufferRenderbuffer_= (PFNGLFRAMEBUFFERRENDERBUFFERPROC) SDL_GL_GetProcAddress("glFramebufferRenderbuffer");
    glBlitFramebuffer_        = (PFNGLBLITFRAMEBUFFERPROC)         SDL_GL_GetProcAddress("glBlitFramebuffer");
    glDeleteFramebuffers_     = (PFNGLDELETEFRAMEBUFFERSPROC)      SDL_GL_GetProcAddress("glDeleteFramebuffers");
    glDeleteRenderbuffers_    = (PFNGLDELETERENDERBUFFERSPROC)     SDL_GL_GetProcAddress("glDeleteRenderbuffers");
}

/* ------------------------------------------------------------ texture build */
void build_textures(void) {
    /* the deeper you go, the more the stone has rotted: cracks spread, grime
     * pools and the walls begin to weep. 0 near the top .. 1 by floor ~13. */
    double wear = (depth - 1) / 12.0; if (wear > 1.0) wear = 1.0;
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            int i = y * TEX + x;
            int brick_h = 16, brick_w = 32, row = y / brick_h;
            int ox = (row & 1) ? brick_w / 2 : 0;
            int mortar = ((x + ox) % brick_w < 2) || (y % brick_h < 2);
            int base = 52 + (int)(frand() * 18);
            if (mortar) tex[0][i] = pack(base * 0.30 * bwall[0], base * 0.32 * bwall[1], base * 0.36 * bwall[2]);
            else {
                /* cold grey-brown stone, recoloured by the biome; picks up torchlight */
                int r = base * 0.92, g = base * 0.86, b = base * 0.80;
                if (frand() < 0.05 + 0.22 * wear) { r -= 16; g -= 16; b -= 14; }   /* dark stains, worse deeper */
                /* branching hairline cracks that spread across the face with depth */
                double ridge = fabs(sin(x * 0.20 + 2.4 * sin(y * 0.11)));
                if (ridge < 0.05 + 0.05 * wear) { int d = (int)(28 * (0.4 + wear)); r -= d; g -= d; b -= d; }
                /* deep floors weep: dark, rusty blood seeping down the stone */
                if (wear > 0.35 && frand() < 0.05 * wear) { r += (int)(22 * wear); g -= 12; b -= 8; }
                if (r < 4) r = 4;
                if (g < 3) g = 3;
                if (b < 3) b = 3;
                tex[0][i] = pack(r * bwall[0], g * bwall[1], b * bwall[2]);
            }
            int f = 30 + (int)(frand() * 14);
            if (frand() < 0.12 * wear) f -= 12;                  /* grime pooling on deep floors */
            if (f < 6) f = 6;
            int crack = ((x * 7 + y * 3) % 29 < 2);
            tex[1][i] = crack ? pack(8 * bfloor[0], 9 * bfloor[1], 10 * bfloor[2])
                              : pack(f * bfloor[0], f * bfloor[1], (f + 4) * bfloor[2]);
            int c = 12 + (int)(frand() * 6);
            tex[2][i] = pack(c * bceil[0], c * bceil[1], (c + 2) * bceil[2]);
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
static uint8_t spr_flg[11][TEX * TEX];
static void put_spr(int t, int x, int y, uint32_t col, uint8_t flg) {
    if (x < 0 || x >= TEX || y < 0 || y >= TEX) return;
    spr_flg[t][y * TEX + x] = flg;
    spr_rgba[t][y * TEX + x] = col;
}
void build_sprites(void) {
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
    /* deep black sockets, big burning eyes, and a gaping fanged maw */
    for (int y = 4; y <= 26; y++)
        for (int x = 0; x < TEX; x++) {
            double le = (x - 27.5) * (x - 27.5) + (y - 10.0) * (y - 10.0);
            double re = (x - 36.5) * (x - 36.5) + (y - 10.0) * (y - 10.0);
            if (le < 10.0 || re < 10.0) {                                          /* hot core */
                double q = (le < re ? le : re) / 10.0;
                put_spr(0, x, y, pack(255, (int)(90 - q * 60), (int)(30 - q * 22)), 2);
            } else if (le < 22.0 || re < 22.0) put_spr(0, x, y, pack(120, 12, 8), 2); /* ember rim */
            else if (le < 40.0 || re < 40.0) put_spr(0, x, y, pack(4, 2, 2), 1);      /* black socket */
            /* thin blood tracks weeping down from each eye */
            if ((x == 27 || x == 37) && y > 12 && y < 24 && ((y + x) % 3)) put_spr(0, x, y, pack(70, 6, 6), 1);
            /* gaping maw with a jagged row of pale fangs */
            double m = (x - 32.0) * (x - 32.0) / 12.0 + (y - 19.0) * (y - 19.0) / 6.0;
            if (m < 1.0) {
                int fang = (y < 19) ? (((x * 7) % 5) < 2 && y > 16) : (((x * 7 + 3) % 5) < 2 && y < 21);
                put_spr(0, x, y, fang ? pack(205, 195, 175) : pack(5, 2, 3), fang ? 2 : 1);
            }
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
    /* 7: CHEST — a hunched iron-bound coffer, domed lid, heavy padlock. The
     * key you need is locked inside; opening it is the fright. */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            if (x < 16 || x > 48 || y < 22 || y > 56) continue;
            double lidy = 34.0;                                   /* lid/body split */
            int band  = (x == 16 || x == 48 || y == 56 || abs(x - 32) < 2); /* iron straps */
            int plank = ((x + (y > lidy ? 0 : 1)) % 6 < 1);       /* wood grain seams  */
            int lid   = (y < lidy);
            if (lid) {                                            /* domed arched lid  */
                double a = (x - 32.0) / 16.0;
                if (y < lidy - 10.0 + a * a * 10.0) continue;     /* carve the arch    */
            }
            int wood = lid ? 74 : 58;                             /* lid catches light */
            int v = wood + (int)(frand() * 8) - (plank ? 22 : 0) - (band ? 40 : 0);
            if (v < 6) v = 6;
            uint32_t col = band ? pack(v + 6, v + 4, v + 6)       /* cold iron   */
                                : pack(v + 30, (int)(v * 0.8) + 8, (int)(v * 0.4)); /* warm wood */
            put_spr(7, x, y, col, 1);
            /* brass padlock hanging at the front seam */
            if (abs(x - 32) < 4 && y > lidy - 2 && y < lidy + 6) put_spr(7, x, y, pack(190, 150, 40), 1);
            if (abs(x - 32) < 3 && y > lidy - 6 && y < lidy - 1) put_spr(7, x, y, pack(150, 120, 30), 1); /* shackle */
        }
    /* 8: DUST MOTE — a soft round speck of warm, ember-lit dust for additive
     * blending near torches. rgb IS the faint light it adds; kept dim so a
     * mote only whispers into the frame. Alpha flag 2 across the disc makes it
     * emissive (unlit glow) with a gaussian rgb falloff for a soft edge.      */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            double dx = x - 32.0, dy = y - 32.0;
            double r2 = dx * dx + dy * dy;
            if (r2 > 100.0) continue;                       /* radius ~10px disc */
            double g = exp(-r2 / 36.0);                     /* soft gaussian core */
            int R = (int)(70 * g), G = (int)(52 * g), B = (int)(28 * g);
            put_spr(8, x, y, pack(R, G, B), 2);
        }
    /* 9: MATCHBOX — a small red box with a pale strike strip and a single
     * match leaning out, tip up. Self-lit (flag 2) so a dropped one glimmers
     * enough to spot in the dark, like the keys do. */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            if (x >= 20 && x <= 44 && y >= 30 && y <= 54) {   /* the box body */
                int edge = (x <= 21 || x >= 43 || y <= 31 || y >= 53);
                int strip = (y >= 30 && y <= 35);             /* darker strike band */
                if (strip)     put_spr(9, x, y, pack(120, 30, 24), 2);
                else if (edge) put_spr(9, x, y, pack(120, 24, 18), 2);
                else           put_spr(9, x, y, pack(200, 46, 34), 2);
            }
            /* a match stick leaning out of the top, red phosphorus tip */
            int mx = 32 + (54 - y) * 12 / 30;                 /* diagonal lean */
            if (y >= 12 && y <= 30 && abs(x - mx) <= 1) put_spr(9, x, y, pack(210, 180, 120), 2);
            if (y >= 12 && y <= 17 && abs(x - mx) <= 2) put_spr(9, x, y, pack(220, 70, 40), 2);
        }
    /* 10: ROCK — a plain lumpy grey-brown stone, dim and self-lit (flag 2) just
     * enough to pick out of the dark, like the other floor pickups. */
    for (int y = 0; y < TEX; y++)
        for (int x = 0; x < TEX; x++) {
            double dx = (x - 32.0) / 15.0, dy = (y - 36.0) / 12.0;
            double bump = 0.10 * sin(x * 0.7 + y * 1.3);           /* lumpy silhouette */
            if (dx * dx + dy * dy > 1.0 + bump) continue;
            double edge = dx * dx + dy * dy;                       /* darker toward the rim */
            int v = (int)(70 - edge * 26) + (int)(frand() * 10);
            if (v < 20) v = 20;
            put_spr(10, x, y, pack(v, (int)(v * 0.94), (int)(v * 0.86)), 2);
        }
    /* bake the flag into the alpha byte for the shader */
    for (int t = 0; t < 11; t++)
        for (int i = 0; i < TEX * TEX; i++) {
            int a = spr_flg[t][i] == 0 ? 0 : (spr_flg[t][i] == 1 ? 128 : 255);
            spr_rgba[t][i] = (spr_rgba[t][i] & 0x00FFFFFF) | ((uint32_t)a << 24);
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
    "layout(location=3) in vec3 aTint;\n"
    "uniform mat4 uMVP;\n"
    "out vec3 vW; out vec2 vUV; out vec3 vN; out vec3 vTint;\n"
    "void main(){ vW=aPos; vUV=aUV; vN=aN; vTint=aTint; gl_Position=uMVP*vec4(aPos,1.0); }\n";
static const char *FSRC =
    "#version 330 core\n"
    "in vec3 vW; in vec2 vUV; in vec3 vN; in vec3 vTint;\n"
    "uniform sampler2D uTex;\n"
    "uniform vec3 uCamPos; uniform vec3 uCamDir;\n"
    "uniform float uAmbient; uniform float uFogK; uniform float uFlicker;\n"
    "uniform vec3 uAmbTint; uniform vec2 uScreenSize;\n"
    "uniform int uMode;\n"                 /* 0 world, 1 sprite */
    "uniform vec3 uSprTint;\n"             /* per-sprite colour (monsters) */
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
    "  int steps = int(len / 0.34) + 1; if(steps > 24) steps = 24;\n"
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
    "  vec3 albedo = (uMode==0) ? t.rgb * vTint : t.rgb * uSprTint;\n"  /* room zones / sprite tint */
    "  vec3 nrm = normalize(vN);\n"
    "  float dist = length(vW - uCamPos);\n"
    "  float fog = 1.0 / (1.0 + dist*dist*uFogK);\n"
    /* cool moonlight ambient so geometry is faintly readable in the dark, */
    /* plus warm torch point lights that carry the real illumination.      */
    "  vec3 lit = uAmbTint;\n"
    "  for(int i=0;i<uTorchCount;i++){\n"
    "    vec3 L = uTorchPos[i] - vW; float td = length(L);\n"
    "    float att = uTorchInt[i] / (1.0 + 0.35*td + 0.55*td*td);\n"
    "    if(att < 0.03) continue;\n"                 /* too dim to bother     */
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
    "  vec3 col = albedo * lit;\n"
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
    "uniform vec2 uOfs;\n"                 /* screen-shake offset (jumpscare) */
    "out vec2 vUV; void main(){ vUV=aUV; gl_Position=vec4(aPos+uOfs,0.0,1.0); }\n";
static const char *OFS =
    "#version 330 core\n"
    "in vec2 vUV; uniform sampler2D uTex; out vec4 frag;\n"
    "void main(){ frag = texture(uTex, vUV); }\n";
/* Post-process: samples the rendered 3D scene and applies a VHS-horror grade —
 * chromatic aberration that swells toward the edges (and on a scare), animated
 * film grain, a faint rolling scanline, and a screen-shake UV offset. This is
 * the pass that upscales the offscreen FBO to the window, replacing a raw blit. */
static const char *PFS =
    "#version 330 core\n"
    "in vec2 vUV; out vec4 frag;\n"
    "uniform sampler2D uTex;\n"
    "uniform vec2 uScreenSize;\n"
    "uniform float uTime, uAber, uGrain;\n"
    "uniform vec2 uShake;\n"
    "float hash(vec2 p){ p=fract(p*vec2(123.34,345.45)); p+=dot(p,p+34.345); return fract(p.x*p.y); }\n"
    "void main(){\n"
    "  vec2 uv = vec2(vUV.x, 1.0 - vUV.y) + uShake;\n"   /* flip to GL orientation, then shake */
    "  vec2 off = (uv - 0.5) * uAber;\n"                 /* radial: grows toward the edges */
    "  float r = texture(uTex, uv + off).r;\n"
    "  float g = texture(uTex, uv).g;\n"
    "  float b = texture(uTex, uv - off).b;\n"
    "  vec3 col = vec3(r, g, b);\n"
    "  float n = hash(uv * uScreenSize + fract(uTime) * vec2(37.0, 17.0));\n"
    "  col += (n - 0.5) * uGrain;\n"                     /* film grain */
    "  col *= 0.97 + 0.03 * sin(uv.y * uScreenSize.y * 1.4 + uTime * 4.0);\n"  /* rolling scanline */
    "  frag = vec4(col, 1.0);\n"
    "}\n";

static GLuint prog3d, progOv, progPost;
static GLint u_ovofs;                                    /* overlay shake offset */
static GLint up_tex, up_scr, up_time, up_aber, up_grain, up_shake;
static GLint u_mvp, u_campos, u_camdir, u_amb, u_fogk, u_flick, u_mode;
static GLint u_ambtint, u_scrsize, u_sprtint;
static float spr_tint[3] = {1.0f, 1.0f, 1.0f};   /* colour multiply for the next sprite */
static GLint u_tcount, u_tpos, u_tint, u_tcol, u_tex, u_map, u_mapsize, u_occl;
static GLuint sceneFBO = 0, sceneTex = 0, sceneDepth = 0;
static int   fboW = 0, fboH = 0;                 /* current FBO allocation      */
static int   rndW = SCREEN_W, rndH = SCREEN_H;   /* internal 3D render size     */
static GLuint worldVAO, worldVBO, sprVAO, sprVBO, ovVAO, ovVBO;
static GLuint texWall, texFloor, texCeil, texLocker, texBracket, texSpr[11], texOverlay, texMap;
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

/* the surface tint written into every vertex push_v emits, so per-room colour
 * zones can be baked into the world mesh (sprites just leave it white).      */
static float cur_tint[3] = {1.0f, 1.0f, 1.0f};
/* one vertex = pos(3) uv(2) normal(3) tint(3) */
static void push_v(float *buf, int *n, float x, float y, float z,
                   float u, float v, float nx, float ny, float nz) {
    float *p = buf + (*n) * 11;
    p[0] = x; p[1] = y; p[2] = z; p[3] = u; p[4] = v; p[5] = nx; p[6] = ny; p[7] = nz;
    p[8] = cur_tint[0]; p[9] = cur_tint[1]; p[10] = cur_tint[2];
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

/* a freestanding centred box with independent x/z half-extents (4 sides + top):
 * altar pedestals, door posts, lintels and slabs.                          */
static void add_box2(float *buf, int *n, double cx, double cz, double hwx, double hwz, double y0, double y1) {
    float x0 = cx - hwx, x1 = cx + hwx, z0 = cz - hwz, z1 = cz + hwz;
    float A[3]={x0,y0,z0}, B[3]={x1,y0,z0}, C[3]={x1,y0,z1}, D[3]={x0,y0,z1};
    float At[3]={x0,y1,z0}, Bt[3]={x1,y1,z0}, Ct[3]={x1,y1,z1}, Dt[3]={x0,y1,z1};
    push_quad(buf, n, A, B, Bt, At, 0, 0, -1, 1);
    push_quad(buf, n, B, C, Ct, Bt, 1, 0, 0, 1);
    push_quad(buf, n, C, D, Dt, Ct, 0, 0, 1, 1);
    push_quad(buf, n, D, A, At, Dt, -1, 0, 0, 1);
    push_quad(buf, n, At, Bt, Ct, Dt, 0, 1, 0, 1);
}

/* the descent door: an iron frame (two posts + a lintel) with a slab that is
 * present only while the floor is locked; collecting all keys drops it.     */
static void add_door(float *buf, int *n, double ex, double ez, double nx, int locked) {
    if (nx != 0.0) {                         /* faces ±X, opening spans Z */
        add_box2(buf, n, ex, ez + 0.34, 0.06, 0.06, 0.0, 0.98);   /* post */
        add_box2(buf, n, ex, ez - 0.34, 0.06, 0.06, 0.0, 0.98);   /* post */
        add_box2(buf, n, ex, ez, 0.07, 0.44, 0.90, 0.99);         /* lintel */
        if (locked) add_box2(buf, n, ex, ez, 0.05, 0.34, 0.0, 0.90);  /* slab */
    } else {                                 /* faces ±Z, opening spans X */
        add_box2(buf, n, ex + 0.34, ez, 0.06, 0.06, 0.0, 0.98);
        add_box2(buf, n, ex - 0.34, ez, 0.06, 0.06, 0.0, 0.98);
        add_box2(buf, n, ex, ez, 0.44, 0.07, 0.90, 0.99);
        if (locked) add_box2(buf, n, ex, ez, 0.34, 0.05, 0.0, 0.90);
    }
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
    /* deeper floors are lit more sparsely — the dark closes in as you descend */
    float dd = (depth - 1) < 12 ? (float)(depth - 1) : 12.0f;
    float spacing = TORCH_SPACING + dd * 0.11f;
    if (spacing > 3.9f) spacing = 3.9f;
    float sp2 = spacing * spacing;
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

/* which room (theme) a cell falls in, or -1 for the connecting corridors */
static int theme_at(int x, int y) {
    for (int i = 0; i < room_count; i++) {
        Room *r = &rooms[i];
        if (x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h) return r->theme;
    }
    return -1;
}
/* set the surface tint for a room theme so each zone reads as its own colour:
 * shrines glow gold, the library runs cold blue, storage is rusty, the exit
 * sickly green, corridors a neutral cool grey. Multiplies the base texture. */
static void tint_for(int theme) {
    float c[3];
    switch (theme) {
        case RM_KEY:      c[0]=1.25f; c[1]=0.92f; c[2]=0.48f; break;  /* gold shrine   */
        case RM_LIBRARY:  c[0]=0.64f; c[1]=0.80f; c[2]=1.12f; break;  /* cold blue     */
        case RM_STORAGE:  c[0]=1.10f; c[1]=0.78f; c[2]=0.55f; break;  /* rust/amber    */
        case RM_CELLS:    c[0]=1.08f; c[1]=0.62f; c[2]=0.58f; break;  /* bloodied rust */
        case RM_EXIT:     c[0]=0.58f; c[1]=1.18f; c[2]=0.72f; break;  /* sickly green  */
        case RM_ENTRANCE: c[0]=1.00f; c[1]=0.90f; c[2]=0.74f; break;  /* warm hearth   */
        default:          c[0]=0.82f; c[1]=0.84f; c[2]=0.94f; break;  /* corridor grey */
    }
    cur_tint[0]=c[0]; cur_tint[1]=c[1]; cur_tint[2]=c[2];
}

/* Rebuild the world mesh for the current maze (walls, floor, ceiling, lockers). */
void build_world_mesh(void) {
    static float buf[(MW * MH * 36 + NUM_LOCKERS * 24 + MAX_KEYS * 32 + MAX_TORCHES * 72 + MAX_PROPS * 32 + 256) * 11];
    int n = 0;
    place_torches();
    /* walls: a face for every wall cell that borders an open cell */
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++) {
            if (is_open(x, y)) continue;
            /* +x neighbour open -> face on x+1 side facing -x, etc. World: (x, y_up, z=map y).
             * Tint each wall face by the room it faces into, so a room's walls
             * carry its colour. */
            if (is_open(x + 1, y)) { tint_for(theme_at(x+1,y)); float a[3]={x+1,0,y}, b[3]={x+1,0,y+1}, c[3]={x+1,1,y+1}, d[3]={x+1,1,y}; push_quad(buf,&n,a,b,c,d,-1,0,0,1); }
            if (is_open(x - 1, y)) { tint_for(theme_at(x-1,y)); float a[3]={x,0,y+1}, b[3]={x,0,y}, c[3]={x,1,y}, d[3]={x,1,y+1}; push_quad(buf,&n,a,b,c,d, 1,0,0,1); }
            if (is_open(x, y + 1)) { tint_for(theme_at(x,y+1)); float a[3]={x+1,0,y+1}, b[3]={x,0,y+1}, c[3]={x,1,y+1}, d[3]={x+1,1,y+1}; push_quad(buf,&n,a,b,c,d,0,0,-1,1); }
            if (is_open(x, y - 1)) { tint_for(theme_at(x,y-1)); float a[3]={x,0,y}, b[3]={x+1,0,y}, c[3]={x+1,1,y}, d[3]={x,1,y}; push_quad(buf,&n,a,b,c,d,0,0,1,1); }
        }
    wallCount = n;
    /* floor — tinted by the room the cell sits in */
    floorStart = n;
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++)
            if (is_open(x, y)) { tint_for(theme_at(x,y)); float a[3]={x,0,y}, b[3]={x+1,0,y}, c[3]={x+1,0,y+1}, d[3]={x,0,y+1}; push_quad(buf,&n,a,b,c,d,0,1,0,1); }
    floorCount = n - floorStart;
    /* ceiling — same zone colour */
    ceilStart = n;
    for (int y = 0; y < MH; y++)
        for (int x = 0; x < MW; x++)
            if (is_open(x, y)) { tint_for(theme_at(x,y)); float a[3]={x,1,y+1}, b[3]={x+1,1,y+1}, c[3]={x+1,1,y}, d[3]={x,1,y}; push_quad(buf,&n,a,b,c,d,0,-1,0,1); }
    ceilCount = n - ceilStart;
    /* locker cabinets + altar pedestals + the descent door (all iron/steel, untinted) */
    cur_tint[0] = cur_tint[1] = cur_tint[2] = 1.0f;
    lockStart = n;
    for (int i = 0; i < NUM_LOCKERS; i++)
        add_locker_box(buf, &n, lockers[i].x, lockers[i].y, lockWX[i], lockWY[i]);
    for (int i = 0; i < num_keys; i++)
        add_box2(buf, &n, pedX[i], pedZ[i], 0.17, 0.17, 0.0, 0.30);   /* shrine plinth */
    add_door(buf, &n, exitX, exitY, doorNx, keys_left > 0);
    lockCount = n - lockStart;
    /* wooden torch handles + room clutter (crates, shelves, debris) */
    brkStart = n;
    for (int i = 0; i < torch_count; i++)
        add_torch(buf, &n, torchX[i], torchZ[i], torchNx[i], torchNz[i]);
    for (int i = 0; i < prop_count; i++) {
        cur_tint[0] = props[i].tr; cur_tint[1] = props[i].tg; cur_tint[2] = props[i].tb;
        add_box2(buf, &n, props[i].x, props[i].z, props[i].hwx, props[i].hwz, props[i].y0, props[i].y1);
    }
    cur_tint[0] = cur_tint[1] = cur_tint[2] = 1.0f;
    brkCount = n - brkStart;

    glBindVertexArray_(worldVAO);
    glBindBuffer_(GL_ARRAY_BUFFER, worldVBO);
    glBufferData_(GL_ARRAY_BUFFER, n * 11 * sizeof(float), buf, GL_STATIC_DRAW);
}

/* upload the current maze walls into the R8 occlusion map texture */
void upload_map(void) {
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

/* re-skin the wall/floor/ceiling GL textures for the current biome (the CPU
 * pixels were just regenerated by build_textures for this floor). */
void reupload_world_textures(void) {
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texWall);  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, TEX, TEX, 0, GL_BGRA, GL_UNSIGNED_BYTE, tex[0]);
    glBindTexture(GL_TEXTURE_2D, texFloor); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, TEX, TEX, 0, GL_BGRA, GL_UNSIGNED_BYTE, tex[1]);
    glBindTexture(GL_TEXTURE_2D, texCeil);  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, TEX, TEX, 0, GL_BGRA, GL_UNSIGNED_BYTE, tex[2]);
}

static void setup_attribs(void) {
    glVertexAttribPointer_(0, 3, GL_FLOAT, GL_FALSE, 11 * sizeof(float), (void*)0);
    glEnableVertexAttribArray_(0);
    glVertexAttribPointer_(1, 2, GL_FLOAT, GL_FALSE, 11 * sizeof(float), (void*)(3 * sizeof(float)));
    glEnableVertexAttribArray_(1);
    glVertexAttribPointer_(2, 3, GL_FLOAT, GL_FALSE, 11 * sizeof(float), (void*)(5 * sizeof(float)));
    glEnableVertexAttribArray_(2);
    glVertexAttribPointer_(3, 3, GL_FLOAT, GL_FALSE, 11 * sizeof(float), (void*)(8 * sizeof(float)));
    glEnableVertexAttribArray_(3);
}
void gl_init(void) {
    prog3d = link_prog(VSRC, FSRC);
    progOv = link_prog(OVS, OFS);
    progPost = link_prog(OVS, PFS);
    u_ovofs   = glGetUniformLocation_(progOv, "uOfs");
    up_tex    = glGetUniformLocation_(progPost, "uTex");
    up_scr    = glGetUniformLocation_(progPost, "uScreenSize");
    up_time   = glGetUniformLocation_(progPost, "uTime");
    up_aber   = glGetUniformLocation_(progPost, "uAber");
    up_grain  = glGetUniformLocation_(progPost, "uGrain");
    up_shake  = glGetUniformLocation_(progPost, "uShake");
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
    u_sprtint = glGetUniformLocation_(prog3d, "uSprTint");
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
    for (int i = 0; i < 11; i++) texSpr[i] = make_texture(spr_rgba[i]);
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

/* a vertical quad centred at (wx,wz) with an explicit horizontal right vector
 * (rx,rz); used both for camera-facing billboards and wall-flat sprites.    */
static void draw_sprite_dir(double wx, double wz, double rx, double rz,
                            double w, double h, double base, int type, float mvp[16]) {
    float hx = (float)(rx * w * 0.5), hz = (float)(rz * w * 0.5);
    float y0 = (float)base, y1 = (float)(base + h);
    float cx = (float)wx, cz = (float)wz;
    cur_tint[0] = cur_tint[1] = cur_tint[2] = 1.0f;   /* sprites are never tinted */
    float buf[6 * 11]; int n = 0;
    push_v(buf, &n, cx - hx, y0, cz - hz, 0, 1, 0, 0, 0);
    push_v(buf, &n, cx + hx, y0, cz + hz, 1, 1, 0, 0, 0);
    push_v(buf, &n, cx + hx, y1, cz + hz, 1, 0, 0, 0, 0);
    push_v(buf, &n, cx - hx, y0, cz - hz, 0, 1, 0, 0, 0);
    push_v(buf, &n, cx + hx, y1, cz + hz, 1, 0, 0, 0, 0);
    push_v(buf, &n, cx - hx, y1, cz - hz, 0, 0, 0, 0, 0);
    glBindVertexArray_(sprVAO);
    glBindBuffer_(GL_ARRAY_BUFFER, sprVBO);
    glBufferData_(GL_ARRAY_BUFFER, n * 11 * sizeof(float), buf, GL_DYNAMIC_DRAW);
    glUniformMatrix4fv_(u_mvp, 1, GL_FALSE, mvp);
    glUniform1i_(u_mode, 1);
    glUniform3f_(u_sprtint, spr_tint[0], spr_tint[1], spr_tint[2]);
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texSpr[type]);
    glDrawArrays(GL_TRIANGLES, 0, 6);
}
static void draw_billboard(double wx, double wz, double w, double h, double base, int type, float mvp[16]) {
    draw_sprite_dir(wx, wz, -sin(yaw), cos(yaw), w, h, base, type, mvp);   /* face the camera */
}

/* All the flame billboards (torches + altar candles) share one texture and
 * additive blend, and their draw order doesn't matter — so batch every quad
 * into a single buffer and issue ONE draw call instead of ~50+ per frame. */
#define MOTES_PER_TORCH 5
/* sized for the largest single additive batch: torch/candle flames, OR the
 * dust motes (MOTES_PER_TORCH per torch), whichever needs more quads. */
static float flamebuf[(MAX_TORCHES * MOTES_PER_TORCH + MAX_KEYS * 2) * 6 * 11];
static int   flamen = 0;
static void flame_quad(double wx, double wz, double w, double h, double base) {
    double rx = -sin(yaw), rz = cos(yaw);
    float hx = (float)(rx * w * 0.5), hz = (float)(rz * w * 0.5);
    float y0 = (float)base, y1 = (float)(base + h), cx = (float)wx, cz = (float)wz;
    cur_tint[0] = cur_tint[1] = cur_tint[2] = 1.0f;
    push_v(flamebuf, &flamen, cx - hx, y0, cz - hz, 0, 1, 0, 0, 0);
    push_v(flamebuf, &flamen, cx + hx, y0, cz + hz, 1, 1, 0, 0, 0);
    push_v(flamebuf, &flamen, cx + hx, y1, cz + hz, 1, 0, 0, 0, 0);
    push_v(flamebuf, &flamen, cx - hx, y0, cz - hz, 0, 1, 0, 0, 0);
    push_v(flamebuf, &flamen, cx + hx, y1, cz + hz, 1, 0, 0, 0, 0);
    push_v(flamebuf, &flamen, cx - hx, y1, cz - hz, 0, 0, 0, 0, 0);
}
static void flush_flames(float mvp[16], GLuint tex) {
    if (flamen == 0) return;
    glBindVertexArray_(sprVAO);
    glBindBuffer_(GL_ARRAY_BUFFER, sprVBO);
    glBufferData_(GL_ARRAY_BUFFER, flamen * 11 * sizeof(float), flamebuf, GL_DYNAMIC_DRAW);
    glUniformMatrix4fv_(u_mvp, 1, GL_FALSE, mvp);
    glUniform1i_(u_mode, 1);
    glUniform3f_(u_sprtint, 1.0f, 1.0f, 1.0f);            /* glows are never tinted */
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glDrawArrays(GL_TRIANGLES, 0, flamen);
    flamen = 0;
}

/* (re)allocate the offscreen scene buffer when the target size changes */
static void ensure_fbo(int w, int h) {
    if (w == fboW && h == fboH && sceneFBO) return;
    if (!sceneFBO) { glGenFramebuffers_(1, &sceneFBO); glGenTextures(1, &sceneTex); glGenRenderbuffers_(1, &sceneDepth); }
    glBindFramebuffer_(GL_FRAMEBUFFER, sceneFBO);
    glBindTexture(GL_TEXTURE_2D, sceneTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, w, h, 0, GL_RGB, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glFramebufferTexture2D_(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sceneTex, 0);
    glBindRenderbuffer_(GL_RENDERBUFFER, sceneDepth);
    glRenderbufferStorage_(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
    glFramebufferRenderbuffer_(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, sceneDepth);
    glActiveTexture_(GL_TEXTURE0);
    fboW = w; fboH = h;
}

void render_3d(void) {
    /* cap the internal render resolution so fragment cost is bounded even at
     * fullscreen; the result is upscaled to the window afterward.           */
    rndW = winW; rndH = winH;
    if (rndW > render_cap_w) { rndH = (int)((long)rndH * render_cap_w / rndW); rndW = render_cap_w; }
    if (rndH < 1) rndH = 1;
    ensure_fbo(rndW, rndH);
    glBindFramebuffer_(GL_FRAMEBUFFER, sceneFBO);
    glViewport(0, 0, rndW, rndH);
    glEnable(GL_DEPTH_TEST);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    float dxc, dyc, dzc; cam_dir(&dxc, &dyc, &dzc);
    /* head bob: bounce the eye height and sway it side to side along the view-right */
    float rgx = (float)-sin(yaw), rgz = (float)cos(yaw);
    float ex = (float)(posX + rgx * bobLat), ey = (float)(0.5 + bobY), ez = (float)(posY + rgz * bobLat);
    float proj[16], view[16], mvp[16];
    mat_perspective(proj, 1.30f, (float)rndW / rndH, 0.05f, 40.0f);
    mat_lookat(view, ex, ey, ez, ex + dxc, ey + dyc, ez + dzc, 0, 1, 0);
    mat_mul(mvp, proj, view);

    glUseProgram_(prog3d);
    glUniformMatrix4fv_(u_mvp, 1, GL_FALSE, mvp);
    glUniform3f_(u_campos, ex, ey, ez);
    glUniform3f_(u_camdir, dxc, dyc, dzc);
    glUniform1f_(u_amb, (float)AMBIENT);
    /* deeper floors press in closer: fog thickens; the biome sets the ambient
     * colour, and it dims a little with depth. A frayed mind (low sanity)
     * closes your sight the same way.                                       */
    double dd = (depth - 1) < 12 ? (depth - 1) : 12;
    double dread_fog = 1.0 - sanity;
    double ad = 1.0 - 0.02 * dd;                        /* deeper = a touch darker */
    glUniform1f_(u_fogk, (float)(FOG_K * (1.0 + 0.08 * dd) * (1.0 + 0.35 * dread_fog)));
    glUniform1f_(u_flick, (float)flicker);
    glUniform3f_(u_ambtint, (float)(biome_amb[0] * ad), (float)(biome_amb[1] * ad), (float)(biome_amb[2] * ad));
    glUniform2f_(u_scrsize, (float)rndW, (float)rndH);

    /* torch point lights: only the nearest few to the camera are sent to the
     * shader each frame. Distant torches contribute nothing visible (fog eats
     * them) but every extra light multiplies the per-pixel ray-march cost, so
     * culling here is what keeps the fragment shader affordable -- especially
     * at fullscreen, where the pixel count balloons.                        */
#define MAX_ACTIVE_TORCHES 20
#define TORCH_CULL_R 15.0f
    static float tp[MAX_ACTIVE_TORCHES * 3], ti[MAX_ACTIVE_TORCHES];
    static float cd[MAX_TORCHES]; static int ci[MAX_TORCHES];
    int nc = 0;
    for (int i = 0; i < torch_count; i++) {
        float lx = torchX[i] + torchNx[i] * TORCH_REACH, lz = torchZ[i] + torchNz[i] * TORCH_REACH;
        float d2 = (lx - ex) * (lx - ex) + (lz - ez) * (lz - ez);
        if (d2 > TORCH_CULL_R * TORCH_CULL_R) continue;
        cd[nc] = d2; ci[nc] = i; nc++;
    }
    /* partial insertion sort: bubble the nearest toward the front */
    for (int a = 0; a < nc && a < MAX_ACTIVE_TORCHES; a++)
        for (int b = a + 1; b < nc; b++)
            if (cd[b] < cd[a]) { float td = cd[a]; cd[a] = cd[b]; cd[b] = td; int ti2 = ci[a]; ci[a] = ci[b]; ci[b] = ti2; }
    int active = 0;
    /* shrine candles are real lights too, and they take priority — so a key
     * room glows warm the moment it's on screen (not just colour-tinted). */
    for (int i = 0; i < num_keys && active < MAX_ACTIVE_TORCHES; i++) {
        if (!keys[i].active) continue;
        float lx = (float)keys[i].x, lz = (float)keys[i].y;
        float d2 = (lx - ex) * (lx - ex) + (lz - ez) * (lz - ez);
        if (d2 > TORCH_CULL_R * TORCH_CULL_R) continue;
        tp[active * 3] = lx; tp[active * 3 + 1] = 0.55f; tp[active * 3 + 2] = lz;
        double f = 0.85 + 0.10 * sin(state_time * 5.0 + i * 2.0);
        ti[active] = (float)(f * 1.05 * flicker);            /* softer than a torch */
        active++;
    }
    /* a struck match is a bright little light right in your hand */
    if (match_burn > 0.0 && active < MAX_ACTIVE_TORCHES) {
        double f = 0.85 + 0.12 * sin(state_time * 30.0);         /* nervous flicker */
        double fade = match_burn < 1.0 ? match_burn : 1.0;       /* gutters out at the end */
        tp[active * 3] = ex; tp[active * 3 + 1] = ey; tp[active * 3 + 2] = ez;
        ti[active] = (float)(f * 1.8 * fade * flicker);
        active++;
    }
    /* then the nearest wall torches fill whatever slots remain */
    for (int k = 0; k < nc && active < MAX_ACTIVE_TORCHES; k++) {
        int i = ci[k];
        /* the light lives at the flame -- the handle tip, out in the room. */
        tp[active * 3] = torchX[i] + torchNx[i] * TORCH_REACH; tp[active * 3 + 1] = TORCH_Y; tp[active * 3 + 2] = torchZ[i] + torchNz[i] * TORCH_REACH;
        double f = 1.15 + 0.22 * sin(state_time * 7.0 + i * 1.7) + (frand() - 0.5) * 0.12;
        ti[active] = (float)(f * 1.5 * flicker);
        active++;
    }
    glUniform1i_(u_tcount, active);
    if (active > 0) {
        glUniform3fv_(u_tpos, active, tp);
        glUniform1fv_(u_tint, active, ti);
    }
    glUniform3f_(u_tcol, biome_torch[0], biome_torch[1], biome_torch[2]);
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
        /* The Stalker: tall & gaunt, filling the corridor height, with a slow
         * uneasy sway and bob so it never reads as a static post. When it has
         * your scent and closes in it rears up — looming bigger as it lunges. */
        double sway = 0.03 * sin(state_time * 1.7);
        double bob  = 0.02 * sin(state_time * 2.3);
        double pd   = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
        double loom = 1.0;
        if (mon_state == AI_HUNT && pd < 5.0) loom = 1.0 + (5.0 - pd) / 5.0 * 0.35;
        if (mon_state == AI_HUNT && mon_type != MON_WATCHER) { bob *= 2.2; sway *= 1.6; } /* twitchier when hunting */
        if (mon_type == MON_WATCHER) { sway = 0; bob = 0; }     /* it stands unnervingly still */
        /* each horror wears its own pallor */
        if      (mon_type == MON_LISTENER) { spr_tint[0]=0.82f; spr_tint[1]=0.88f; spr_tint[2]=0.98f; } /* ashen grey */
        else if (mon_type == MON_WATCHER)  { spr_tint[0]=0.55f; spr_tint[1]=0.85f; spr_tint[2]=1.35f; } /* cold corpse-blue */
        double mh = (mon_type == MON_WATCHER) ? 1.12 : 1.06;    /* the Watcher looms taller */
        draw_billboard(monX - sin(yaw) * sway, monY + cos(yaw) * sway,
                       0.72 * loom, (mh + bob) * loom, 0.0, 0, mvp);
        spr_tint[0] = spr_tint[1] = spr_tint[2] = 1.0f;         /* reset for other sprites */
    }
    /* the hallucinated Stalker: flickers in and out where it isn't really */
    if (phantom_t > 0.0 && ((int)(state_time * 22) % 3) != 0)
        draw_billboard(phantomX, phantomY, 0.66, 0.99, 0.0, 0, mvp);
    /* each key is locked inside a chest squatting on the floor */
    for (int i = 0; i < num_keys; i++)
        if (keys[i].active) draw_billboard(keys[i].x, keys[i].y, 0.44, 0.42, 0.0, 7, mvp);
    /* scattered matchboxes bob just off the floor */
    for (int i = 0; i < MAX_MATCHPICK; i++)
        if (matchpick[i].active)
            draw_billboard(matchpick[i].x, matchpick[i].y, 0.17, 0.17, 0.04 + 0.02 * sin(state_time * 2.0 + i), 9, mvp);
    /* scattered rock pickups, and a rock currently arcing through the air */
    for (int i = 0; i < MAX_ROCKPICK; i++)
        if (rockpick[i].active)
            draw_billboard(rockpick[i].x, rockpick[i].y, 0.15, 0.13, 0.02, 10, mvp);
    if (rockFlyT > 0.0) {
        double p = 1.0 - rockFlyT / ROCK_FLY_DUR;              /* 0 at throw .. 1 at impact */
        double fx = rockFX0 + (rockTX - rockFX0) * p, fz = rockFY0 + (rockTY - rockFY0) * p;
        double arc = sin(p * 3.14159265) * 0.45;               /* rises then falls */
        draw_billboard(fx, fz, 0.14, 0.14, 0.35 + arc, 10, mvp);
    }
    for (int i = 0; i < NUM_NOTES; i++)
        if (notes[i].active) {
            /* pinned flat to the wall: sit on the wall face, tangent along it */
            double px = notes[i].x + noteWX[i] * 0.44, pz = notes[i].y + noteWY[i] * 0.44;
            draw_sprite_dir(px, pz, -noteWY[i], noteWX[i], 0.34, 0.40, 0.34, 5, mvp);
        }
    if (has_up) draw_billboard(upX, upY, 0.95, 0.95, 0.02, 6, mvp);  /* stairs up   */

    /* additive glows: torch flames, and the door's portal light once open */
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glDepthMask(GL_FALSE);
    /* the open doorway breathes a soft green light you're drawn toward */
    if (keys_left == 0) {
        double pulse = 0.6 + 0.22 * sin(state_time * 2.4);
        if (descend_t > 0) pulse = 1.1;                 /* flares as you step through */
        draw_billboard(exitX, exitY, 0.34 * pulse, 0.62 * pulse, 0.06, 2, mvp);
    }
    /* altar candles flank each still-locked chest — a warm pair of flames that
     * marks a shrine (and its key) from down the corridor. */
    for (int i = 0; i < num_keys; i++) {
        if (!keys[i].active) continue;
        double fl = 0.85 + 0.15 * sin(state_time * 6.0 + i * 4.0) + (frand() - 0.5) * 0.06;
        for (int s = -1; s <= 1; s += 2) {
            double cxp = keys[i].x + s * 0.36, czp = keys[i].y + 0.30;
            flame_quad(cxp, czp, 0.085 * fl, 0.16 * fl, 0.30);
        }
    }
    for (int i = 0; i < torch_count; i++) {
        double fl = 0.88 + 0.16 * sin(state_time * 9.0 + i * 2.1)
                         + 0.05 * sin(state_time * 23.0 + i);        /* fast jitter */
        double s = 0.27 * fl;
        double fx = torchX[i] + torchNx[i] * TORCH_REACH;
        double fz = torchZ[i] + torchNz[i] * TORCH_REACH;
        double base = TORCH_TIP_Y - 0.02;
        flame_quad(fx, fz, s * 1.15, s * 1.7,  base);         /* tongue */
        flame_quad(fx, fz, s * 0.62, s * 1.05, base + 0.04);  /* core   */
    }
    flush_flames(mvp, texSpr[4]);                             /* one draw for every flame */

    /* dust motes: a few embers of dust drift and rise in each torch's glow.
     * Each mote's path is derived procedurally from the torch index + time, so
     * there is no per-frame state to keep -- it loops as it rises, swelling in
     * then shrinking away (the additive footprint IS the fade). Far torches are
     * skipped so the motes only clutter the space you're actually near.      */
    for (int i = 0; i < torch_count; i++) {
        double fx = torchX[i] + torchNx[i] * TORCH_REACH;
        double fz = torchZ[i] + torchNz[i] * TORCH_REACH;
        double ddx = fx - posX, ddz = fz - posY;
        if (ddx * ddx + ddz * ddz > 49.0) continue;           /* > 7 units: skip */
        double tang_x = torchNz[i], tang_z = -torchNx[i];     /* along the wall  */
        for (int m = 0; m < MOTES_PER_TORCH; m++) {
            double seed = i * 3.7 + m * 1.61803;
            double rise = 1.4 + 0.5 * sin(seed);              /* per-mote period */
            double p = fmod(state_time / rise + seed, 1.0);   /* 0 low .. 1 high */
            double env = sin(p * 3.14159);                    /* fade in/out env */
            double lat = 0.22 * sin(seed * 2.3 + state_time * 0.7 + p * 2.0);
            double fwd = 0.10 * sin(seed * 1.7 + state_time * 0.5);
            double mx = fx + tang_x * lat + torchNx[i] * fwd;
            double mz = fz + tang_z * lat + torchNz[i] * fwd;
            double my = TORCH_TIP_Y - 0.28 + p * 0.7;         /* rise past the flame */
            double sz = 0.028 * env;                          /* swell in, shrink out */
            flame_quad(mx, mz, sz, sz, my);
        }
    }
    flush_flames(mvp, texSpr[8]);                             /* one draw for every mote */
    glDepthMask(GL_TRUE);
    glDisable(GL_BLEND);
}

/* Dump the current back buffer to a binary PPM (for dev screenshots). */
void save_ppm(const char *path) {
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

/* upscale the offscreen 3D scene to the window through the post-process grade:
 * chromatic aberration + film grain + rolling scanline, with an optional
 * screen-shake that spikes on scares (chest screamer, hallucination flash) and
 * as a frayed mind bleeds the colour apart. Replaces the old raw blit. */
void present_scene(void) {
    glBindFramebuffer_(GL_FRAMEBUFFER, 0);          /* draw to the window, not the scene FBO */
    glViewport(0, 0, winW, winH);
    double scare = 0.0;
    if (screamer_t > 0.0) scare = fmax(scare, screamer_t / SCREAMER_DUR);
    if (vision_t   > 0.0) scare = fmax(scare, 0.6 * vision_t / VIS_DUR);
    double dread = 1.0 - sanity;
    double aber  = 0.0028 + 0.012 * dread + 0.055 * scare;   /* uv split at the edge */
    double grain = 0.045 + 0.10  * dread + 0.12  * scare;
    double smag  = 0.012 * scare;                            /* shake magnitude (uv) */
    float sx = (float)(smag * sin(state_time * 57.0));
    float sy = (float)(smag * cos(state_time * 43.0));
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glUseProgram_(progPost);
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, sceneTex);
    glUniform1i_(up_tex, 0);
    glUniform2f_(up_scr, (float)winW, (float)winH);
    glUniform1f_(up_time, (float)state_time);
    glUniform1f_(up_aber, (float)aber);
    glUniform1f_(up_grain, (float)grain);
    glUniform2f_(up_shake, sx, sy);
    glBindVertexArray_(ovVAO);
    glDrawArrays(GL_TRIANGLES, 0, 6);
}

void present_overlay(void) {
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram_(progOv);
    /* the catch jumpscare kicks the whole overlay for the first moments */
    float ox = 0.0f, oy = 0.0f;
    if (game_state == ST_CAUGHT && state_time < 0.6) {
        float k = (float)(0.05 * (0.6 - state_time) / 0.6);
        ox = k * sinf((float)state_time * 71.0f);
        oy = k * cosf((float)state_time * 53.0f);
    }
    glUniform2f_(u_ovofs, ox, oy);
    glActiveTexture_(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texOverlay);
    /* storage is allocated once in gl_init; just refresh the pixels each frame
     * (glTexSubImage2D avoids reallocating the texture every frame). */
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, SCREEN_W, SCREEN_H, GL_BGRA, GL_UNSIGNED_BYTE, fb);
    glBindVertexArray_(ovVAO);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glDisable(GL_BLEND);
}
