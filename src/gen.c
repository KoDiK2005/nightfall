/*
 * NIGHTFALL — level generation: rooms, biomes, pathing queries, level reset,
 * and level-object interactions (chests). The floor is built from themed
 * rectangular rooms joined by corridors, then populated with keys, lockers,
 * notes, matches, pillars and props.
 */
#include "game.h"

/* main.c owns these; gen.c reads/writes them while building a floor */

/* ------------------------------------------------------------ biome palette */
/* Every floor wears a different palette, light colour and name, so descending
 * feels like passing through distinct places. Chosen by depth (cycled); the
 * wall/floor/ceiling tints recolour the generated stone and the ambient/torch
 * colours reset the mood. */
const Biome BIOMES[NBIOMES] = {
  {"КАТАКОМБЫ",        {1.00f,0.96f,0.88f},{1.00f,0.97f,0.90f},{1.00f,1.00f,1.00f},{0.075f,0.080f,0.100f},{1.00f,0.52f,0.18f}},
  {"ЗАТОПЛЕННЫЙ ЯРУС", {0.58f,0.86f,0.82f},{0.56f,0.80f,0.78f},{0.56f,0.74f,0.82f},{0.045f,0.088f,0.115f},{0.90f,0.62f,0.38f}},
  {"ГОРНИЛО",          {1.08f,0.56f,0.40f},{1.02f,0.52f,0.38f},{0.88f,0.46f,0.38f},{0.125f,0.050f,0.040f},{1.00f,0.48f,0.14f}},
  {"КОСТЯНОЙ СКЛЕП",   {1.04f,0.99f,0.80f},{0.98f,0.93f,0.76f},{0.92f,0.87f,0.72f},{0.092f,0.088f,0.070f},{1.00f,0.56f,0.22f}},
  {"МЁРЗЛЫЙ ЧЕРТОГ",   {0.78f,0.90f,1.12f},{0.76f,0.88f,1.08f},{0.80f,0.92f,1.15f},{0.055f,0.082f,0.130f},{1.00f,0.72f,0.44f}},
  {"БЕЗДНА",           {0.60f,0.53f,0.74f},{0.58f,0.53f,0.72f},{0.54f,0.49f,0.68f},{0.050f,0.045f,0.078f},{0.92f,0.50f,0.30f}},
};
int   biome = 0;
float bwall[3]  = {1.00f,0.96f,0.88f}, bfloor[3] = {1.00f,0.97f,0.90f}, bceil[3] = {1.00f,1.00f,1.00f};
float biome_amb[3] = {0.075f,0.080f,0.100f}, biome_torch[3] = {1.00f,0.52f,0.18f};
static void apply_biome_palette(void) {
    const Biome *b = &BIOMES[biome % NBIOMES];
    for (int i = 0; i < 3; i++) {
        bwall[i] = b->wall[i]; bfloor[i] = b->floor[i]; bceil[i] = b->ceil[i];
        biome_amb[i] = b->amb[i]; biome_torch[i] = b->torch[i];
    }
}

/* --------------------------------------------------------------- floor build */
int is_open(int x, int y) { return x >= 0 && x < MW && y >= 0 && y < MH && map[y][x] != '#'; }

/* find which cardinal neighbour of (x,y) is a wall (so a prop/note/locker can
 * back onto it). Returns 1 and sets *wx,*wy to that direction, else 0. */
static int wall_dir(int x, int y, int *wx, int *wy) {
    static const int wdx[4] = {1, -1, 0, 0}, wdy[4] = {0, 0, 1, -1};
    for (int k = 0; k < 4; k++)
        if (!is_open(x + wdx[k], y + wdy[k])) { *wx = wdx[k]; *wy = wdy[k]; return 1; }
    *wx = *wy = 0;
    return 0;
}

static void room_center(const Room *r, int *cx, int *cy) { *cx = r->x + r->w / 2; *cy = r->y + r->h / 2; }

int patrol_order[MAX_ROOMS], patrol_len = 0, patrol_pos = 0;
/* shuffle every non-entrance room into a beat the monster loops while
 * wandering, so idle movement reads as a patrol through the halls rather
 * than picking a fresh random cell each time. Re-rolled once per floor. */
