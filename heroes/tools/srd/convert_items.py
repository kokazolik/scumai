#!/usr/bin/env python3
"""SRD 5.1 (CC-BY-4.0): всё оружие, доспехи и магические предметы → data/items.json.
Запуск: python3 -I tools/srd/convert_items.py <путь к @opencharacter/5e-srd-5.1/package/content>
Русские названия и описания — ручной перевод; механики сведены к тому, что умеет игра."""
import json, os, sys

DT = {"slashing": "рубящий", "piercing": "колющий", "bludgeoning": "дробящий"}
PRICE = {"c": 80, "u": 400, "r": 1500, "v": 4000, "l": 10000}
RAR = {"c": "обычный", "u": "необычный", "r": "редкий", "v": "очень редкий", "l": "легендарный"}

# ---- всё оружие SRD: id: (рус, урон, тип, свойства) ----
WEAPONS = {
    "club": ("Дубинка", "1d4", "дробящий", "light"), "dagger": None, "greatclub": ("Палица", "1d8", "дробящий", "two"),
    "handaxe": ("Ручной топор", "1d6", "рубящий", "light thrown"), "javelin": ("Метательное копьё", "1d6", "колющий", "thrown"),
    "light_hammer": ("Лёгкий молот", "1d4", "дробящий", "light thrown"), "mace": None, "quarterstaff": None,
    "sickle": ("Серп", "1d4", "рубящий", "light"), "spear": None, "crossbow": None,
    "dart": ("Дротики", "1d4", "колющий", "fin ranged"), "shortbow": None, "sling": ("Праща", "1d4", "дробящий", "ranged"),
    "battleaxe": None, "flail": ("Цеп", "1d8", "дробящий", ""), "glaive": ("Глефа", "1d10", "рубящий", "two reach"),
    "greataxe": None, "greatsword": None, "halberd": ("Алебарда", "1d10", "рубящий", "two reach"),
    "lance": ("Рыцарское копьё", "1d12", "колющий", "reach"), "longsword": None, "maul": ("Кувалда", "2d6", "дробящий", "two"),
    "morningstar": ("Моргенштерн", "1d8", "колющий", ""), "pike": ("Пика", "1d10", "колющий", "two reach"), "rapier": None,
    "scimitar": ("Скимитар", "1d6", "рубящий", "fin light"), "shortsword": None, "trident": ("Трезубец", "1d6", "колющий", "thrown"),
    "war_pick": ("Боевая кирка", "1d8", "колющий", ""), "warhammer": None, "whip": ("Кнут", "1d4", "рубящий", "fin reach"),
    "blowgun": ("Духовая трубка", "1d1", "колющий", "ranged"), "hand_crossbow": ("Ручной арбалет", "1d6", "колющий", "ranged light"),
    "heavy_crossbow": ("Тяжёлый арбалет", "1d10", "колющий", "ranged two"), "longbow": None,
}
WPRICE = {"club": 1, "greatclub": 1, "handaxe": 5, "javelin": 1, "light_hammer": 2, "sickle": 1, "dart": 1, "sling": 1, "flail": 10,
          "glaive": 20, "halberd": 20, "lance": 10, "maul": 10, "morningstar": 15, "pike": 5, "scimitar": 25, "trident": 5, "war_pick": 5,
          "whip": 2, "blowgun": 10, "hand_crossbow": 75, "heavy_crossbow": 50}
PROPS_RU = {"light": "лёгкое", "thrown": "метательное", "reach": "длинное (бьёт из-за плеча)"}

ARMOR = {
    "hide": {"name": "Шкурный доспех", "type": "armor", "ac": 12, "dex_max": 2, "cat": "средний", "price": 10},
    "ring_mail": {"name": "Колечный доспех", "type": "armor", "ac": 14, "dex_max": 0, "cat": "тяжёлый", "price": 30},
}


def W(base, name, r, desc, **f):
    d = {"base": base, "name": name, "type": "weapon", "magic": True, "rar": r, "desc": desc}
    d.update(f)
    return d


def X(type_, name, r, desc, **f):
    d = {"name": name, "type": type_, "magic": True, "rar": r, "desc": desc}
    d.update(f)
    return d


def ext(dice, dt, vs=""):
    e = {"dice": dice, "dt": dt}
    if vs == "undead":
        e["undead"] = True
    elif vs:
        e["vs"] = vs
    return e


