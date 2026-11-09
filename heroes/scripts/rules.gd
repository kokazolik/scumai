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

## Ячейки заклинаний полного заклинателя по уровням (1..10), уровни ячеек 1..5.
const SLOTS := [[2], [3], [4, 2], [4, 3], [4, 3, 2], [4, 3, 3], [4, 3, 3, 1], [4, 3, 3, 2], [4, 3, 3, 3, 1], [4, 3, 3, 3, 2]]
## Полузаклинатель (Паладин): ячейки со 2 уровня.
const HALF_SLOTS := [[], [2], [3], [3], [4, 2], [4, 2], [4, 3], [4, 3], [4, 3, 2], [4, 3, 2]]
## Магия договора (Колдун): мало ячеек, все одного уровня, возвращаются на коротком отдыхе.
const PACT_SLOTS := [[1], [2], [0, 2], [0, 2], [0, 0, 2], [0, 0, 2], [0, 0, 0, 2], [0, 0, 0, 2], [0, 0, 0, 0, 2], [0, 0, 0, 0, 2]]

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
		"spells": ["fire_bolt", "ray_of_frost", "shocking_grasp", "magic_missile", "burning_hands", "sleep", "scorching_ray", "fireball", "lightning_bolt", "ice_storm", "cone_of_cold"],
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
		"spells": ["sacred_flame", "cure_wounds", "healing_word", "guiding_bolt", "inflict_wounds", "bless", "shield_of_faith", "spiritual_weapon", "hold_person", "mass_healing_word", "guardian_faith", "flame_strike", "mass_cure_wounds"],
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
		"spells": ["vicious_mockery", "healing_word", "thunderwave", "sleep", "shatter", "hold_person", "confusion", "mass_cure_wounds"],
		"start": [["rapier", true], ["leather", true], ["fine_clothes", true], ["lute", false]],
		"features": "Вдохновение барда (союзник добавляет 1к6 к броску), заклинания на Харизме",
		"desc": "Песни, обаяние и вдохновение"},
	"Варвар": {"armor": ["лёгкий", "средний", "shield"], "hd": 12, "saves": ["СИЛ", "ТЕЛ"], "main": "СИЛ",
		"scores": {"СИЛ": 15, "ТЕЛ": 14, "ЛОВ": 13, "МДР": 12, "ХАР": 10, "ИНТ": 8},
		"skills": ["Атлетика", "Выживание", "Запугивание"],
		"start": [["greataxe", true], ["traveler_clothes", true], ["spear", false], ["potion_heal", false]],
		"features": "Ярость (бонусное действие: +2 урона вблизи и вдвое меньше урона по тебе), защита без доспехов 10+ЛОВ+ТЕЛ, Дополнительная атака с 5 уровня",
		"desc": "Ярость, секира и железная шкура"},
	"Паладин": {"armor": ["лёгкий", "средний", "тяжёлый", "shield"], "hd": 10, "saves": ["МДР", "ХАР"], "main": "СИЛ", "caster": "ХАР", "half": true,
		"scores": {"СИЛ": 15, "ХАР": 14, "ТЕЛ": 13, "МДР": 12, "ЛОВ": 10, "ИНТ": 8},
		"skills": ["Атлетика", "Убеждение", "Религия"],
		"spells": ["cure_wounds", "bless", "shield_of_faith", "hold_person", "branding_smite", "crusaders_mantle"],
		"start": [["longsword", true], ["chain_mail", true], ["shield", true], ["holy_symbol", true], ["potion_heal", false]],
		"features": "Наложение рук (запас лечения 5×уровень), Божественная кара со 2 уровня (тратит ячейку: +2к8 излучением при ударе), Дополнительная атака с 5 уровня",
		"desc": "Клятва, кара и щит для друга"},
	"Колдун": {"armor": ["лёгкий"], "hd": 8, "saves": ["МДР", "ХАР"], "main": "ХАР", "caster": "ХАР", "pact": true,
		"scores": {"ХАР": 15, "ТЕЛ": 14, "ЛОВ": 13, "МДР": 12, "ИНТ": 10, "СИЛ": 8},
		"skills": ["Магия", "Обман", "Запугивание"],
		"spells": ["eldritch_blast", "hex", "burning_hands", "hold_person", "scorching_ray", "fireball", "blight", "banishing_flame"],
		"start": [["dagger", true], ["leather", true], ["traveler_clothes", true], ["spellbook", false], ["potion_heal", false]],
		"features": "Мистический заряд, Порча (+1к6 некротикой по проклятому), мало ячеек договора — но они возвращаются на привале",
		"desc": "Договор с тёмной силой"},
}

## Подклассы: выбор на 3 уровне. Эффекты складываются вместе с талантами (talent_sum), особые — в game.gd.
const SUBCLASSES := {
	"battle_master": {"cls": "Воин", "name": "Мастер боя", "desc": "Ответный выпад (реакция) и подсечка: первый удар за ход +1к8 и сбивает с ног"},
	"champ": {"cls": "Воин", "name": "Чемпион", "desc": "Крит на 19–20 и +1 хит за уровень", "crit": 1, "hp_lvl": 1},
	"evocation": {"cls": "Маг", "name": "Школа воплощения", "desc": "+3 урона атакующими заклинаниями", "spell_dmg": 3},
	"abjuration": {"cls": "Маг", "name": "Школа ограждения", "desc": "+1 КД и +2 ко всем спасброскам", "ac": 1, "save_all": 2},
	"thief": {"cls": "Плут", "name": "Вор", "desc": "Быстрые руки: предметы и броски — бонусным действием; +2 Ловкость рук", "skills": {"Ловкость рук": 2}},
	"assassin_sub": {"cls": "Плут", "name": "Ассасин", "desc": "В первом раунде боя — преимущество, и любое попадание критическое"},
	"life_domain": {"cls": "Жрец", "name": "Домен жизни", "desc": "Лечение сильнее на 4, +1 КД в доспехе", "heal": 4, "ac_armor": 1},
	"war_domain": {"cls": "Жрец", "name": "Домен войны", "desc": "+2 урона оружием и боевой жрец: удар бонусным действием (МДР раз за отдых)", "dmg_weapon": 2},
	"hunter_sub": {"cls": "Следопыт", "name": "Охотник", "desc": "Убийца великанов: +1к8 по раненому врагу раз за ход"},
	"beast_master": {"cls": "Следопыт", "name": "Повелитель зверей", "desc": "Верный волк сражается рядом и растёт вместе с тобой"},
	"lore_college": {"cls": "Бард", "name": "Коллегия знаний", "desc": "+2 ко всем навыкам и +1 вдохновение на отдых", "skill_all": 2, "inspire": 1},
	"valor_college": {"cls": "Бард", "name": "Коллегия доблести", "desc": "+1 КД, +2 урона оружием, средние доспехи и щит", "ac": 1, "dmg_weapon": 2},
	"berserker": {"cls": "Варвар", "name": "Берсерк", "desc": "Бешенство: в ярости — лишний удар бонусным действием"},
	"bear_totem": {"cls": "Варвар", "name": "Тотем медведя", "desc": "+1 ярость за отдых, +2 хита за уровень, в ярости — +1 КД", "hp_lvl": 2},
	"devotion": {"cls": "Паладин", "name": "Клятва преданности", "desc": "+1 ко всем спасброскам и лечение сильнее на 3", "save_all": 1, "heal": 3},
	"vengeance": {"cls": "Паладин", "name": "Клятва мести", "desc": "+1 к попаданию и +2 урона оружием", "atk_weapon": 1, "dmg_weapon": 2},
	"fiend": {"cls": "Колдун", "name": "Покровитель — Исчадие", "desc": "Тёмное благословение: добил врага — лечишься на ХАР+уровень"},
	"blade_pact": {"cls": "Колдун", "name": "Договор клинка", "desc": "Бьёшь оружием через Харизму, +1 к попаданию, вторая атака с 5 уровня", "atk_weapon": 1},
}

