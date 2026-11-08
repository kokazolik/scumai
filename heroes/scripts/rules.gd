extends RefCounted
## Правила по мотивам открытой базы 5-й редакции (SRD 5.1, CC BY 4.0), упрощённые для телефона.
## Здесь только данные и чистые функции: классы, расы, навыки, предметы, заклинания, монстры, лут.
## Использование: const R = preload("res://scripts/rules.gd")

const AB := ["СИЛ", "ЛОВ", "ТЕЛ", "ИНТ", "МДР", "ХАР"]
const AB_NAME := {"СИЛ": "Сила", "ЛОВ": "Ловкость", "ТЕЛ": "Телосложение", "ИНТ": "Интеллект", "МДР": "Мудрость", "ХАР": "Харизма"}

const SKILLS := {
	"Атлетика": "СИЛ",
	"Акробатика": "ЛОВ", "Ловкость рук": "ЛОВ", "Скрытность": "ЛОВ",
	"Магия": "ИНТ", "История": "ИНТ", "Анализ": "ИНТ", "Природа": "ИНТ", "Религия": "ИНТ",
	"Уход за животными": "МДР", "Проницательность": "МДР", "Медицина": "МДР", "Восприятие": "МДР", "Выживание": "МДР",
	"Обман": "ХАР", "Запугивание": "ХАР", "Выступление": "ХАР", "Убеждение": "ХАР",
}

## Опыт для уровней 2..10.
const XP_LEVELS := [300, 900, 2700, 6500, 14000, 23000, 34000, 48000, 64000]

## Ячейки заклинаний полного заклинателя по уровням (1..10), уровни ячеек 1..3 (выше пока нет заклинаний).
const SLOTS := [[2], [3], [4, 2], [4, 3], [4, 3, 2], [4, 3, 3], [4, 3, 3], [4, 3, 3], [4, 3, 3], [4, 3, 3]]

const RACES := {
	"Человек": {"bonus": {"СИЛ": 1, "ЛОВ": 1, "ТЕЛ": 1, "ИНТ": 1, "МДР": 1, "ХАР": 1}, "desc": "+1 ко всем характеристикам"},
	"Эльф": {"bonus": {"ЛОВ": 2, "ИНТ": 1}, "skills": ["Восприятие"], "desc": "+2 ЛОВ, +1 ИНТ, зоркий (Восприятие)"},
	"Дварф": {"bonus": {"ТЕЛ": 2, "МДР": 1}, "hp_per_level": 1, "desc": "+2 ТЕЛ, +1 МДР, +1 хит за уровень"},
	"Полурослик": {"bonus": {"ЛОВ": 2, "ХАР": 1}, "lucky": true, "desc": "+2 ЛОВ, +1 ХАР, везучий: перебрасывает единицы"},
	"Полуорк": {"bonus": {"СИЛ": 2, "ТЕЛ": 1}, "relentless": true, "desc": "+2 СИЛ, +1 ТЕЛ, раз за отдых не падает от удара"},
	"Тифлинг": {"bonus": {"ХАР": 2, "ИНТ": 1}, "desc": "+2 ХАР, +1 ИНТ, потомок демонов, видит в темноте"},
	"Гном": {"bonus": {"ИНТ": 2, "ЛОВ": 1}, "desc": "+2 ИНТ, +1 ЛОВ, хитрый изобретатель"},
}

const CLASSES := {
	"Воин": {"armor": ["лёгкий", "средний", "тяжёлый", "shield"], "hd": 10, "saves": ["СИЛ", "ТЕЛ"], "main": "СИЛ",
		"scores": {"СИЛ": 15, "ТЕЛ": 14, "ЛОВ": 13, "МДР": 12, "ХАР": 10, "ИНТ": 8},
		"skills": ["Атлетика", "Запугивание", "Восприятие"],
		"start": [["longsword", true], ["chain_mail", true], ["shield", true], ["traveler_clothes", true], ["potion_heal", false]],
		"features": "Второе дыхание (раз за отдых лечит 1к10+уровень), Дополнительная атака с 5 уровня",
		"desc": "Крепкий боец в тяжёлой броне"},
	"Маг": {"armor": [], "hd": 6, "saves": ["ИНТ", "МДР"], "main": "ИНТ", "caster": "ИНТ",
		"scores": {"ИНТ": 15, "ТЕЛ": 14, "ЛОВ": 13, "МДР": 12, "ХАР": 10, "СИЛ": 8},
		"skills": ["Магия", "История", "Анализ"],
		"spells": ["fire_bolt", "ray_of_frost", "magic_missile", "burning_hands", "sleep", "scorching_ray", "fireball"],
		"start": [["quarterstaff", true], ["mage_robe", true], ["spellbook", false], ["potion_heal", false]],
		"features": "Заклинания на Интеллекте: огонь, лёд, усыпление",
		"desc": "Огонь, лёд и тайные знания"},
	"Плут": {"armor": ["лёгкий"], "hd": 8, "saves": ["ЛОВ", "ИНТ"], "main": "ЛОВ",
		"scores": {"ЛОВ": 15, "ТЕЛ": 14, "ИНТ": 13, "ХАР": 12, "МДР": 10, "СИЛ": 8},
		"skills": ["Скрытность", "Ловкость рук", "Акробатика", "Обман"],
		"start": [["rapier", true], ["leather", true], ["traveler_clothes", true], ["shortbow", false], ["thieves_tools", false]],
		"features": "Скрытая атака (+1к6 за каждые 2 уровня, раз за ход), мастер навыков",
		"desc": "Замки, ловушки и удар в спину"},
	"Жрец": {"armor": ["лёгкий", "средний", "тяжёлый", "shield"], "hd": 8, "saves": ["МДР", "ХАР"], "main": "МДР", "caster": "МДР",
		"scores": {"МДР": 15, "ТЕЛ": 14, "СИЛ": 13, "ХАР": 12, "ИНТ": 10, "ЛОВ": 8},
		"skills": ["Медицина", "Религия", "Проницательность"],
		"spells": ["sacred_flame", "cure_wounds", "healing_word", "guiding_bolt", "shield_of_faith", "spiritual_weapon", "mass_healing_word"],
		"start": [["mace", true], ["scale_mail", true], ["shield", true], ["holy_symbol", true]],
		"features": "Заклинания на Мудрости: лечение, свет, защита",
		"desc": "Лечит друзей и жжёт нежить"},
	"Следопыт": {"armor": ["лёгкий", "средний", "shield"], "hd": 10, "saves": ["СИЛ", "ЛОВ"], "main": "ЛОВ",
		"scores": {"ЛОВ": 15, "МДР": 14, "ТЕЛ": 13, "СИЛ": 12, "ИНТ": 10, "ХАР": 8},
		"skills": ["Выживание", "Природа", "Восприятие", "Скрытность"],
		"start": [["longbow", true], ["leather", true], ["hunter_cloak", true], ["shortsword", false], ["potion_heal", false]],
		"features": "Стрельба (+2 к атакам дальнобойным оружием), Дополнительная атака с 5 уровня",
		"desc": "Лук, следы и дикие земли"},
	"Бард": {"armor": ["лёгкий"], "hd": 8, "saves": ["ЛОВ", "ХАР"], "main": "ХАР", "caster": "ХАР",
		"scores": {"ХАР": 15, "ЛОВ": 14, "ТЕЛ": 13, "ИНТ": 12, "МДР": 10, "СИЛ": 8},
		"skills": ["Выступление", "Убеждение", "Обман", "Проницательность"],
		"spells": ["vicious_mockery", "healing_word", "thunderwave", "sleep", "shatter"],
		"start": [["rapier", true], ["leather", true], ["fine_clothes", true], ["lute", false]],
		"features": "Вдохновение барда (союзник добавляет 1к6 к броску), заклинания на Харизме",
		"desc": "Песни, обаяние и вдохновение"},
}