# ---- магические предметы SRD. Механика — то, что работает в игре; остальное ведущий отыгрывает по описанию ----
MAGIC = {
    # оружие
    "dragon_slayer": W("longsword", "Убийца драконов", "r", "+1; по драконам +3к6", attack=1, damage=1, extra=ext("3d6", "рубящий", "дракон")),
    "giant_slayer": W("greataxe", "Убийца великанов", "r", "+1; по великанам +2к6 и сбивает с ног", attack=1, damage=1, extra=ext("2d6", "рубящий", "великан")),
    "vicious_weapon": W("longsword", "Жестокий клинок", "r", "на крите +7 урона", crit_bonus=7),
    "sword_of_sharpness": W("longsword", "Меч остроты", "v", "крит на 19–20, на крите +4к6", crit=19, crit_bonus=14),
    "vorpal_sword": W("longsword", "Головорубный меч", "l", "+3; крит на 19–20 и +6к8 на крите", attack=3, damage=3, crit=19, crit_bonus=27),
    "holy_avenger": W("longsword", "Священный мститель", "l", "+3; по исчадиям и нежити +2к10 излучением; +2 к спасброскам", attack=3, damage=3, save=2, extra=ext("2d10", "излучение", "undead")),
    "sun_blade": W("longsword", "Солнечный клинок", "r", "клинок из света: +2, излучение, по нежити +1к8", attack=2, damage=2, dt="излучение", extra=ext("1d8", "излучение", "undead")),
    "luck_blade": W("longsword", "Клинок удачи", "l", "+1 к атаке, урону и спасброскам", attack=1, damage=1, save=1),
    "defender": W("longsword", "Защитник", "l", "+3; часть силы уходит в защиту: +2 КД", attack=3, damage=3, ac=2),
    "dancing_sword": W("longsword", "Танцующий меч", "v", "+1; сам взлетает и рубит рядом с хозяином", attack=1, damage=1),
    "nine_lives_stealer": W("longsword", "Похититель девяти жизней", "v", "+2; на крите может сразу оборвать жизнь (+6к8)", attack=2, damage=2, crit_bonus=27),
    "sword_of_life_stealing": W("longsword", "Меч похищения жизни", "r", "на крите +3к6 некротикой и лечит владельца", drain="1d4", crit_bonus=10),
    "sword_of_wounding": W("longsword", "Меч ранений", "r", "раны от него кровоточат: +1к4 некротикой", extra=ext("1d4", "некротический")),
    "scimitar_of_speed": W("scimitar", "Скимитар скорости", "v", "+2; лишний удар бонусным действием", attack=2, damage=2),
    "berserker_axe": W("battleaxe", "Топор берсерка", "r", "+1, +1 хит за уровень; проклят: зовёт в бой", attack=1, damage=1, cursed=True),
    "mace_of_disruption": W("mace", "Булава разрушения", "r", "по нежити и исчадиям +2к6 излучением", extra=ext("2d6", "излучение", "undead")),
    "mace_of_smiting": W("mace", "Булава кары", "r", "+1; по конструктам +2", attack=1, damage=1, extra=ext("2d6", "дробящий", "конструкт")),
    "mace_of_terror": W("mace", "Булава ужаса", "r", "может пугать врагов (3 заряда в день)", stun=False),
    "javelin_of_lightning": W("javelin", "Копьё молний", "u", "брошенное, становится молнией: +4к6", extra=ext("4d6", "молния")),
    "dwarven_thrower": W("warhammer", "Дварфийский метатель", "v", "+3; возвращается в руку, по великанам +2к8", attack=3, damage=3, extra=ext("2d8", "дробящий", "великан")),
    "oathbow": W("longbow", "Лук клятвы", "v", "по заклятому врагу +3к6", extra=ext("3d6", "колющий")),
    "trident_of_fish_command": W("trident", "Трезубец повелителя рыб", "u", "подчиняет морских зверей"),
    "dagger_of_venom": W("dagger", "Кинжал яда", "r", "+1; клинок сочится ядом: +2к10 ядом", attack=1, damage=1, extra=ext("2d10", "яд")),
    "hammer_of_thunderbolts": W("maul", "Молот громовых ударов", "l", "+1; громовой удар оглушает на крите", attack=1, damage=1, stun=True, extra=ext("1d8", "звук")),
    "frost_brand": None, "flame_tongue": None,
    # доспехи и щиты
    "adamantine_armor": X("armor", "Адамантиновые латы", "u", "критические удары по вам — обычные", ac=18, dex_max=0, cat="тяжёлый", nocrit=True),
    "mithral_armor": X("armor", "Мифриловая кольчуга", "u", "лёгкая, не мешает красться", ac=16, dex_max=0, cat="тяжёлый"),
    "elven_chain": X("armor", "Эльфийская кольчуга", "r", "+1, носится как лёгкий доспех", ac=14, dex_max=-1, cat="лёгкий"),
    "dwarven_plate": X("armor", "Дварфийские латы", "v", "+2, не сбить с ног", ac=20, dex_max=0, cat="тяжёлый"),
    "dragon_scale_mail": X("armor", "Доспех из драконьей чешуи", "v", "+1, сопротивление огню", ac=15, dex_max=2, cat="средний", res=["огонь"], save=0),
    "demon_armor": X("armor", "Демонический доспех", "v", "+1, когти бьют 1к8; проклят", ac=19, dex_max=0, cat="тяжёлый", cursed=True),
    "armor_of_invulnerability": X("armor", "Доспех неуязвимости", "l", "сопротивление обычному оружию", ac=18, dex_max=0, cat="тяжёлый", res=["рубящий", "колющий", "дробящий"]),
    "armor_of_resistance": X("armor", "Доспех сопротивления", "r", "сопротивление холоду, огню и молнии", ac=14, dex_max=2, cat="средний", res=["огонь", "холод", "молния"]),
    "armor_of_vulnerability": X("armor", "Доспех уязвимости", "r", "сопротивление рубящему, но слабость к другим ударам; проклят", ac=18, dex_max=0, cat="тяжёлый", res=["рубящий"], cursed=True),
    "glamoured_studded_leather": X("armor", "Зачарованная проклёпанная кожа", "r", "+1, выглядит как любая одежда", ac=13, dex_max=-1, cat="лёгкий", skill={"Обман": 2}),
    "plate_armor_of_etherealness": X("armor", "Латы эфирности", "l", "раз в день — уйти в Эфир", ac=18, dex_max=0, cat="тяжёлый"),
    "animated_shield": X("shield", "Оживлённый щит", "v", "парит рядом сам", ac=2),
    "arrow_catching_shield": X("shield", "Ловец стрел", "r", "+2 КД против стрел (всегда +1)", ac=3),
    "spellguard_shield": X("shield", "Щит от чар", "v", "преимущество против заклинаний", ac=2, save=2),
    "shield_of_missile_attraction": X("shield", "Щит притяжения снарядов", "r", "стрелы летят в вас; проклят", ac=2, cursed=True),
    "sentinel_shield": None,
    # одежда, плащи, сапоги, пояса (слот «одежда»)
    "boots_of_elvenkind": X("clothes", "Эльфийские сапоги", "u", "шаги беззвучны", skill={"Скрытность": 4}),
    "boots_of_levitation": X("clothes", "Сапоги левитации", "r", "подниматься в воздух по желанию", skill={"Атлетика": 1}),
    "boots_of_speed": X("clothes", "Сапоги скорости", "r", "щёлк каблуками — двойная скорость", skill={"Акробатика": 3}),
    "boots_of_striding_and_springing": X("clothes", "Сапоги-скороходы", "u", "прыжки втрое дальше", skill={"Атлетика": 2}),
    "boots_of_the_winterlands": X("clothes", "Сапоги зимних земель", "u", "холод не страшен", res=["холод"]),
    "winged_boots": X("clothes", "Крылатые сапоги", "u", "летать до 4 часов в день"),
    "slippers_of_spider_climbing": X("clothes", "Туфли паука", "u", "ходить по стенам и потолку", skill={"Атлетика": 3}),
    "cloak_of_arachnida": X("clothes", "Плащ паука", "v", "сопротивление яду, ходить по стенам", res=["яд"]),
    "cloak_of_displacement": X("clothes", "Плащ смещения", "r", "вы кажетесь не там, где стоите", ac=2),
    "cloak_of_the_bat": X("clothes", "Плащ летучей мыши", "r", "в темноте можно летать", skill={"Скрытность": 3}),
    "cloak_of_the_manta_ray": X("clothes", "Плащ ската", "u", "дышать под водой"),
    "cape_of_the_mountebank": X("clothes", "Накидка шарлатана", "r", "раз в день — исчезнуть в облаке дыма", skill={"Обман": 2}),
    "robe_of_eyes": X("clothes", "Мантия глаз", "r", "видит всё вокруг и невидимое", skill={"Восприятие": 5}),
    "robe_of_scintillating_colors": X("clothes", "Мантия мерцающих красок", "v", "слепящие узоры сбивают врагов", ac=1),
    "robe_of_stars": X("clothes", "Звёздная мантия", "v", "+1 к спасброскам, звёзды бьют как волшебные стрелы", save=1, charges=6, spell="magic_missile"),
    "robe_of_the_archmagi": X("clothes", "Мантия архимага", "l", "КД 15 без доспеха, +2 к СЛ заклинаний", ac=3, spell_atk=2, save=1),
    "robe_of_useful_items": X("clothes", "Мантия полезных вещей", "u", "заплатки превращаются в нужные вещи"),
    "mantle_of_spell_resistance": X("clothes", "Мантия сопротивления чарам", "r", "преимущество против заклинаний", save=2),
    "bracers_of_archery": X("clothes", "Наручи стрелка", "u", "+2 к урону луком", skill={"Восприятие": 1}, bow_dmg=2),
    "bracers_of_defense": X("clothes", "Наручи защиты", "r", "+2 КД без доспеха и щита", ac=2),
    "gloves_of_missile_snaring": X("clothes", "Перчатки ловли снарядов", "u", "ловят стрелы на лету", ac=1),
    "gloves_of_swimming_and_climbing": X("clothes", "Перчатки пловца и скалолаза", "u", "плавать и лазать без труда", skill={"Атлетика": 2}),
    "belt_of_dwarvenkind": X("clothes", "Пояс дварфов", "r", "ТЕЛ +2, сопротивление яду", abil={"ТЕЛ": 2}, res=["яд"]),
    "belt_of_hill_giant_strength": X("clothes", "Пояс силы холмового великана", "r", "СИЛ становится 21", abil_set={"СИЛ": 21}),
    "belt_of_stone_giant_strength": X("clothes", "Пояс силы каменного великана", "v", "СИЛ становится 23", abil_set={"СИЛ": 23}),
    "belt_of_frost_giant_strength": X("clothes", "Пояс силы ледяного великана", "v", "СИЛ становится 23", abil_set={"СИЛ": 23}),
    "belt_of_fire_giant_strength": X("clothes", "Пояс силы огненного великана", "v", "СИЛ становится 25", abil_set={"СИЛ": 25}),
    "belt_of_cloud_giant_strength": X("clothes", "Пояс силы облачного великана", "l", "СИЛ становится 27", abil_set={"СИЛ": 27}),
    "belt_of_storm_giant_strength": X("clothes", "Пояс силы штормового великана", "l", "СИЛ становится 29", abil_set={"СИЛ": 29}),
    # головные уборы
    "headband_of_intellect": X("head", "Обруч интеллекта", "u", "ИНТ становится 19", abil_set={"ИНТ": 19}),
    "helm_of_brilliance": X("head", "Шлем сияния", "v", "самоцветы мечут огонь и свет", res=["огонь"], charges=4, spell="fireball"),
    "helm_of_comprehending_languages": X("head", "Шлем понимания языков", "u", "понимает любой язык и письмо", skill={"История": 2}),
    "helm_of_telepathy": X("head", "Шлем телепатии", "u", "читает поверхностные мысли", skill={"Проницательность": 4}),
    "helm_of_teleportation": X("head", "Шлем телепортации", "r", "трижды переносит вас куда угодно"),
    "hat_of_disguise": X("head", "Шляпа маскировки", "u", "принимать любой облик", skill={"Обман": 3}),
    "circlet_of_blasting": X("head", "Обруч взрывов", "u", "раз в день — палящий луч", charges=1, spell="scorching_ray"),
    "goggles_of_night": X("head", "Очки ночи", "u", "видеть в темноте", skill={"Восприятие": 2}),
    "eyes_of_the_eagle": X("head", "Глаза орла", "u", "зоркость орла", skill={"Восприятие": 5}),
    "eyes_of_minute_seeing": X("head", "Глаза мелочей", "u", "разглядеть любую мелочь вблизи", skill={"Анализ": 5}),
    "eyes_of_charming": X("head", "Глаза очарования", "u", "трижды в день очаровать человека", skill={"Убеждение": 3}),
    # кольца
    "ring_of_resistance": X("ring", "Кольцо сопротивления огню", "r", "сопротивление огню", res=["огонь"]),
    "ring_of_evasion": X("ring", "Кольцо уклонения", "r", "уходить от взрывов", save=1),
    "ring_of_feather_falling": X("ring", "Кольцо пёрышка", "r", "падать медленно, как пух"),
    "ring_of_free_action": X("ring", "Кольцо свободы действий", "r", "не сковать", cimm=["held"]),
    "ring_of_invisibility": X("ring", "Кольцо невидимости", "l", "стать невидимым по желанию", skill={"Скрытность": 6}),
    "ring_of_jumping": X("ring", "Кольцо прыжков", "u", "прыжки втрое дальше", skill={"Атлетика": 2}),
    "ring_of_mind_shielding": X("ring", "Кольцо защиты разума", "u", "мысли не прочесть, ложь не распознать", skill={"Обман": 2}),
    "ring_of_regeneration": X("ring", "Кольцо регенерации", "v", "раны затягиваются сами: +1к6 хитов каждый ход в бою", regen="1d6"),
    "ring_of_spell_storing": X("ring", "Кольцо хранения заклинаний", "r", "хранит заклинание: «Удержание»", charges=1, spell="hold_person"),
    "ring_of_spell_turning": X("ring", "Кольцо отражения заклинаний", "l", "преимущество против чар", save=3),
    "ring_of_swimming": X("ring", "Кольцо плавания", "u", "плавать как рыба"),
    "ring_of_telekinesis": X("ring", "Кольцо телекинеза", "v", "двигать вещи взглядом"),
    "ring_of_the_ram": X("ring", "Кольцо тарана", "r", "призрачный таран: 3 заряда", charges=3, spell="thunderwave"),
    "ring_of_three_wishes": X("ring", "Кольцо трёх желаний", "l", "три желания — любое чудо"),
    "ring_of_warmth": X("ring", "Кольцо тепла", "u", "сопротивление холоду", res=["холод"]),
    "ring_of_water_walking": X("ring", "Кольцо хождения по воде", "u", "ходить по воде как по земле"),
    "ring_of_x_ray_vision": X("ring", "Кольцо рентгеновского зрения", "r", "видеть сквозь стены", skill={"Восприятие": 3}),
    "ring_of_shooting_stars": X("ring", "Кольцо падающих звёзд", "v", "сверкающие шары молний", charges=6, spell="lightning_bolt"),
    "ring_of_animal_influence": X("ring", "Кольцо власти над зверями", "r", "успокаивать и звать зверей", skill={"Уход за животными": 4}),
    "ring_of_djinni_summoning": X("ring", "Кольцо призыва джинна", "l", "в кольце заточён джинн"),
    "ring_of_air_elemental_command": X("ring", "Кольцо власти над воздухом", "l", "повелевать стихией воздуха", res=["молния"]),
    "ring_of_earth_elemental_command": X("ring", "Кольцо власти над землёй", "l", "повелевать стихией земли", res=["кислота"]),
    "ring_of_fire_elemental_command": X("ring", "Кольцо власти над огнём", "l", "повелевать стихией огня", res=["огонь"]),
    "ring_of_water_elemental_command": X("ring", "Кольцо власти над водой", "l", "повелевать стихией воды", res=["холод"]),
    # амулеты, броши, талисманы (слот «амулет»)
    "amulet_of_proof_against_detection_and_location": X("amulet", "Амулет сокрытия", "u", "вас не найти магией", skill={"Скрытность": 2}),
    "amulet_of_the_planes": X("amulet", "Амулет планов", "v", "шагнуть в другой мир"),
    "brooch_of_shielding": X("amulet", "Брошь защиты", "u", "сопротивление силовому урону, волшебные стрелы не берут", res=["силовой"]),
    "medallion_of_thoughts": X("amulet", "Медальон мыслей", "u", "читать мысли", skill={"Проницательность": 3}),
    "necklace_of_adaptation": X("amulet", "Ожерелье адаптации", "u", "дышать где угодно, газы не страшны", res=["яд"]),
    "necklace_of_fireballs": X("amulet", "Ожерелье огненных шаров", "r", "бусины — огненные шары", charges=5, spell="fireball"),
    "necklace_of_prayer_beads": X("amulet", "Чётки", "r", "бусины лечат и благословляют", charges=4, spell="cure_wounds"),
    "periapt_of_health": X("amulet", "Талисман здоровья", "u", "болезни не пристают", save=1),
    "periapt_of_proof_against_poison": X("amulet", "Талисман от яда", "r", "яд не действует", res=["яд"], cimm=["poisoned"]),
    "periapt_of_wound_closure": X("amulet", "Талисман затягивания ран", "u", "раны быстро затягиваются, сам встаёт", regen="1d4"),
    "scarab_of_protection": X("amulet", "Скарабей защиты", "l", "преимущество против чар, отводит смерть", save=2),
    "talisman_of_pure_good": X("amulet", "Талисман чистого добра", "l", "свет испепеляет зло", spell_atk=2),
    "talisman_of_ultimate_evil": X("amulet", "Талисман абсолютного зла", "l", "тьма губит добро", spell_atk=2, cursed=True),
    "talisman_of_the_sphere": X("amulet", "Талисман сферы", "l", "повелевает сферой уничтожения"),
    "stone_of_good_luck": X("amulet", "Камень удачи", "u", "+1 к проверкам и спасброскам", save=1, skill_all=1),
    "ioun_stone_of_protection": X("amulet", "Камень Йоун: защита", "r", "+1 КД", ac=1),
    "ioun_stone_of_agility": X("amulet", "Камень Йоун: ловкость", "v", "ЛОВ +2", abil={"ЛОВ": 2}),
    "ioun_stone_of_fortitude": X("amulet", "Камень Йоун: стойкость", "v", "ТЕЛ +2", abil={"ТЕЛ": 2}),
    "ioun_stone_of_insight": X("amulet", "Камень Йоун: прозрение", "v", "МДР +2", abil={"МДР": 2}),
    "ioun_stone_of_intellect": X("amulet", "Камень Йоун: интеллект", "v", "ИНТ +2", abil={"ИНТ": 2}),
    "ioun_stone_of_leadership": X("amulet", "Камень Йоун: лидерство", "v", "ХАР +2", abil={"ХАР": 2}),
    "ioun_stone_of_strength": X("amulet", "Камень Йоун: сила", "v", "СИЛ +2", abil={"СИЛ": 2}),
    "ioun_stone_of_awareness": X("amulet", "Камень Йоун: бдительность", "r", "не застать врасплох", skill={"Восприятие": 2}),
    "ioun_stone_of_mastery": X("amulet", "Камень Йоун: мастерство", "l", "+1 к бонусу мастерства", save=1, skill_all=1),
    "ioun_stone_of_regeneration": X("amulet", "Камень Йоун: регенерация", "l", "раны затягиваются", regen="1d6"),
    "ioun_stone_of_absorption": X("amulet", "Камень Йоун: поглощение", "v", "поглощает слабые заклинания", save=1),
    "ioun_stone_of_greater_absorption": X("amulet", "Камень Йоун: большое поглощение", "l", "поглощает заклинания", save=2),
    "ioun_stone_of_reserve": X("amulet", "Камень Йоун: запас", "r", "хранит чары", charges=1, spell="magic_missile"),
    "ioun_stone_of_sustenance": X("amulet", "Камень Йоун: насыщение", "r", "не нужна еда и питьё"),
    "pearl_of_power": X("amulet", "Жемчужина силы", "u", "возвращает потраченную ячейку (на отдыхе)", skill={"Магия": 2}),
    "wand_of_the_war_mage_plus_one": X("amulet", "Жезл боевого мага +1", "u", "+1 к атакам заклинаниями", spell_atk=1),
    "wand_of_the_war_mage_plus_two": X("amulet", "Жезл боевого мага +2", "r", "+2 к атакам заклинаниями", spell_atk=2),
    "wand_of_the_war_mage_plus_three": X("amulet", "Жезл боевого мага +3", "v", "+3 к атакам заклинаниями", spell_atk=3),
    "rod_of_absorption": X("amulet", "Жезл поглощения", "v", "впитывает направленные заклинания", save=2),
    "rod_of_alertness": X("amulet", "Жезл бдительности", "v", "+1 КД, не застать врасплох", ac=1, skill={"Восприятие": 3}),
    "rod_of_rulership": X("amulet", "Жезл власти", "r", "подчиняет толпу", skill={"Убеждение": 4}),
    "rod_of_security": X("amulet", "Жезл безопасности", "v", "уводит в рай-убежище"),
    "rod_of_lordly_might": X("amulet", "Жезл владычества", "l", "превращается в оружие, +3", spell_atk=1, ac=1),
    # волшебные палочки и посохи — заряды заклинаний
    "wand_of_magic_missiles": X("scroll", "Палочка волшебных стрел", "u", "7 зарядов «Волшебной стрелы»", spell="magic_missile", charges=7),
    "wand_of_fireballs": X("scroll", "Палочка огненных шаров", "r", "7 зарядов «Огненного шара»", spell="fireball", charges=7),
    "wand_of_lightning_bolts": X("scroll", "Палочка молний", "r", "7 зарядов «Молнии»", spell="lightning_bolt", charges=7),
    "wand_of_paralysis": X("scroll", "Палочка паралича", "r", "7 зарядов: сковать врага", spell="hold_person", charges=7),
    "wand_of_web": X("scroll", "Палочка паутины", "u", "7 зарядов «Сна» — паутина валит врагов", spell="sleep", charges=7),
    "wand_of_fear": X("scroll", "Палочка страха", "r", "7 зарядов «Злой насмешки»", spell="vicious_mockery", charges=7),
    "wand_of_binding": X("scroll", "Палочка оков", "r", "7 зарядов: сковать", spell="hold_person", charges=7),
    "wand_of_polymorph": X("scroll", "Палочка превращения", "v", "превращает врага в безобидную зверушку", spell="sleep", charges=7),
    "wand_of_wonder": X("scroll", "Палочка чудес", "r", "непредсказуемые чары", spell="confusion", charges=7),
    "wand_of_enemy_detection": X("misc", "Палочка поиска врагов", "r", "указывает на враждебных существ"),
    "wand_of_magic_detection": X("misc", "Палочка поиска магии", "u", "чует магию рядом"),
    "wand_of_secrets": X("misc", "Палочка тайн", "u", "дрожит возле тайных дверей и ловушек"),
    "staff_of_fire": X("scroll", "Посох огня", "v", "10 зарядов: огненный шар, сопротивление огню", spell="fireball", charges=10),
    "staff_of_frost": X("scroll", "Посох мороза", "v", "10 зарядов: конус холода", spell="cone_of_cold", charges=10),
    "staff_of_healing": X("scroll", "Посох исцеления", "r", "10 зарядов: массовое лечение", spell="mass_cure_wounds", charges=10),
    "staff_of_thunder_and_lightning": X("scroll", "Посох грома и молний", "v", "молния, гром, буря", spell="lightning_bolt", charges=5),
    "staff_of_swarming_insects": X("scroll", "Посох роя насекомых", "r", "рой жалит врагов", spell="confusion", charges=10),
    "staff_of_charming": X("scroll", "Посох очарования", "r", "очаровывает и усыпляет", spell="sleep", charges=10),
    "staff_of_the_woodlands": X("scroll", "Посох лесов", "r", "силы леса: опутывающие корни", spell="hold_person", charges=10),
    "staff_of_the_python": X("misc", "Посох-питон", "u", "превращается в гигантского змея"),
    "staff_of_power": W("quarterstaff", "Посох силы", "v", "+2 к атаке, КД и спасброскам; бьёт силой", attack=2, damage=2, ac=2, save=2, extra=ext("1d6", "силовой")),
    "staff_of_the_magi": W("quarterstaff", "Посох магов", "l", "+2; КД и спасброски +2, огненный шар по зову", attack=2, damage=2, save=2, spell_atk=2, extra=ext("1d6", "силовой")),
    "staff_of_striking": W("quarterstaff", "Посох ударов", "v", "+3; заряд — ещё +1к6 силой", attack=3, damage=3, extra=ext("1d6", "силовой")),
    "staff_of_withering": W("quarterstaff", "Посох иссушения", "r", "+2к10 некротикой", extra=ext("2d10", "некротический")),
    # зелья
    "potion_supreme": X("potion", "Высшее зелье лечения", "v", "лечит 10к4+20", heal="10d4+20"),
    "potion_of_heroism": X("potion", "Зелье героизма", "r", "+10 хитов и благословение", heal="10", buff="heroism"),
    "potion_of_invisibility": X("potion", "Зелье невидимости", "v", "невидимость: враги вас не видят", heal="", buff="invis"),
    "potion_of_speed": X("potion", "Зелье скорости", "v", "ускорение: +2 КД и лишняя атака", heal="", buff="haste"),
    "potion_of_growth": X("potion", "Зелье роста", "u", "вырастаете: +1к4 урона ударами", heal="", buff="growth"),
    "potion_of_flying": X("potion", "Зелье полёта", "v", "летать час", heal=""),
    "potion_of_gaseous_form": X("potion", "Зелье газообразной формы", "r", "стать облачком тумана", heal=""),
    "potion_of_diminution": X("potion", "Зелье уменьшения", "r", "уменьшиться до мышиного роста", heal=""),
    "potion_of_climbing": X("potion", "Зелье лазания", "c", "лазать как паук", heal=""),
    "potion_of_water_breathing": X("potion", "Зелье подводного дыхания", "u", "дышать под водой", heal=""),
    "potion_of_animal_friendship": X("potion", "Зелье дружбы с животными", "u", "звери становятся друзьями", heal=""),
    "potion_of_clairvoyance": X("potion", "Зелье ясновидения", "r", "увидеть далёкое место", heal=""),
    "potion_of_mind_reading": X("potion", "Зелье чтения мыслей", "r", "читать мысли", heal=""),
    "potion_of_poison": X("potion", "Зелье яда", "u", "выглядит как лечебное, но это яд!", heal="", buff="poison", cursed=True),
    "philter_of_love": X("potion", "Любовное зелье", "u", "очарование тем, кого увидишь первым", heal=""),
    "oil_of_sharpness": X("coat", "Масло остроты", "v", "оружие режет как бритва: 6 ударов по +1к6", dice="1d6", hits=6, dt="рубящий"),
    "oil_of_etherealness": X("misc", "Масло эфирности", "r", "войти в Эфир"),
    "oil_of_slipperiness": X("misc", "Масло скольжения", "u", "не схватить, не сковать"),
    "sharpness_coating": None,
    "restorative_ointment": X("potion", "Целебная мазь", "u", "лечит 2к8+2 и снимает яд", heal="2d8+2", cure=["poisoned"]),
    "universal_solvent": X("misc", "Всерастворитель", "l", "растворяет любой клей"),
    "sovereign_glue": X("misc", "Верховный клей", "l", "склеивает намертво"),
    "dust_of_disappearance": X("potion", "Пыль исчезновения", "u", "невидимость для вас", heal="", buff="invis"),
    "dust_of_dryness": X("misc", "Пыль сухости", "u", "впитывает воду, бьёт водных существ"),
    "dust_of_sneezing_and_choking": X("bomb", "Пыль чихания и удушья", "u", "враги задыхаются", dmg="1d4", dt="яд", save="ТЕЛ", dc=15),
    "bead_of_force": X("bomb", "Бусина силы", "r", "взрыв силы 5к4", dmg="5d4", dt="силовой", save="ЛОВ", dc=15),
    "elemental_gem_red_corundum": X("misc", "Самоцвет стихий: корунд", "u", "призывает огненного элементаля"),
    "elemental_gem_blue_sapphire": X("misc", "Самоцвет стихий: сапфир", "u", "призывает воздушного элементаля"),
    "elemental_gem_emerald": X("misc", "Самоцвет стихий: изумруд", "u", "призывает водного элементаля"),
    "elemental_gem_yellow_diamond": X("misc", "Самоцвет стихий: алмаз", "u", "призывает земляного элементаля"),
}
for dt_en, dt_ru, nm in [("acid", "кислота", "кислоте"), ("cold", "холод", "холоду"), ("fire", "огонь", "огню"), ("force", "силовой", "силе"),
                         ("lightning", "молния", "молнии"), ("necrotic", "некротический", "некротике"), ("poison", "яд", "яду"),
                         ("psychic", "психический", "психической атаке"), ("radiant", "излучение", "излучению"), ("thunder", "звук", "звуку")]:
    MAGIC["potion_of_%s_resistance" % dt_en] = X("potion", "Зелье сопротивления %s" % nm, "u", "на бой: урон (%s) вдвое меньше" % dt_ru, heal="", res=[dt_ru])