## Таланты: выбор при новом уровне (по мотивам SRD 5.1, своими словами).
## cls: для каких классов (пусто — для всех). Эффекты складываются в talent_sum().
const TALENTS := {
	"tough": {"name": "Крепкий", "desc": "+2 хита за каждый уровень, в том числе прошлые", "hp_lvl": 2},
	"alert": {"name": "Бдительный", "desc": "+5 к инициативе: в бою ходишь раньше", "init": 5},
	"resilient": {"name": "Стойкий", "desc": "+1 ко всем спасброскам", "save_all": 1},
	"keen": {"name": "Зоркий", "desc": "+3 к Восприятию и Проницательности", "skills": {"Восприятие": 3, "Проницательность": 3}},
	"defense": {"name": "Стиль «Оборона»", "desc": "+1 КД, пока на тебе доспех", "ac_armor": 1, "cls": ["Воин", "Следопыт", "Жрец", "Паладин", "Варвар"]},
	"dueling": {"name": "Стиль «Дуэль»", "desc": "+2 урона одноручным оружием ближнего боя", "dmg_onehand": 2, "cls": ["Воин", "Следопыт", "Плут", "Паладин"]},
	"great_weapon": {"name": "Мощный замах", "desc": "+3 урона двуручным оружием", "dmg_two": 3, "cls": ["Воин", "Варвар", "Паладин"]},
	"champion": {"name": "Чемпион", "desc": "Критическое попадание оружием на 19-20", "crit": 1, "cls": ["Воин", "Следопыт", "Варвар"]},
	"marksman": {"name": "Меткий стрелок", "desc": "+1 к попаданию и +2 урона дальнобойным оружием", "atk_ranged": 1, "dmg_ranged": 2, "cls": ["Следопыт", "Плут", "Воин"]},
	"hunter": {"name": "Метка охотника", "desc": "+2 урона любым оружием", "dmg_weapon": 2, "cls": ["Следопыт"]},
	"assassin": {"name": "Убийца", "desc": "Скрытая атака сильнее на 1к6", "sneak_dice": 1, "cls": ["Плут"]},
	"expertise": {"name": "Экспертиза", "desc": "+3 к Скрытности, Ловкости рук и Обману", "skills": {"Скрытность": 3, "Ловкость рук": 3, "Обман": 3}, "cls": ["Плут", "Бард"]},
	"evasion": {"name": "Увёртливость", "desc": "+1 КД и +1 ко всем спасброскам", "ac": 1, "save_all": 1, "cls": ["Плут"]},
	"life": {"name": "Домен жизни", "desc": "Лечение заклинаниями и зельями сильнее на 3", "heal": 3, "cls": ["Жрец", "Бард", "Паладин"]},
	"divine_strike": {"name": "Божественный удар", "desc": "+3 урона оружием (священная сила)", "dmg_weapon": 3, "cls": ["Жрец"]},
	"war_caster": {"name": "Боевой маг", "desc": "+1 к атаке заклинаниями и к их Сложности", "spell_atk": 1, "cls": ["Маг", "Жрец", "Бард", "Колдун", "Паладин"]},
	"evoker": {"name": "Школа воплощения", "desc": "+2 урона атакующими заклинаниями", "spell_dmg": 2, "cls": ["Маг"]},
	"arcane_ward": {"name": "Магическая защита", "desc": "+2 КД (невидимый щит)", "ac": 2, "cls": ["Маг", "Колдун"]},
	"more_inspire": {"name": "Песнь отваги", "desc": "+1 вдохновение барда на каждый отдых", "inspire": 1, "cls": ["Бард"]},
	"agonizing": {"name": "Тёмный дар", "desc": "+2 урона атакующими заклинаниями", "spell_dmg": 2, "cls": ["Колдун"]},
	"devil_sight": {"name": "Дьявольское зрение", "desc": "+3 к Восприятию и Запугиванию", "skills": {"Восприятие": 3, "Запугивание": 3}, "cls": ["Колдун", "Варвар"]},
	"thick_hide": {"name": "Толстая шкура", "desc": "+1 КД и +1 хит за уровень", "ac": 1, "hp_lvl": 1, "cls": ["Варвар"]},
	"aura_courage": {"name": "Аура отваги", "desc": "+2 ко всем спасброскам", "save_all": 2, "cls": ["Паладин"]},
	"lore": {"name": "Знаток", "desc": "+1 ко всем навыкам", "skill_all": 1, "cls": ["Бард"]},
}


static func talent_sum(h: Dictionary, key: String) -> int:
	var t := 0
	var sd: Dictionary = SUBCLASSES.get(str(h.get("sub", "")), {})
	if sd.has(key) and not (sd[key] is Dictionary):
		t += int(sd[key])
	for id in h.get("talents", []):
		var d: Dictionary = TALENTS.get(str(id), {})
		if d.has(key) and not (d[key] is Dictionary):
			t += int(d[key])
	return t