static void build_patrol_route(void) {
    patrol_len = 0;
    for (int i = 0; i < room_count; i++) {
        if (rooms[i].theme == RM_ENTRANCE) continue;
        patrol_order[patrol_len++] = i;
    }
    for (int i = patrol_len - 1; i > 0; i--) {
        int j = rand() % (i + 1);
        int t = patrol_order[i]; patrol_order[i] = patrol_order[j]; patrol_order[j] = t;
    }
    patrol_pos = patrol_len > 0 ? rand() % patrol_len : 0;
}

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
    int target = 7 + rand() % 4 + num_keys - 3;          /* more rooms as keys grow */
    if (target > MAX_ROOMS) target = MAX_ROOMS;          /* 7..10, up to 13 deep    */
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
    /* the first few remaining rooms hold keys (shrines); then storage/library/cells */
    int keyrooms = 0;
    for (int i = 1; i < room_count; i++) {
        if (rooms[i].theme != RM_HALL) continue;
        if (keyrooms < num_keys) { rooms[i].theme = RM_KEY; keyrooms++; }
        else { int p = i % 3; rooms[i].theme = p == 0 ? RM_STORAGE : p == 1 ? RM_LIBRARY : RM_CELLS; }
    }
    build_patrol_route();
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
void set_target(int cx, int cy) { tgtX = cx; tgtY = cy; flood_from_cell(cx, cy); }
/* Where the Stalker drifts when it has lost you. Mostly it walks its shuffled
 * patrol beat room-to-room (build_patrol_route), so idle movement reads as a
 * route through the halls; sometimes it instead detours to something you must
 * reach — an unopened chest or the exit door — so it haunts your objectives
 * as well as patrolling them. */
void pick_wander(void) {
    double r = frand();
    if (r < 0.20 && keys_left > 0) {                 /* detour: a still-locked shrine */
        int idx[MAX_KEYS], nn = 0;
        for (int i = 0; i < num_keys; i++) if (keys[i].active) idx[nn++] = i;
        if (nn) { int k = idx[rand() % nn]; set_target((int)keys[k].x, (int)keys[k].y); return; }
    } else if (r < 0.30) {                            /* detour: linger by the way down */
        set_target((int)exitX, (int)exitY); return;
    }
    if (patrol_len > 0) {                             /* otherwise, next stop on the beat */
        patrol_pos = (patrol_pos + 1) % patrol_len;
        int cx, cy; room_center(&rooms[patrol_order[patrol_pos]], &cx, &cy);
        if (is_open(cx, cy)) { set_target(cx, cy); return; }
    }
    for (int i = 0; i < 64; i++) {                    /* fallback: just roam         */
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (is_open(x, y)) { set_target(x, y); return; }
    }
}
int has_los(double ax, double ay, double bx, double by) {
    double dx = bx - ax, dy = by - ay, d = sqrt(dx * dx + dy * dy);
    int steps = (int)(d * 8) + 1;
    for (int i = 1; i < steps; i++) {
        double t = (double)i / steps;
        if (!is_open((int)(ax + dx * t), (int)(ay + dy * t))) return 0;
    }
    return 1;
}

