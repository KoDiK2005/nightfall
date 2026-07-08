/*
 * NIGHTFALL — сюжетный режим.
 *
 * В отличие от бесконечного спуска (gen.c генерирует этажи процедурно),
 * здесь уровни рукописные: карта прописана вручную, вместо generate_rooms().
 * Каждый уровень сюжетки — отдельная психологическая травма, а внутри
 * уровня игрок проходит пять стадий принятия горя (Кюблер-Росс):
 * Отрицание -> Гнев -> Торги -> Депрессия -> Принятие.
 *
 * Уровень 1 (семейная травма), этап "Отрицание": вся площадка -- это
 * воспоминание целиком. Дом с лужайкой и беседкой стоит посреди пустоты
 * (лужайка/дорога отрисовываются без потолка -- см. RM_LAWN/RM_ROAD в
 * build_world_mesh, render.c). Игрок появляется на проезжей части перед
 * домом; по пути к двери всплывают три воспоминания (внутренний голос
 * оправдывает то, что видел). У двери его встречает мать -- без лица (у
 * неё никогда нет настроения, лицо ей ни к чему), отчитывает и гонит в
 * комнату.
 *
 * Дальше по стадиям: Гнев, Торги, Депрессия, Принятие -- следующие шаги.
 */
#include "game.h"

int story_mode  = 0;
int story_level = 1;
int story_stage = STORY_DENIAL;

double story_speed_mult = 1.0;

int    story_mother_visible = 0;
double story_motherX, story_motherY;

const char **story_subtitle_lines = NULL;
double       story_subtitle_a = 0.0;

/* фазы этапа "Отрицание": подход к дому по дороге -> сцена с матерью в
 * дверях -> он уже в своей комнате (дальше пока заглушка).             */
enum { DENIAL_APPROACH, DENIAL_CONFRONT, DENIAL_AFTERMATH };
static int denial_phase;

/* -------------------------------------------------- всплывающие воспоминания */
/* Тексты воспоминаний, всплывающих по пути к дому. Внутренний голос героя
 * оправдывает то, что видит -- это и есть суть отрицания: "у всех так",
 * "не так уж и плохо", "надо просто вырасти". */
#define DENIAL_MEMORIES 3
static const char *DENIAL_TEXTS[DENIAL_MEMORIES][6] = {
    { "МАТЬ КРИЧИТ ИЗ-ЗА РАЗБИТОЙ ТАРЕЛКИ.",
      "ЭТО НЕ ЗЛОСТЬ. ЭТО ВОСПИТАНИЕ.",
      "У ВСЕХ ТАК В СЕМЬЕ.",
      "НАДО ПРОСТО БЫТЬ ВНИМАТЕЛЬНЕЕ.", NULL },
    { "ОТЕЦ СНОВА ЗАСНУЛ ПЕРЕД ТЕЛЕВИЗОРОМ.",
      "БУТЫЛКА НА ПОЛУ - ОБЫЧНОЕ ДЕЛО.",
      "ОН ЖЕ НЕ ПОДНИМАЕТ РУКУ. ЗНАЧИТ ВСЁ НОРМАЛЬНО.",
      "МНОГИЕ ОТЦЫ ТАК ОТДЫХАЮТ.", NULL },
    { "Я ЗАКРЫВАЮ ДВЕРЬ И НЕ ПЛАЧУ.",
      "НАДО ПРОСТО ВЫРАСТИ.",
      "СТАТЬ НОРМАЛЬНЫМ ВЗРОСЛЫМ ЧЕЛОВЕКОМ.",
      "ЗАБЫТЬ ОБ ЭТОМ.", NULL },
};
/* точки на дороге, где всплывает очередное воспоминание (один раз каждая) */
static const double MEMORY_Y[DENIAL_MEMORIES] = { 4.0, 7.0, 10.0 };
static int memory_seen[DENIAL_MEMORIES];

/* -------------------------------------------------------- реплики матери */
/* Она отчитывает и гонит его в комнату -- по одной строке за раз, E
 * пропускает текущую (см. story_try_interact). */
