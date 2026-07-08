/*
 * NIGHTFALL — сюжетный режим.
 *
 * В отличие от бесконечного спуска (gen.c генерирует этажи процедурно),
 * здесь уровни рукописные: карта прописана вручную как есть, вместо
 * generate_rooms(). Каждый уровень сюжетки — отдельная психологическая
 * травма, а внутри уровня игрок проходит пять стадий принятия горя
 * (Кюблер-Росс): Отрицание -> Гнев -> Торги -> Депрессия -> Принятие.
 *
 * Пока реализован только Уровень 1 (семейная травма) / стадия "Отрицание".
 * Остальные стадии и уровни -- следующие шаги; см. story_start_denial()
 * как шаблон для них.
 *
 * Геймплейно стадия "Отрицание" -- это не погоня, а тихая прогулка по
 * дому детства: монстра нет, тревога не растёт. Игрок находит три
 * воспоминания (E рядом с предметом), в которых внутренний голос героя
 * оправдывает то, что происходило в семье. Когда все три прочитаны,
 * открывается дверь-порог -- переход к следующей стадии (Гнев, пока
 * заглушка -- см. ST_STORY_END).
 */
#include "game.h"

int story_mode  = 0;
int story_level = 1;
int story_stage = STORY_DENIAL;

Note   story_notes[STORY_MAX_NOTES];
double story_noteWX[STORY_MAX_NOTES], story_noteWY[STORY_MAX_NOTES];
int    story_note_count = 0;
int    story_notes_read = 0;
int    story_near_note   = -1;

/* Тексты воспоминаний этапа "Отрицание". Формат как у NOTES в gen.c:
 * до 6 строк, обрывается на NULL. Внутренний голос героя оправдывает
 * то, что видит -- это и есть суть отрицания: "у всех так", "не так
 * уж и плохо", "надо просто вырасти". */
#define DENIAL_TEXTS_COUNT 3
static const char *DENIAL_TEXTS[DENIAL_TEXTS_COUNT][6] = {
    { /* кухня: мать срывается на нём за разбитую тарелку */
      "МАТЬ КРИЧИТ ИЗ-ЗА РАЗБИТОЙ ТАРЕЛКИ.",
      "ЭТО НЕ ЗЛОСТЬ. ЭТО ВОСПИТАНИЕ.",
      "У ВСЕХ ТАК В СЕМЬЕ.",
      "НАДО ПРОСТО БЫТЬ ВНИМАТЕЛЬНЕЕ.", NULL },
    { /* гостиная: отец в очередной раз пьян перед телевизором */
      "ОТЕЦ СНОВА ЗАСНУЛ ПЕРЕД ТЕЛЕВИЗОРОМ.",
      "БУТЫЛКА НА ПОЛУ - ОБЫЧНОЕ ДЕЛО.",
      "ОН ЖЕ НЕ ПОДНИМАЕТ РУКУ. ЗНАЧИТ ВСЁ НОРМАЛЬНО.",
      "МНОГИЕ ОТЦЫ ТАК ОТДЫХАЮТ.", NULL },
    { /* детская: он сам себя утешает и учится молчать */
      "Я ЗАКРЫВАЮ ДВЕРЬ И НЕ ПЛАЧУ.",
      "НАДО ПРОСТО ВЫРАСТИ.",
      "СТАТЬ НОРМАЛЬНЫМ ВЗРОСЛЫМ ЧЕЛОВЕКОМ.",
      "ЗАБЫТЬ ОБ ЭТОМ.", NULL },
};
static const char **get_denial_text(int text_id) {
    if (text_id < 0 || text_id >= DENIAL_TEXTS_COUNT) return NULL;
    return DENIAL_TEXTS[text_id];
}
/* Публичный доступ для hud.c: какие строки показывать в панели чтения.
 * На будущие этапы/уровни здесь появится ветвление по story_level/stage. */
const char **story_get_reading_lines(int text_id) {
    return get_denial_text(text_id);
}

/* координаты дверного порога, ведущего к следующей стадии */
static double doorX, doorY;

/* закрасить прямоугольник (включительно) полом -- свой, отдельный от
 * carve_rect в gen.c, потому что уровень тут не процедурный, а прописан
 * руками: список комнат ниже читается как чертёж дома. */
static void carve(int x0, int y0, int x1, int y1) {
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++)
            if (x > 0 && x < MW - 1 && y > 0 && y < MH - 1) map[y][x] = '.';
}

/* положить воспоминание у стены рядом с (x,y), с автоматической
 * ориентацией спрайта на ближайшую стену (как lore-записки в gen.c). */
static void place_note(int x, int y, int text_id) {
    if (story_note_count >= STORY_MAX_NOTES) return;
    int wx, wy;
    if (!wall_dir(x, y, &wx, &wy)) { wx = 0; wy = -1; }   /* запасной вариант */
    int i = story_note_count++;
    story_notes[i].x = x + 0.5; story_notes[i].y = y + 0.5;
    story_notes[i].active = 1; story_notes[i].text = text_id;
    story_noteWX[i] = wx; story_noteWY[i] = wy;
}

/* Уровень 1, стадия "Отрицание": маленький дом детства.
 * Прихожая (спавн) -> общий коридор -> кухня / гостиная / детская,
 * коридор упирается в дверь-порог в комнате в самом низу.            */