static func talent_skill(h: Dictionary, skill: String) -> int:
	var t := talent_sum(h, "skill_all")
	t += int(SUBCLASSES.get(str(h.get("sub", "")), {}).get("skills", {}).get(skill, 0))
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
static func make_choice(h: Dictionary, at := -1) -> Dictionary:
	var lv := int(h.level) if at < 0 else at
	if lv == 3 and str(h.get("sub", "")) == "":
		var subs := []
		for id in SUBCLASSES:
			if SUBCLASSES[id].cls == h.cls:
				subs.append(id)
		if subs.size() > 0:
			return {"level": lv, "kind": "sub", "options": subs}
	if lv in [4, 8]:
		var opts := []
		for a in AB:
			if int(h.scores[a]) < 20:
				opts.append(a)
		return {"level": lv, "kind": "asi", "options": opts}
	var pool := []
	var queued := []
	for q in h.get("choices", []):
		if str(q.get("kind", "")) == "talent":
			queued += q.options
	for id in TALENTS:
		var d: Dictionary = TALENTS[id]
		if id in h.get("talents", []) or id in queued:
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
	if c.kind == "sub":
		h.sub = pick
		var sd: Dictionary = SUBCLASSES[pick]
		if int(sd.get("hp_lvl", 0)) > 0:
			var addh := int(sd.hp_lvl) * int(h.level)
			h.max_hp = int(h.max_hp) + addh
			h.hp = int(h.hp) + addh
		if int(sd.get("inspire", 0)) > 0:
			h.inspire = int(h.get("inspire", 0)) + int(sd.inspire)
		if pick == "valor_college":
			h.extra_armor = ["средний", "shield"]
		_class_res(h)
		return "%s выбирает путь: «%s» — %s." % [h.name, sd.name, sd.desc]
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
## Базовые предметы игры. Полный список (всё оружие, доспехи и магические вещи SRD 5.1) — в ITEMS после загрузки data/items.json.
const ITEMS_BASE := {
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
	# уникальные магические: extra — добавочный урон при попадании, drain — лечит владельца
	"flame_tongue": {"name": "Язык пламени", "type": "weapon", "dt": "рубящий", "dmg": "1d8", "ability": "СИЛ", "extra": {"dice": "2d6", "dt": "огонь"}, "magic": true, "price": 1200, "desc": "клинок вспыхивает: +2к6 огнём"},
	"frost_brand": {"name": "Морозный клинок", "type": "weapon", "dt": "рубящий", "dmg": "2d6", "ability": "СИЛ", "two": true, "extra": {"dice": "1d6", "dt": "холод"}, "save": 1, "magic": true, "price": 1500, "desc": "+1к6 холодом, иней бережёт: +1 к спасброскам"},
	"vampire_blade": {"name": "Кровопийца", "type": "weapon", "dt": "колющий", "dmg": "1d8", "ability": "fin", "drain": "1d6", "magic": true, "price": 1100, "desc": "пьёт кровь: +1к6 некротикой и лечит тебя на столько же"},
	"storm_bow": {"name": "Лук бури", "type": "weapon", "dt": "колющий", "dmg": "1d8", "ability": "ЛОВ", "ranged": true, "two": true, "attack": 1, "extra": {"dice": "1d6", "dt": "молния"}, "magic": true, "price": 1300, "desc": "стрелы с треском молний: +1к6"},
	"thunder_hammer": {"name": "Громовой молот", "type": "weapon", "dt": "дробящий", "dmg": "1d10", "ability": "СИЛ", "extra": {"dice": "1d8", "dt": "звук"}, "stun": true, "magic": true, "price": 1400, "desc": "+1к8 громом, на крите оглушает"},
	"sun_mace": {"name": "Солнечная булава", "type": "weapon", "dt": "дробящий", "dmg": "1d6", "ability": "СИЛ", "attack": 1, "damage": 1, "extra": {"dice": "1d8", "dt": "излучение", "undead": true}, "magic": true, "price": 1000, "desc": "+1, по нежити +1к8 излучением"},

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
	"held": {"name": "Скован", "icon": "cond_held", "desc": "не может действовать; удары вблизи — критические; каждый ход пытается вырваться"},
	"wet": {"name": "Мокрый", "icon": "cond_wet", "desc": "огонь ранит вполовину, холод и молния — вдвое"},
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
	if dc.has("blinded") or dc.has("stunned") or dc.has("held") or (dc.has("prone") and melee):
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
	"shocking_grasp": {"dt": "молния", "col": "9fe8ff", "name": "Электрошок", "lvl": 0, "kind": "attack", "dmg": "1d8", "desc": "разряд молнии, 1к8; по воде — бьёт током всех впереди"},
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
	"shield_of_faith": {"bonus": true, "col": "ffe08a", "name": "Щит веры", "lvl": 1, "kind": "buff", "ac": 2, "conc": true, "desc": "+2 КД союзнику, пока держишь концентрацию"},
	"bless": {"col": "ffe08a", "name": "Благословение", "lvl": 1, "kind": "bless", "conc": true, "desc": "все союзники +1к4 к атакам и спасброскам, пока держишь концентрацию"},
	"hold_person": {"col": "c9b8ff", "name": "Удержание", "lvl": 2, "kind": "hold", "save": "МДР", "conc": true, "desc": "сковывает врага: удары вблизи по нему — критические"},
	"scorching_ray": {"dt": "огонь", "col": "ff7a3d", "name": "Палящий луч", "lvl": 2, "kind": "attack", "dmg": "2d6", "rays": 3, "desc": "три луча по 2к6"},
	"shatter": {"dt": "звук", "col": "8fb4ff", "name": "Дребезги", "lvl": 2, "kind": "save", "save": "ТЕЛ", "dmg": "3d8", "aoe": true, "desc": "звон по всем, 3к8"},
	"spiritual_weapon": {"bonus": true, "dt": "силовой", "col": "ffe08a", "name": "Духовное оружие", "lvl": 2, "kind": "attack", "dmg": "2d8", "desc": "призрачный молот, 2к8"},
	"mass_healing_word": {"bonus": true, "col": "6fe3a0", "name": "Лечащее слово для всех", "lvl": 3, "kind": "heal", "dmg": "1d4", "all": true, "desc": "лечит всех союзников"},
	"fireball": {"dt": "огонь", "col": "ff5a2a", "name": "Огненный шар", "lvl": 3, "kind": "save", "save": "ЛОВ", "dmg": "8d6", "aoe": true, "desc": "взрыв по всем врагам, 8к6"},
	"eldritch_blast": {"dt": "силовой", "col": "c86bff", "name": "Мистический заряд", "lvl": 0, "kind": "attack", "dmg": "1d10", "add_mod": true, "desc": "луч тёмной силы, 1к10 + ХАР; с 5 уровня — два луча"},
	"hex": {"bonus": true, "col": "a35bff", "name": "Порча", "lvl": 1, "kind": "hex", "conc": true, "desc": "проклятие на врага: твои попадания по нему +1к6 некротикой"},
	"branding_smite": {"bonus": true, "col": "ffe08a", "name": "Клеймящая кара", "lvl": 2, "kind": "smite_buff", "dmg": "2d6", "desc": "следующий удар оружием +2к6 излучением и подсвечивает врага (он не спрячется)"},
	"crusaders_mantle": {"col": "ffd75e", "name": "Мантия крестоносца", "lvl": 3, "kind": "mantle", "conc": true, "desc": "удары оружием всех союзников +1к4 излучением, пока держишь концентрацию"},
	"blight": {"dt": "некротический", "col": "8fae5a", "name": "Усыхание", "lvl": 4, "kind": "save", "save": "ТЕЛ", "dmg": "8d8", "no_undead": true, "desc": "высасывает жизнь из врага, 8к8 (нежить не берёт)"},
	"banishing_flame": {"dt": "огонь", "col": "ff5a2a", "name": "Адское пламя", "lvl": 5, "kind": "save", "save": "ЛОВ", "dmg": "10d6", "aoe": true, "surf": "fire", "desc": "пламя преисподней по всем врагам, 10к6, земля горит"},
	"ice_storm": {"dt": "холод", "col": "a8e4ff", "name": "Ледяная буря", "lvl": 4, "kind": "save", "save": "ЛОВ", "dmg": "6d8", "aoe": true, "surf": "ice", "desc": "град по всем врагам, 6к8, земля во льду"},
	"cone_of_cold": {"dt": "холод", "col": "7fd4ff", "name": "Конус холода", "lvl": 5, "kind": "save", "save": "ТЕЛ", "dmg": "8d8", "aoe": true, "desc": "волна мороза по всем, 8к8"},
	"confusion": {"dt": "психический", "col": "ff8fd0", "name": "Смятение", "lvl": 4, "kind": "save", "save": "МДР", "dmg": "3d8", "aoe": true, "cond": "stunned", "desc": "враги теряются: 3к8 и пропуск хода"},
	"guardian_faith": {"dt": "излучение", "col": "ffd75e", "name": "Страж веры", "lvl": 4, "kind": "save", "save": "ЛОВ", "dmg": "6d8", "desc": "призрачный страж бьёт врага, 6к8"},
	"flame_strike": {"dt": "огонь", "col": "ffb35e", "name": "Небесный огонь", "lvl": 5, "kind": "save", "save": "ЛОВ", "dmg": "8d6", "aoe": true, "desc": "столб огня и света по всем врагам, 8к6"},
	"lightning_bolt": {"dt": "молния", "col": "9fe8ff", "name": "Молния", "lvl": 3, "kind": "save", "save": "ЛОВ", "dmg": "8d6", "aoe": true, "desc": "разряд по всем врагам в линию, 8к6"},
	"inflict_wounds": {"dt": "некротический", "col": "8fae5a", "name": "Нанесение ран", "lvl": 1, "kind": "attack", "dmg": "3d10", "desc": "касание смерти, 3к10"},
	"mass_cure_wounds": {"col": "6fe3a0", "name": "Массовое лечение ран", "lvl": 5, "kind": "heal", "dmg": "3d8", "all": true, "desc": "лечит всех союзников на 3к8 + мод."},
}