## Таланты: выбор при новом уровне (по мотивам SRD 5.1, своими словами).
## cls: для каких классов (пусто — для всех). Эффекты складываются в talent_sum().
const TALENTS := {
	"tough": {"name": "Крепкий", "desc": "+2 хита за каждый уровень, в том числе прошлые", "hp_lvl": 2},
	"alert": {"name": "Бдительный", "desc": "+5 к инициативе: в бою ходишь раньше", "init": 5},
	"resilient": {"name": "Стойкий", "desc": "+1 ко всем спасброскам", "save_all": 1},
	"keen": {"name": "Зоркий", "desc": "+3 к Восприятию и Проницательности", "skills": {"Восприятие": 3, "Проницательность": 3}},
	"defense": {"name": "Стиль «Оборона»", "desc": "+1 КД, пока на тебе доспех", "ac_armor": 1, "cls": ["Воин", "Следопыт", "Жрец"]},
	"dueling": {"name": "Стиль «Дуэль»", "desc": "+2 урона одноручным оружием ближнего боя", "dmg_onehand": 2, "cls": ["Воин", "Следопыт", "Плут"]},
	"great_weapon": {"name": "Мощный замах", "desc": "+3 урона двуручным оружием", "dmg_two": 3, "cls": ["Воин"]},
	"champion": {"name": "Чемпион", "desc": "Критическое попадание оружием на 19-20", "crit": 1, "cls": ["Воин", "Следопыт"]},
	"marksman": {"name": "Меткий стрелок", "desc": "+1 к попаданию и +2 урона дальнобойным оружием", "atk_ranged": 1, "dmg_ranged": 2, "cls": ["Следопыт", "Плут", "Воин"]},
	"hunter": {"name": "Метка охотника", "desc": "+2 урона любым оружием", "dmg_weapon": 2, "cls": ["Следопыт"]},
	"assassin": {"name": "Убийца", "desc": "Скрытая атака сильнее на 1к6", "sneak_dice": 1, "cls": ["Плут"]},
	"expertise": {"name": "Экспертиза", "desc": "+3 к Скрытности, Ловкости рук и Обману", "skills": {"Скрытность": 3, "Ловкость рук": 3, "Обман": 3}, "cls": ["Плут", "Бард"]},
	"evasion": {"name": "Увёртливость", "desc": "+1 КД и +1 ко всем спасброскам", "ac": 1, "save_all": 1, "cls": ["Плут"]},
	"life": {"name": "Домен жизни", "desc": "Лечение заклинаниями и зельями сильнее на 3", "heal": 3, "cls": ["Жрец", "Бард"]},
	"divine_strike": {"name": "Божественный удар", "desc": "+3 урона оружием (священная сила)", "dmg_weapon": 3, "cls": ["Жрец"]},
	"war_caster": {"name": "Боевой маг", "desc": "+1 к атаке заклинаниями и к их Сложности", "spell_atk": 1, "cls": ["Маг", "Жрец", "Бард"]},
	"evoker": {"name": "Школа воплощения", "desc": "+2 урона атакующими заклинаниями", "spell_dmg": 2, "cls": ["Маг"]},
	"arcane_ward": {"name": "Магическая защита", "desc": "+2 КД (невидимый щит)", "ac": 2, "cls": ["Маг"]},
	"more_inspire": {"name": "Песнь отваги", "desc": "+1 вдохновение барда на каждый отдых", "inspire": 1, "cls": ["Бард"]},
	"lore": {"name": "Знаток", "desc": "+1 ко всем навыкам", "skill_all": 1, "cls": ["Бард"]},
}


static func talent_sum(h: Dictionary, key: String) -> int:
	var t := 0
	for id in h.get("talents", []):
		var d: Dictionary = TALENTS.get(str(id), {})
		if d.has(key) and not (d[key] is Dictionary):
			t += int(d[key])
	return t


static func talent_skill(h: Dictionary, skill: String) -> int:
	var t := talent_sum(h, "skill_all")
	for id in h.get("talents", []):
		t += int(TALENTS.get(str(id), {}).get("skills", {}).get(skill, 0))
	return t


static func talent_names(h: Dictionary) -> Array:
	var out := []
	for id in h.get("talents", []):
		if TALENTS.has(str(id)):
			out.append(TALENTS[str(id)])
	return out


## Новый выбор при повышении уровня: на 4 и 8 — +2 к характеристике, иначе один из трёх талантов.
static func make_choice(h: Dictionary) -> Dictionary:
	var lv := int(h.level)
	if lv in [4, 8]:
		var opts := []
		for a in AB:
			if int(h.scores[a]) < 20:
				opts.append(a)
		return {"level": lv, "kind": "asi", "options": opts}
	var pool := []
	for id in TALENTS:
		var d: Dictionary = TALENTS[id]
		if id in h.get("talents", []):
			continue
		if d.has("cls") and not (h.cls in d.cls):
			continue
		pool.append(id)
	pool.shuffle()
	# свои классовые таланты вперёд, общие — для разнообразия
	pool.sort_custom(func(a, b): return int(TALENTS[a].has("cls")) > int(TALENTS[b].has("cls")))
	var opts2 := pool.slice(0, 2)
	for id in pool.slice(2):
		if not TALENTS[id].has("cls"):
			opts2.append(id)
			break
	if opts2.size() < 3:
		for id in pool:
			if not (id in opts2) and opts2.size() < 3:
				opts2.append(id)
	if opts2.is_empty():
		return {}
	return {"level": lv, "kind": "talent", "options": opts2}


## Применяет выбор игрока. Возвращает строку для летописи или "" если выбор неверный.
static func apply_choice(h: Dictionary, pick: String) -> String:
	var ch: Array = h.get("choices", [])
	if ch.is_empty():
		return ""
	var c: Dictionary = ch[0]
	if not (pick in c.options):
		return ""
	ch.pop_front()
	if c.kind == "asi":
		h.scores[pick] = mini(20, int(h.scores[pick]) + 2)
		return "%s: %s +2 (теперь %d)." % [h.name, AB_NAME.get(pick, pick), int(h.scores[pick])]
	if not h.has("talents"):
		h.talents = []
	h.talents.append(pick)
	var d: Dictionary = TALENTS[pick]
	if int(d.get("hp_lvl", 0)) > 0:
		var add := int(d.hp_lvl) * int(h.level)
		h.max_hp = int(h.max_hp) + add
		h.hp = int(h.hp) + add
	if int(d.get("inspire", 0)) > 0:
		h.inspire = int(h.get("inspire", 0)) + int(d.inspire)
	return "%s осваивает талант «%s»: %s." % [h.name, d.name, d.desc]


## Слоты снаряжения.
const SLOT_NAMES := {"weapon": "Оружие", "offhand": "Щит", "armor": "Доспех", "clothes": "Одежда",
	"head": "Голова", "ring": "Кольцо", "amulet": "Амулет"}