void story_start_denial(void) {
    story_level = 1;
    story_stage = STORY_DENIAL;

    /* полностью своя карта: сначала всё стены, потом вручную прорезаем комнаты */
    for (int y = 0; y < MH; y++) { for (int x = 0; x < MW; x++) map[y][x] = '#'; map[y][MW] = 0; }

    carve(12, 1, 16, 3);     /* прихожая (точка спавна)               */
    carve(13, 3, 15, 18);    /* общий коридор -- позвоночник дома      */
    carve(2, 5, 11, 9);      /* кухня                                   */
    carve(17, 5, 27, 9);     /* гостиная                                */
    carve(11, 7, 27, 7);     /* коридор, связывающий кухню/гостиную с позвоночником */
    carve(2, 12, 11, 16);    /* детская                                 */
    carve(11, 13, 15, 13);   /* связка детской с позвоночником          */
    carve(11, 17, 17, 19);   /* комната перед дверью-порогом            */

    /* никакой процедурной комнатной раскраски для первого черновика --
     * room_count=0 значит все стены получат нейтральный тон коридора. */
    room_count = 0;

    /* точка спавна: центр прихожей */
    startX = 14; startY = 2;
    posX = startX + 0.5; posY = startY + 0.5; yaw = 1.5708 /* смотрим на юг, вглубь дома */; pitch = 0;

    /* дверь-порог в конце коридора, перекрывает его с юга на север */
    doorX = 14.5; doorY = 18.5;
    exitX = doorX; exitY = doorY;
    doorNx = 0; doorNz = 1;

    /* воспоминания: кухня, гостиная, детская -- по одному на комнату */
    story_note_count = 0;
    story_notes_read = 0;
    place_note(2, 6, 0);      /* кухня: у левой стены   */
    place_note(27, 6, 1);     /* гостиная: у правой стены */
    place_note(2, 14, 2);     /* детская: у левой стены  */

    /* используем keys_left как счётчик "сколько воспоминаний ещё не
     * прочитано" -- дверной меш (add_door в render.c) уже умеет рисовать
     * заперто/отперто по этому флагу, только знак другой. */
    num_keys = DENIAL_TEXTS_COUNT;
    keys_left = DENIAL_TEXTS_COUNT;

    /* обнулить всё, что относится к бесконечному режиму, чтобы не
     * протащить призраков предыдущей игры в дом: сундуки/ключи, спички,
     * камни, обычные lore-записки, декор, шкафчики (уводим за карту). */
    for (int i = 0; i < MAX_KEYS; i++) keys[i].active = 0;
    for (int i = 0; i < MAX_MATCHPICK; i++) matchpick[i].active = 0;
    for (int i = 0; i < MAX_ROCKPICK; i++) rockpick[i].active = 0;
    for (int i = 0; i < NUM_NOTES; i++) notes[i].active = 0;
    for (int i = 0; i < NUM_LOCKERS; i++) { lockers[i].x = -5; lockers[i].y = -5; }
    prop_count = 0;
    match_burn = 0.0; match_count = 0; rock_count = 0; rockFlyT = 0.0;

    /* без монстра: отрицание -- это тишина и мнимый уют, не погоня.
     * Убираем Стал­кера далеко за пределы дома, чтобы он не отрисовался. */
    monX = -5; monY = -5;

    /* сбросить состояние игрока, которое могло остаться от предыдущей
     * игры (например hidden=1, если вышли в меню, прячась в шкафчике --
     * иначе персонаж в сюжетном режиме не сможет пошевелиться). */
    hidden = 0; stamina = 1.0; exhausted = 0;
    velX = 0.0; velY = 0.0;

    /* тёплая, "домашняя" палитра вместо процедурного камня подземелья --
     * подменяем напрямую, не трогая biome/NBIOMES бесконечного режима. */
    depth = 1;   /* чтобы build_textures() не состарил камень трещинами */
    bwall[0] = 1.05f;  bwall[1] = 0.92f;  bwall[2] = 0.72f;   /* тёплые обои   */
    bfloor[0] = 0.55f; bfloor[1] = 0.40f; bfloor[2] = 0.28f;  /* дерево пола   */
    bceil[0] = 0.95f;  bceil[1] = 0.90f;  bceil[2] = 0.80f;
    biome_amb[0] = 0.085f; biome_amb[1] = 0.075f; biome_amb[2] = 0.060f;
    biome_torch[0] = 1.00f; biome_torch[1] = 0.70f; biome_torch[2] = 0.40f;

    build_textures();
    reupload_world_textures();
    build_world_mesh();
    upload_map();
}

/* Каждый кадр, пока story_mode и ST_PLAY: найти ближайшее воспоминание
 * в радиусе E, и проверить, дошёл ли игрок до двери-порога.            */
void story_update(double dt) {
    (void)dt;
    story_near_note = -1;
    for (int i = 0; i < story_note_count; i++)
        if (story_notes[i].active) {
            double dx = posX - story_notes[i].x, dy = posY - story_notes[i].y;
            if (dx * dx + dy * dy < PICKUP_DIST * PICKUP_DIST) story_near_note = i;
        }

    if (keys_left == 0) {
        double ed = (posX - doorX) * (posX - doorX) + (posY - doorY) * (posY - doorY);
        if (ed < 0.36) game_state = ST_STORY_END;   /* дошёл до порога -- этап пройден */
    }
}

/* E рядом с непрочитанным воспоминанием: показать текст и снять один
 * "замок" с двери-порога (как открытие сундука в бесконечном режиме). */
void story_try_interact(void) {
    if (story_near_note < 0) return;
    int i = story_near_note;
    if (story_notes[i].active == 1) {          /* ещё не читали в этом заходе */
        story_notes[i].active = 2;              /* 2 = прочитано, спрайт остаётся */
        story_notes_read++;
        if (keys_left > 0) { keys_left--; if (keys_left == 0) build_world_mesh(); }
    }
    reading_note = story_notes[i].text;         /* панель чтения берёт текст отсюда */
    game_state = ST_READING;
    if (snd_pickup) Mix_PlayChannel(3, snd_pickup, 0);
}
