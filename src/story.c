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
 * воспоминание целиком. Двухэтажный дом с лужайкой и беседкой стоит
 * посреди пустоты (лужайка/дорога отрисовываются без потолка -- см.
 * RM_LAWN/RM_ROAD в build_world_mesh, render.c). Игрок появляется на
 * проезжей части перед домом; по пути к двери всплывают три воспоминания
 * (внутренний голос оправдывает то, что видел). У двери его встречает
 * мать -- без лица (у неё никогда нет настроения, лицо ей ни к чему),
 * отчитывает и гонит в комнату наверху.
 *
 * "Второй этаж" здесь -- отдельная зона той же плоской карты (движок не
 * умеет по-настоящему многоуровневые Z-этажи), связанная с первым этажом
 * лестницей-триггером в холле: подходишь -- тебя переносит наверх, и
 * обратно так же вниз. Первый этаж и второй расставлены по мотивам
 * планировки, которую дал пользователь (см. комментарии у каждой комнаты).
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
 * дверях -> он уже наверху, в своей комнате, и может обойти весь дом.   */
enum { DENIAL_APPROACH, DENIAL_CONFRONT, DENIAL_AFTERMATH };
static int denial_phase;

/* -------------------------------------------------- всплывающие воспоминания */
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
static const double MEMORY_Y[DENIAL_MEMORIES] = { 4.0, 7.0, 10.0 };
static int memory_seen[DENIAL_MEMORIES];

/* -------------------------------------------------------- реплики матери */
#define MOTHER_LINES_N 4
static const char *MOTHER_LINES[MOTHER_LINES_N] = {
    "ГДЕ ТЫ ШЛЯЛСЯ?",
    "ОПЯТЬ ОДНИ ПРОБЛЕМЫ ИЗ-ЗА ТЕБЯ.",
    "ВЕЧНО ТЫ ВСЁ ПОРТИШЬ.",
    "МАРШ В КОМНАТУ. НЕ ПОПАДАЙСЯ МНЕ НА ГЛАЗА.",
};
static int    mother_line_idx;
static double mother_line_timer;
static const char *mother_line_buf[2];

#define MOTHER_LINE_DUR 4.0
#define MEMORY_POPUP_DUR 8.5

static double doorX, doorY;          /* порог дома, где начинается сцена с матерью */
static double kid1X, kid1Y;          /* детская 1 -- куда мать отправляет героя    */
static double stairsUpX, stairsUpY, stairsUpToX, stairsUpToY;
static double stairsDnX, stairsDnY, stairsDnToX, stairsDnToY;
static double stairs_cooldown = 0.0;

/* закрасить прямоугольник (включительно) полом -- свой, отдельный от
 * carve_rect в gen.c: уровень тут не процедурный, а прописан руками. */
static void carve(int x0, int y0, int x1, int y1) {
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++)
            if (x > 0 && x < MW - 1 && y > 0 && y < MH - 1) map[y][x] = '.';
}
/* обвести прямоугольник стеной (для комнат, вырезанных из лужайки) */
static void wall_ring(int x0, int y0, int x1, int y1) {
    for (int x = x0; x <= x1; x++) { map[y0][x] = '#'; map[y1][x] = '#'; }
    for (int y = y0; y <= y1; y++) { map[y][x0] = '#'; map[y][x1] = '#'; }
}
static void door_gap(int x, int y) { map[y][x] = '.'; }

/* беседка на лужайке -- просто декор: четыре столба и плоская крыша. */
static void place_gazebo(double cx, double cz) {
    float tr = 0.55f, tg = 0.42f, tb = 0.30f;
    double half = 1.6;
    double px[4] = { cx - half, cx + half, cx - half, cx + half };
    double pz[4] = { cz - half, cz - half, cz + half, cz + half };
    for (int i = 0; i < 4 && prop_count < MAX_PROPS; i++)
        props[prop_count++] = (Prop){ px[i], pz[i], 0.09, 0.09, 0.0, 1.15, tr, tg, tb };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, half + 0.25, half + 0.25, 1.05, 1.20, tr * 0.85f, tg * 0.85f, tb * 0.85f };
}

/* крыша -- вложенные "ступени" вместо гладкого ската (движок умеет только
 * осепараллельные коробки); подходит и для дома, и для зоны верхнего этажа. */