## Свои монстры и тактические добавки к официальным (tac, drop, boss). Остальной бестиарий — data/monsters.json (SRD 5.1).
## atk — бонус атаки, multi — атак за ход.
const MONSTERS_CUSTOM := {
	"kobold": {"name": "Кобольд", "tac": ["oil"], "bow": true, "ac": 12, "hp": 5, "atk": 4, "dmg": "1d4+2", "dex": 2, "xp": 25},
	"giant_rat": {"name": "Гигантская крыса", "ac": 12, "hp": 7, "atk": 4, "dmg": "1d4+2", "dex": 2, "xp": 25},
	"bandit": {"name": "Бандит", "tac": ["fire_arrow"], "bow": true, "ac": 12, "hp": 11, "atk": 3, "dmg": "1d6+1", "dex": 1, "xp": 25},
	"cultist": {"name": "Сектант", "tac": ["heal", "fire_arrow"], "bow": true, "ac": 12, "hp": 9, "atk": 3, "dmg": "1d6+1", "dex": 1, "xp": 25},
	"goblin": {"name": "Гоблин", "tac": ["fire_arrow"], "bow": true, "ac": 15, "hp": 7, "atk": 4, "dmg": "1d6+2", "dex": 2, "xp": 50},
	"wolf": {"name": "Волк", "on_hit": {"cond": "prone", "save": "СИЛ", "dc": 11, "rounds": 1}, "ac": 13, "hp": 11, "atk": 4, "dmg": "2d4+2", "dex": 2, "xp": 50},
	"skeleton": {"name": "Скелет", "vuln": ["дробящий"], "ac": 13, "hp": 13, "atk": 4, "dmg": "1d6+2", "dex": 2, "xp": 50, "undead": true, "saves": {"ТЕЛ": 2, "МДР": -1}},
	"zombie": {"name": "Зомби", "fort": true, "ac": 8, "hp": 22, "atk": 3, "dmg": "1d6+1", "dex": -2, "xp": 50, "undead": true, "saves": {"ТЕЛ": 3, "МДР": -2}},
	"giant_spider_small": {"name": "Пещерный паук", "tac": ["web"], "vuln": ["огонь"], "on_hit": {"cond": "poisoned", "save": "ТЕЛ", "dc": 11, "rounds": 3}, "drop": "venom_sac", "ac": 13, "hp": 12, "atk": 4, "dmg": "1d6+2", "dex": 3, "xp": 50},
	"goblin_shaman": {"name": "Гоблин-шаман", "tac": ["oil", "ignite", "heal"], "caster": true, "ac": 12, "hp": 12, "atk": 4, "dmg": "1d6+2", "dex": 2, "xp": 100},
	"orc": {"name": "Орк", "tac": ["shove"], "ac": 13, "hp": 15, "atk": 5, "dmg": "1d12+3", "dex": 1, "xp": 100},
	"hobgoblin": {"name": "Хобгоблин", "bow": true, "ac": 18, "hp": 11, "atk": 3, "dmg": "1d8+1", "dex": 1, "xp": 100},
	"shadow": {"name": "Тень", "res": ["рубящий", "колющий", "дробящий"], "vuln": ["излучение"], "on_hit": {"cond": "frightened", "save": "МДР", "dc": 10, "rounds": 2}, "ac": 12, "hp": 16, "atk": 4, "dmg": "2d6+2", "dex": 2, "xp": 100, "undead": true},
	"bandit_captain": {"name": "Главарь бандитов", "boss": true, "ac": 15, "hp": 65, "atk": 5, "dmg": "1d6+3", "multi": 2, "dex": 3, "xp": 450},
	"ghoul": {"name": "Гуль", "vuln": ["излучение"], "on_hit": {"cond": "stunned", "save": "ТЕЛ", "dc": 10, "rounds": 1}, "ac": 12, "hp": 22, "atk": 4, "dmg": "2d6+2", "dex": 2, "xp": 200, "undead": true},
	"dire_wolf": {"name": "Лютоволк", "on_hit": {"cond": "prone", "save": "СИЛ", "dc": 13, "rounds": 1}, "ac": 14, "hp": 37, "atk": 5, "dmg": "2d6+3", "dex": 2, "xp": 200},
	"giant_spider": {"name": "Гигантский паук", "tac": ["web"], "vuln": ["огонь"], "on_hit": {"cond": "poisoned", "save": "ТЕЛ", "dc": 12, "rounds": 3}, "drop": "venom_sac", "ac": 14, "hp": 26, "atk": 5, "dmg": "1d8+3", "dex": 3, "xp": 200},
	"bugbear": {"name": "Багбир", "tac": ["shove"], "ac": 16, "hp": 27, "atk": 4, "dmg": "2d8+2", "dex": 2, "xp": 200},
	"harpy": {"name": "Гарпия", "on_hit": {"cond": "frightened", "save": "МДР", "dc": 11, "rounds": 2}, "ac": 11, "hp": 38, "atk": 3, "dmg": "2d4+1", "multi": 2, "dex": 1, "xp": 200},
	"ogre": {"name": "Огр", "tac": ["shove"], "boss": true, "ac": 11, "hp": 59, "atk": 6, "dmg": "2d8+4", "dex": -1, "xp": 450, "saves": {"ТЕЛ": 3, "МДР": -2}},
	"wight": {"name": "Умертвие", "res": ["рубящий", "колющий", "дробящий"], "vuln": ["излучение"], "ac": 14, "hp": 45, "atk": 4, "dmg": "1d8+2", "multi": 2, "dex": 2, "xp": 700, "undead": true, "saves": {"ТЕЛ": 3}},
	"minotaur": {"name": "Минотавр", "tac": ["shove"], "boss": true, "ac": 14, "hp": 76, "atk": 6, "dmg": "2d12+4", "dex": 0, "xp": 700, "saves": {"ТЕЛ": 3}},
	"troll": {"name": "Тролль", "regen": 10, "vuln": ["огонь"], "ac": 15, "hp": 84, "atk": 7, "dmg": "2d6+4", "multi": 3, "dex": 1, "xp": 1800, "saves": {"ТЕЛ": 5, "МДР": -1}},
	"wyvern": {"name": "Виверна", "boss": true, "ac": 13, "hp": 110, "atk": 7, "dmg": "2d6+4", "multi": 2, "dex": 0, "xp": 1800},
	"young_dragon": {"name": "Молодой дракон", "res": ["огонь"], "boss": true, "on_hit": {"cond": "frightened", "save": "МДР", "dc": 13, "rounds": 2}, "ac": 18, "hp": 136, "atk": 9, "dmg": "2d10+5", "multi": 3, "dex": 1, "xp": 3900, "saves": {"ТЕЛ": 5, "МДР": 4, "ЛОВ": 4}},
}