## Предметы. type: weapon / armor / shield / clothes / head / ring / amulet / potion / scroll / misc.
## weapon: dmg, ability (СИЛ / ЛОВ / fin = лучшая из двух), ranged, two (двуручное).
## armor: ac, dex_max (-1 = без ограничения), cat. Бонусы: ac, attack, damage, save, abil {}, skill {}.
const ITEMS := {
	"dagger": {"name": "Кинжал", "type": "weapon", "dt": "колющий", "dmg": "1d4", "ability": "fin", "price": 2},
	"shortsword": {"name": "Короткий меч", "type": "weapon", "dt": "колющий", "dmg": "1d6", "ability": "fin", "price": 10},
	"rapier": {"name": "Рапира", "type": "weapon", "dt": "колющий", "dmg": "1d8", "ability": "fin", "price": 25},
	"longsword": {"name": "Длинный меч", "type": "weapon", "dt": "рубящий", "dmg": "1d8", "ability": "СИЛ", "price": 15},
	"greatsword": {"name": "Двуручный меч", "type": "weapon", "dt": "рубящий", "dmg": "2d6", "ability": "СИЛ", "two": true, "price": 50},
	"battleaxe": {"name": "Боевой топор", "type": "weapon", "dt": "рубящий", "dmg": "1d8", "ability": "СИЛ", "price": 10},
	"greataxe": {"name": "Секира", "type": "weapon", "dt": "рубящий", "dmg": "1d12", "ability": "СИЛ", "two": true, "price": 30},
	"mace": {"name": "Булава", "type": "weapon", "dt": "дробящий", "dmg": "1d6", "ability": "СИЛ", "price": 5},
	"warhammer": {"name": "Боевой молот", "type": "weapon", "dt": "дробящий", "dmg": "1d8", "ability": "СИЛ", "price": 15},
	"quarterstaff": {"name": "Боевой посох", "type": "weapon", "dt": "дробящий", "dmg": "1d6", "ability": "СИЛ", "price": 1},
	"spear": {"name": "Копьё", "type": "weapon", "dt": "колющий", "dmg": "1d6", "ability": "СИЛ", "price": 1},
	"shortbow": {"name": "Короткий лук", "type": "weapon", "dt": "колющий", "dmg": "1d6", "ability": "ЛОВ", "ranged": true, "two": true, "price": 25},
	"longbow": {"name": "Длинный лук", "type": "weapon", "dt": "колющий", "dmg": "1d8", "ability": "ЛОВ", "ranged": true, "two": true, "price": 50},
	"crossbow": {"name": "Лёгкий арбалет", "type": "weapon", "dt": "колющий", "dmg": "1d8", "ability": "ЛОВ", "ranged": true, "two": true, "price": 25},

	"padded": {"name": "Стёганый доспех", "type": "armor", "ac": 11, "dex_max": -1, "cat": "лёгкий", "price": 5},
	"leather": {"name": "Кожаный доспех", "type": "armor", "ac": 11, "dex_max": -1, "cat": "лёгкий", "price": 10},
	"studded": {"name": "Проклёпанная кожа", "type": "armor", "ac": 12, "dex_max": -1, "cat": "лёгкий", "price": 45},
	"chain_shirt": {"name": "Кольчужная рубаха", "type": "armor", "ac": 13, "dex_max": 2, "cat": "средний", "price": 50},
	"scale_mail": {"name": "Чешуйчатый доспех", "type": "armor", "ac": 14, "dex_max": 2, "cat": "средний", "price": 50},
	"breastplate": {"name": "Кираса", "type": "armor", "ac": 14, "dex_max": 2, "cat": "средний", "price": 400},
	"half_plate": {"name": "Полулаты", "type": "armor", "ac": 15, "dex_max": 2, "cat": "средний", "price": 750},
	"chain_mail": {"name": "Кольчуга", "type": "armor", "ac": 16, "dex_max": 0, "cat": "тяжёлый", "price": 75},
	"splint": {"name": "Наборный доспех", "type": "armor", "ac": 17, "dex_max": 0, "cat": "тяжёлый", "price": 200},
	"plate": {"name": "Латы", "type": "armor", "ac": 18, "dex_max": 0, "cat": "тяжёлый", "price": 1500},
	"shield": {"name": "Щит", "type": "shield", "ac": 2, "price": 10},

	"traveler_clothes": {"name": "Дорожная одежда", "type": "clothes", "price": 2},
	"fine_clothes": {"name": "Нарядный камзол", "type": "clothes", "skill": {"Убеждение": 1}, "price": 15},
	"mage_robe": {"name": "Мантия мага", "type": "clothes", "skill": {"Магия": 1}, "price": 10},
	"hunter_cloak": {"name": "Плащ охотника", "type": "clothes", "skill": {"Скрытность": 1}, "price": 10},
	"elven_cloak": {"name": "Эльфийский плащ", "type": "clothes", "skill": {"Скрытность": 4}, "magic": true, "price": 400},
	"cloak_protection": {"name": "Плащ защиты", "type": "clothes", "ac": 1, "save": 1, "magic": true, "price": 500},
	"leather_cap": {"name": "Кожаная шапка", "type": "head", "price": 2},
	"helmet": {"name": "Шлем", "type": "head", "save": 0, "skill": {"Запугивание": 1}, "price": 10},
	"circlet_wisdom": {"name": "Обруч мудреца", "type": "head", "abil": {"МДР": 2}, "magic": true, "price": 600},
	"ring_protection": {"name": "Кольцо защиты", "type": "ring", "ac": 1, "save": 1, "magic": true, "price": 600},
	"ring_luck": {"name": "Кольцо удачи", "type": "ring", "skill": {"Обман": 2, "Убеждение": 2}, "magic": true, "price": 300},
	"amulet_health": {"name": "Амулет здоровья", "type": "amulet", "abil": {"ТЕЛ": 2}, "magic": true, "price": 800},
	"gauntlets_power": {"name": "Перчатки огровой силы", "type": "amulet", "abil": {"СИЛ": 3}, "magic": true, "price": 900},
	"amulet_ward": {"name": "Оберег от зла", "type": "amulet", "save": 2, "magic": true, "price": 700},

	"potion_heal": {"name": "Зелье лечения", "type": "potion", "heal": "2d4+2", "price": 50},
	"potion_greater": {"name": "Большое зелье лечения", "type": "potion", "heal": "4d4+4", "price": 150},
	"potion_superior": {"name": "Превосходное зелье лечения", "type": "potion", "heal": "8d4+8", "price": 450},
	"scroll_fire": {"name": "Свиток огненного шара", "type": "scroll", "spell": "fireball", "price": 300},
	"scroll_missile": {"name": "Свиток волшебной стрелы", "type": "scroll", "spell": "magic_missile", "price": 60},
	"scroll_cure": {"name": "Свиток лечения ран", "type": "scroll", "spell": "cure_wounds", "price": 60},

	"thieves_tools": {"name": "Воровские инструменты", "type": "misc", "skill": {"Ловкость рук": 2}, "price": 25},
	"spellbook": {"name": "Книга заклинаний", "type": "misc", "price": 50},
	"holy_symbol": {"name": "Священный символ", "type": "amulet", "price": 5},
	"lute": {"name": "Лютня", "type": "misc", "skill": {"Выступление": 2}, "price": 35},
	"rope": {"name": "Верёвка (15 м)", "type": "misc", "skill": {"Атлетика": 1}, "price": 1},
	"torch": {"name": "Факел", "type": "misc", "price": 1},
	"rations": {"name": "Паёк", "type": "misc", "price": 1},
	"misc": {"name": "Вещь", "type": "misc", "price": 1},

	"herb": {"name": "Лечебные травы", "type": "reagent", "price": 5},
	"venom_sac": {"name": "Ядовитая железа", "type": "reagent", "price": 15},
	"ember_dust": {"name": "Огненная пыль", "type": "reagent", "price": 15},
	"antidote": {"name": "Противоядие", "type": "potion", "heal": "1d4", "cure": ["poisoned"], "price": 50},
	"poison_vial": {"name": "Флакон яда", "type": "coat", "dice": "1d6", "hits": 3, "price": 100},
	"fire_flask": {"name": "Алхимический огонь", "type": "bomb", "dmg": "2d6", "save": "ЛОВ", "dc": 12, "price": 50},
}

