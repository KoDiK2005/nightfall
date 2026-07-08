/*
 * NIGHTFALL — a first-person horror game for Linux (real-3D OpenGL build).
 *
 * The maze is genuine 3D geometry rendered through an OpenGL 3.3 core
 * pipeline: textured wall/floor/ceiling quads, a perspective camera with
 * free mouse-look (yaw AND pitch), a fragment-shader torchlight + fog, and
 * camera-facing billboards for the Stalker, keys, exit and lockers.
 *
 * The engine is split across a few files by responsibility:
 *   game.h    shared types, extern globals, cross-file prototypes
 *   gen.c     level generation: rooms, biomes, pathing, chests
 *   ai.c      the monster's brain and the sanity/dread system
 *   audio.c   procedural dread audio
 *   render.c  GL setup, textures/sprites, the world mesh, the render passes
 *   hud.c     the 2D software overlay: font, HUD, menus, hallucinations
 *   main.c    this file: window/audio setup, the event loop, player input
 *
 * Build:  make            (needs SDL2 + SDL2_mixer + OpenGL)
 * Run:    ./nightfall
 * Classic raycaster fallback:  make run-classic
 *
 * Controls:  W/A/S/D move   Mouse look   Shift run   E hide   F match   Esc quit
 */
#include "game.h"

/* -------------------------------------------------------------- game state */
double sens_mult = 1.0;          /* mouse-look sensitivity multiplier   */
int    master_vol = 100;         /* master audio volume 0..128          */
int    pause_sel = 0;            /* highlighted row in the pause menu    */
double log_copy_flash = 0.0;     /* >0 while the pause menu shows a copy result */
int    log_copy_ok = 0;

char   map[MH][MW + 1];
double posX, posY;               /* position on the floor plane       */
double velX = 0.0, velY = 0.0;   /* smoothed movement velocity        */
double bob_phase = 0.0;          /* advances with distance walked     */
double bobY = 0.0, bobLat = 0.0; /* head-bob camera offsets           */
double yaw = 0.0, pitch = 0.0;   /* look direction                    */
double monX, monY;
int    gdist[MH][MW];
double stamina = 1.0;
int    exhausted = 0;
int    hidden = 0;
double sanity = 1.0;

int    game_state = ST_TITLE;
double state_time = 0.0;
double tension = 0.0, flicker = 1.0;

Key    keys[MAX_KEYS];
int    num_keys = 3;             /* keys required on this floor (grows w/ depth) */
int    keys_left;
int    near_chest = -1;          /* index of an openable chest within reach */
double exitX, exitY;
double doorNx = 1, doorNz = 0;   /* the exit door's facing (axis-snapped) */
double descend_t = 0.0;          /* >0 while the descent transition plays  */
int    descend_done = 0;         /* floor already swapped mid-transition   */

Locker lockers[NUM_LOCKERS];
int    near_locker = -1;

Note   notes[NUM_NOTES];
double noteWX[NUM_NOTES], noteWY[NUM_NOTES];   /* dir from cell to backing wall */
int    reading_note = 0;         /* which lore note is on screen       */
int    near_note = -1;           /* index of a readable note within reach */

/* matches: a scarce light you can strike. It lets you see -- but the glow
 * gives you away, so the Stalker spots you from much farther. A light-vs-hide
 * gamble. (The blind Listener doesn't care about light, so it's safe there.) */
MatchPick matchpick[MAX_MATCHPICK];
int    match_count = 0;          /* matches in your pocket             */
double match_burn  = 0.0;        /* seconds the struck match still burns */

RockPick rockpick[MAX_ROCKPICK];
int    rock_count = 0;
double rockFlyT = 0.0;
double rockFX0, rockFY0, rockTX, rockTY;

int    depth = 1;                /* current floor (1 = topmost)        */
int    best_depth = 1;           /* deepest floor reached this session */
double mon_speed = MONSTER_SPD;  /* scales with depth                  */
double upX, upY;                 /* stairs back up (only when depth>1) */
int    has_up = 0;