/* Lore notes, shown when picked up. Each ends with a NULL line. Russian. */
const char *NOTES[NOTE_POOL][6] = {
    {"ФАКЕЛЫ ГАСНУТ САМИ.", "Я ЗАЖИГАЮ ИХ СНОВА.", "ОНО ЗНАЕТ ЧТО Я ЗДЕСЬ.", "ВНИЗУ.", NULL},
    {"НЕ БЕГИ.", "ОНО СЛЫШИТ КАЖДЫЙ ШАГ.", "ИДИ МЕДЛЕННО.", "ДЫШИ ТИХО.", NULL},
    {"ТРИ КЛЮЧА НА КАЖДУЮ ДВЕРЬ.", "ЗАЧЕМ ВНИЗ?", "ЧТО ОНИ ДЕРЖАТ", "НА САМОМ ДНЕ?", NULL},
    {"Я СЧИТАЛ ЭТАЖИ.", "ПОТОМ ЛАМПА ПОГАСЛА.", "ШЁПОТ", "НЕ ПРЕКРАЩАЛСЯ.", NULL},
    {"ЕСЛИ ТЫ ЧИТАЕШЬ ЭТО -", "ТЫ НЕ ПЕРВЫЙ.", "И НЕ ПОСЛЕДНИЙ.", "ОНО НИКОГДА НЕ СЫТО.", NULL},
    {"ШКАФЫ - ТВОИ ДРУЗЬЯ.", "НО ОНО ПРОВЕРЯЕТ ИХ.", "РАНО ИЛИ ПОЗДНО.", NULL},
    {"Я ВИДЕЛ ЕГО ЛИЦО.", "БЕЛОЕ. ПУСТОЕ.", "ОНО УЛЫБАЛОСЬ МНЕ.", "Я БОЛЬШЕ НЕ СПЛЮ.", NULL},
    {"ДВЕРЬ ВНИЗ - НЕ СПАСЕНИЕ.", "ЭТО ПРИГЛАШЕНИЕ.", "МЫ ВСЕ СПУСКАЕМСЯ.", "КАЖДЫЙ В СВОЙ ЧЕРЕД.", NULL},
    {"СТЕНЫ ДЫШАТ КОГДА ТЕМНО.", "НЕ СМОТРИ ДОЛГО.", "ОНИ СМОТРЯТ В ОТВЕТ.", NULL},
    {"МОЙ ФОНАРЬ УМЕР НА", "ЧЕТЫРНАДЦАТОМ ЭТАЖЕ.", "ДАЛЬШЕ ТОЛЬКО", "ГОЛОДНАЯ ТЬМА.", NULL},
    {"ЧЕМ ГЛУБЖЕ - ТЕМ БОЛЬШЕ", "СУНДУКОВ С КЛЮЧАМИ.", "ОНО СТЕРЕЖЁТ КАЖДЫЙ.", NULL},
    {"СВЕЧИ У СУНДУКА", "ГОРЯТ НЕ ДЛЯ ТЕБЯ.", "ОНИ ЗОВУТ ЕГО.", NULL},
    {"НЕ ОТКРЫВАЙ КРЫШКУ", "ЕСЛИ СЛЫШИШЬ ДЫХАНИЕ", "ЗА СПИНОЙ.", "УЖЕ ПОЗДНО.", NULL},
    {"КАЖДЫЙ ЭТАЖ ТЕМНЕЕ.", "ФАКЕЛОВ ВСЁ МЕНЬШЕ.", "СКОРО ОСТАНЕТСЯ", "ТОЛЬКО ТЬМА.", NULL},
};

/* flood from the entrance; true only if the exit and every key are reachable.
 * Used to reject any decorative pillar that would sever the floor.          */
static int reach_ok(void) {
    flood_from_cell(startX, startY);
    if (gdist[(int)exitY][(int)exitX] >= (1 << 20)) return 0;
    for (int i = 0; i < num_keys; i++)
        if (gdist[(int)keys[i].y][(int)keys[i].x] >= (1 << 20)) return 0;
    return 1;
}

/* scatter theme-appropriate clutter: crates in storage, bookshelves in the
 * library, barred cells with blood, low debris elsewhere. Deterministic per
 * level (stored, not rebuilt each frame) so it survives the door-open mesh
 * rebuild. */
