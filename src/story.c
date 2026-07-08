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

#define MOTHER_LINE_DUR 4.0
#define MEMORY_POPUP_DUR 8.5

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

/* крыша дома -- три вложенные "ступени" вместо гладкого ската (движок
 * умеет только осепараллельные коробки), плюс труба: силуэт читается как
 * двускатная крыша, а не плоская коробка без верха.                     */
static void place_roof(double cx, double cz, double hwx, double hwz) {
    float tr = 0.32f, tg = 0.16f, tb = 0.13f;    /* тёмная кровля */
    if (prop_count < MAX_PROPS)      /* карниз -- нависает над стенами   */
        props[prop_count++] = (Prop){ cx, cz, hwx + 0.4, hwz + 0.4, wall_h, wall_h + 0.16f, tr, tg, tb };
    if (prop_count < MAX_PROPS)      /* средний ярус -- уже и выше       */
        props[prop_count++] = (Prop){ cx, cz, hwx * 0.66, hwz * 0.66, wall_h + 0.16f, wall_h + 0.62f, tr * 1.05f, tg * 1.05f, tb * 1.05f };
    if (prop_count < MAX_PROPS)      /* конёк                            */
        props[prop_count++] = (Prop){ cx, cz, hwx * 0.30, hwz * 0.30, wall_h + 0.62f, wall_h + 0.86f, tr * 1.1f, tg * 1.1f, tb * 1.1f };
    if (prop_count < MAX_PROPS)      /* труба -- отец у телевизора, но дом топят */
        props[prop_count++] = (Prop){ cx + hwx * 0.5, cz - hwz * 0.4, 0.22, 0.22, wall_h + 0.2f, wall_h + 1.3f, 0.32f, 0.28f, 0.26f };
}

/* Комната героя (x 2-6, y 11-16 внутри стен wall_ring(1,10,7,17)):
 * кровать, стол со стулом, и дверь на стене -- пока декоративная, герой
 * сюда попадает по сценарию, а не пешком. Когда появится проход из дома,
 * дверь на этой же стене станет настоящей. */
static void place_child_room_furniture(void) {
    /* кровать вдоль южной стены -- продавленный матрас и подушка */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 3.3, 15.3, 1.15, 0.55, 0.0, 0.26, 0.40f, 0.34f, 0.26f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 2.4, 15.3, 0.32, 0.42, 0.26, 0.40, 0.62f, 0.58f, 0.50f };
    /* стол и стул в углу у окна (окна пока нет -- см. будущие доработки) */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 5.6, 11.6, 0.42, 0.42, 0.0, 0.46, 0.42f, 0.30f, 0.20f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 5.6, 12.5, 0.22, 0.22, 0.0, 0.42, 0.36f, 0.26f, 0.18f };
    /* дверь на западной стене -- декоративная, ждёт коридора из дома */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 1.3, 13.5, 0.05, 0.55, 0.0, 0.9, 0.30f, 0.20f, 0.14f };
}

/* Двор дома, где пьют и срываются на детях: не ухоженная лужайка, а
 * заросший бурьяном участок с мусором, битым стеклом и ржавой развалюхой
 * машины у забора. Обходит дорогу, дом и беседку.                       */