static void place_roof(double cx, double cz, double hwx, double hwz) {
    float tr = 0.32f, tg = 0.16f, tb = 0.13f;
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, hwx + 0.4, hwz + 0.4, wall_h, wall_h + 0.16f, tr, tg, tb };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, hwx * 0.66, hwz * 0.66, wall_h + 0.16f, wall_h + 0.62f, tr * 1.05f, tg * 1.05f, tb * 1.05f };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, hwx * 0.30, hwz * 0.30, wall_h + 0.62f, wall_h + 0.86f, tr * 1.1f, tg * 1.1f, tb * 1.1f };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx + hwx * 0.5, cz - hwz * 0.4, 0.22, 0.22, wall_h + 0.2f, wall_h + 1.3f, 0.32f, 0.28f, 0.26f };
}

/* --------------------------------------------------------- первый этаж */
/* По плану пользователя: тамбур, бойлерная, холл с лестницей, гостевой
 * санузел, гостевая спальня/кабинет, и единое пространство кухни-гостиной
 * (кухня + столовая + зона отдыха, без внутренних стен).                */
static void build_ground_floor(void) {
    wall_ring(8, 13, 32, 31);            /* внешние стены первого этажа  */
    wall_ring(12, 13, 16, 16);           /* тамбур-прихожая              */
    wall_ring(17, 13, 20, 16);           /* бойлерная/техпомещение       */
    wall_ring(12, 17, 16, 22);           /* холл с лестницей             */
    wall_ring(8, 17, 11, 20);            /* гостевой санузел             */
    wall_ring(8, 21, 14, 27);            /* гостевая спальня / кабинет   */

    /* дверные проёмы -- carve'ятся ПОСЛЕ всех wall_ring выше: иначе более
     * поздний wall_ring, делящий ту же стену на две комнаты, затирал бы
     * проём, прорезанный раньше (как случилось с входной дверью). */
    door_gap(14, 13);                    /* входная дверь с дороги       */
    door_gap(16, 14); door_gap(17, 14);  /* тамбур <-> бойлерная         */
    door_gap(14, 16); door_gap(14, 17);  /* тамбур <-> холл              */
    door_gap(16, 18); door_gap(16, 19); door_gap(16, 20);  /* холл -> кухня-гостиная, широкий проём без двери */
    door_gap(11, 18); door_gap(12, 18);  /* санузел <-> холл             */
    door_gap(13, 21); door_gap(13, 22);  /* спальня <-> холл             */

    /* кухня-гостиная -- всё, что осталось внутри внешних стен и не
     * обнесено собственным кольцом выше: единое пространство нарочно
     * без перегородок (зона кухни/столовая/отдых различаются мебелью) */

    room_count = 0;
    rooms[room_count++] = (Room){ 13, 1, 3, 12, RM_ROAD };
    rooms[room_count++] = (Room){ 12, 13, 5, 4, RM_ENTRANCE };   /* тамбур   */
    rooms[room_count++] = (Room){ 17, 13, 4, 4, RM_STORAGE };    /* бойлерная -- рыжеватый тон труб и котла */
    rooms[room_count++] = (Room){ 12, 17, 5, 6, RM_ENTRANCE };   /* холл     */
    rooms[room_count++] = (Room){ 8, 17, 4, 4, RM_ENTRANCE };    /* гостевой санузел */
    rooms[room_count++] = (Room){ 8, 21, 7, 7, RM_ENTRANCE };    /* гостевая спальня */
    rooms[room_count++] = (Room){ 17, 13, 15, 18, RM_LIBRARY };  /* кухня-гостиная -- прохладный дневной тон окон */
}