static void generate_props(void) {
    prop_count = 0;
    for (int i = 0; i < room_count && prop_count < MAX_PROPS; i++) {
        Room *r = &rooms[i];
        if (r->theme == RM_ENTRANCE || r->theme == RM_EXIT) continue;
        int budget = (r->theme == RM_STORAGE || r->theme == RM_LIBRARY) ? 4 : 3;
        int placed = 0;
        for (int yy = r->y; yy < r->y + r->h && placed < budget && prop_count < MAX_PROPS; yy++)
            for (int xx = r->x; xx < r->x + r->w && placed < budget && prop_count < MAX_PROPS; xx++) {
                if (!is_open(xx, yy)) continue;
                if (abs(xx - startX) + abs(yy - startY) < 3) continue;
                if (abs(xx - (int)exitX) + abs(yy - (int)exitY) < 2) continue;
                int busy = 0;
                for (int j = 0; j < num_keys; j++)   if ((int)keys[j].x == xx && (int)keys[j].y == yy) busy = 1;
                for (int j = 0; j < NUM_LOCKERS; j++) if ((int)lockers[j].x == xx && (int)lockers[j].y == yy) busy = 1;
                for (int j = 0; j < NUM_NOTES; j++)  if ((int)notes[j].x == xx && (int)notes[j].y == yy) busy = 1;
                if (busy) continue;
                if (placed > 0 && (rand() & 3) != 0) continue;      /* spread them out */
                int wx, wy, wall = wall_dir(xx, yy, &wx, &wy);
                double cx = xx + 0.5, cz = yy + 0.5;
                if (r->theme == RM_STORAGE && wall) {               /* crates + barrels */
                    double px = cx + wx * 0.18, pz = cz + wy * 0.18, top = 0.28 + frand() * 0.12;
                    props[prop_count++] = (Prop){px, pz, 0.26, 0.26, 0.0, top, 0.60f, 0.42f, 0.22f};
                    if (prop_count < MAX_PROPS && frand() < 0.45)   /* a smaller crate on top */
                        props[prop_count++] = (Prop){px + 0.06, pz - 0.05, 0.17, 0.17, top, top + 0.24, 0.58f, 0.40f, 0.21f};
                    else if (prop_count < MAX_PROPS && frand() < 0.5) /* an iron-dark barrel */
                        props[prop_count++] = (Prop){px, pz, 0.19, 0.19, 0.0, 0.44, 0.34f, 0.27f, 0.22f};
                } else if (r->theme == RM_LIBRARY && wall) {        /* a shelf of books */
                    double px = cx + wx * 0.36, pz = cz + wy * 0.36;
                    double hwx = (wx != 0) ? 0.10 : 0.36, hwz = (wx != 0) ? 0.36 : 0.10;
                    props[prop_count++] = (Prop){px, pz, hwx, hwz, 0.0, 0.90, 0.30f, 0.19f, 0.10f}; /* dark plank */
                    double tanx = (wx != 0) ? 0.0 : 1.0, tanz = (wx != 0) ? 1.0 : 0.0;
                    static const float spine[6][3] = {{0.70f,0.16f,0.13f},{0.16f,0.34f,0.55f},{0.22f,0.50f,0.26f},
                                                      {0.62f,0.52f,0.16f},{0.46f,0.20f,0.52f},{0.55f,0.30f,0.14f}};
                    for (int bk = -2; bk <= 2 && prop_count < MAX_PROPS; bk++) {   /* coloured spines */
                        double off = bk * 0.13, bh = 0.50 + frand() * 0.30;
                        double bx = px + tanx * off, bz = pz + tanz * off;
                        const float *sp = spine[rand() % 6];
                        props[prop_count++] = (Prop){bx, bz, (wx != 0) ? 0.055 : 0.05, (wx != 0) ? 0.05 : 0.055,
                                                     0.30, 0.30 + bh, sp[0], sp[1], sp[2]};
                    }
                } else if (r->theme == RM_CELLS && wall) {          /* a barred prison cell */
                    /* back the cage onto the wall; bars run along it, facing the room */
                    double bcx = cx - wx * 0.10, bcz = cz - wy * 0.10;
                    double tanx = (wx != 0) ? 0.0 : 1.0, tanz = (wx != 0) ? 1.0 : 0.0;
                    for (int bk = -2; bk <= 2 && prop_count < MAX_PROPS; bk++) {   /* vertical iron bars */
                        double bx = bcx + tanx * bk * 0.15, bz = bcz + tanz * bk * 0.15;
                        props[prop_count++] = (Prop){bx, bz, 0.028, 0.028, 0.0, 0.92, 0.30f, 0.31f, 0.35f};
                    }
                    if (prop_count < MAX_PROPS)                     /* top rail tying the bars */
                        props[prop_count++] = (Prop){bcx, bcz, (wx != 0) ? 0.03 : 0.33, (wx != 0) ? 0.33 : 0.03,
                                                     0.84, 0.92, 0.26f, 0.27f, 0.30f};
                    if (prop_count < MAX_PROPS && frand() < 0.7) {  /* a dark blood pool on the floor */
                        double px = cx + wx * 0.16, pz = cz + wy * 0.16;
                        props[prop_count++] = (Prop){px, pz, 0.24 + frand() * 0.08, 0.24 + frand() * 0.08,
                                                     0.012, 0.03, 0.24f, 0.03f, 0.03f};
                    }
                } else if (r->theme == RM_CELLS) {                  /* open floor: just the blood */
                    props[prop_count++] = (Prop){cx, cz, 0.22 + frand() * 0.08, 0.22 + frand() * 0.08,
                                                 0.012, 0.03, 0.22f, 0.03f, 0.03f};
                } else if (r->theme == RM_KEY) {                    /* shrine relics: pale bones */
                    props[prop_count++] = (Prop){cx, cz, 0.17, 0.17, 0.0, 0.12 + frand() * 0.08, 0.82f, 0.80f, 0.70f};
                    if (prop_count < MAX_PROPS && frand() < 0.6)
                        props[prop_count++] = (Prop){cx + 0.10, cz - 0.08, 0.09, 0.09, 0.0, 0.17, 0.88f, 0.86f, 0.78f};
                } else {                                            /* biome-flavoured floor decor */
                    double j = frand() * 0.1;
                    switch (biome % NBIOMES) {
                        case 1:  /* FLOODED — mossy mounds, sometimes a tall reed */
                            props[prop_count++] = (Prop){cx, cz, 0.24 + j, 0.24 + j, 0.0, 0.10 + frand() * 0.08, 0.28f, 0.55f, 0.40f};
                            if (prop_count < MAX_PROPS && frand() < 0.4)
                                props[prop_count++] = (Prop){cx + 0.1, cz - 0.08, 0.05, 0.05, 0.0, 0.45 + frand() * 0.3, 0.24f, 0.50f, 0.34f};
                            break;
                        case 2:  /* FURNACE — heaps of dark warm coals */
                            props[prop_count++] = (Prop){cx, cz, 0.22 + j, 0.22 + j, 0.0, 0.09 + frand() * 0.07, 0.55f, 0.22f, 0.12f};
                            if (prop_count < MAX_PROPS && frand() < 0.5)
                                props[prop_count++] = (Prop){cx - 0.08, cz + 0.06, 0.12, 0.12, 0.0, 0.10, 0.70f, 0.30f, 0.14f};
                            break;
                        case 3:  /* BONE CRYPT — scattered pale bones */
                            props[prop_count++] = (Prop){cx, cz, 0.20 + j, 0.20 + j, 0.0, 0.09 + frand() * 0.06, 0.80f, 0.78f, 0.66f};
                            break;
                        case 4:  /* FROST — jagged pale-blue ice shards */
                            props[prop_count++] = (Prop){cx, cz, 0.09 + frand() * 0.05, 0.09 + frand() * 0.05, 0.0, 0.35 + frand() * 0.35, 0.72f, 0.86f, 1.08f};
                            break;
                        case 5:  /* ABYSS — thin dark growths */
                            props[prop_count++] = (Prop){cx, cz, 0.07 + frand() * 0.05, 0.07 + frand() * 0.05, 0.0, 0.40 + frand() * 0.4, 0.46f, 0.34f, 0.62f};
                            break;
                        default: /* CATACOMBS — low grey rubble */
                            props[prop_count++] = (Prop){cx, cz, 0.22 + j, 0.22 + j, 0.0, 0.10 + frand() * 0.10, 0.42f, 0.41f, 0.39f};
                            break;
                    }
                }
                placed++;
            }
    }
}

