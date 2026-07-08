/*
 * NIGHTFALL — shared internal header.
 *
 * The engine is one program split across a few translation units by
 * responsibility (level generation, monster AI, audio, GL rendering, HUD/menus,
 * and main() itself). Gameplay state is genuinely shared between them -- the
 * player's position, the map, the monster, timers -- so this header declares
 * every cross-file global as `extern` and every cross-file function with a
 * prototype. Each global is *defined* (storage allocated) in exactly one .c
 * file; see the comment above each block below for which one.
 */
#ifndef NIGHTFALL_GAME_H
#define NIGHTFALL_GAME_H

#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <SDL2/SDL_opengl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <dirent.h>
#include <zlib.h>

/* ------------------------------------------------------------------ config */
#define SCREEN_W 1024
#define SCREEN_H 576
#define TEX      64

#define MW 29
#define MH 21
#define MAX_KEYS 6           /* array capacity; the live count scales with depth */
#define NUM_LOCKERS 5
#define NUM_NOTES 2
#define MAX_ROOMS 14
#define MAX_PILLARS 24
#define MAX_PROPS 150
#define MAX_TORCHES 48
#define MAX_MATCHPICK 4
#define MAX_ROCKPICK 4
#define MAX_VISIONS 24

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

#define MATCH_DUR     4.5   /* seconds one struck match burns */
#define VIS_DUR       0.5
#define SCREAMER_DUR  0.85

#define ROCK_FLY_DUR   0.35 /* seconds a thrown rock is airborne */
#define ROCK_MAX_RANGE 9.0  /* how far a throw can carry before it just drops */
#define ROCK_NOISE_TTL 5.0  /* how long the monster can still hear it land */

#define CH_CREAK  8              /* chest-lid creak on open   */
#define CH_SHRINE 9              /* looping shrine hum, volume by proximity */

/* ------------------------------------------------------------------- enums */
enum { ST_TITLE, ST_PLAY, ST_CAUGHT, ST_WIN, ST_READING, ST_PAUSED };
enum { AI_HUNT, AI_SEARCH, AI_WANDER };
/* the floor's horror. Each plays differently:
 *   STALKER  — hunts by sight and sound, lunges up close (floors 1-3)
 *   LISTENER — blind; homes on any footstep, so freeze when it's near (4+)
 *   WATCHER  — only moves while unwatched, then rushes; silent (7+)          */
enum { MON_STALKER, MON_LISTENER, MON_WATCHER };
/* the floor is built from themed rectangular rooms joined by corridors,
 * instead of a featureless maze. Each room's theme decides what it holds. */
enum { RM_ENTRANCE, RM_KEY, RM_STORAGE, RM_LIBRARY, RM_HALL, RM_EXIT, RM_CELLS };

/* ---------------------------------------------------------------- typedefs */
typedef struct { double x, y; int active; } Key;   /* active = chest still locked */
typedef struct { double x, y; } Locker;
typedef struct { double x, y; int active, text; } Note;
typedef struct { double x, y; int active; } MatchPick;
typedef struct { double x, y; int active; } RockPick;
typedef struct { int x, y, w, h, theme; } Room;
/* clutter that gives each room type its own character: crates, barrels,
 * book spines, bones, rubble. tr/tg/tb tints the box so a prop reads as its
 * material (via the world mesh's per-vertex tint). */
typedef struct { double x, z, hwx, hwz, y0, y1; float tr, tg, tb; } Prop;
/* Biomes: every floor wears a different palette, light colour and name, so
 * descending feels like passing through distinct places. */
typedef struct { const char *name; float wall[3], floor[3], ceil[3], amb[3], torch[3]; } Biome;
/* Hallucination images the player drops into assets/visions/ — flashed on
 * screen as sanity collapses. */
typedef struct { int w, h; unsigned char *px; } Vision;   /* RGBA bytes */

#define NBIOMES 6
#define NOTE_POOL 14   /* keep in sync with the NOTES table's row count in gen.c */

/* =========================================================================
 * main.c — owns core play state: player, map, level layout results, keys/
 * lockers/notes/matches, timers, and the small dependency-free utilities.
 * ========================================================================= */
extern double sens_mult;         /* mouse-look sensitivity multiplier   */
extern int    master_vol;        /* master audio volume 0..128          */
extern int    pause_sel;         /* highlighted row in the pause menu    */

extern char   map[MH][MW + 1];
extern double posX, posY;
extern double velX, velY;
extern double bob_phase;
extern double bobY, bobLat;
extern double yaw, pitch;
extern double monX, monY;
extern int    gdist[MH][MW];
extern double stamina;
extern int    exhausted;
extern int    hidden;
extern double sanity;

extern int    game_state;
extern double state_time;
extern double tension, flicker;

extern Key    keys[MAX_KEYS];
extern int    num_keys;
extern int    keys_left;
extern int    near_chest;
extern double exitX, exitY;
extern double doorNx, doorNz;
extern double descend_t;
extern int    descend_done;

extern Locker lockers[NUM_LOCKERS];
extern int    near_locker;