#define MOTHER_LINES_N 4
static const char *MOTHER_LINES[MOTHER_LINES_N] = {
    "ГДЕ ТЫ ШЛЯЛСЯ?",
    "ОПЯТЬ ОДНИ ПРОБЛЕМЫ ИЗ-ЗА ТЕБЯ.",
    "ВЕЧНО ТЫ ВСЁ ПОРТИШЬ.",
    "МАРШ В КОМНАТУ. НЕ ПОПАДАЙСЯ МНЕ НА ГЛАЗА.",
};
static int    mother_line_idx;
static double mother_line_timer;
static const char *mother_line_buf[2];   /* {реплика, NULL} -- под формат subtitle_lines */

#define MOTHER_LINE_DUR 2.6
#define MEMORY_POPUP_DUR 4.5

/* дверь дома (порог, где начинается сцена с матерью) и комната, куда
 * героя отправляют после отповеди */
static double doorX, doorY;
static double childRoomX, childRoomY;

/* закрасить прямоугольник (включительно) полом -- свой, отдельный от
 * carve_rect в gen.c: уровень тут не процедурный, а прописан руками. */
static void carve(int x0, int y0, int x1, int y1) {
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++)
            if (x > 0 && x < MW - 1 && y > 0 && y < MH - 1) map[y][x] = '.';
}
/* обвести прямоугольник стеной (для дома/комнаты, вырезанных из лужайки) */
static void wall_ring(int x0, int y0, int x1, int y1) {
    for (int x = x0; x <= x1; x++) { map[y0][x] = '#'; map[y1][x] = '#'; }
    for (int y = y0; y <= y1; y++) { map[y][x0] = '#'; map[y][x1] = '#'; }
}

/* беседка на лужайке -- просто декор: четыре столба и плоская крыша,
 * никакого отдельного геймплея, чтобы место читалось обжитым.          */
static void place_gazebo(double cx, double cz) {
    float tr = 0.55f, tg = 0.42f, tb = 0.30f;   /* тёплое дерево */
    double half = 1.6;
    double px[4] = { cx - half, cx + half, cx - half, cx + half };
    double pz[4] = { cz - half, cz - half, cz + half, cz + half };
    for (int i = 0; i < 4 && prop_count < MAX_PROPS; i++)
        props[prop_count++] = (Prop){ px[i], pz[i], 0.09, 0.09, 0.0, 1.15, tr, tg, tb };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, half + 0.25, half + 0.25, 1.05, 1.20, tr * 0.85f, tg * 0.85f, tb * 0.85f };
}

/* Уровень 1, стадия "Отрицание": дом с лужайкой и беседкой посреди
 * пустоты. Игрок появляется на дороге перед домом.                      */