static void place_ground_floor_furniture(void) {
    /* тамбур: глубокий шкаф-купе для верхней одежды */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 15.3, 13.6, 0.5, 0.18, 0.0, 1.3, 0.32f, 0.22f, 0.16f };
    /* бойлерная: котёл и бойлер */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 18.4, 14.4, 0.3, 0.3, 0.0, 1.1, 0.42f, 0.42f, 0.44f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 19.3, 15.3, 0.22, 0.22, 0.0, 0.9, 0.55f, 0.50f, 0.30f };
    /* холл: лестница наверх -- растущие по высоте ступени вдоль стены,
     * и кладовая под лестницей (просто тёмный короб) */
    for (int i = 0; i < 6 && prop_count < MAX_PROPS; i++)
        props[prop_count++] = (Prop){ 15.3, 18.4 + i * 0.35, 0.45, 0.16, 0.0, 0.14 + i * 0.16, 0.36f, 0.28f, 0.20f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 13.0, 21.3, 0.5, 0.35, 0.0, 0.85, 0.26f, 0.20f, 0.16f };
    /* гостевой санузел: унитаз, раковина, душевая кабина */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 9.3, 18.3, 0.18, 0.2, 0.0, 0.38, 0.75f, 0.75f, 0.75f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 10.5, 18.3, 0.22, 0.16, 0.35, 0.55, 0.72f, 0.74f, 0.76f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 9.3, 19.5, 0.4, 0.05, 0.0, 1.6, 0.55f, 0.62f, 0.66f };
    /* гостевая спальня/кабинет: кровать + рабочий стол со стулом */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 9.6, 25.3, 1.0, 0.55, 0.0, 0.26, 0.42f, 0.36f, 0.28f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 12.7, 22.6, 0.42, 0.32, 0.0, 0.46, 0.36f, 0.26f, 0.18f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 12.7, 23.4, 0.2, 0.2, 0.0, 0.42, 0.30f, 0.22f, 0.16f };
    /* кухня-гостиная: остров кухни, обеденный стол на четверых, диван и ТВ-тумба */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 20.0, 15.6, 0.9, 0.55, 0.0, 0.5, 0.42f, 0.30f, 0.22f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 26.0, 15.5, 0.85, 0.85, 0.0, 0.42, 0.40f, 0.30f, 0.22f };
    { double dx[4] = { 25.1, 26.9, 26.0, 26.0 }, dz[4] = { 15.5, 15.5, 14.6, 16.4 };
      for (int i = 0; i < 4 && prop_count < MAX_PROPS; i++)
          props[prop_count++] = (Prop){ dx[i], dz[i], 0.18, 0.18, 0.0, 0.42, 0.32f, 0.24f, 0.18f }; }
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 27.0, 26.0, 1.3, 0.55, 0.0, 0.42, 0.30f, 0.22f, 0.30f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 27.0, 28.0, 0.55, 0.18, 0.0, 0.5, 0.18f, 0.16f, 0.16f };
}

/* --------------------------------------------------------- второй этаж */
/* Отдельная зона той же карты (движок не умеет Z-этажи), нарочно вынесенная
 * далеко на восток -- если бы она стояла там, где напрашивается (сразу за
 * домом), её стены перекрыли бы саму дорогу к входной двери. Центральный
 * холл, мастер-спальня (с гардеробом и санузлом мебелью прямо в углах --
 * отдельные комнаты под них тут не влезают), две детские, общий санузел.
 * Пока изолирована от первого этажа -- связь только через лестницу.     */
static void build_upper_floor(void) {
    wall_ring(34, 1, 53, 12);
    /* центральный холл -- сплошной коридор y=6, соединяет все комнаты,
     * сам ни через одну из них не проходит */
    wall_ring(35, 1, 43, 5);             /* мастер-спальня (родительская) */
    wall_ring(44, 1, 48, 5);             /* детская 1                     */
    wall_ring(49, 1, 53, 5);             /* детская 2                     */
    wall_ring(35, 7, 40, 11);            /* общий санузел                 */
    door_gap(39, 5);                     /* мастер-спальня <-> холл       */
    door_gap(46, 5);                     /* детская 1 <-> холл            */
    door_gap(51, 5);                     /* детская 2 <-> холл            */
    door_gap(37, 7);                     /* санузел <-> холл              */

    /* room_count уже накоплен build_ground_floor -- продолжаем тем же массивом */
    rooms[room_count++] = (Room){ 35, 1, 8, 5, RM_ENTRANCE };    /* мастер-спальня */
    rooms[room_count++] = (Room){ 44, 1, 4, 5, RM_ENTRANCE };    /* детская 1      */
    rooms[room_count++] = (Room){ 49, 1, 4, 5, RM_ENTRANCE };    /* детская 2      */
    rooms[room_count++] = (Room){ 35, 7, 5, 5, RM_ENTRANCE };    /* общий санузел  */
    /* холл верхнего этажа не тонируется отдельно -- остаётся нейтральным
     * (theme_at возвращает -1 для клеток вне перечисленных комнат)      */

    kid1X = 46.0; kid1Y = 3.0;
}