extern Note   notes[NUM_NOTES];
extern double noteWX[NUM_NOTES], noteWY[NUM_NOTES];
extern int    reading_note;
extern int    near_note;

extern MatchPick matchpick[MAX_MATCHPICK];
extern int    match_count;
extern double match_burn;

/* rocks: pocket a few off the floor, throw one (facing direction) to make it
 * strike stone somewhere down the corridor -- a deliberate lure the monster
 * will go and investigate, away from you. */
extern RockPick rockpick[MAX_ROCKPICK];
extern int    rock_count;
extern double rockFlyT;                       /* >0 while a thrown rock is airborne */
extern double rockFX0, rockFY0;                /* where it was thrown from          */
extern double rockTX, rockTY;                  /* where it will land                */

extern int    depth;
extern int    best_depth;
extern double mon_speed;
extern double upX, upY;
extern int    has_up;

extern Room   rooms[MAX_ROOMS];
extern int    room_count;
extern int    startX, startY;
extern int    pcellX[MAX_PILLARS], pcellY[MAX_PILLARS];
extern int    pillar_count;
extern double pedX[MAX_KEYS], pedZ[MAX_KEYS];

extern Prop   props[MAX_PROPS];
extern int    prop_count;

/* dependency-free helpers, usable from every module */
int      clamp8(int v);
uint32_t packa(int r, int g, int b, int a);
uint32_t pack(int r, int g, int b);
double   frand(void);

/* =========================================================================
 * gen.c — level generation: rooms, biome palette, pathing queries, level
 * reset, and level-object interactions (opening a chest).
 * ========================================================================= */
extern const Biome BIOMES[NBIOMES];
extern const char *NOTES[NOTE_POOL][6];
extern int   biome;
extern float bwall[3], bfloor[3], bceil[3];
extern float biome_amb[3], biome_torch[3];

int  is_open(int x, int y);
int  has_los(double ax, double ay, double bx, double by);
void set_target(int cx, int cy);
void pick_wander(void);
void new_game(void);
void open_chest(int i);

/* =========================================================================
 * ai.c — the monster's brain and the sanity/dread system.
 * ========================================================================= */
extern int    mon_sees;
extern double phantomX, phantomY;
extern double phantom_t;
extern double phantom_timer;
extern double whisper_timer, event_timer, surge;
extern int    mon_state;
extern int    tgtX, tgtY;
extern double lastKnownX, lastKnownY;
extern double hunt_recalc, search_time;
extern double noiseX, noiseY, noise_t;
extern int    mon_type;
extern double reveal_t;
extern double growl_timer;

void make_noise(double x, double y, double ttl);
void update_ai(double dt, int moving, int sprinting);
void update_fear(double dt);

/* =========================================================================
 * audio.c — procedural sound effects and the dread-driven mix.
 * ========================================================================= */
extern Mix_Chunk *snd_ambient, *snd_heart, *snd_scare, *snd_pickup, *snd_step, *snd_whisper;
extern Mix_Chunk *snd_roar, *snd_growl, *snd_creak, *snd_shrine, *snd_thud;
extern double heart_timer, step_timer;

void apply_master_volume(void);
void update_audio(double dt, int moving);

/* =========================================================================
 * render.c — GL setup, procedural textures/sprites, the world mesh, and the
 * 3D + post-process render passes.
 * ========================================================================= */
extern uint32_t tex[3][TEX * TEX];         /* 0 wall, 1 floor, 2 ceiling     */
extern uint32_t lockmetal[TEX * TEX];
extern uint32_t brackmetal[TEX * TEX];
extern uint32_t spr_rgba[11][TEX * TEX];

extern float torchX[MAX_TORCHES], torchZ[MAX_TORCHES];
extern float torchNx[MAX_TORCHES], torchNz[MAX_TORCHES];
extern int   torch_count;

extern double lockWX[NUM_LOCKERS], lockWY[NUM_LOCKERS];

extern int   occl_on;
extern int   winW, winH;
extern int   render_cap_w;

void load_gl(void);
void build_textures(void);
void build_sprites(void);
void gl_init(void);
void reupload_world_textures(void);
void build_world_mesh(void);
void upload_map(void);
void render_3d(void);
void present_scene(void);
void present_overlay(void);
void save_ppm(const char *path);

/* =========================================================================
 * hud.c — the 2D software overlay: font/text, menus, HUD, hallucinations.
 * ========================================================================= */
extern uint32_t fb[SCREEN_W * SCREEN_H];   /* 2D overlay buffer, ARGB */

extern Vision visions[MAX_VISIONS];
extern int    nvisions;
extern double vision_t, vision_timer;
extern int    vision_idx;
extern double screamer_t;
extern int    screamer_idx;

void load_visions(void);
void ov_clear(void);
void draw_title(void);
void draw_jumpscare(void);
void draw_hud(void);
void draw_note(void);
void draw_pause(void);
void draw_hidden_overlay(void);
void draw_sanity_fx(void);
void draw_vision(void);
void draw_screamer(void);

#endif