## Типы урона. Враги бывают уязвимы (×2) или стойки (½) к некоторым.
const DT_GEN := {"рубящий": "рубящему", "колющий": "колющему", "дробящий": "дробящему", "огонь": "огню", "холод": "холоду",
	"излучение": "излучению", "психический": "психическому", "силовой": "силовому", "звук": "звуку", "яд": "яду", "молния": "молнии", "некротический": "некротике"}

## Предметы окружения в бою (как в тактических RPG: бочки, люстры, обрывы).
## kind: aoe — по всем врагам впереди, one — по выбранному врагу, edge — сталкивать с обрыва, high — возвышенность.
const ENV := {
	"barrel": {"name": "Бочка с маслом", "icon": "env_barrel", "kind": "aoe", "dmg": "3d6", "dt": "огонь", "save": "ЛОВ", "dc": 13, "surf": "fire", "desc": "поджечь: взрыв по врагам впереди, 3к6 огнём, земля горит"},
	"chandelier": {"name": "Люстра", "icon": "env_chandelier", "kind": "one", "dmg": "2d8", "dt": "дробящий", "save": "ЛОВ", "dc": 12, "cond": "prone", "desc": "обрушить на врага: 2к8 и сбивает с ног"},
	"brazier": {"name": "Жаровня", "icon": "env_brazier", "kind": "one", "dmg": "2d6", "dt": "огонь", "save": "ЛОВ", "dc": 12, "surf": "fire", "desc": "опрокинуть угли на врагов: 2к6 огнём, земля горит"},
	"rocks": {"name": "Шаткие камни", "icon": "env_rocks", "kind": "one", "dmg": "2d10", "dt": "дробящий", "save": "ЛОВ", "dc": 13, "desc": "обрушить камнепад: 2к10"},
	"oil": {"name": "Бочонок масла", "icon": "env_oil", "kind": "aoe", "dmg": "", "dt": "", "save": "ЛОВ", "dc": 12, "cond": "prone", "surf": "oil", "desc": "разлить под ноги врагам: скользко, а огонь подожжёт лужу"},
	"web": {"name": "Старая паутина", "icon": "env_web", "kind": "one", "dmg": "", "dt": "", "save": "СИЛ", "dc": 12, "cond": "stunned", "surf": "web", "desc": "обрушить на врагов: липнут, а огонь её сожжёт"},
	"water": {"name": "Бочка воды", "icon": "env_oil", "kind": "aoe", "dmg": "", "dt": "", "save": "ЛОВ", "dc": 0, "surf": "water", "desc": "окатить врагов: мокрые — холод и молния вдвое"},
	"cliff": {"name": "Обрыв", "icon": "env_cliff", "kind": "edge", "dmg": "3d6", "dt": "дробящий", "desc": "толкнуть врага вниз: 3к6 от падения", "keep": true},
	"high": {"name": "Возвышенность", "icon": "env_high", "kind": "high", "desc": "занять (тратит перемещение): +2 к стрельбе и заклинаниям-атакам", "keep": true},
}
const ENV_BY_PLACE := {
	"tavern": ["chandelier", "barrel", "brazier", "water"], "village": ["barrel", "high", "oil", "water"], "city": ["barrel", "chandelier", "high"],
	"forest": ["high", "rocks", "web"], "road": ["high", "rocks", "barrel"], "cave": ["rocks", "cliff", "web", "water"],
	"dungeon": ["brazier", "chandelier", "oil", "web"], "castle": ["chandelier", "brazier", "high"], "ruins": ["rocks", "high", "cliff"],
	"swamp": ["water", "web", "rocks"], "lake": ["water", "high", "rocks"], "port": ["barrel", "oil", "water"], "sea": ["water", "barrel", "oil"],
	"camp": ["brazier", "barrel", "oil"], "temple": ["brazier", "chandelier", "water"], "tower": ["brazier", "high", "chandelier"],
	"mountain": ["cliff", "rocks", "high"], "field": ["high", "rocks", "oil"],
}

## Поверхности под ногами врагов (как в BG3). Огонь поджигает масло и паутину, холод морозит воду, молния бьёт по ней током.
const SURFACES := {
	"oil": {"name": "Масло", "col": "8a7a3a", "desc": "скользко: можно упасть; огонь подожжёт"},
	"fire": {"name": "Огонь", "col": "ff7a3d", "desc": "горит: 1к6 огнём в начале хода"},
	"water": {"name": "Вода", "col": "5aa9ff", "desc": "мокрые: холод и молния вдвое, огонь вполовину"},
	"ice": {"name": "Лёд", "col": "bfe9ff", "desc": "скользко: легко упасть"},
	"web": {"name": "Паутина", "col": "c8c8c8", "desc": "липко: можно застрять на ход; огонь сожжёт"},
	"shock": {"name": "Вода под током", "col": "9fe8ff", "desc": "бьёт током: можно оцепенеть"},
}