static void place_upper_floor_furniture(void) {
    /* мастер-спальня (интерьер x36-42,y2-4): кровать побольше, гардероб и
     * "санузел" мебелью в углу -- отдельные комнаты под них тут не влезают */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 38.0, 3.4, 1.2, 0.6, 0.0, 0.28, 0.40f, 0.30f, 0.30f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 41.3, 2.4, 0.3, 0.35, 0.0, 1.3, 0.30f, 0.22f, 0.18f };   /* гардероб */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 41.3, 3.8, 0.3, 0.3, 0.0, 0.5, 0.70f, 0.72f, 0.75f };    /* раковина санузла */

    /* детская 1 (интерьер x45-47,y2-4) -- кровать, стол со стулом, дверь на
     * стене (герой сюда попадает по сценарию из сцены с матерью) */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 46.0, 3.5, 0.85, 0.45, 0.0, 0.26, 0.40f, 0.34f, 0.26f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 45.3, 3.1, 0.22, 0.28, 0.26, 0.40, 0.62f, 0.58f, 0.50f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 46.6, 2.3, 0.28, 0.28, 0.0, 0.46, 0.42f, 0.30f, 0.20f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 46.6, 2.7, 0.16, 0.16, 0.0, 0.42, 0.36f, 0.26f, 0.18f };

    /* детская 2 (интерьер x50-52,y2-4) -- зеркальная планировка */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 51.0, 3.5, 0.85, 0.45, 0.0, 0.26, 0.38f, 0.30f, 0.30f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 51.6, 3.1, 0.22, 0.28, 0.26, 0.40, 0.60f, 0.56f, 0.52f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 50.4, 2.3, 0.28, 0.28, 0.0, 0.46, 0.40f, 0.28f, 0.20f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 50.4, 2.7, 0.16, 0.16, 0.0, 0.42, 0.34f, 0.24f, 0.18f };

    /* общий санузел (интерьер x36-39,y8-10) -- душевая, унитаз, стиральная со стиркой */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 36.5, 8.4, 0.3, 0.05, 0.0, 1.6, 0.55f, 0.62f, 0.66f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 39.0, 8.4, 0.18, 0.2, 0.0, 0.38, 0.75f, 0.75f, 0.75f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 36.6, 10.3, 0.28, 0.28, 0.0, 0.6, 0.68f, 0.68f, 0.70f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 37.4, 10.3, 0.28, 0.28, 0.0, 0.6, 0.70f, 0.70f, 0.72f };
}

/* Двор дома, где пьют и срываются на детях: не ухоженная лужайка, а
 * заросший бурьяном участок с мусором, битым стеклом и ржавой развалюхой
 * машины у забора. Обходит дорогу, дом, беседку и зону верхнего этажа.  */