## Рецепты алхимии: что получится и что уходит. Варить можно вне боя.
const RECIPES := {
	"potion_heal": {"need": {"herb": 2}, "skill": "Медицина"},
	"antidote": {"need": {"herb": 1, "venom_sac": 1}, "skill": "Медицина"},
	"poison_vial": {"need": {"venom_sac": 2}, "skill": "Природа"},
	"fire_flask": {"need": {"ember_dust": 1, "herb": 1}, "skill": "Магия"},
	"potion_greater": {"need": {"potion_heal": 2, "ember_dust": 1}, "skill": "Магия"},
}

## Состояния. Пока висят — дают помеху или преимущество, rounds — сколько раундов боя.
const CONDS := {
	"poisoned": {"name": "Отравлен", "icon": "cond_poisoned", "desc": "помеха на атаки и проверки"},
	"blinded": {"name": "Ослеплён", "icon": "cond_blinded", "desc": "помеха на атаки, по нему бьют с преимуществом"},
	"frightened": {"name": "Испуган", "icon": "cond_frightened", "desc": "помеха на атаки и проверки"},
	"prone": {"name": "Сбит с ног", "icon": "cond_prone", "desc": "помеха на атаки, вблизи по нему бьют с преимуществом; встать — потратить перемещение"},
	"stunned": {"name": "Оглушён", "icon": "cond_stunned", "desc": "пропускает ход, по нему бьют с преимуществом"},
}


static func cond_from(s: String) -> String:
	var low := s.strip_edges().to_lower()
	if CONDS.has(low):
		return low
	for k in CONDS:
		if str(CONDS[k].name).to_lower().left(5) == low.left(5):
			return k
	var syn := {"отрав": "poisoned", "яд": "poisoned", "ослеп": "blinded", "испуг": "frightened", "страх": "frightened",
		"сбит": "prone", "лежит": "prone", "упал": "prone", "оглуш": "stunned", "парал": "stunned"}
	for k in syn:
		if low.begins_with(k):
			return syn[k]
	return ""


## Помеха/преимущество от состояний: атакующий и цель.
static func cond_adv(att: Dictionary, def: Dictionary, melee: bool) -> int:
	var a := 0
	var ac: Dictionary = att.get("conds", {})
	var dc: Dictionary = def.get("conds", {})
	if ac.has("poisoned") or ac.has("blinded") or ac.has("frightened") or ac.has("prone"):
		a -= 1
	if dc.has("blinded") or dc.has("stunned") or (dc.has("prone") and melee):
		a += 1
	if dc.has("prone") and not melee:
		a -= 1
	return clampi(a, -1, 1)


static func check_adv(h: Dictionary) -> int:
	var c: Dictionary = h.get("conds", {})
	return -1 if (c.has("poisoned") or c.has("frightened")) else 0

## Заклинания. kind: attack (бросок атаки), save (спасбросок цели), auto (без промаха), heal, buff, sleep.
const SPELLS := {
	"fire_bolt": {"dt": "огонь", "col": "ff7a3d", "name": "Огненный снаряд", "lvl": 0, "kind": "attack", "dmg": "1d10", "desc": "сгусток огня, 1к10"},
	"ray_of_frost": {"dt": "холод", "col": "7fd4ff", "name": "Луч холода", "lvl": 0, "kind": "attack", "dmg": "1d8", "desc": "ледяной луч, 1к8"},
	"sacred_flame": {"dt": "излучение", "col": "ffd75e", "name": "Священное пламя", "lvl": 0, "kind": "save", "save": "ЛОВ", "dmg": "1d8", "desc": "свет с небес, 1к8"},
	"vicious_mockery": {"dt": "психический", "col": "ff8fd0", "name": "Злая насмешка", "lvl": 0, "kind": "save", "save": "МДР", "dmg": "1d4", "cond": "frightened", "desc": "обидная шутка, 1к4, пугает"},
	"magic_missile": {"dt": "силовой", "col": "b98cff", "name": "Волшебная стрела", "lvl": 1, "kind": "auto", "dmg": "3d4+3", "desc": "три стрелы без промаха"},
	"burning_hands": {"dt": "огонь", "col": "ff7a3d", "name": "Огненные ладони", "lvl": 1, "kind": "save", "save": "ЛОВ", "dmg": "3d6", "aoe": true, "desc": "веер огня по всем врагам, 3к6"},
	"thunderwave": {"dt": "звук", "col": "8fb4ff", "name": "Громовая волна", "lvl": 1, "kind": "save", "save": "ТЕЛ", "dmg": "2d8", "aoe": true, "cond": "prone", "desc": "удар грома по всем, 2к8, сбивает с ног"},
	"guiding_bolt": {"dt": "излучение", "col": "ffd75e", "name": "Направленный снаряд", "lvl": 1, "kind": "attack", "dmg": "4d6", "cond": "blinded", "desc": "луч света, 4к6, слепит"},
	"sleep": {"col": "a9a0ff", "name": "Усыпление", "lvl": 1, "kind": "sleep", "dmg": "5d8", "desc": "усыпляет слабых врагов"},
	"cure_wounds": {"col": "6fe3a0", "name": "Лечение ран", "lvl": 1, "kind": "heal", "dmg": "1d8", "desc": "лечит 1к8 + мод."},
	"healing_word": {"bonus": true, "col": "6fe3a0", "name": "Лечащее слово", "lvl": 1, "kind": "heal", "dmg": "1d4", "desc": "лечит 1к4 + мод. издалека"},
	"shield_of_faith": {"bonus": true, "col": "ffe08a", "name": "Щит веры", "lvl": 1, "kind": "buff", "ac": 2, "desc": "+2 КД союзнику до конца боя"},
	"scorching_ray": {"dt": "огонь", "col": "ff7a3d", "name": "Палящий луч", "lvl": 2, "kind": "attack", "dmg": "2d6", "rays": 3, "desc": "три луча по 2к6"},
	"shatter": {"dt": "звук", "col": "8fb4ff", "name": "Дребезги", "lvl": 2, "kind": "save", "save": "ТЕЛ", "dmg": "3d8", "aoe": true, "desc": "звон по всем, 3к8"},
	"spiritual_weapon": {"bonus": true, "dt": "силовой", "col": "ffe08a", "name": "Духовное оружие", "lvl": 2, "kind": "attack", "dmg": "2d8", "desc": "призрачный молот, 2к8"},
	"mass_healing_word": {"bonus": true, "col": "6fe3a0", "name": "Лечащее слово для всех", "lvl": 3, "kind": "heal", "dmg": "1d4", "all": true, "desc": "лечит всех союзников"},
	"fireball": {"dt": "огонь", "col": "ff5a2a", "name": "Огненный шар", "lvl": 3, "kind": "save", "save": "ЛОВ", "dmg": "8d6", "aoe": true, "desc": "взрыв по всем врагам, 8к6"},
}