## Весь бестиарий: 325 официальных монстров SRD 5.1 + свои. Грузится один раз.
static var MONSTERS := {}
const CUSTOM_OVERLAY := ["tac", "drop", "boss"]


static func _static_init() -> void:
	load_monsters()
	load_items()


static var ITEMS := {}
const RARITY := {"c": "обычный", "u": "необычный", "r": "редкий", "v": "очень редкий", "l": "легендарный"}


static func load_items() -> void:
	if not ITEMS.is_empty():
		return
	ITEMS = ITEMS_BASE.duplicate(true)
	var f := FileAccess.open("res://data/items.json", FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text()) if f != null else null
	if d is Dictionary:
		for id in d:
			if ITEMS.has(id):
				continue
			var it: Dictionary = d[id]
			if it.has("base"):
				var b: Dictionary = ITEMS.get(str(it.base), {}).duplicate(true)
				for k in ["desc", "name", "price"]:
					b.erase(k)
				for k in it:
					if k != "base":
						b[k] = it[k]
				it = b
			for k in ["price", "ac", "attack", "damage", "save", "charges", "hits", "dc", "spell_atk", "crit", "crit_bonus", "bow_dmg", "dex_max", "skill_all"]:
				if it.has(k):
					it[k] = int(it[k])
			ITEMS[id] = it
	# свиток на каждое заклинание
	var have := []
	for id in ITEMS:
		if str(ITEMS[id].type) == "scroll" and int(ITEMS[id].get("charges", 0)) == 0:
			have.append(str(ITEMS[id].get("spell", "")))
	for sp in SPELLS:
		if sp in have:
			continue
		var lv := int(SPELLS[sp].lvl)
		var sid := "scroll_" + str(sp)
		if not ITEMS.has(sid):
			ITEMS[sid] = {"name": "Свиток: " + str(SPELLS[sp].name), "type": "scroll", "spell": sp, "price": [25, 60, 150, 300, 600, 1200][clampi(lv, 0, 5)],
				"rar": ["c", "c", "u", "u", "r", "r"][clampi(lv, 0, 5)]}


static func load_monsters() -> void:
	if not MONSTERS.is_empty():
		return
	var f := FileAccess.open("res://data/monsters.json", FileAccess.READ)
	if f != null:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			MONSTERS = d
	for id in MONSTERS_CUSTOM:
		var cm: Dictionary = MONSTERS_CUSTOM[id]
		if MONSTERS.has(id):
			for k in CUSTOM_OVERLAY:
				if cm.has(k):
					MONSTERS[id][k] = cm[k]
		else:
			MONSTERS[id] = cm.duplicate(true)
	for id in MONSTERS:
		var m: Dictionary = MONSTERS[id]
		m.ac = int(m.get("ac", 12))
		m.hp = int(m.get("hp", 10))
		m.atk = int(m.get("atk", 3))
		m.xp = maxi(10, int(m.get("xp", 10)))
		m.dex = int(m.get("dex", 0))
		if not m.has("cr"):
			m.cr = cr_of_xp(int(m.xp))


const CR_XP := [[0, 10], [0.125, 25], [0.25, 50], [0.5, 100], [1, 200], [2, 450], [3, 700], [4, 1100], [5, 1800], [6, 2300], [7, 2900],
	[8, 3900], [9, 5000], [10, 5900], [11, 7200], [12, 8400], [13, 10000], [14, 11500], [15, 13000], [16, 15000], [17, 18000],
	[18, 20000], [19, 22000], [20, 25000], [21, 33000], [22, 41000], [23, 50000], [24, 62000], [30, 155000]]


static func cr_of_xp(xp: int) -> float:
	var best := 0.0
	for r in CR_XP:
		if xp >= int(r[1]):
			best = float(r[0])
	return best


static func cr_text(cr: float) -> String:
	if cr == 0.125:
		return "1/8"
	if cr == 0.25:
		return "1/4"
	if cr == 0.5:
		return "1/2"
	return str(int(cr))


## Поиск монстра по id, английскому или русскому имени (ведущий может написать как угодно).
static func find_monster(key: String) -> String:
	var k := key.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	if MONSTERS.has(k):
		return k
	var low := key.strip_edges().to_lower()
	if low == "":
		return ""
	for id in MONSTERS:
		var m: Dictionary = MONSTERS[id]
		if str(m.get("en", "")).to_lower() == low or str(m.name).to_lower() == low:
			return id
	return ""


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
			if str(d.get("heal", "")) != "":
				parts.append("лечит %s" % dice_ru(str(d.heal)))
			if d.has("cure"):
				parts.append("снимает отравление")
		"reagent":
			parts.append("ингредиент для алхимии")
		"coat":
			if str(d.get("dt", "яд")) == "яд":
				parts.append("яд на оружие: %d попадания +%s и отравление" % [int(d.hits), dice_ru(str(d.dice))])
			else:
				parts.append("натереть оружие: %d попаданий +%s" % [int(d.hits), dice_ru(str(d.dice))])
		"bomb":
			parts.append("бросить во врага: %s, спасбросок %s СЛ %d — половина" % [dice_ru(str(d.dmg)), d.save, int(d.dc)])
		"scroll":
			if int(d.get("charges", 0)) > 0:
				parts.append("заряды: %d/%d · %s" % [int(d.get("ch", d.charges)), int(d.charges), str(SPELLS.get(str(d.spell), {}).get("name", "?"))])
			else:
				parts.append("одно заклинание: " + str(SPELLS.get(str(d.spell), {}).get("name", "?")))
	if d.type not in ["armor", "shield"] and int(d.get("ac", 0)) > 0:
		parts.append("+%d КД" % int(d.ac))
	if int(d.get("attack", 0)) > 0 and d.type == "weapon":
		parts.append("+%d к атаке и урону" % int(d.attack))
	if int(d.get("save", 0)) > 0 and str(d.get("desc", "")) == "":
		parts.append("+%d к спасброскам" % int(d.save))
	for a in d.get("abil", {}):
		parts.append("%s +%d" % [a, int(d.abil[a])])
	for a in d.get("abil_set", {}):
		parts.append("%s = %d" % [a, int(d.abil_set[a])])
	if not d.get("res", []).is_empty():
		parts.append("сопротивление: " + ", ".join(d.res))
	if d.type != "scroll" and int(d.get("charges", 0)) > 0 and SPELLS.has(str(d.get("spell", ""))):
		parts.append("заряды «%s»: %d/%d" % [SPELLS[str(d.spell)].name, int(d.get("ch", d.charges)), int(d.charges)])
	if str(d.get("rar", "")) != "":
		parts.append(str(RARITY.get(str(d.rar), "")))
	if d.get("cursed", false):
		parts.append("☠ проклятый")
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