static int yard_blocked(double x, double z) {
    if (x > 7.5 && x < 33.0 && z > 12.0 && z < 32.0) return 1;   /* первый этаж   */
    if (x > 12.0 && x < 16.0 && z < 14.0) return 1;              /* дорога        */
    if (fabs(x - 26.0) < 2.3 && fabs(z - 6.0) < 2.3) return 1;   /* беседка       */
    if (x > 33.5 && x < 53.5 && z > 0.5 && z < 12.5) return 1;   /* зона верхнего этажа */
    return 0;
}
static void place_yard_clutter(void) {
    for (int i = 0; i < 46 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        float g = 0.32f + frand() * 0.28f;
        props[prop_count++] = (Prop){ x, z, 0.07 + frand() * 0.07, 0.07 + frand() * 0.07,
            0.0, 0.20 + frand() * 0.28, g, g * 1.35f, g * 0.28f };
    }
    for (int i = 0; i < 16 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        float g = 0.30f + frand() * 0.12f;
        props[prop_count++] = (Prop){ x, z, 0.06 + frand() * 0.05, 0.06 + frand() * 0.05,
            0.0, 0.07 + frand() * 0.06, g, g * 0.96f, g * 0.92f };
    }
    for (int i = 0; i < 15 && prop_count < MAX_PROPS; i++) {
        double x = 12.5 + frand() * 4.0, z = 10.5 + frand() * 3.5;
        if (yard_blocked(x, z)) continue;
        int brown = frand() < 0.5;
        props[prop_count++] = (Prop){ x, z, 0.05, 0.05, 0.0, 0.16 + frand() * 0.05,
            brown ? 0.20f : 0.10f, brown ? 0.14f : 0.22f, brown ? 0.06f : 0.12f };
    }
    for (int i = 0; i < 10 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        int brown = frand() < 0.5;
        props[prop_count++] = (Prop){ x, z, 0.05, 0.05, 0.0, 0.16 + frand() * 0.05,
            brown ? 0.20f : 0.10f, brown ? 0.14f : 0.22f, brown ? 0.06f : 0.12f };
    }
    for (int i = 0; i < 14 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        props[prop_count++] = (Prop){ x, z, 0.18 + frand() * 0.20, 0.18 + frand() * 0.20,
            0.0, 0.12 + frand() * 0.18, 0.32f, 0.29f, 0.24f };
    }
    { double wallx[4] = { 8.6, 32.4, 12, 16 }, wallz[4] = { 15, 17, 12.6, 12.6 };
      for (int i = 0; i < 4 && prop_count < MAX_PROPS; i++)
          props[prop_count++] = (Prop){ wallx[i], wallz[i], 0.30 + frand() * 0.14, 0.24 + frand() * 0.12,
              0.0, 0.10 + frand() * 0.10, 0.30f, 0.27f, 0.16f }; }
    for (int x = 2; x <= MW - 3 && prop_count < MAX_PROPS; x += 2) {
        if (frand() < 0.35) continue;
        if (yard_blocked(x, 2.5)) continue;
        props[prop_count++] = (Prop){ x, 2.3, 0.05, 0.05, 0.0, 0.62, 0.42f, 0.24f, 0.16f };
    }
    /* машина и бельевая верёвка -- в открытой лужайке южнее дома, подальше
     * и от зоны верхнего этажа (восток), и от дороги/дома/беседки */
    double cx = 44.0, cz = 36.0;
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, 1.5, 0.85, 0.0, 0.55, 0.28f, 0.14f, 0.10f };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, 1.1, 0.7, 0.55, 0.72, 0.24f, 0.12f, 0.09f };

    double clx0 = 20.0, clx1 = 23.0, clz = 36.0;
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ clx0, clz, 0.05, 0.05, 0.0, 1.0, 0.30f, 0.22f, 0.16f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ clx1, clz, 0.05, 0.05, 0.0, 1.0, 0.30f, 0.22f, 0.16f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ (clx0 + clx1) / 2, clz, (clx1 - clx0) / 2, 0.02, 0.97, 1.0, 0.55f, 0.52f, 0.46f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ clx0 + 0.6, clz, 0.14, 0.03, 0.7, 0.95, 0.62f, 0.60f, 0.55f };

    /* крыльцо -- низкая ступень (узкая по высоте), но во всю ширину проёма */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 14.5, 12.3, 0.9, 0.4, 0.0, 0.08, 0.28f, 0.24f, 0.20f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 13.0, 12.5, 0.14, 0.14, 0.0, 0.22, 0.32f, 0.20f, 0.14f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 13.0, 12.5, 0.03, 0.03, 0.22, 0.42, 0.35f, 0.30f, 0.10f };
}

/* Уровень 1, стадия "Отрицание": двухэтажный дом с лужайкой и беседкой
 * посреди пустоты. Игрок появляется на дороге перед домом.               */