## Монстры (упрощённые статблоки SRD). atk — бонус атаки, multi — атак за ход.
const MONSTERS := {
	"kobold": {"name": "Кобольд", "bow": true, "ac": 12, "hp": 5, "atk": 4, "dmg": "1d4+2", "dex": 2, "xp": 25},
	"giant_rat": {"name": "Гигантская крыса", "ac": 12, "hp": 7, "atk": 4, "dmg": "1d4+2", "dex": 2, "xp": 25},
	"bandit": {"name": "Бандит", "bow": true, "ac": 12, "hp": 11, "atk": 3, "dmg": "1d6+1", "dex": 1, "xp": 25},
	"cultist": {"name": "Сектант", "bow": true, "ac": 12, "hp": 9, "atk": 3, "dmg": "1d6+1", "dex": 1, "xp": 25},
	"goblin": {"name": "Гоблин", "bow": true, "ac": 15, "hp": 7, "atk": 4, "dmg": "1d6+2", "dex": 2, "xp": 50},
	"wolf": {"name": "Волк", "on_hit": {"cond": "prone", "save": "СИЛ", "dc": 11, "rounds": 1}, "ac": 13, "hp": 11, "atk": 4, "dmg": "2d4+2", "dex": 2, "xp": 50},
	"skeleton": {"name": "Скелет", "vuln": ["дробящий"], "ac": 13, "hp": 13, "atk": 4, "dmg": "1d6+2", "dex": 2, "xp": 50, "undead": true, "saves": {"ТЕЛ": 2, "МДР": -1}},
	"zombie": {"name": "Зомби", "fort": true, "ac": 8, "hp": 22, "atk": 3, "dmg": "1d6+1", "dex": -2, "xp": 50, "undead": true, "saves": {"ТЕЛ": 3, "МДР": -2}},
	"giant_spider_small": {"name": "Пещерный паук", "vuln": ["огонь"], "on_hit": {"cond": "poisoned", "save": "ТЕЛ", "dc": 11, "rounds": 3}, "drop": "venom_sac", "ac": 13, "hp": 12, "atk": 4, "dmg": "1d6+2", "dex": 3, "xp": 50},
	"orc": {"name": "Орк", "ac": 13, "hp": 15, "atk": 5, "dmg": "1d12+3", "dex": 1, "xp": 100},
	"hobgoblin": {"name": "Хобгоблин", "bow": true, "ac": 18, "hp": 11, "atk": 3, "dmg": "1d8+1", "dex": 1, "xp": 100},
	"shadow": {"name": "Тень", "res": ["рубящий", "колющий", "дробящий"], "vuln": ["излучение"], "on_hit": {"cond": "frightened", "save": "МДР", "dc": 10, "rounds": 2}, "ac": 12, "hp": 16, "atk": 4, "dmg": "2d6+2", "dex": 2, "xp": 100, "undead": true},
	"bandit_captain": {"name": "Главарь бандитов", "boss": true, "ac": 15, "hp": 65, "atk": 5, "dmg": "1d6+3", "multi": 2, "dex": 3, "xp": 450},
	"ghoul": {"name": "Гуль", "vuln": ["излучение"], "on_hit": {"cond": "stunned", "save": "ТЕЛ", "dc": 10, "rounds": 1}, "ac": 12, "hp": 22, "atk": 4, "dmg": "2d6+2", "dex": 2, "xp": 200, "undead": true},
	"dire_wolf": {"name": "Лютоволк", "on_hit": {"cond": "prone", "save": "СИЛ", "dc": 13, "rounds": 1}, "ac": 14, "hp": 37, "atk": 5, "dmg": "2d6+3", "dex": 2, "xp": 200},
	"giant_spider": {"name": "Гигантский паук", "vuln": ["огонь"], "on_hit": {"cond": "poisoned", "save": "ТЕЛ", "dc": 12, "rounds": 3}, "drop": "venom_sac", "ac": 14, "hp": 26, "atk": 5, "dmg": "1d8+3", "dex": 3, "xp": 200},
	"bugbear": {"name": "Багбир", "ac": 16, "hp": 27, "atk": 4, "dmg": "2d8+2", "dex": 2, "xp": 200},
	"harpy": {"name": "Гарпия", "on_hit": {"cond": "frightened", "save": "МДР", "dc": 11, "rounds": 2}, "ac": 11, "hp": 38, "atk": 3, "dmg": "2d4+1", "multi": 2, "dex": 1, "xp": 200},
	"ogre": {"name": "Огр", "boss": true, "ac": 11, "hp": 59, "atk": 6, "dmg": "2d8+4", "dex": -1, "xp": 450, "saves": {"ТЕЛ": 3, "МДР": -2}},
	"wight": {"name": "Умертвие", "res": ["рубящий", "колющий", "дробящий"], "vuln": ["излучение"], "ac": 14, "hp": 45, "atk": 4, "dmg": "1d8+2", "multi": 2, "dex": 2, "xp": 700, "undead": true, "saves": {"ТЕЛ": 3}},
	"minotaur": {"name": "Минотавр", "boss": true, "ac": 14, "hp": 76, "atk": 6, "dmg": "2d12+4", "dex": 0, "xp": 700, "saves": {"ТЕЛ": 3}},
	"troll": {"name": "Тролль", "regen": 10, "vuln": ["огонь"], "ac": 15, "hp": 84, "atk": 7, "dmg": "2d6+4", "multi": 3, "dex": 1, "xp": 1800, "saves": {"ТЕЛ": 5, "МДР": -1}},
	"wyvern": {"name": "Виверна", "boss": true, "ac": 13, "hp": 110, "atk": 7, "dmg": "2d6+4", "multi": 2, "dex": 0, "xp": 1800},
	"young_dragon": {"name": "Молодой дракон", "res": ["огонь"], "boss": true, "on_hit": {"cond": "frightened", "save": "МДР", "dc": 13, "rounds": 2}, "ac": 18, "hp": 136, "atk": 9, "dmg": "2d10+5", "multi": 3, "dex": 1, "xp": 3900, "saves": {"ТЕЛ": 5, "МДР": 4, "ЛОВ": 4}},
}

## Типы урона. Враги бывают уязвимы (×2) или стойки (½) к некоторым.
const DT_GEN := {"рубящий": "рубящему", "колющий": "колющему", "дробящий": "дробящему", "огонь": "огню", "холод": "холоду",
	"излучение": "излучению", "психический": "психическому", "силовой": "силовому", "звук": "звуку", "яд": "яду"}