static int yard_blocked(double x, double z) {
    if (x > 9.0 && x < 19.0 && z > 13.0 && z < 20.0) return 1;   /* дом      */
    if (x > 12.0 && x < 16.0 && z < 14.0) return 1;              /* дорога   */
    if (fabs(x - 22.0) < 2.3 && fabs(z - 6.0) < 2.3) return 1;   /* беседка  */
    if (x > 0.5 && x < 7.5 && z > 9.5 && z < 17.5) return 1;     /* комната героя */
    return 0;
}
static void place_yard_clutter(void) {
    /* заросли бурьяна -- пожелтевшая, неухоженная трава пучками, гуще у стен */
    for (int i = 0; i < 46 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        float g = 0.32f + frand() * 0.28f;
        props[prop_count++] = (Prop){ x, z, 0.07 + frand() * 0.07, 0.07 + frand() * 0.07,
            0.0, 0.20 + frand() * 0.28, g, g * 1.35f, g * 0.28f };
    }
    /* мелкие камни, разбросанные по всему двору */
    for (int i = 0; i < 16 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        float g = 0.30f + frand() * 0.12f;
        props[prop_count++] = (Prop){ x, z, 0.06 + frand() * 0.05, 0.06 + frand() * 0.05,
            0.0, 0.07 + frand() * 0.06, g, g * 0.96f, g * 0.92f };
    }
    /* пустые бутылки -- бурое и зелёное стекло вперемешку, особенно у крыльца */
    for (int i = 0; i < 15 && prop_count < MAX_PROPS; i++) {
        double x = 12.5 + frand() * 4.0, z = 10.5 + frand() * 3.5;
        if (yard_blocked(x, z)) continue;
        int brown = frand() < 0.5;
        props[prop_count++] = (Prop){ x, z, 0.05, 0.05, 0.0, 0.16 + frand() * 0.05,
            brown ? 0.20f : 0.10f, brown ? 0.14f : 0.22f, brown ? 0.06f : 0.12f };
    }
    /* ещё бутылки, раскиданные по всему двору -- не только у крыльца */
    for (int i = 0; i < 10 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        int brown = frand() < 0.5;
        props[prop_count++] = (Prop){ x, z, 0.05, 0.05, 0.0, 0.16 + frand() * 0.05,
            brown ? 0.20f : 0.10f, brown ? 0.14f : 0.22f, brown ? 0.06f : 0.12f };
    }
    /* мусор -- смятые кучи, ничем не прикрытые, гуще у стен дома */
    for (int i = 0; i < 14 && prop_count < MAX_PROPS; i++) {
        double x = 1.5 + frand() * (MW - 3.0), z = 1.5 + frand() * (MH - 3.0);
        if (yard_blocked(x, z)) continue;
        props[prop_count++] = (Prop){ x, z, 0.18 + frand() * 0.20, 0.18 + frand() * 0.20,
            0.0, 0.12 + frand() * 0.18, 0.32f, 0.29f, 0.24f };
    }
    /* куча мусора и старых листьев прямо у стен дома, будто годами не убирали */
    { double wallx[4] = { 9.6, 18.4, 12, 16 }, wallz[4] = { 15, 17, 13.6, 13.6 };
      for (int i = 0; i < 4 && prop_count < MAX_PROPS; i++)
          props[prop_count++] = (Prop){ wallx[i], wallz[i], 0.30 + frand() * 0.14, 0.24 + frand() * 0.12,
              0.0, 0.10 + frand() * 0.10, 0.30f, 0.27f, 0.16f }; }
    /* ржавый забор -- рваный, с провалами, не по всему периметру */
    for (int x = 2; x <= MW - 3 && prop_count < MAX_PROPS; x += 2) {
        if (frand() < 0.35) continue;                     /* провалы в заборе */
        if (yard_blocked(x, 2.5)) continue;
        props[prop_count++] = (Prop){ x, 2.3, 0.05, 0.05, 0.0, 0.62, 0.42f, 0.24f, 0.16f };
    }
    /* брошенная ржавая машина у забора -- со сплюснутой "крышей" */
    double cx = MW - 6.0, cz = 5.0;
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, 1.5, 0.85, 0.0, 0.55, 0.28f, 0.14f, 0.10f };
    if (prop_count < MAX_PROPS)
        props[prop_count++] = (Prop){ cx, cz, 1.1, 0.7, 0.55, 0.72, 0.24f, 0.12f, 0.09f };

    /* бельевая верёвка на двух покосившихся столбах -- забыта, бельё
     * никогда не снимают */
    double clx0 = 20.0, clx1 = 23.0, clz = 12.0;
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ clx0, clz, 0.05, 0.05, 0.0, 1.0, 0.30f, 0.22f, 0.16f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ clx1, clz, 0.05, 0.05, 0.0, 1.0, 0.30f, 0.22f, 0.16f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ (clx0 + clx1) / 2, clz, (clx1 - clx0) / 2, 0.02, 0.97, 1.0, 0.55f, 0.52f, 0.46f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ clx0 + 0.6, clz, 0.14, 0.03, 0.7, 0.95, 0.62f, 0.60f, 0.55f };   /* забытая тряпка */

    /* шаткое крыльцо со ступенькой у самой двери -- уже, вплотную к проёму */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 14.5, 13.3, 0.55, 0.4, 0.0, 0.16, 0.28f, 0.24f, 0.20f };
    /* засохший цветок в треснувшем горшке рядом с крыльцом -- единственная
     * попытка уюта, давно заброшенная */
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 13.0, 13.5, 0.14, 0.14, 0.0, 0.22, 0.32f, 0.20f, 0.14f };
    if (prop_count < MAX_PROPS) props[prop_count++] = (Prop){ 13.0, 13.5, 0.03, 0.03, 0.22, 0.42, 0.35f, 0.30f, 0.10f };
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
    /* комната героя: сейчас запечатана со всех сторон -- сюда его
     * "отправляют" скриптом после отповеди. Дверь на своей стене уже
     * стоит (декоративно) для будущего шага, когда туда нужно будет
     * дойти самому пешком, а не оказаться там по сценарию. */
    wall_ring(1, 10, 7, 17);

    /* -------- темы зон, чтобы дорога/дом/комната были раскрашены и
     * дорога с лужайкой остались без потолка (см. build_world_mesh) --
     * порядок важен: узкие зоны идут раньше широкой лужайки-заглушки. */
    room_count = 0;
    rooms[room_count++] = (Room){ 13, 1, 3, 13, RM_ROAD };        /* дорога к дому   */
    rooms[room_count++] = (Room){ 11, 15, 7, 4, RM_ENTRANCE };    /* внутри дома     */
    rooms[room_count++] = (Room){ 2, 11, 5, 6, RM_ENTRANCE };     /* комната героя   */
    rooms[room_count++] = (Room){ 1, 1, MW - 2, MH - 2, RM_LAWN };/* лужайка (фон)   */

    /* стены дома поднимаются под двухэтажную высоту -- нужно раньше
     * place_roof (крыша садится на верх стен) */
    wall_h = 2.0f;

    /* беседка, крыша дома, заросший захламлённый двор, и обстановка
     * комнаты героя (кровать/стол/стул/дверь) */
    prop_count = 0;
    place_gazebo(22.0, 6.0);
    place_roof(14.0, 16.5, 4.0, 2.5);
    place_yard_clutter();
    place_child_room_furniture();

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

    childRoomX = 4.5; childRoomY = 13.5;

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