## Лут из сундука: золото и 1-3 предмета. tier 1..4 по уровню героев. Магия — по редкости (как в DMG): чем выше уровень, тем реже обычное.
static func by_rarity(r: String, types: Array = []) -> Array:
	var out := []
	for id in ITEMS:
		var d: Dictionary = ITEMS[id]
		if str(d.get("rar", "")) == r and (types.is_empty() or str(d.type) in types):
			out.append(id)
	return out


static func mundane(types: Array) -> Array:
	var out := []
	for id in ITEMS:
		var d: Dictionary = ITEMS[id]
		if str(d.type) in types and not d.get("magic", false) and str(d.get("rar", "")) == "" and id != "misc":
			out.append(id)
	return out


static func roll_magic(tier: int) -> Dictionary:
	var table: Array = {1: [["c", 50], ["u", 45], ["r", 5]], 2: [["c", 15], ["u", 55], ["r", 28], ["v", 2]],
		3: [["u", 30], ["r", 50], ["v", 18], ["l", 2]], 4: [["r", 40], ["v", 45], ["l", 15]]}[clampi(tier, 1, 4)]
	var x := randi_range(1, 100)
	var r := "u"
	for row in table:
		x -= int(row[1])
		if x <= 0:
			r = str(row[0])
			break
	var pool := by_rarity(r)
	if pool.is_empty():
		pool = by_rarity("u")
	return {"id": pool[randi() % pool.size()]}


static func roll_loot(tier: int) -> Dictionary:
	tier = clampi(tier, 1, 4)
	var gold := roll("%dd10" % (tier * 2)) * (5 if tier < 3 else 15)
	var items := []
	var n := randi_range(1, 2 + (1 if tier >= 2 else 0))
	var commons := ["potion_heal", "potion_heal", "rope", "torch", "rations", "herb", "herb", "ember_dust", "antidote", "thieves_tools", "fire_flask",
		"scroll_missile", "scroll_cure", "leather_cap", "helmet", "fine_clothes", "hunter_cloak"]
	var gear := mundane(["weapon", "armor", "shield"])
	for i in n:
		var r := randf()
		var it := {}
		if r < 0.1 + 0.1 * tier:
			it = roll_magic(tier)
		elif r < 0.25 + 0.1 * tier:
			var wa := mundane(["weapon", "armor", "shield"])
			var id: String = wa[randi() % wa.size()]
			it = {"id": id, "plus": clampi(randi_range(1, tier), 1, 3)}
		elif r < 0.55:
			it = {"id": gear[randi() % gear.size()]}
		else:
			it = {"id": commons[randi() % commons.size()]}
		items.append(it)
	return {"gold": gold, "items": items}


## Товары лавки по уровню: всё обычное оружие и доспехи SRD, зелья, свитки, а в больших городах — магия.
static func shop_stock(tier: int) -> Array:
	var ids := ["potion_heal", "potion_heal", "rope", "torch", "rations", "herb", "herb", "ember_dust", "antidote", "thieves_tools", "fire_flask",
		"scroll_missile", "scroll_cure", "helmet", "leather_cap", "fine_clothes", "hunter_cloak", "traveler_clothes"]
	var gear := mundane(["weapon", "armor", "shield"])
	gear.shuffle()
	ids += gear.slice(0, 8)
	if tier >= 2:
		ids += ["potion_greater", "scroll_fire"]
	var out := []
	ids.shuffle()
	for id in ids.slice(0, 12):
		if ITEMS.has(id):
			out.append({"id": id})
	var mag := by_rarity("c") + by_rarity("u") + (by_rarity("r") if tier >= 3 else [])
	mag.shuffle()
	for id in mag.slice(0, mini(tier, 3)):
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
	for k in ["rations", "rations", "torch"]:
		h.items.append({"id": k})
	h.max_hp = int(c.hd) + mod(int(scores["ТЕЛ"])) + int(r.get("hp_per_level", 0))
	h.hp = h.max_hp
	_update_slots(h)
	h.slots = h.slots_max.duplicate()
	_class_res(h)
	return h


## Классовые запасы на отдых: ярость, наложение рук, удары боевого жреца.
static func _class_res(h: Dictionary) -> void:
	var lv := int(h.level)
	if h.cls == "Варвар":
		h.rages = (2 if lv < 3 else (3 if lv < 6 else 4)) + (1 if str(h.get("sub", "")) == "bear_totem" else 0)
	if h.cls == "Паладин":
		h.lay = 5 * lv
	if str(h.get("sub", "")) == "war_domain":
		h.war_left = maxi(1, amod(h, "МДР"))


static func rages_max(h: Dictionary) -> int:
	var lv := int(h.level)
	return (2 if lv < 3 else (3 if lv < 6 else 4)) + (1 if str(h.get("sub", "")) == "bear_totem" else 0)


static func _update_slots(h: Dictionary) -> void:
	if not CLASSES[h.cls].has("caster"):
		h.slots_max = []
		return
	var table: Array = PACT_SLOTS if CLASSES[h.cls].get("pact", false) else (HALF_SLOTS if CLASSES[h.cls].get("half", false) else SLOTS)
	var mx: Array = table[clampi(int(h.level), 1, 10) - 1].duplicate()
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
		extra = ", выбери %s" % ("+2 к характеристике" if ch.kind == "asi" else ("свой путь (подкласс)" if ch.kind == "sub" else "новый талант"))
	var old_max := (h.slots_max as Array).duplicate()
	_update_slots(h)
	for i in h.slots_max.size():
		var before := int(old_max[i]) if i < old_max.size() else 0
		h.slots[i] = int(h.slots[i]) + int(h.slots_max[i]) - before
	if int(h.level) == 5 and (h.cls in EXTRA_ATTACK or str(h.get("sub", "")) in ["blade_pact", "valor_college"]):
		extra += ", вторая атака за ход"
	if int(h.level) == 2 and h.cls == "Паладин":
		extra += ", Божественная кара и первые заклинания"
	var lay_before := int(h.get("lay", 0))
	_class_res(h)
	if h.cls == "Паладин":
		h.lay = mini(5 * int(h.level), lay_before + 5)
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
	var setv := int(h.get("pot_abil", {}).get(a, 0))
	for d in equipped_defs(h):
		v += int(d.get("abil", {}).get(a, 0))
		setv = maxi(setv, int(d.get("abil_set", {}).get(a, 0)))
	return maxi(mini(v, 22), setv)