## Предметы окружения в бою (как в тактических RPG: бочки, люстры, обрывы).
## kind: aoe — по всем врагам впереди, one — по выбранному врагу, edge — сталкивать с обрыва, high — возвышенность.
const ENV := {
	"barrel": {"name": "Бочка с маслом", "icon": "env_barrel", "kind": "aoe", "dmg": "3d6", "dt": "огонь", "save": "ЛОВ", "dc": 13, "desc": "поджечь: взрыв по врагам впереди, 3к6 огнём"},
	"chandelier": {"name": "Люстра", "icon": "env_chandelier", "kind": "one", "dmg": "2d8", "dt": "дробящий", "save": "ЛОВ", "dc": 12, "cond": "prone", "desc": "обрушить на врага: 2к8 и сбивает с ног"},
	"brazier": {"name": "Жаровня", "icon": "env_brazier", "kind": "one", "dmg": "2d6", "dt": "огонь", "save": "ЛОВ", "dc": 12, "desc": "опрокинуть угли на врага: 2к6 огнём"},
	"rocks": {"name": "Шаткие камни", "icon": "env_rocks", "kind": "one", "dmg": "2d10", "dt": "дробящий", "save": "ЛОВ", "dc": 13, "desc": "обрушить камнепад: 2к10"},
	"oil": {"name": "Скользкая жижа", "icon": "env_oil", "kind": "aoe", "dmg": "", "dt": "", "save": "ЛОВ", "dc": 12, "cond": "prone", "desc": "разлить под ноги врагам: падают"},
	"web": {"name": "Старая паутина", "icon": "env_web", "kind": "one", "dmg": "", "dt": "", "save": "СИЛ", "dc": 12, "cond": "stunned", "desc": "сбросить на врага: запутывает на раунд"},
	"cliff": {"name": "Обрыв", "icon": "env_cliff", "kind": "edge", "dmg": "3d6", "dt": "дробящий", "desc": "толкнуть врага вниз: 3к6 от падения", "keep": true},
	"high": {"name": "Возвышенность", "icon": "env_high", "kind": "high", "desc": "занять (тратит перемещение): +2 к стрельбе и заклинаниям-атакам", "keep": true},
}
const ENV_BY_PLACE := {
	"tavern": ["chandelier", "barrel", "brazier"], "village": ["barrel", "high", "oil"], "city": ["barrel", "chandelier", "high"],
	"forest": ["high", "rocks", "web"], "road": ["high", "rocks", "barrel"], "cave": ["rocks", "cliff", "web"],
	"dungeon": ["brazier", "chandelier", "oil", "web"], "castle": ["chandelier", "brazier", "high"], "ruins": ["rocks", "high", "cliff"],
}


static func weapon_dt(w: Dictionary) -> String:
	if str(w.get("dt", "")) != "":
		return str(w.dt)
	var n := str(w.get("name", "")).to_lower()
	for k in ["меч", "топор", "секир", "сабл", "клинок", "тесак", "коса", "серп"]:
		if n.contains(k) and not n.contains("короткий"):
			return "рубящий"
	for k in ["молот", "булав", "посох", "дубин", "кистен", "палиц", "кулак"]:
		if n.contains(k):
			return "дробящий"
	return "колющий"


## Типы мест для карты.
const PLACE_TYPES := ["village", "city", "tavern", "forest", "road", "cave", "dungeon", "castle", "ruins",
	"swamp", "mountain", "lake", "camp", "temple", "tower", "field", "sea", "port"]


# ---------- функции ----------

static func mod(score: int) -> int:
	return floori((score - 10) / 2.0)


static func prof(level: int) -> int:
	return 2 + (level - 1) / 4


## «2d6+3» → число.
static func roll(expr: String) -> int:
	var p := parse_dice(expr)
	var total: int = p.bonus
	for i in p.n:
		total += randi_range(1, p.sides)
	return total


static func parse_dice(expr: String) -> Dictionary:
	var e := expr.replace(" ", "").to_lower().replace("к", "d").replace("д", "d").replace("-", "+-")
	var n := 0
	var sides := 1
	var bonus := 0
	for term in e.split("+", false):
		if term.contains("d"):
			var p := term.split("d")
			var k := clampi(p[0].to_int() if p[0] != "" else 1, 1, 20)
			var sd := clampi(p[1].to_int(), 1, 100)
			if n == 0:
				n = k
				sides = sd
			else:
				bonus += k * (sd + 1) / 2
		elif term.is_valid_int():
			bonus += int(term)
	return {"n": n, "sides": sides, "bonus": bonus}


## «2d6» → «2к6» для показа.
static func dice_ru(expr: String) -> String:
	return expr.replace("d", "к")


static func item_def(it: Dictionary) -> Dictionary:
	var base: Dictionary = ITEMS.get(str(it.get("id", "misc")), ITEMS["misc"]).duplicate(true)
	for k in it:
		if k != "id":
			base[k] = it[k]
	var plus := int(it.get("plus", 0))
	if plus > 0:
		if base.type == "weapon":
			base.attack = int(base.get("attack", 0)) + plus
			base.damage = int(base.get("damage", 0)) + plus
		elif base.type in ["armor", "shield"]:
			base.ac = int(base.get("ac", 0)) + plus
		base.magic = true
	return base


static func item_name(it: Dictionary) -> String:
	var d := item_def(it)
	var n := str(d.get("name", "Вещь"))
	if "_" in n:
		n = _humanize(n)
	var plus := int(it.get("plus", 0))
	if plus > 0 and not n.ends_with("+%d" % plus):
		n += " +%d" % plus
	return n


static func item_desc(it: Dictionary) -> String:
	var d := item_def(it)
	var parts := []
	match str(d.type):
		"weapon":
			parts.append("урон %s" % dice_ru(str(d.dmg)))
			if d.get("ranged", false):
				parts.append("дальнобойное")
			if d.get("two", false):
				parts.append("двуручное")
			if str(d.get("ability", "")) == "fin":
				parts.append("фехтовальное")
		"armor":
			parts.append("КД %d%s" % [int(d.ac), "" if int(d.dex_max) == 0 else (" + ЛОВ" if int(d.dex_max) < 0 else " + ЛОВ (макс. 2)")])
			parts.append(str(d.get("cat", "")))
		"shield":
			parts.append("+%d КД" % int(d.ac))
		"potion":
			parts.append("лечит %s" % dice_ru(str(d.heal)))
			if d.has("cure"):
				parts.append("снимает отравление")
		"reagent":
			parts.append("ингредиент для алхимии")
		"coat":
			parts.append("яд на оружие: %d попадания +%s и отравление" % [int(d.hits), dice_ru(str(d.dice))])
		"bomb":
			parts.append("бросить во врага: %s, спасбросок %s СЛ %d — половина" % [dice_ru(str(d.dmg)), d.save, int(d.dc)])
		"scroll":
			parts.append("одно заклинание: " + str(SPELLS.get(str(d.spell), {}).get("name", "?")))
	if d.type not in ["armor", "shield"] and int(d.get("ac", 0)) > 0:
		parts.append("+%d КД" % int(d.ac))
	if int(d.get("attack", 0)) > 0 and d.type == "weapon":
		parts.append("+%d к атаке и урону" % int(d.attack))
	if int(d.get("save", 0)) > 0:
		parts.append("+%d к спасброскам" % int(d.save))
	for a in d.get("abil", {}):
		parts.append("%s +%d" % [a, int(d.abil[a])])
	for s in d.get("skill", {}):
		parts.append("%s +%d" % [s, int(d.skill[s])])
	if str(d.get("desc", "")) != "":
		parts.append(str(d.desc))
	return ", ".join(parts)


static func item_slot(it: Dictionary) -> String:
	var t := str(item_def(it).type)
	match t:
		"weapon": return "weapon"
		"shield": return "offhand"
		"armor", "clothes", "head", "ring", "amulet": return t
	return ""


static func item_price(it: Dictionary) -> int:
	var d := item_def(it)
	var p := int(d.get("price", 1))
	var plus := int(it.get("plus", 0))
	if plus > 0:
		p += [0, 500, 2000, 6000][clampi(plus, 0, 3)]
	return p