Room   rooms[MAX_ROOMS];
int    room_count = 0;
int    startX, startY;           /* player spawn cell (entrance room)  */
int    pcellX[MAX_PILLARS], pcellY[MAX_PILLARS];   /* pillar candidates  */
int    pillar_count = 0;
double pedX[MAX_KEYS], pedZ[MAX_KEYS];             /* altar pedestals    */

Prop   props[MAX_PROPS];
int    prop_count = 0;

/* --------------------------------------------------------------- utilities */
int clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
uint32_t packa(int r, int g, int b, int a) {
    return ((uint32_t)clamp8(a) << 24) | (clamp8(r) << 16) | (clamp8(g) << 8) | clamp8(b);
}
uint32_t pack(int r, int g, int b) { return packa(r, g, b, 255); }
double frand(void) { return rand() / (double)RAND_MAX; }

/* ------------------------------------------------------------------ physics */
static void try_move(double nx, double ny, double r) {
    if (is_open((int)(nx + (nx > posX ? r : -r)), (int)posY)) posX = nx;
    if (is_open((int)posX, (int)(ny + (ny > posY ? r : -r)))) posY = ny;
}

/* -------------------------------------------------------------------- main */
int main(int argc, char **argv) {
    (void)argc; (void)argv;
    unsigned seed = getenv("NIGHTFALL_SEED") ? (unsigned)atoi(getenv("NIGHTFALL_SEED")) : (unsigned)time(NULL);
    srand(seed);
    nf_log_init();
    nf_log("NIGHTFALL start, seed=%u", seed);
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
    nf_log_hw(win);

    if (Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 1024) < 0) {
        fprintf(stderr, "audio disabled: %s\n", Mix_GetError());
        nf_log("audio disabled: %s", Mix_GetError());
    }
    Mix_AllocateChannels(10);                     /* 0-7 in use; 8 creak, 9 shrine hum */
    snd_ambient = Mix_LoadWAV("assets/ambient.wav");
    snd_heart   = Mix_LoadWAV("assets/heartbeat.wav");
    snd_scare   = Mix_LoadWAV("assets/scare.wav");
    snd_pickup  = Mix_LoadWAV("assets/pickup.wav");
    snd_step    = Mix_LoadWAV("assets/step.wav");
    snd_whisper = Mix_LoadWAV("assets/whisper.wav");
    snd_roar    = Mix_LoadWAV("assets/roar.wav");
    snd_growl   = Mix_LoadWAV("assets/growl.wav");
    snd_creak   = Mix_LoadWAV("assets/creak.wav");
    snd_shrine  = Mix_LoadWAV("assets/shrine.wav");
    snd_thud    = Mix_LoadWAV("assets/thud.wav");
    if (!snd_ambient) { fprintf(stderr, "warning: assets not found — run 'make audio'\n"); nf_log("warning: assets not found -- run 'make audio'"); }
    if (snd_ambient) { Mix_Volume(0, 60); Mix_PlayChannel(0, snd_ambient, -1); }
    apply_master_volume();

    build_textures();
    build_sprites();
    gl_init();
    load_visions();
    if (getenv("NIGHTFALL_DEPTH")) depth = atoi(getenv("NIGHTFALL_DEPTH"));
    if (getenv("NIGHTFALL_RCAP")) { render_cap_w = atoi(getenv("NIGHTFALL_RCAP")); if (render_cap_w < 320) render_cap_w = 320; }
    new_game();
    if (getenv("NIGHTFALL_LIGHT")) { match_count = 5; match_burn = MATCH_DUR; }  /* start with a lit match */
    if (getenv("NIGHTFALL_SANITY")) sanity = atof(getenv("NIGHTFALL_SANITY"));
    if (getenv("NIGHTFALL_DUMPMAP")) {
        const char *tn[] = {"entrance","key","storage","library","hall","exit","cells"};
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
                else for (int k = 0; k < num_keys; k++) if ((int)keys[k].x == x && (int)keys[k].y == y) c = 'K';
                line[x] = c;
            }
            line[MW] = 0;
            fprintf(stderr, "%s\n", line);
        }
    }

    SDL_SetRelativeMouseMode(SDL_TRUE);
    const char *shotpath = getenv("NIGHTFALL_SHOT");
    int shot_frame = 0;
    if ((getenv("NIGHTFALL_AUTOPLAY") || shotpath) && !getenv("NIGHTFALL_SHOTTITLE")) { game_state = ST_PLAY; state_time = 0; }
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
        if (getenv("NIGHTFALL_SHOWEXIT")) {            /* stand back from the door */
            if (getenv("NIGHTFALL_OPENDOOR")) { keys_left = 0; build_world_mesh(); }
            double dx = doorNx, dz = doorNz;
            for (double s = 2.5; s >= 1.5; s -= 0.5) {
                double px = exitX + dx * s, pz = exitY + dz * s;
                if (is_open((int)px, (int)pz)) { posX = px; posY = pz;
                    yaw = atan2(exitY - pz, exitX - px); pitch = -0.02; }
            }
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
        if (getenv("NIGHTFALL_SHOWMATCH") && matchpick[0].active) {  /* dev: face a matchbox pickup */
            double tx = matchpick[0].x, tz = matchpick[0].y;
            for (double s = 1.6; s >= 1.0; s -= 0.3)
                for (int d = 0; d < 4; d++) {
                    double ox = (d==0)-(d==1), oz = (d==2)-(d==3);
                    double px = tx + ox * s, pz = tz + oz * s;
                    if (is_open((int)px, (int)pz)) { posX = px; posY = pz;
                        yaw = atan2(tz - pz, tx - px); pitch = -0.1; }
                }
        }
        if (getenv("NIGHTFALL_SHOWROCK") && rockpick[0].active) {  /* dev: face a rock pickup */
            double tx = rockpick[0].x, tz = rockpick[0].y;
            for (double s = 1.6; s >= 1.0; s -= 0.3)
                for (int d = 0; d < 4; d++) {
                    double ox = (d==0)-(d==1), oz = (d==2)-(d==3);
                    double px = tx + ox * s, pz = tz + oz * s;
                    if (is_open((int)px, (int)pz)) { posX = px; posY = pz;
                        yaw = atan2(tz - pz, tx - px); pitch = -0.1; }
                }
        }
        if (getenv("NIGHTFALL_SHOWPROP") && prop_count > 0) {   /* face room clutter */
            int pi = atoi(getenv("NIGHTFALL_SHOWPROP"));
            if (pi < 0 || pi >= prop_count) pi = 0;
            double tx = props[pi].x, tz = props[pi].z;
            for (double s = 2.5; s >= 1.5; s -= 0.5)
                for (int d = 0; d < 4; d++) {
                    double ox = (d==0)-(d==1), oz = (d==2)-(d==3);
                    double px = tx + ox * s, pz = tz + oz * s;
                    if (is_open((int)px, (int)pz)) { posX = px; posY = pz;
                        yaw = atan2(tz - pz, tx - px); pitch = -0.05; }
                }
        }
        if (getenv("NIGHTFALL_SHOWWNOTE")) {           /* face a wall-pinned note */
            double nx = notes[0].x, nz = notes[0].y;
            double bx2 = nx - noteWX[0] * 1.6, bz2 = nz - noteWY[0] * 1.6;   /* step into the room */
            if (is_open((int)bx2, (int)bz2)) { posX = bx2; posY = bz2; }
            yaw = atan2(noteWY[0], noteWX[0]); pitch = -0.02;
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
        if (log_copy_flash > 0) log_copy_flash -= dt;

        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            if (e.type == SDL_WINDOWEVENT &&
                (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED || e.window.event == SDL_WINDOWEVENT_RESIZED)) {
                SDL_GL_GetDrawableSize(win, &winW, &winH);
            }
            if (e.type == SDL_KEYDOWN) {
                SDL_Scancode k = e.key.keysym.scancode;
                if (k == SDL_SCANCODE_ESCAPE) {
                    if (game_state == ST_PLAY)   { game_state = ST_PAUSED; pause_sel = 0; SDL_SetRelativeMouseMode(SDL_FALSE); }
                    else if (game_state == ST_PAUSED) { game_state = ST_PLAY; SDL_SetRelativeMouseMode(SDL_TRUE); }
                    else running = 0;
                }
                /* pause-menu controls */
                if (game_state == ST_PAUSED) {
                    if (k == SDL_SCANCODE_W || k == SDL_SCANCODE_UP)   pause_sel = (pause_sel + 1) % 2;
                    if (k == SDL_SCANCODE_S || k == SDL_SCANCODE_DOWN) pause_sel = (pause_sel + 1) % 2;
                    int dir = (k == SDL_SCANCODE_D || k == SDL_SCANCODE_RIGHT) ? 1
                            : (k == SDL_SCANCODE_A || k == SDL_SCANCODE_LEFT)  ? -1 : 0;
                    if (dir) {
                        if (pause_sel == 0) {
                            sens_mult += dir * 0.1;
                            if (sens_mult < 0.3) sens_mult = 0.3;
                            if (sens_mult > 2.5) sens_mult = 2.5;
                        } else {
                            master_vol += dir * 8;
                            if (master_vol < 0)   master_vol = 0;
                            if (master_vol > 128) master_vol = 128;
                            apply_master_volume();
                        }
                    }
                    if (k == SDL_SCANCODE_Q) { game_state = ST_TITLE; SDL_SetRelativeMouseMode(SDL_TRUE); }
                    if (k == SDL_SCANCODE_C) {              /* copy the bug-report log to the clipboard */
                        log_copy_ok = nf_log_copy_to_clipboard();
                        log_copy_flash = 2.5;
                    }
                }
                if (k == SDL_SCANCODE_F11) {
                    fullscreen = !fullscreen;
                    SDL_SetWindowFullscreen(win, fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
                    SDL_GL_GetDrawableSize(win, &winW, &winH);
                }
                if ((k == SDL_SCANCODE_RETURN || k == SDL_SCANCODE_KP_ENTER ||
                     k == SDL_SCANCODE_SPACE) && game_state == ST_TITLE) {
                    depth = 1; match_count = 2; rock_count = 2; new_game(); game_state = ST_PLAY; state_time = 0;
                }
                if (k == SDL_SCANCODE_R && (game_state == ST_CAUGHT || game_state == ST_WIN)) {
                    depth = 1; match_count = 2; rock_count = 2; new_game(); game_state = ST_PLAY; state_time = 0;
                }
                /* dismiss a note you're reading -- else-if so the same E press
                 * doesn't fall through and immediately re-open it. */
                if ((k == SDL_SCANCODE_E || k == SDL_SCANCODE_SPACE ||
                     k == SDL_SCANCODE_RETURN) && game_state == ST_READING) {
                    game_state = ST_PLAY;
                }
                else if (k == SDL_SCANCODE_E && game_state == ST_PLAY) {
                    if (hidden) hidden = 0;
                    else if (near_chest >= 0) open_chest(near_chest);
                    else if (near_note >= 0) {                 /* stop and read the scrap */
                        reading_note = notes[near_note].text;
                        game_state = ST_READING;
                        if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
                    }
                    else if (near_locker >= 0) { hidden = 1; posX = lockers[near_locker].x; posY = lockers[near_locker].y; }
                }
                /* strike a match: a few seconds of light, at the cost of being seen */
                else if (k == SDL_SCANCODE_F && game_state == ST_PLAY && !hidden &&
                         match_count > 0 && match_burn <= 0.0) {
                    match_count--; match_burn = MATCH_DUR;
                    make_noise(posX, posY, 2.0);           /* the strike hisses */
                    if (snd_step) { Mix_VolumeChunk(snd_step, 90); Mix_PlayChannel(2, snd_step, 0);
                        Mix_SetPosition(2, 0, 0); }        /* your own hands: dead centre */
                }
                /* throw a rock: it lands down the corridor and knocks loud
                 * enough to pull the monster there -- away from you. */
                else if (k == SDL_SCANCODE_G && game_state == ST_PLAY && !hidden &&
                         rock_count > 0 && rockFlyT <= 0.0) {
                    double fx = cos(yaw), fy = sin(yaw);
                    double landX = posX, landY = posY;
                    for (double s = 0.4; s <= ROCK_MAX_RANGE; s += 0.25) {
                        if (!is_open((int)(posX + fx * s), (int)(posY + fy * s))) break;
                        landX = posX + fx * s; landY = posY + fy * s;
                    }
                    rock_count--;
                    rockFX0 = posX; rockFY0 = posY;
                    rockTX = landX; rockTY = landY;
                    rockFlyT = ROCK_FLY_DUR;
                }
            }
            if (e.type == SDL_MOUSEMOTION && game_state == ST_PLAY && !hidden) {
                yaw   += e.motion.xrel * MOUSE_SENS * sens_mult;
                pitch -= e.motion.yrel * MOUSE_SENS * sens_mult;
                if (pitch >  1.45) pitch =  1.45;
                if (pitch < -1.45) pitch = -1.45;
            }
        }

        if (game_state == ST_PLAY) {
            const Uint8 *ks = SDL_GetKeyboardState(NULL);
            int want_run = ks[SDL_SCANCODE_LSHIFT] && !exhausted && stamina > 0.05;
            int moving = 0;
            if (!hidden) {
                double fx = cos(yaw), fz = sin(yaw), rx = -sin(yaw), rz = cos(yaw);
                /* build a normalised input direction so diagonals aren't faster */
                double ix = 0, iy = 0;
                if (ks[SDL_SCANCODE_W]) { ix += fx; iy += fz; }
                if (ks[SDL_SCANCODE_S]) { ix -= fx; iy -= fz; }
                if (ks[SDL_SCANCODE_D]) { ix += rx; iy += rz; }
                if (ks[SDL_SCANCODE_A]) { ix -= rx; iy -= rz; }
                if (ks[SDL_SCANCODE_LEFT])  yaw -= 1.8 * dt;
                if (ks[SDL_SCANCODE_RIGHT]) yaw += 1.8 * dt;
                double il = sqrt(ix * ix + iy * iy);
                double tvx = 0, tvy = 0, target = want_run ? PLAYER_RUN : PLAYER_WALK;
                if (il > 1e-4) { ix /= il; iy /= il; tvx = ix * target; tvy = iy * target; }
                /* ease velocity toward the target (quick to start, quicker to stop) */
                double rate = (il > 1e-4 ? 11.0 : 14.0) * dt; if (rate > 1.0) rate = 1.0;
                velX += (tvx - velX) * rate;
                velY += (tvy - velY) * rate;
                double sp = sqrt(velX * velX + velY * velY);
                if (sp > 0.05) {
                    double ox = posX, oy = posY;
                    try_move(posX + velX * dt, posY + velY * dt, 0.18);
                    /* kill velocity on an axis we couldn't move along (hit a wall) */
                    if (fabs(posX - ox) < 1e-6) velX *= 0.2;
                    if (fabs(posY - oy) < 1e-6) velY *= 0.2;
                }
                moving = sp > 0.6;
                /* head bob: advance by distance, amplitude scales with speed */
                bob_phase += sp * dt * 3.4;
                double amp = (want_run ? 0.055 : 0.035) * (sp / PLAYER_WALK);
                if (amp > 0.07) amp = 0.07;
                bobY   = sin(bob_phase * 2.0) * amp;
                bobLat = sin(bob_phase) * amp * 0.6;
            } else { velX = velY = 0; bobY = bobLat = 0; }
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
                double fdepth = 0.4 + tension * 0.4 + (1.0 - sanity) * 0.3;
                flicker = 1.0 - (frand() < chance ? frand() * fdepth : 0);
            }

            /* keys are locked in chests now: find the nearest one you could open
             * (E opens it -> the screamer). Auto-open during a dev screenshot. */
            near_chest = -1;
            for (int i = 0; i < num_keys; i++)
                if (keys[i].active) {
                    double kd = (posX - keys[i].x) * (posX - keys[i].x) + (posY - keys[i].y) * (posY - keys[i].y);
                    if (kd < PICKUP_DIST * PICKUP_DIST) { near_chest = i;
                        if (shotpath) open_chest(i);   /* headless screenshots don't press keys */
                    }
                }
            /* find the nearest lore note you could stop to read (E reads it) */
            near_note = -1;
            for (int i = 0; i < NUM_NOTES; i++)
                if (notes[i].active) {
                    double nd = (posX - notes[i].x) * (posX - notes[i].x) + (posY - notes[i].y) * (posY - notes[i].y);
                    if (nd < PICKUP_DIST * PICKUP_DIST) near_note = i;
                }
            /* walk over a matchbox to pocket it */
            for (int i = 0; i < MAX_MATCHPICK; i++)
                if (matchpick[i].active) {
                    double dx = posX - matchpick[i].x, dy = posY - matchpick[i].y;
                    if (dx * dx + dy * dy < PICKUP_DIST * PICKUP_DIST) {
                        matchpick[i].active = 0; match_count++;
                        if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
                    }
                }
            /* walk over a rock to pocket it */
            for (int i = 0; i < MAX_ROCKPICK; i++)
                if (rockpick[i].active) {
                    double dx = posX - rockpick[i].x, dy = posY - rockpick[i].y;
                    if (dx * dx + dy * dy < PICKUP_DIST * PICKUP_DIST) {
                        rockpick[i].active = 0; rock_count++;
                        if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
                    }
                }
            /* a thrown rock lands: the strike carries as a noise the monster
             * can go investigate, at a volume that fades with how far it flew. */
            if (rockFlyT > 0.0) {
                rockFlyT -= dt;
                if (rockFlyT <= 0.0) {
                    rockFlyT = 0.0;
                    make_noise(rockTX, rockTY, ROCK_NOISE_TTL);
                    if (snd_thud) {
                        double thrown = sqrt((rockTX - rockFX0) * (rockTX - rockFX0) + (rockTY - rockFY0) * (rockTY - rockFY0));
                        int vol = (int)(110 - 6 * thrown); if (vol < 40) vol = 40;
                        Mix_VolumeChunk(snd_thud, vol);
                        Mix_PlayChannel(2, snd_thud, 0);
                        play_positional(2, rockTX, rockTY);
                    }
                }
            }
            /* step through the open door -> a fade-to-black descent transition */
            if (descend_t > 0.0) {
                descend_t -= dt;
                if (descend_t <= 0.8 && !descend_done) {    /* swap the floor while black */
                    double save = descend_t;                /* new_game() resets it; keep the fade */
                    depth++; if (depth > best_depth) best_depth = depth;
                    new_game();
                    nf_log("descended to depth=%d, mon_type=%d", depth, mon_type);
                    descend_t = save; descend_done = 1;
                }
                if (descend_t <= 0.0) { descend_t = 0.0; descend_done = 0; state_time = 0; }
            } else if (keys_left == 0) {
                double ed = (posX - exitX) * (posX - exitX) + (posY - exitY) * (posY - exitY);
                if (ed < 0.36) {                            /* enter the doorway */
                    descend_t = 1.6;
                    if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
                }
            }
            /* climb back up */
            if (has_up && descend_t == 0.0) {
                double ud = (posX - upX) * (posX - upX) + (posY - upY) * (posY - upY);
                if (ud < 0.4) { depth--; new_game(); state_time = 0;
                    nf_log("climbed back to depth=%d, mon_type=%d", depth, mon_type); }
            }
            double md = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
            int caught = (!hidden && md < CATCH_DIST && !shotpath);
            if (hidden && near_locker >= 0 && (mon_state == AI_HUNT || mon_state == AI_SEARCH)) {
                double ld = sqrt((monX - lockers[near_locker].x) * (monX - lockers[near_locker].x) +
                                 (monY - lockers[near_locker].y) * (monY - lockers[near_locker].y));
                if (ld < CHECK_DIST) { caught = 1; hidden = 0; }
            }
            if (caught) { game_state = ST_CAUGHT; state_time = 0;
                if (depth > best_depth) best_depth = depth;
                nf_log("caught by mon_type=%d at depth=%d", mon_type, depth);
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
            render_3d();                                 /* into the offscreen FBO */
            present_scene();                             /* post-process upscale to window */
        }

        /* dev screenshot: capture the pure 3D scene after a few settling frames */
        if (shotpath && !getenv("NIGHTFALL_SHOWNOTE") && game_state == ST_PLAY && ++shot_frame >= 24) {
            save_ppm(shotpath);
            running = 0;
        }

        ov_clear();
        if (game_state == ST_TITLE) draw_title();
        else if (game_state == ST_CAUGHT) draw_jumpscare();
        else if (game_state == ST_READING) { draw_hud(); draw_note(); }
        else if (game_state == ST_PAUSED)  draw_pause();
        else {
            draw_sanity_fx();
            if (hidden) draw_hidden_overlay();
            draw_hud();
            draw_vision();                       /* hallucination flash on top */
            draw_screamer();                     /* chest jump-scare over all   */
        }
        /* descent fade: darkness peaks exactly as the next floor swaps in */
        if (descend_t > 0.0) {
            double f = 1.0 - fabs(descend_t - 0.8) / 0.8;
            if (f < 0.0) f = 0.0;
            if (f > 1.0) f = 1.0;
            uint32_t px = packa(0, 0, 0, (int)(f * 255));
            for (int i = 0; i < SCREEN_W * SCREEN_H; i++) fb[i] = px;
        }
        present_overlay();

        /* dev: capture the composited overlay (note panel / title / HUD) */
        if (shotpath && (getenv("NIGHTFALL_SHOWNOTE") || getenv("NIGHTFALL_SHOTTITLE") || getenv("NIGHTFALL_SHOTHUD") || getenv("NIGHTFALL_SHOWSCREAM") || getenv("NIGHTFALL_SHOTDEATH") || getenv("NIGHTFALL_SHOTPAUSE")) && ++shot_frame >= 6) {
            if (getenv("NIGHTFALL_SHOTPAUSE")) { game_state = ST_PAUSED; pause_sel = atoi(getenv("NIGHTFALL_SHOTPAUSE")) ? 1 : 0; }
            if (getenv("NIGHTFALL_SHOWNOTE")) { reading_note = atoi(getenv("NIGHTFALL_SHOWNOTE")); game_state = ST_READING; }
            if (getenv("NIGHTFALL_SANITY")) sanity = atof(getenv("NIGHTFALL_SANITY"));   /* hold it low */
            if (getenv("NIGHTFALL_SHOWVISION")) { vision_t = VIS_DUR * 0.55; vision_idx = atoi(getenv("NIGHTFALL_SHOWVISION")); }
            if (getenv("NIGHTFALL_SHOWSCREAM")) { screamer_t = SCREAMER_DUR * 0.8; screamer_idx = atoi(getenv("NIGHTFALL_SHOWSCREAM")); }
            if (getenv("NIGHTFALL_SHOTDEATH")) { game_state = ST_CAUGHT; state_time = 2.0; best_depth = depth + 3; }
            if (shot_frame >= 10) { save_ppm(shotpath); running = 0; }
        }

        SDL_GL_SwapWindow(win);
    }

    if (snd_ambient) Mix_FreeChunk(snd_ambient);
    if (snd_heart)   Mix_FreeChunk(snd_heart);
    if (snd_scare)   Mix_FreeChunk(snd_scare);
    if (snd_pickup)  Mix_FreeChunk(snd_pickup);
    if (snd_step)    Mix_FreeChunk(snd_step);
    if (snd_whisper) Mix_FreeChunk(snd_whisper);
    if (snd_roar)    Mix_FreeChunk(snd_roar);
    if (snd_growl)   Mix_FreeChunk(snd_growl);
    if (snd_creak)   Mix_FreeChunk(snd_creak);
    if (snd_shrine)  Mix_FreeChunk(snd_shrine);
    if (snd_thud)    Mix_FreeChunk(snd_thud);
    Mix_CloseAudio();
    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(win);
    SDL_Quit();
    nf_log("session end, best_depth=%d", best_depth);
    nf_log_close();
    return 0;
}