## Сопротивления героя: вещи и выпитые зелья. Урон этих типов — вдвое меньше.
static func hero_res(h: Dictionary) -> Array:
	var out: Array = h.get("res_tmp", []).duplicate()
	for d in equipped_defs(h):
		for t in d.get("res", []):
			if not t in out:
				out.append(t)
	return out


static func equip_sum(h: Dictionary, key: String) -> int:
	var v := 0
	for d in equipped_defs(h):
		v += int(d.get(key, 0))
	return v


static func amod(h: Dictionary, a: String) -> int:
	return mod(score(h, a))


static func ac(h: Dictionary) -> int:
	var dex := amod(h, "ЛОВ")
	var total := 10 + dex
	var armor = h.equip.get("armor")
	if h.cls == "Варвар" and not (armor is Dictionary and not armor.is_empty()):
		total += amod(h, "ТЕЛ")
	if h.get("raging", false) and str(h.get("sub", "")) == "bear_totem":
		total += 1
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
	return b + talent_skill(h, skill) + equip_sum(h, "skill_all")


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
	if str(h.get("sub", "")) == "blade_pact" and not w.get("ranged", false):
		m = maxi(m, amod(h, "ХАР"))
	var atk := m + prof(int(h.level)) + int(w.get("attack", 0)) + talent_sum(h, "atk_weapon")
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
	if h.get("raging", false) and not w.get("ranged", false):
		dmg_bonus += 2 if int(h.level) < 9 else 3
	if w.get("ranged", false):
		dmg_bonus += equip_sum(h, "bow_dmg")
	var crit := mini(20 - talent_sum(h, "crit"), int(w.get("crit", 20)))
	var n_att := 2 if (int(h.level) >= 5 and (h.cls in EXTRA_ATTACK or str(h.get("sub", "")) in ["blade_pact", "valor_college"])) else 1
	if h.get("haste", false):
		n_att += 1
	return {"name": str(w.name), "atk": atk, "dice": str(w.dmg), "bonus": dmg_bonus, "crit": crit, "crit_bonus": int(w.get("crit_bonus", 0)),
		"ranged": bool(w.get("ranged", false)), "fin": a == "fin" or bool(w.get("ranged", false)), "dt": weapon_dt(w),
		"extra": w.get("extra", {}), "drain": str(w.get("drain", "")), "stun": bool(w.get("stun", false)),
		"attacks": n_att}


const EXTRA_ATTACK := ["Воин", "Следопыт", "Варвар", "Паладин"]


static func caster_mod(h: Dictionary) -> int:
	var c: Dictionary = CLASSES[h.cls]
	return amod(h, str(c.caster)) if c.has("caster") else 0


static func spell_attack(h: Dictionary) -> int:
	return prof(int(h.level)) + caster_mod(h) + talent_sum(h, "spell_atk") + equip_sum(h, "spell_atk")


static func spell_dc(h: Dictionary) -> int:
	return 8 + prof(int(h.level)) + caster_mod(h) + talent_sum(h, "spell_atk") + equip_sum(h, "spell_atk")


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
	_class_res(h)
	h.erase("raging")
	h.relentless = bool(RACES.get(h.race, {}).get("relentless", false))
	h.death_s = 0
	h.death_f = 0
	h.stable = false
	h.dead = false
	h.temp_ac = 0
	h.conds = {}
	clear_potions(h)


## Действие зелий (сопротивления, сила великана, ускорение) заканчивается после боя или отдыха.
static func clear_potions(h: Dictionary) -> void:
	for k in ["res_tmp", "pot_abil", "haste", "growth"]:
		h.erase(k)


## Короткий отдых как в BG3: половина максимума хитов и второе дыхание. Возвращает вылеченное.
static func short_rest(h: Dictionary) -> int:
	var before := int(h.hp)
	h.hp = mini(int(h.max_hp), int(h.hp) + ceili(int(h.max_hp) / 2.0))
	if h.cls == "Воин":
		h.second_wind = true
	if CLASSES[h.cls].get("pact", false):
		h.slots = (h.slots_max as Array).duplicate()
	if h.cls == "Варвар":
		h.rages = mini(rages_max(h), int(h.get("rages", 0)) + 1)
	return int(h.hp) - before


## Ночлег без еды (как в BG3 «частичный отдых»): половина хитов и половина ячеек.
static func partial_rest(h: Dictionary) -> void:
	h.hp = mini(int(h.max_hp), int(h.hp) + ceili(int(h.max_hp) / 2.0))
	for i in (h.slots_max as Array).size():
		h.slots[i] = mini(int(h.slots_max[i]), int(h.slots[i]) + ceili(int(h.slots_max[i]) / 2.0))
	h.death_s = 0
	h.death_f = 0
	h.stable = false
	h.dead = false
	h.temp_ac = 0
	h.conds = {}


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
static func catalog_text(tier := 2) -> String:
	var parts := []
	var magic := []
	var rars: Array = ["c", "u", "r", "v", "l"].slice(0, clampi(tier + 1, 2, 5))
	for id in ITEMS:
		if id == "misc" or str(id).begins_with("scroll_") and int(ITEMS[id].get("charges", 0)) == 0 and not id in ["scroll_fire", "scroll_missile", "scroll_cure"]:
			continue
		var d: Dictionary = ITEMS[id]
		if str(d.get("rar", "")) == "":
			parts.append("%s=%s" % [id, d.name])
		elif str(d.rar) in rars:
			magic.append("%s=%s" % [id, d.name])
	magic.shuffle()
	return ", ".join(parts) + ". Магические (официальные D&D, выдавай редко, по сюжету): " + ", ".join(magic.slice(0, 45))


static func monsters_text(lv := 0, limit := 170) -> String:
	var lo := 0.0
	var hi := 30.0
	if lv > 0:
		hi = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 20.0][clampi(lv, 1, 20) - 1]
		lo = 0.125 if lv <= 2 else (0.25 if lv <= 4 else float(lv) / 4.0)
	var parts := []
	var ids := MONSTERS.keys()
	ids.sort_custom(func(a, b): return float(MONSTERS[a].cr) < float(MONSTERS[b].cr))
	for id in ids:
		var m: Dictionary = MONSTERS[id]
		var cr := float(m.cr)
		if cr < lo or cr > hi:
			continue
		var tags := []
		for t in [["aoe", "дыхание/волна"], ["caster", "заклинатель"], ["leg", "легендарный"], ["fear", "ужас"], ["regen", "регенерация"],
				["pack", "стая"], ["healer", "лекарь"], ["fly", "летает"], ["undead", "нежить"]]:
			if m.has(t[0]) and not (m[t[0]] is bool and not m[t[0]]):
				tags.append(t[1])
		parts.append("%s=%s (%s, ПО %s%s)" % [id, m.name, str(m.get("type", "")), cr_text(cr), "" if tags.is_empty() else ", " + ", ".join(tags)])
		if parts.size() >= limit:
			break
	return ", ".join(parts)