static void reset_level(void) {
    /* deeper floors demand more keys (more chests to crack, more ground to
     * cover): 3 up top, one more every three floors, capped at MAX_KEYS. */
    num_keys = 3 + (depth - 1) / 3;
    if (num_keys > MAX_KEYS) num_keys = MAX_KEYS;
    biome = (depth - 1) % NBIOMES;          /* each floor a different biome, cycled */
    apply_biome_palette();
    generate_rooms();
    posX = startX + 0.5; posY = startY + 0.5; yaw = 0; pitch = 0;
    mon_speed = MONSTER_SPD + (depth - 1) * 0.10;
    if (mon_speed > 3.2) mon_speed = 3.2;

    /* the descent door lives in the exit room; stairs up in the entrance corner */
    for (int i = 0; i < room_count; i++)
        if (rooms[i].theme == RM_EXIT) { int cx, cy; room_center(&rooms[i], &cx, &cy); exitX = cx + 0.5; exitY = cy + 0.5; }
    /* face the door toward the entrance side, snapped to the nearest axis */
    { double ddx = startX - (int)exitX, ddy = startY - (int)exitY;
      if (fabs(ddx) >= fabs(ddy)) { doorNx = ddx >= 0 ? 1 : -1; doorNz = 0; }
      else                        { doorNx = 0; doorNz = ddy >= 0 ? 1 : -1; } }
    descend_t = 0.0; descend_done = 0;

    /* keys sit on pedestals at the heart of the shrine (RM_KEY) rooms */
    keys_left = num_keys;
    int ki = 0;
    for (int i = 0; i < room_count && ki < num_keys; i++) {
        if (rooms[i].theme != RM_KEY) continue;
        int cx, cy; room_center(&rooms[i], &cx, &cy);
        keys[ki].x = cx + 0.5; keys[ki].y = cy + 0.5; keys[ki].active = 1;
        pedX[ki] = cx + 0.5; pedZ[ki] = cy + 0.5; ki++;
    }
    while (ki < num_keys) {                                /* fallback scatter    */
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (!is_open(x, y) || (abs(x - startX) + abs(y - startY)) < 4) continue;
        keys[ki].x = x + 0.5; keys[ki].y = y + 0.5; keys[ki].active = 1;
        pedX[ki] = x + 0.5; pedZ[ki] = y + 0.5; ki++;
    }

    /* a struck match doesn't survive the descent; scatter a few fresh ones */
    match_burn = 0.0;
    for (int i = 0; i < MAX_MATCHPICK; i++) matchpick[i].active = 0;
    int mp = 2 + rand() % 2;                               /* 2-3 per floor */
    for (int i = 0, tries = 0; i < mp && tries < 400; tries++) {
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (!is_open(x, y) || (abs(x - startX) + abs(y - startY)) < 4) continue;
        matchpick[i].x = x + 0.5; matchpick[i].y = y + 0.5; matchpick[i].active = 1; i++;
    }

    /* rocks to throw as a lure; a fresh handful each floor, same spread as matches */
    rockFlyT = 0.0;
    for (int i = 0; i < MAX_ROCKPICK; i++) rockpick[i].active = 0;
    int rp = 2 + rand() % 2;                               /* 2-3 per floor */
    for (int i = 0, tries = 0; i < rp && tries < 400; tries++) {
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (!is_open(x, y) || (abs(x - startX) + abs(y - startY)) < 4) continue;
        rockpick[i].x = x + 0.5; rockpick[i].y = y + 0.5; rockpick[i].active = 1; i++;
    }

    /* raise the candidate pillars into columns, skipping any that would block
     * a key, the exit, the spawn, or sever the floor's connectivity.        */
    for (int p = 0; p < pillar_count; p++) {
        int px = pcellX[p], py = pcellY[p];
        if (!is_open(px, py) || (px == startX && py == startY)) continue;
        if ((int)exitX == px && (int)exitY == py) continue;
        int skip = 0;
        for (int i = 0; i < num_keys; i++) if ((int)keys[i].x == px && (int)keys[i].y == py) skip = 1;
        if (skip) continue;
        map[py][px] = '#';
        if (!reach_ok()) map[py][px] = '.';               /* undo: it disconnects */
    }

    /* lockers line the walls of storage rooms (then anywhere, to fill quota) */
    int li = 0;
    for (int pass = 0; pass < 2 && li < NUM_LOCKERS; pass++)
        for (int i = 0; i < room_count && li < NUM_LOCKERS; i++) {
            if (rooms[i].theme == RM_ENTRANCE || rooms[i].theme == RM_EXIT) continue;
            if (pass == 0 && rooms[i].theme != RM_STORAGE) continue;
            Room *r = &rooms[i];
            for (int yy = r->y; yy < r->y + r->h && li < NUM_LOCKERS; yy++)
                for (int xx = r->x; xx < r->x + r->w && li < NUM_LOCKERS; xx++) {
                    if (!is_open(xx, yy) || abs(xx - startX) + abs(yy - startY) < 3) continue;
                    if (abs(xx - (int)exitX) + abs(yy - (int)exitY) < 2) continue;
                    int wx, wy;
                    if (!wall_dir(xx, yy, &wx, &wy)) continue;
                    int ok = 1;
                    for (int j = 0; j < li; j++)
                        if (fabs(lockers[j].x - (xx + 0.5)) + fabs(lockers[j].y - (yy + 0.5)) < 2) ok = 0;
                    for (int j = 0; j < num_keys; j++)
                        if (fabs(keys[j].x - (xx + 0.5)) + fabs(keys[j].y - (yy + 0.5)) < 1.5) ok = 0;
                    if (!ok) continue;
                    lockers[li].x = xx + 0.5; lockers[li].y = yy + 0.5;
                    lockWX[li] = wx; lockWY[li] = wy; li++;
                }
        }

    /* lore notes are pinned to the walls of library rooms (then any wall) */
    int ni = 0;
    for (int pass = 0; pass < 2 && ni < NUM_NOTES; pass++)
        for (int i = 0; i < room_count && ni < NUM_NOTES; i++) {
            if (rooms[i].theme == RM_ENTRANCE || rooms[i].theme == RM_EXIT) continue;
            if (pass == 0 && rooms[i].theme != RM_LIBRARY) continue;
            Room *r = &rooms[i];
            for (int yy = r->y; yy < r->y + r->h && ni < NUM_NOTES; yy++)
                for (int xx = r->x; xx < r->x + r->w && ni < NUM_NOTES; xx++) {
                    if (!is_open(xx, yy) || abs(xx - startX) + abs(yy - startY) < 3) continue;
                    if (abs(xx - (int)exitX) + abs(yy - (int)exitY) < 2) continue;
                    int wx, wy;
                    if (!wall_dir(xx, yy, &wx, &wy)) continue;
                    int ok = 1;
                    for (int j = 0; j < ni; j++)
                        if (fabs(notes[j].x - (xx + 0.5)) + fabs(notes[j].y - (yy + 0.5)) < 2) ok = 0;
                    for (int j = 0; j < NUM_LOCKERS; j++)
                        if (fabs(lockers[j].x - (xx + 0.5)) + fabs(lockers[j].y - (yy + 0.5)) < 1.5) ok = 0;
                    if (!ok) continue;
                    notes[ni].x = xx + 0.5; notes[ni].y = yy + 0.5; notes[ni].active = 1;
                    noteWX[ni] = wx; noteWY[ni] = wy;
                    notes[ni].text = rand() % NOTE_POOL; ni++;
                }
        }
    while (ni < NUM_NOTES) {                               /* fallback: any wall cell */
        int x = 1 + rand() % (MW - 2), y = 1 + rand() % (MH - 2);
        if (!is_open(x, y)) continue;
        int wx, wy;
        if (!wall_dir(x, y, &wx, &wy)) continue;
        notes[ni].x = x + 0.5; notes[ni].y = y + 0.5; notes[ni].active = 1;
        noteWX[ni] = wx; noteWY[ni] = wy;
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

    generate_props();

    tension = 0; flicker = 1;
    heart_timer = step_timer = 0;
    stamina = 1.0; exhausted = 0; hidden = 0; near_locker = -1;
    sanity = 1.0; mon_sees = 0; surge = 0;
    phantom_t = 0.0; phantom_timer = 10.0;
    vision_t = 0.0; vision_timer = 12.0;
    screamer_t = 0.0; near_chest = -1; near_note = -1;
    whisper_timer = 8.0; event_timer = 14.0;
    mon_state = AI_WANDER; lastKnownX = posX; lastKnownY = posY;
    hunt_recalc = search_time = growl_timer = 0;
    noise_t = 0.0;
    /* which horror stalks this floor — new kinds unlock with depth, with the
     * first sighting of each guaranteed on floors 4 and 7 to teach it. */
    if      (depth < 4)   mon_type = MON_STALKER;
    else if (depth == 4)  mon_type = MON_LISTENER;
    else if (depth == 7)  mon_type = MON_WATCHER;
    else                  mon_type = rand() % (depth >= 7 ? 3 : 2);
    reveal_t = (mon_type == MON_STALKER) ? 0.0 : 6.0;   /* warn about the odd ones */
    pick_wander();
}

void new_game(void) {
    reset_level();
    build_textures();            /* regenerate stone in this floor's biome palette */
    reupload_world_textures();
    build_world_mesh();
    upload_map();
}

/* crack open a chest: claim its key, and slam a photo full-screen as a scare */
void open_chest(int i) {
    if (i < 0 || i >= num_keys || !keys[i].active) return;
    keys[i].active = 0; keys_left--;
    nf_log("chest opened (key %d/%d) at depth=%d", num_keys - keys_left, num_keys, depth);
    make_noise(keys[i].x, keys[i].y, 6.0);       /* the lid's crack carries far */
    if (snd_creak) {
        Mix_VolumeChunk(snd_creak, 110); Mix_PlayChannel(CH_CREAK, snd_creak, 0);
        play_positional(CH_CREAK, keys[i].x, keys[i].y);
    }
    if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
    if (nvisions > 0) {                          /* the screamer needs a photo */
        screamer_idx = rand() % nvisions;
        screamer_t = SCREAMER_DUR;
        if (snd_scare) { Mix_VolumeChunk(snd_scare, 120); Mix_PlayChannel(4, snd_scare, 0); }
    }
    if (keys_left == 0) build_world_mesh();      /* the exit door's slab drops */
}