for g, sc, r in [("hill", 21, "u"), ("frost", 23, "r"), ("stone", 23, "r"), ("fire", 25, "r"), ("cloud", 27, "v"), ("storm", 29, "l")]:
    gn = {"hill": "холмового", "frost": "ледяного", "stone": "каменного", "fire": "огненного", "cloud": "облачного", "storm": "штормового"}[g]
    MAGIC["potion_of_%s_giant_strength" % g] = X("potion", "Зелье силы %s великана" % gn, r, "на бой: СИЛ %d" % sc, heal="", abil_set={"СИЛ": sc})
for k, nm, sc in [("bodily_health", "Руководство по здоровью тела", "ТЕЛ"), ("gainful_exercise", "Руководство по полезным упражнениям", "СИЛ"),
                  ("quickness_of_action", "Руководство по быстроте действий", "ЛОВ")]:
    MAGIC["manual_of_" + k] = X("misc", nm, "v", "прочесть за неделю: %s +2 навсегда" % sc, tome={sc: 2})
for k, nm, sc in [("clear_thought", "Фолиант ясной мысли", "ИНТ"), ("leadership_and_influence", "Фолиант лидерства и влияния", "ХАР"),
                  ("understanding", "Фолиант понимания", "МДР")]:
    MAGIC["tome_of_" + k] = X("misc", nm, "v", "прочесть за неделю: %s +2 навсегда" % sc, tome={sc: 2})
