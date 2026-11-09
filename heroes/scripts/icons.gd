extends RefCounted
## Иконки интерфейса (game-icons.net, CC BY 3.0 — см. art/ATTRIBUTION.md).
## Все PNG белые на прозрачном фоне: красить через modulate / self_modulate.
## Использование: const Icons = preload("res://scripts/icons.gd")
##   Icons.tex("ui_coin"), Icons.for_class("Воин"), Icons.for_race("Эльф"),
##   Icons.for_monster("Гоблин 2"), Icons.for_item({"id": "longsword"})

const DIR := "res://art/icons/"

const CLASS_ICONS := {
	"Воин": "cls_warrior", "Маг": "cls_wizard", "Плут": "cls_rogue",
	"Жрец": "cls_cleric", "Следопыт": "cls_ranger", "Бард": "cls_bard",
}

const RACE_ICONS := {
	"Человек": "race_human", "Эльф": "race_elf", "Дварф": "race_dwarf", "Полурослик": "race_halfling",
	"Полуорк": "race_halforc", "Тифлинг": "race_tiefling", "Гном": "race_gnome",
}

const MONSTER_IDS := ["kobold", "giant_rat", "bandit", "cultist", "goblin", "wolf", "skeleton", "zombie",
	"giant_spider_small", "orc", "hobgoblin", "shadow", "bandit_captain", "ghoul", "dire_wolf",
	"giant_spider", "bugbear", "harpy", "ogre", "wight", "minotaur", "troll", "wyvern", "young_dragon"]

## Подстроки русских имён → id. Порядок важен: более длинные / специфичные раньше
## (Лютоволк до Волк, Хобгоблин до Гоблин, Главарь до Бандит, Гигантский паук до паук).
const MONSTER_NAMES := [
	["лютоволк", "dire_wolf"], ["волк", "wolf"],
	["хобгоблин", "hobgoblin"], ["шаман", "goblin"], ["гоблин", "goblin"],
	["главарь", "bandit_captain"], ["бандит", "bandit"], ["разбойник", "bandit"],
	["гигантский паук", "giant_spider"], ["паук", "giant_spider_small"],
	["крыса", "giant_rat"], ["кобольд", "kobold"], ["сектант", "cultist"], ["культист", "cultist"],
	["скелет", "skeleton"], ["зомби", "zombie"], ["полуорк", "orc"], ["орк", "orc"],
	["тень", "shadow"], ["гуль", "ghoul"], ["багбир", "bugbear"], ["гарпия", "harpy"],
	["огр", "ogre"], ["умертвие", "wight"], ["минотавр", "minotaur"], ["тролль", "troll"],
	["виверна", "wyvern"], ["дракон", "young_dragon"],
]

## id предмета из rules.gd ITEMS → иконка.
const ITEM_ICONS := {
	"dagger": "it_dagger", "shortsword": "it_sword", "rapier": "it_sword", "longsword": "it_sword",
	"greatsword": "it_sword", "battleaxe": "it_axe", "greataxe": "it_axe", "mace": "it_mace",
	"warhammer": "it_mace", "quarterstaff": "it_staff", "spear": "it_spear",
	"shortbow": "it_bow", "longbow": "it_bow", "crossbow": "it_bow",
	"padded": "it_armor_light", "leather": "it_armor_light", "studded": "it_armor_light",
	"chain_shirt": "it_armor_light", "scale_mail": "it_armor_heavy", "breastplate": "it_armor_heavy",
	"half_plate": "it_armor_heavy", "chain_mail": "it_armor_heavy", "splint": "it_armor_heavy",
	"plate": "it_armor_heavy", "shield": "it_shield",
	"traveler_clothes": "it_clothes", "fine_clothes": "it_clothes", "mage_robe": "it_clothes",
	"hunter_cloak": "it_cloak", "elven_cloak": "it_cloak", "cloak_protection": "it_cloak",
	"leather_cap": "it_head", "helmet": "it_head", "circlet_wisdom": "it_head",
	"ring_protection": "it_ring", "ring_luck": "it_ring",
	"amulet_health": "it_amulet", "gauntlets_power": "it_amulet", "amulet_ward": "it_amulet",
	"holy_symbol": "it_amulet",
	"potion_heal": "it_potion", "potion_greater": "it_potion", "potion_superior": "it_potion",
	"scroll_fire": "it_scroll", "scroll_missile": "it_scroll", "scroll_cure": "it_scroll",
	"thieves_tools": "it_lockpicks", "spellbook": "it_book", "lute": "it_lute", "rope": "it_rope",
	"torch": "it_torch", "rations": "it_food", "misc": "it_misc",
	"herb": "it_herb", "venom_sac": "it_venom", "ember_dust": "it_ember", "antidote": "it_antidote",
	"poison_vial": "it_poison", "fire_flask": "it_bomb",
}