void story_start_denial(void) {
    story_level = 1;
    story_stage = STORY_DENIAL;
    denial_phase = DENIAL_APPROACH;

    /* сначала всё стены, потом -- сплошная открытая лужайка (почти весь
     * прямоугольник карты), и уже поверх неё вырезаем дом/комнату стенами */
    for (int y = 0; y < MH; y++) { for (int x = 0; x < MW; x++) map[y][x] = '#'; map[y][MW] = 0; }
    carve(1, 1, MW - 2, MH - 2);              /* вся лужайка + дорога открыты */

    /* дом: внешние стены с проёмом-дверью в верхней стене (со стороны дороги) */
    wall_ring(10, 14, 18, 19);
    map[14][14] = '.';                        /* дверной проём */
    /* комната героя: запечатана со всех сторон -- сюда его "отправляют"
     * скриптом после отповеди, а не пешком, так что дверь ей не нужна */
    wall_ring(2, 2, 5, 5);

    /* -------- темы зон, чтобы дорога/дом/комната были раскрашены и
     * дорога с лужайкой остались без потолка (см. build_world_mesh) --
     * порядок важен: узкие зоны идут раньше широкой лужайки-заглушки. */
    room_count = 0;
    rooms[room_count++] = (Room){ 13, 1, 3, 13, RM_ROAD };        /* дорога к дому   */
    rooms[room_count++] = (Room){ 11, 15, 7, 4, RM_ENTRANCE };    /* внутри дома     */
    rooms[room_count++] = (Room){ 3, 3, 2, 2, RM_ENTRANCE };      /* комната героя   */
    rooms[room_count++] = (Room){ 1, 1, MW - 2, MH - 2, RM_LAWN };/* лужайка (фон)   */

    /* беседка -- в стороне от дороги и дома */
    prop_count = 0;
    place_gazebo(22.0, 6.0);

    /* точка спавна: на дороге перед домом, лицом к двери */
    startX = 14; startY = 1;
    posX = startX + 0.5; posY = startY + 1.5; yaw = 1.5708; pitch = 0;

    /* дверь дома -- начинается закрытой (add_door рисует "замок"), и
     * буквально "открывается" (build_world_mesh) в момент, когда игрок
     * подходит вплотную -- см. story_update(). */
    doorX = 14.5; doorY = 14.5;
    exitX = doorX; exitY = doorY;
    doorNx = 0; doorNz = 1;
    num_keys = 1; keys_left = 1;

    childRoomX = 3.5; childRoomY = 3.5;

    /* сброс триггеров и субтитров */
    for (int i = 0; i < DENIAL_MEMORIES; i++) memory_seen[i] = 0;
    story_subtitle_lines = NULL; story_subtitle_a = 0.0;
    story_mother_visible = 0;
    story_speed_mult = 0.45;   /* медленнее, чтобы успеть прочитать воспоминания */

    /* обнулить всё, что относится к бесконечному режиму, чтобы не
     * протащить призраков предыдущей игры на лужайку: сундуки/ключи,
     * спички, камни, lore-записки, шкафчики (уводим за карту). */
    for (int i = 0; i < MAX_KEYS; i++) keys[i].active = 0;
    for (int i = 0; i < MAX_MATCHPICK; i++) matchpick[i].active = 0;
    for (int i = 0; i < MAX_ROCKPICK; i++) rockpick[i].active = 0;
    for (int i = 0; i < NUM_NOTES; i++) notes[i].active = 0;
    for (int i = 0; i < NUM_LOCKERS; i++) { lockers[i].x = -5; lockers[i].y = -5; }
    match_burn = 0.0; match_count = 0; rock_count = 0; rockFlyT = 0.0;

    /* без монстра: отрицание -- это тишина и мнимый уют, не погоня */
    monX = -5; monY = -5;

    /* сбросить состояние игрока, которое могло остаться от предыдущей
     * игры (например hidden=1, если вышли в меню, прячась в шкафчике) */
    hidden = 0; stamina = 1.0; exhausted = 0;
    velX = 0.0; velY = 0.0;

    /* тёплая, "домашняя" палитра вместо процедурного камня подземелья --
     * подменяем напрямую, не трогая biome/NBIOMES бесконечного режима.
     * Лужайка и дорога получают тон уже через RM_LAWN/RM_ROAD в tint_for. */
    depth = 1;   /* чтобы build_textures() не состарил камень трещинами */
    bwall[0] = 1.05f;  bwall[1] = 0.92f;  bwall[2] = 0.72f;
    bfloor[0] = 0.55f; bfloor[1] = 0.40f; bfloor[2] = 0.28f;
    bceil[0] = 0.95f;  bceil[1] = 0.90f;  bceil[2] = 0.80f;
    /* заметно светлее, чем подземелье -- это открытая пустота под мутным
     * небом, а не тёмный коридор; иначе лужайка тонет в черноте вдали от
     * факелов дома. */
    /* процедурные текстуры тут очень тёмные по своей природе (расчёт на
     * подсветку факелами вблизи) -- чтобы лужайка вдали от факелов не
     * тонула в черноте, ambient держим настолько высоким, что дневной
     * свет фактически проступает через саму текстуру, а не только тонирует. */
    biome_amb[0] = 3.6f; biome_amb[1] = 3.5f; biome_amb[2] = 3.3f;
    biome_torch[0] = 1.00f; biome_torch[1] = 0.70f; biome_torch[2] = 0.40f;

    /* стены дома поднимаются под двухэтажную высоту -- лужайка/дорога всё
     * равно без потолка, так что выше становится только сам дом (и заодно
     * запечатанная комната героя, ей это не мешает). */
    wall_h = 2.0f;

    build_textures();
    reupload_world_textures();
    build_world_mesh();
    upload_map();

    /* эмбиент этапа -- реальный файл, если он лежит в assets/, иначе тихо
     * ничего не играет (см. game.h) */
    Mix_HaltChannel(0);
    if (snd_story_l1_denial) { Mix_VolumeChunk(snd_story_l1_denial, 70); Mix_PlayChannel(0, snd_story_l1_denial, -1); }
}