# сюжетные чудесные предметы: работают через ведущего
STORY = {
    "apparatus_of_the_crab": ("Аппарат-краб", "l", "железная бочка-подлодка на клешнях"),
    "bag_of_beans": ("Мешок бобов", "r", "бобы прорастают чудесами и бедами"),
    "bag_of_devouring": ("Мешок пожирания", "v", "пасть иного мира, глотает всё живое"),
    "bag_of_holding": ("Бездонная сумка", "u", "вмещает намного больше, чем кажется"),
    "bag_of_tricks": ("Мешок фокусов", "u", "достаёт из себя пушистых зверьков-союзников"),
    "bowl_of_commanding_water_elementals": ("Чаша водного элементаля", "r", "призывает водного элементаля"),
    "brazier_of_commanding_fire_elementals": ("Жаровня огненного элементаля", "r", "призывает огненного элементаля"),
    "censer_of_controlling_air_elementals": ("Кадило воздушного элементаля", "r", "призывает воздушного элементаля"),
    "stone_of_controlling_earth_elementals": ("Камень земляного элементаля", "r", "призывает земляного элементаля"),
    "broom_of_flying": ("Летающая метла", "u", "летает с седоком"),
    "candle_of_invocation": ("Свеча воззвания", "v", "зовёт помощь божества"),
    "carpet_of_flying": ("Ковёр-самолёт", "v", "летает с пассажирами"),
    "chime_of_opening": ("Колокольчик открывания", "r", "звон открывает замки"),
    "crystal_ball": ("Хрустальный шар", "v", "показывает далёких людей"),
    "crystal_ball_of_mind_reading": ("Хрустальный шар чтения мыслей", "l", "видит и читает мысли"),
    "crystal_ball_of_telepathy": ("Хрустальный шар телепатии", "l", "видит и говорит мысленно"),
    "crystal_ball_of_true_seeing": ("Хрустальный шар истинного зрения", "l", "видит сквозь иллюзии"),
    "cube_of_force": ("Куб силы", "r", "силовой барьер вокруг"),
    "cubic_gate": ("Кубические врата", "l", "врата в другие миры"),
    "decanter_of_endless_water": ("Графин бесконечной воды", "u", "льёт воду без конца"),
    "deck_of_illusions": ("Колода иллюзий", "u", "карты оживают иллюзиями"),
    "deck_of_many_things": ("Колода многих вещей", "l", "каждая карта — судьба: счастье или гибель"),
    "dimensional_shackles": ("Кандалы измерений", "r", "сковывают и не дают телепортироваться"),
    "efficient_quiver": ("Удобный колчан", "u", "вмещает сотни стрел"),
    "efreeti_bottle": ("Бутыль ифрита", "v", "в ней заточён ифрит"),
    "eversmoking_bottle": ("Вечно дымящая бутыль", "u", "заволакивает всё дымом"),
    "folding_boat": ("Складная лодка", "r", "шкатулка, что раскладывается в лодку"),
    "gem_of_brightness": ("Самоцвет яркости", "u", "свет и слепящие лучи"),
    "gem_of_seeing": ("Самоцвет зрения", "r", "видеть истину сквозь чары"),
    "handy_haversack": ("Удобный рюкзак", "r", "нужная вещь всегда сверху"),
    "horn_of_blasting": ("Рог разрушения", "r", "звук рушит стены"),
    "horn_of_valhalla_silver": ("Серебряный рог Вальхаллы", "r", "призывает духов-воинов"),
    "horn_of_valhalla_brass": ("Латунный рог Вальхаллы", "r", "призывает духов-воинов"),
    "horn_of_valhalla_bronze": ("Бронзовый рог Вальхаллы", "v", "призывает духов-воинов"),
    "horn_of_valhalla_iron": ("Железный рог Вальхаллы", "l", "призывает духов-воинов"),
    "horseshoes_of_a_zephyr": ("Подковы зефира", "v", "конь скачет по воздуху"),
    "horseshoes_of_speed": ("Подковы скорости", "r", "конь скачет вдвое быстрее"),
    "immovable_rod": ("Недвижимый жезл", "u", "застывает в воздухе намертво"),
    "instant_fortress": ("Мгновенная крепость", "r", "кубик вырастает в башню"),
    "iron_bands_of_binding": ("Железные путы", "r", "опутывают врага"),
    "iron_flask": ("Железная фляга", "l", "заточает существо внутри"),
    "lantern_of_revealing": ("Фонарь раскрытия", "u", "показывает невидимое"),
    "manual_of_golems": ("Руководство по големам", "v", "как создать голема"),
    "marvelous_pigments": ("Чудесные краски", "v", "нарисованное становится настоящим"),
    "mirror_of_life_trapping": ("Зеркало ловушки жизни", "v", "заточает отражённых"),
    "pipes_of_haunting": ("Свирель страха", "u", "мелодия пугает врагов"),
    "pipes_of_the_sewers": ("Свирель стоков", "u", "зовёт крыс"),
    "portable_hole": ("Переносная дыра", "r", "чёрный круг ткани — карман в иное"),
    "rope_of_climbing": ("Верёвка лазания", "u", "сама ползёт и вяжет узлы"),
    "rope_of_entanglement": ("Опутывающая верёвка", "r", "сама связывает врага"),
    "sphere_of_annihilation": ("Сфера уничтожения", "l", "чёрная пустота стирает всё"),
    "well_of_many_worlds": ("Колодец многих миров", "l", "портал в другой мир"),
    "wind_fan": ("Веер ветров", "u", "поднимает ураганный ветер"),
    "wings_of_flying": ("Крылья полёта", "r", "плащ становится крыльями"),
    "figurine_of_wondrous_power_bronze_griffon": ("Статуэтка: бронзовый грифон", "r", "оживает грифоном"),
    "figurine_of_wondrous_power_ebony_fly": ("Статуэтка: эбеновая муха", "r", "оживает гигантской мухой"),
    "figurine_of_wondrous_power_golden_lions": ("Статуэтка: золотые львы", "r", "оживают львами"),
    "figurine_of_wondrous_power_ivory_goats": ("Статуэтка: козы из кости", "r", "оживают волшебными козами"),
    "figurine_of_wondrous_power_marble_elephant": ("Статуэтка: мраморный слон", "r", "оживает слоном"),
    "figurine_of_wondrous_power_obsidian_steed": ("Статуэтка: обсидиановый скакун", "v", "оживает кошмарным конём"),
    "figurine_of_wondrous_power_onyx_dog": ("Статуэтка: ониксовый пёс", "r", "оживает верным псом"),
    "figurine_of_wondrous_power_serpentine_owl": ("Статуэтка: змеевиковая сова", "r", "оживает гигантской совой"),
    "figurine_of_wondrous_power_silver_raven": ("Статуэтка: серебряный ворон", "u", "оживает вороном-вестником"),
    "feather_token_anchor": ("Перо Кваала: якорь", "r", "удерживает корабль на месте"),
    "feather_token_bird": ("Перо Кваала: птица", "r", "огромная птица несёт вас"),
    "feather_token_fan": ("Перо Кваала: веер", "r", "попутный ветер для корабля"),
    "feather_token_swan_boat": ("Перо Кваала: лебедь", "r", "лодка-лебедь"),
    "feather_token_tree": ("Перо Кваала: дерево", "r", "мгновенно вырастает дуб"),
    "feather_token_whip": ("Перо Кваала: кнут", "r", "летающий кнут бьёт врагов"),
    "ammunition_plus_one": ("Стрелы +1", "u", "зачарованные стрелы и болты"),
    "ammunition_plus_two": ("Стрелы +2", "r", "зачарованные стрелы и болты"),
    "ammunition_plus_three": ("Стрелы +3", "v", "зачарованные стрелы и болты"),
    "arrow_of_slaying": ("Стрела убийства", "v", "смертельна для одного вида существ"),
    "trident_of_fish_command_": None,
}
for k, v in STORY.items():
    if v:
        MAGIC[k] = X("misc", v[0], v[1], v[2])