## Создаёт предмет из ответа нейронки: id из каталога, либо свободная вещь.
## «ancient_cylinder» → «Ancient cylinder»: хотя бы без подчёркиваний, с заглавной буквы.
static func _humanize(s: String) -> String:
	s = s.replace("_", " ").strip_edges()
	if s == "":
		return "Вещь"
	return s.left(1).to_upper() + s.substr(1)


static func item_from_ai(v) -> Dictionary:
	if v is String:
		var s := str(v).strip_edges()
		if ITEMS.has(s) and s != "misc":
			return {"id": s}
		for id in ITEMS:
			if ITEMS[id].name.to_lower() == s.to_lower():
				return {"id": id}
		return {"id": "misc", "name": _humanize(s).left(40)}
	if v is Dictionary:
		var id := str(v.get("id", "misc"))
		var note := str(v.get("note", v.get("desc", ""))).strip_edges().left(200)
		if not ITEMS.has(id) or id == "misc":
			var mi := {"id": "misc", "name": _humanize(str(v.get("name", id))).left(40)}
			if note != "":
				mi.note = note
			return mi
		var it := {"id": id}
		if note != "":
			it.note = note
		var plus := clampi(int(v.get("plus", 0)), 0, 3)
		if plus > 0:
			it.plus = plus
		if str(v.get("name", "")) != "" and str(v.get("name")) != ITEMS[id].name:
			it.name = str(v.name).left(40)
		return it
	return {}


## Лут из сундука: золото и 1-3 предмета. tier 1..4 по уровню героев.
static func roll_loot(tier: int) -> Dictionary:
	tier = clampi(tier, 1, 4)
	var gold := roll("%dd10" % (tier * 2)) * (5 if tier < 3 else 15)
	var items := []
	var n := randi_range(1, 2 + (1 if tier >= 2 else 0))
	var commons := ["potion_heal", "potion_heal", "dagger", "shortsword", "leather", "studded", "chain_shirt", "shield",
		"leather_cap", "helmet", "rope", "torch", "rations", "scroll_missile", "scroll_cure", "fine_clothes", "hunter_cloak",
		"crossbow", "spear", "battleaxe", "warhammer", "shortbow", "herb", "herb", "ember_dust", "antidote", "thieves_tools", "fire_flask"]
	var uncommons := ["potion_greater", "scale_mail", "breastplate", "longsword", "rapier", "longbow", "greatsword",
		"greataxe", "chain_mail", "scroll_fire", "ring_luck"]
	var magic := ["elven_cloak", "cloak_protection", "ring_protection", "amulet_health", "gauntlets_power",
		"amulet_ward", "circlet_wisdom", "potion_superior", "half_plate", "splint", "plate"]
	for i in n:
		var r := randf()
		var it := {}
		if r < 0.12 * tier:
			it = {"id": magic[randi() % magic.size()]}
		elif r < 0.12 * tier + 0.15:
			var weapons := ["longsword", "rapier", "shortsword", "longbow", "battleaxe", "mace", "warhammer", "greatsword"]
			it = {"id": weapons[randi() % weapons.size()], "plus": clampi(randi_range(1, tier - 1 + 1), 1, 3)}
		elif r < 0.5 and tier >= 2:
			it = {"id": uncommons[randi() % uncommons.size()]}
		else:
			it = {"id": commons[randi() % commons.size()]}
		items.append(it)
	return {"gold": gold, "items": items}


## Товары лавки по уровню.
static func shop_stock(tier: int) -> Array:
	var ids := ["potion_heal", "potion_heal", "rope", "torch", "rations", "dagger", "shortsword", "longsword", "rapier",
		"mace", "battleaxe", "quarterstaff", "shortbow", "longbow", "crossbow", "leather", "studded", "chain_shirt",
		"scale_mail", "chain_mail", "shield", "helmet", "leather_cap", "fine_clothes", "hunter_cloak", "traveler_clothes",
		"scroll_missile", "scroll_cure", "herb", "herb", "ember_dust", "antidote", "thieves_tools", "fire_flask"]
	if tier >= 2:
		ids += ["potion_greater", "breastplate", "greatsword", "greataxe", "splint", "half_plate", "scroll_fire", "ring_luck"]
	if tier >= 3:
		ids += ["plate", "elven_cloak", "cloak_protection", "ring_protection", "potion_superior"]
	var out := []
	ids.shuffle()
	for id in ids.slice(0, 12):
		out.append({"id": id})
	return out


# ---------- герой ----------

static func new_hero(hero_name: String, race: String, cls: String, about: String) -> Dictionary:
	var c: Dictionary = CLASSES[cls]
	var r: Dictionary = RACES.get(race, RACES["Человек"])
	var scores := {}
	for a in AB:
		scores[a] = int(c.scores[a]) + int(r.bonus.get(a, 0))
	var skills: Array = c.skills.duplicate()
	for s in r.get("skills", []):
		if not (s in skills):
			skills.append(s)
	var h := {"name": hero_name, "race": race, "cls": cls, "about": about, "level": 1, "xp": 0,
		"scores": scores, "skills": skills, "gold": 15, "equip": {}, "items": [],
		"hd_left": 1, "slots": [], "slots_max": [], "second_wind": cls == "Воин",
		"inspire": maxi(1, mod(int(scores["ХАР"]))) if cls == "Бард" else 0,
		"relentless": bool(r.get("relentless", false)), "inspired": false,
		"death_s": 0, "death_f": 0, "stable": false, "dead": false, "temp_ac": 0}
	for pair in c.start:
		var it := {"id": pair[0]}
		if pair[1]:
			h.equip[item_slot(it)] = it
		else:
			h.items.append(it)
	h.max_hp = int(c.hd) + mod(int(scores["ТЕЛ"])) + int(r.get("hp_per_level", 0))
	h.hp = h.max_hp
	_update_slots(h)
	h.slots = h.slots_max.duplicate()
	return h


static func _update_slots(h: Dictionary) -> void:
	if not CLASSES[h.cls].has("caster"):
		h.slots_max = []
		return
	var mx: Array = SLOTS[clampi(int(h.level), 1, 10) - 1].duplicate()
	var cur: Array = h.get("slots", [])
	var out := []
	for i in mx.size():
		out.append(int(cur[i]) if i < cur.size() else 0)
	h.slots_max = mx
	h.slots = out


## Повышение уровня. Возвращает текст для журнала.
static func level_up(h: Dictionary) -> String:
	h.level = int(h.level) + 1
	var c: Dictionary = CLASSES[h.cls]
	var gain := maxi(1, int(c.hd) / 2 + 1 + mod(score(h, "ТЕЛ")) + int(RACES.get(h.race, {}).get("hp_per_level", 0)) + talent_sum(h, "hp_lvl"))
	h.max_hp = int(h.max_hp) + gain
	h.hp = h.max_hp
	h.hd_left = mini(int(h.level), int(h.hd_left) + 1)
	var extra := ""
	var ch := make_choice(h)
	if not ch.is_empty():
		if not h.has("choices"):
			h.choices = []
		h.choices.append(ch)
		extra = ", выбери %s" % ("+2 к характеристике" if ch.kind == "asi" else "новый талант")
	var old_max := (h.slots_max as Array).duplicate()
	_update_slots(h)
	for i in h.slots_max.size():
		var before := int(old_max[i]) if i < old_max.size() else 0
		h.slots[i] = int(h.slots[i]) + int(h.slots_max[i]) - before
	if int(h.level) == 5 and h.cls in ["Воин", "Следопыт"]:
		extra += ", вторая атака за ход"
	return "%s достигает %d уровня! +%d хитов%s." % [h.name, h.level, gain, extra]