void story_start_denial(void) {
    story_level = 1;
    story_stage = STORY_DENIAL;
    denial_phase = DENIAL_APPROACH;

    for (int y = 0; y < MH; y++) { for (int x = 0; x < MW; x++) map[y][x] = '#'; map[y][MW] = 0; }
    carve(1, 1, MW - 2, MH - 2);

    wall_h = 2.0f;   /* двухэтажная высота стен -- нужно раньше place_roof (крыша садится сверху) */

    build_ground_floor();
    build_upper_floor();

    prop_count = 0;
    place_gazebo(26.0, 6.0);
    place_roof(20.0, 22.0, 12.0, 9.0);      /* крыша первого этажа   */
    place_roof(10.5, 6.5, 9.5, 5.5);        /* крыша над зоной верхнего этажа */
    place_yard_clutter();
    place_ground_floor_furniture();
    place_upper_floor_furniture();

    /* точка спавна: на дороге перед домом, лицом к двери */
    startX = 14; startY = 1;
    posX = startX + 0.5; posY = startY + 1.5; yaw = 1.5708; pitch = 0;

    /* дверь дома -- начинается закрытой (add_door рисует "замок"), и
     * буквально "открывается" (build_world_mesh) в момент, когда игрок
     * подходит вплотную -- см. story_update(). */
    doorX = 14.5; doorY = 13.5;
    exitX = doorX; exitY = doorY;
    doorNx = 0; doorNz = 1;
    num_keys = 1; keys_left = 1;

    /* лестница в холле первого этажа <-> холл второго этажа, в обе стороны */
    stairsUpX = 15.5; stairsUpY = 20.5; stairsUpToX = 43.5; stairsUpToY = 6.5;
    stairsDnX = 36.5; stairsDnY = 6.5;  stairsDnToX = 15.5; stairsDnToY = 22.5;
    stairs_cooldown = 0.0;

    /* сброс триггеров и субтитров */
    for (int i = 0; i < DENIAL_MEMORIES; i++) memory_seen[i] = 0;
    story_subtitle_lines = NULL; story_subtitle_a = 0.0;
    story_mother_visible = 0;
    story_speed_mult = 0.26;   /* совсем медленный, тяжёлый шаг -- время прочитать всё */

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
     * подменяем напрямую, не трогая biome/NBIOMES бесконечного режима. */
    depth = 1;
    bwall[0] = 1.05f;  bwall[1] = 0.92f;  bwall[2] = 0.72f;
    bfloor[0] = 0.55f; bfloor[1] = 0.40f; bfloor[2] = 0.28f;
    bceil[0] = 0.95f;  bceil[1] = 0.90f;  bceil[2] = 0.80f;
    /* процедурные текстуры тут очень тёмные по своей природе (расчёт на
     * подсветку факелами вблизи) -- чтобы лужайка вдали от факелов не
     * тонула в черноте, ambient держим настолько высоким, что дневной
     * свет фактически проступает через саму текстуру, а не только тонирует. */
    biome_amb[0] = 3.6f; biome_amb[1] = 3.5f; biome_amb[2] = 3.3f;
    biome_torch[0] = 1.00f; biome_torch[1] = 0.70f; biome_torch[2] = 0.40f;

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
    double fade_in = 1.1, fade_out = 1.8;
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
            keys_left = 0; build_world_mesh();     /* дверь "открывается" */
            story_mother_visible = 1;
            story_motherX = 14.5; story_motherY = 14.6;   /* чуть внутри тамбура, за порогом */
            story_speed_mult = 0.0;
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
                /* отповедь окончена -- гонит его в детскую наверху */
                story_mother_visible = 0;
                posX = kid1X; posY = kid1Y;
                story_speed_mult = 1.0;
                denial_phase = DENIAL_AFTERMATH;
                story_subtitle_lines = NULL;
            } else {
                mother_line_timer = MOTHER_LINE_DUR;
                mother_line_buf[0] = MOTHER_LINES[mother_line_idx]; mother_line_buf[1] = NULL;
                show_subtitle(mother_line_buf, MOTHER_LINE_DUR + 0.8);
            }
        }
    } else if (denial_phase == DENIAL_AFTERMATH) {
        /* он уже наверху -- теперь дом открыт для свободного обхода,
         * включая лестницу между этажами (в обе стороны, с коротким
         * "остыванием", чтобы не перекинуло туда-обратно за один шаг). */
        if (stairs_cooldown > 0.0) stairs_cooldown -= dt;
        else {
            double du = (posX - stairsUpX) * (posX - stairsUpX) + (posY - stairsUpY) * (posY - stairsUpY);
            double dn = (posX - stairsDnX) * (posX - stairsDnX) + (posY - stairsDnY) * (posY - stairsDnY);
            if (du < 1.0) { posX = stairsUpToX; posY = stairsUpToY; stairs_cooldown = 1.5; }
            else if (dn < 1.0) { posX = stairsDnToX; posY = stairsDnToY; stairs_cooldown = 1.5; }
        }
    }
}

/* E во время отповеди матери -- пропустить текущую реплику, не ждать таймер */
void story_try_interact(void) {
    if (denial_phase == DENIAL_CONFRONT) mother_line_timer = 0.0;
}