DUP = {"amulet_of_health": "amulet_health", "cloak_of_protection": "cloak_protection", "ring_of_protection": "ring_protection",
       "cloak_of_elvenkind": "elven_cloak", "gauntlets_of_ogre_power": "gauntlets_power", "potion_of_healing": "potion_heal",
       "potion_of_greater_healing": "potion_greater", "potion_of_superior_healing": "potion_superior", "potion_of_supreme_healing": "potion_supreme",
       "flame_tongue": "flame_tongue", "frost_brand": "frost_brand"}
TEMPLATES = {"weapon_plus_one", "weapon_plus_two", "weapon_plus_three", "armor_plus_one", "armor_plus_two", "armor_plus_three",
             "shield_plus_one", "shield_plus_two", "shield_plus_three", "stored_spell", "sharpness_coating", "sentinel_shield"}
SCROLLS = {"spell_scroll_cantrip", "spell_scroll_level_1", "spell_scroll_level_2", "spell_scroll_level_3", "spell_scroll_level_4",
           "spell_scroll_level_5", "spell_scroll_level_6", "spell_scroll_level_7", "spell_scroll_level_8", "spell_scroll_level_9"}


def main(content):
    out = {}
    for wid, v in WEAPONS.items():
        if not v:
            continue
        name, dmg, dt, props = v
        p = props.split()
        d = {"name": name, "type": "weapon", "dt": dt, "dmg": dmg, "price": WPRICE.get(wid, 5),
             "ability": "fin" if "fin" in p else ("ЛОВ" if "ranged" in p else "СИЛ")}
        if "ranged" in p:
            d["ranged"] = True
        if "two" in p or ("ranged" in p and "light" not in p and wid not in ("dart", "sling", "blowgun")):
            d["two"] = True
        extra = [PROPS_RU[x] for x in p if x in PROPS_RU]
        if extra:
            d["desc"] = ", ".join(extra)
        out[wid] = d
    out.update(ARMOR)
    srd_ids = set(f[:-5].replace("-", "_") for f in os.listdir(os.path.join(content, "magic-items")) if f.endswith(".yaml"))
    missing = []
    for sid in sorted(srd_ids):
        if sid in DUP or sid in TEMPLATES or sid in SCROLLS:
            continue
        if sid not in MAGIC or MAGIC[sid] is None:
            missing.append(sid)
    for k, v in MAGIC.items():
        if v is None:
            continue
        v = dict(v)
        r = v.pop("rar")
        v["rar"] = r
        v["price"] = PRICE[r]
        if v.get("charges"):
            v["price"] = int(v["price"] * 0.8)
        out[k] = v
    print("items:", len(out), "magic:", sum(1 for v in out.values() if v.get("magic")))
    print("SRD magic not mapped:", missing)
    os.makedirs("data", exist_ok=True)
    with open("data/items.json", "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main(sys.argv[1])