static func xp_next(h: Dictionary) -> int:
	var l := int(h.level)
	return XP_LEVELS[l - 1] if l - 1 < XP_LEVELS.size() else 999999


static func equipped_defs(h: Dictionary) -> Array:
	var out := []
	for s in h.equip:
		if h.equip[s] is Dictionary and not h.equip[s].is_empty():
			out.append(item_def(h.equip[s]))
	return out


static func score(h: Dictionary, a: String) -> int:
	var v := int(h.scores.get(a, 10))
	for d in equipped_defs(h):
		v += int(d.get("abil", {}).get(a, 0))
	return mini(v, 22)


static func amod(h: Dictionary, a: String) -> int:
	return mod(score(h, a))


static func ac(h: Dictionary) -> int:
	var dex := amod(h, "ЛОВ")
	var total := 10 + dex
	var armor = h.equip.get("armor")
	if armor is Dictionary and not armor.is_empty():
		var d := item_def(armor)
		var dm := int(d.get("dex_max", -1))
		total = int(d.ac) + (dex if dm < 0 else (0 if dm == 0 else mini(dex, dm)))
	for s in h.equip:
		if s == "armor" or not (h.equip[s] is Dictionary) or h.equip[s].is_empty():
			continue
		total += int(item_def(h.equip[s]).get("ac", 0))
	total += talent_sum(h, "ac")
	if armor is Dictionary and not armor.is_empty():
		total += talent_sum(h, "ac_armor")
	return total + int(h.get("temp_ac", 0))


static func save_bonus(h: Dictionary, a: String) -> int:
	var b := amod(h, a)
	if a in CLASSES[h.cls].saves:
		b += prof(int(h.level))
	for d in equipped_defs(h):
		b += int(d.get("save", 0))
	return b + talent_sum(h, "save_all")


static func skill_bonus(h: Dictionary, skill: String) -> int:
	var a: String = SKILLS.get(skill, "СИЛ")
	var b := amod(h, a)
	if skill in h.skills:
		b += prof(int(h.level))
	for d in equipped_defs(h):
		b += int(d.get("skill", {}).get(skill, 0))
	for it in h.items:
		var d := item_def(it)
		if d.type == "misc":
			b += int(d.get("skill", {}).get(skill, 0))
	return b + talent_skill(h, skill)


static func weapon(h: Dictionary) -> Dictionary:
	var w = h.equip.get("weapon")
	if w is Dictionary and not w.is_empty():
		return item_def(w)
	return {"name": "Кулаки", "type": "weapon", "dmg": "1d1", "ability": "СИЛ"}


static func attack_info(h: Dictionary) -> Dictionary:
	var w := weapon(h)
	var a := str(w.get("ability", "СИЛ"))
	var m := amod(h, "СИЛ")
	if a == "ЛОВ" or w.get("ranged", false):
		m = amod(h, "ЛОВ")
	elif a == "fin":
		m = maxi(amod(h, "СИЛ"), amod(h, "ЛОВ"))
	var atk := m + prof(int(h.level)) + int(w.get("attack", 0))
	if h.cls == "Следопыт" and w.get("ranged", false):
		atk += 2
	var dmg_bonus := m + int(w.get("damage", 0)) + talent_sum(h, "dmg_weapon")
	if w.get("ranged", false):
		atk += talent_sum(h, "atk_ranged")
		dmg_bonus += talent_sum(h, "dmg_ranged")
	elif w.get("two", false):
		dmg_bonus += talent_sum(h, "dmg_two")
	else:
		dmg_bonus += talent_sum(h, "dmg_onehand")
	return {"name": str(w.name), "atk": atk, "dice": str(w.dmg), "bonus": dmg_bonus, "crit": 20 - talent_sum(h, "crit"),
		"ranged": bool(w.get("ranged", false)), "fin": a == "fin" or bool(w.get("ranged", false)), "dt": weapon_dt(w),
		"attacks": 2 if (int(h.level) >= 5 and h.cls in ["Воин", "Следопыт"]) else 1}


static func caster_mod(h: Dictionary) -> int:
	var c: Dictionary = CLASSES[h.cls]
	return amod(h, str(c.caster)) if c.has("caster") else 0


static func spell_attack(h: Dictionary) -> int:
	return prof(int(h.level)) + caster_mod(h) + talent_sum(h, "spell_atk")


static func spell_dc(h: Dictionary) -> int:
	return 8 + prof(int(h.level)) + caster_mod(h) + talent_sum(h, "spell_atk")


## Заклинания, доступные герою сейчас (по уровню ячеек).
static func known_spells(h: Dictionary) -> Array:
	var out := []
	var c: Dictionary = CLASSES[h.cls]
	var max_lvl: int = (h.slots_max as Array).size()
	for id in c.get("spells", []):
		if int(SPELLS[id].lvl) <= max_lvl:
			out.append(id)
	return out


## Можно ли сейчас прочитать заклинание: заговоры всегда, иначе нужна ячейка его уровня или выше.
static func slot_for(h: Dictionary, spell_id: String) -> int:
	var lvl := int(SPELLS[spell_id].lvl)
	if lvl == 0:
		return 0
	for i in range(lvl - 1, (h.slots as Array).size()):
		if int(h.slots[i]) > 0:
			return i + 1
	return -1


static func is_down(h: Dictionary) -> bool:
	return int(h.hp) <= 0


static func long_rest(h: Dictionary) -> void:
	h.hp = h.max_hp
	h.slots = (h.slots_max as Array).duplicate()
	h.hd_left = mini(int(h.level), int(h.hd_left) + maxi(1, int(h.level) / 2))
	h.second_wind = h.cls == "Воин"
	if h.cls == "Бард":
		h.inspire = maxi(1, amod(h, "ХАР")) + talent_sum(h, "inspire")
	h.relentless = bool(RACES.get(h.race, {}).get("relentless", false))
	h.death_s = 0
	h.death_f = 0
	h.stable = false
	h.dead = false
	h.temp_ac = 0
	h.conds = {}


## Короткий отдых: тратит кости хитов, пока не вылечится. Возвращает вылеченное.
static func short_rest(h: Dictionary) -> int:
	var healed := 0
	var hd := int(CLASSES[h.cls].hd)
	while int(h.hd_left) > 0 and int(h.hp) < int(h.max_hp):
		var v := maxi(1, randi_range(1, hd) + amod(h, "ТЕЛ"))
		h.hp = mini(int(h.max_hp), int(h.hp) + v)
		h.hd_left = int(h.hd_left) - 1
		healed += v
	if h.cls == "Воин":
		h.second_wind = true
	return healed


## Числа из JSON приходят дробными; превращаем целые обратно в int.
static func intify(v):
	if v is float and v == floorf(v):
		return int(v)
	if v is Array:
		var out := []
		for x in v:
			out.append(intify(x))
		return out
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = intify(v[k])
		return d
	return v


## Каталог для подсказки нейронке.
static func catalog_text() -> String:
	var parts := []
	for id in ITEMS:
		if id != "misc":
			parts.append("%s=%s" % [id, ITEMS[id].name])
	return ", ".join(parts)


static func monsters_text() -> String:
	var parts := []
	for id in MONSTERS:
		var m: Dictionary = MONSTERS[id]
		parts.append("%s=%s (%d оп.)" % [id, m.name, m.xp])
	return ", ".join(parts)