/* показать субтитр на фиксированное время с плавным затуханием на краях */
static double subtitle_remain = 0.0, subtitle_total = 1.0;
static void show_subtitle(const char **lines, double dur) {
    story_subtitle_lines = lines;
    subtitle_remain = subtitle_total = dur;
}
static void update_subtitle_fade(double dt) {
    if (subtitle_remain <= 0.0) { story_subtitle_a = 0.0; return; }
    subtitle_remain -= dt;
    if (subtitle_remain <= 0.0) { story_subtitle_lines = NULL; story_subtitle_a = 0.0; return; }
    double fade_in = 0.4, fade_out = 0.8;
    double a = 1.0;
    if (subtitle_total - subtitle_remain < fade_in) a = (subtitle_total - subtitle_remain) / fade_in;
    else if (subtitle_remain < fade_out) a = subtitle_remain / fade_out;
    story_subtitle_a = a;
}

/* Каждый кадр, пока story_mode и ST_PLAY. Движение уже применено снаружи
 * (main.c) -- тут только сюжетные триггеры и заскриптованные сцены.     */
void story_update(double dt) {
    update_subtitle_fade(dt);

    if (denial_phase == DENIAL_APPROACH) {
        for (int i = 0; i < DENIAL_MEMORIES; i++)
            if (!memory_seen[i] && fabs(posY - MEMORY_Y[i]) < 1.4 && fabs(posX - 14.5) < 2.0) {
                memory_seen[i] = 1;
                show_subtitle(DENIAL_TEXTS[i], MEMORY_POPUP_DUR);
            }
        double dd = (posX - doorX) * (posX - doorX) + (posY - doorY) * (posY - doorY);
        if (dd < 1.1) {
            /* дошёл до двери -- она "открывается", и вместо матери-ИИ
             * просто ставим её в проёме и запускаем отповедь по репликам */
            keys_left = 0; build_world_mesh();
            story_mother_visible = 1;
            story_motherX = 14.5; story_motherY = 15.6;   /* чуть внутри дома, за порогом (дом начинается южнее y=14) */
            story_speed_mult = 0.0;             /* замер на месте, пока отчитывает */
            denial_phase = DENIAL_CONFRONT;
            mother_line_idx = 0; mother_line_timer = MOTHER_LINE_DUR;
            mother_line_buf[0] = MOTHER_LINES[0]; mother_line_buf[1] = NULL;
            show_subtitle(mother_line_buf, MOTHER_LINE_DUR + 0.8);
        }
    } else if (denial_phase == DENIAL_CONFRONT) {
        mother_line_timer -= dt;
        if (mother_line_timer <= 0.0) {
            mother_line_idx++;
            if (mother_line_idx >= MOTHER_LINES_N) {
                /* отповедь окончена -- гонит его в комнату */
                story_mother_visible = 0;
                posX = childRoomX; posY = childRoomY;
                story_speed_mult = 1.0;
                denial_phase = DENIAL_AFTERMATH;
                story_subtitle_lines = NULL;
            } else {
                mother_line_timer = MOTHER_LINE_DUR;
                mother_line_buf[0] = MOTHER_LINES[mother_line_idx]; mother_line_buf[1] = NULL;
                show_subtitle(mother_line_buf, MOTHER_LINE_DUR + 0.8);
            }
        }
    }
    /* DENIAL_AFTERMATH: он уже в своей комнате -- дальше следующий шаг */
}

/* E во время отповеди матери -- пропустить текущую реплику, не ждать таймер */
void story_try_interact(void) {
    if (denial_phase == DENIAL_CONFRONT) mother_line_timer = 0.0;
}