## Иконка по полю type (для неизвестных id).
const TYPE_ICONS := {
	"weapon": "it_weapon", "armor": "it_armor_light", "shield": "it_shield", "clothes": "it_clothes",
	"head": "it_head", "ring": "it_ring", "amulet": "it_amulet", "potion": "it_potion",
	"scroll": "it_scroll", "misc": "it_misc", "reagent": "it_herb", "coat": "it_poison", "bomb": "it_bomb",
}

## Подстроки названия (для «misc»-вещей с произвольным именем).
const NAME_ICONS := [
	["ключ", "it_key"], ["сундук", "it_chest"], ["ларец", "it_chest"], ["золот", "it_gold"],
	["монет", "it_gold"], ["зелье", "it_potion"], ["эликсир", "it_potion"], ["свиток", "it_scroll"],
	["книг", "it_book"], ["карта", "ui_map"], ["кольцо", "it_ring"], ["амулет", "it_amulet"],
	["медальон", "it_amulet"], ["кулон", "it_amulet"], ["плащ", "it_cloak"], ["шлем", "it_head"],
	["факел", "it_torch"], ["верёвк", "it_rope"], ["веревк", "it_rope"], ["еда", "it_food"],
	["паёк", "it_food"], ["хлеб", "it_food"], ["мясо", "it_food"], ["лютн", "it_lute"],
	["инструмент", "it_tools"], ["отмычк", "it_lockpicks"], ["трав", "it_herb"], ["противояд", "it_antidote"], ["яд", "it_poison"], ["кинжал", "it_dagger"], ["нож", "it_dagger"],
	["меч", "it_sword"], ["сабл", "it_sword"], ["топор", "it_axe"], ["секир", "it_axe"],
	["булав", "it_mace"], ["молот", "it_mace"], ["посох", "it_staff"], ["копь", "it_spear"],
	["лук", "it_bow"], ["арбалет", "it_bow"], ["щит", "it_shield"], ["доспех", "it_armor_heavy"],
	["кольчуг", "it_armor_heavy"], ["одежд", "it_clothes"], ["мантия", "it_clothes"],
]

static var _cache := {}


## Текстура по ключу (имя файла без .png). Нет файла → it_misc (или null, если нет и его).
static func tex(key: String) -> Texture2D:
	if _cache.has(key):
		return _cache[key]
	var path := DIR + key + ".png"
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	if t == null and key != "it_misc":
		t = tex("it_misc")
	_cache[key] = t
	return t


static func has(key: String) -> bool:
	return ResourceLoader.exists(DIR + key + ".png")


static func for_class(cls: String) -> Texture2D:
	return tex(CLASS_ICONS.get(cls.strip_edges(), "ui_hero"))


static func for_race(race: String) -> Texture2D:
	return tex(RACE_ICONS.get(race.strip_edges(), "race_human"))


## id монстра («goblin») или русское имя («Гоблин 2», «Гоблин-разбойник»).
static func monster_key(id_or_name: String) -> String:
	var s := id_or_name.strip_edges()
	if s in MONSTER_IDS:
		return "mon_" + s
	var low := s.to_lower()
	for pair in MONSTER_NAMES:
		if low.contains(pair[0]):
			return "mon_" + pair[1]
	return "monster_generic"


static func for_monster(id_or_name: String) -> Texture2D:
	return tex(monster_key(id_or_name))


## Ключ иконки для предмета вида {"id": "longsword", "name": ..., "type": ...}.
static func item_key(item: Dictionary) -> String:
	var id := str(item.get("id", "misc"))
	if ITEM_ICONS.has(id) and id != "misc":
		return ITEM_ICONS[id]
	var low := str(item.get("name", "")).to_lower()
	if low != "":
		for pair in NAME_ICONS:
			if low.contains(pair[0]):
				return pair[1]
	var t := str(item.get("type", ""))
	if TYPE_ICONS.has(t):
		return TYPE_ICONS[t]
	return "it_misc"


static func for_item(item: Dictionary) -> Texture2D:
	return tex(item_key(item))
