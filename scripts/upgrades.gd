extends RefCounted
class_name Upgrades
## Магазин улучшений конторы и ранги оператора.
## Уровни улучшений хранятся в сохранении: {"id": уровень}.

const LIST := [
	{"id": "script", "name": "Методичка продаж", "desc": "Клиенты начинают разговор с доверием выше на 6 за уровень.", "prices": [6000, 18000], "rank": 0},
	{"id": "coffee", "name": "Кофемашина", "desc": "+1 звонок в смене за уровень: больше шансов закрыть план.", "prices": [9000, 25000], "rank": 0},
	{"id": "spoof", "name": "Подменный номер банка", "desc": "Шанс получить карту или перевод выше на 8% за уровень.", "prices": [12000, 32000], "rank": 1},
	{"id": "lawyer", "name": "Свой адвокат", "desc": "Жара растёт на 25% медленнее за уровень.", "prices": [15000, 40000], "rank": 1},
	{"id": "base", "name": "Слитая база клиентов", "desc": "Перед звонком видно, сколько у клиента денег и на что он ведётся.", "prices": [25000], "rank": 2},
	{"id": "acting", "name": "Курсы актёрского мастерства", "desc": "Ошибки в разговоре стоят на треть меньше доверия.", "prices": [35000], "rank": 2},
	{"id": "office", "name": "Офис в бизнес-центре", "desc": "Звонят клиенты побогаче: бюджет выше на 30%.", "prices": [60000], "rank": 3},
]

## Ранги по всем деньгам, заработанным за игру. mult — во сколько раз богаче клиенты.
const RANKS := [
	{"name": "Стажёр", "earned": 0, "mult": 1.0},
	{"name": "Оператор", "earned": 30000, "mult": 1.2},
	{"name": "Старший оператор", "earned": 100000, "mult": 1.45},
	{"name": "Начальник смены", "earned": 250000, "mult": 1.75},
	{"name": "Директор конторы", "earned": 600000, "mult": 2.1},
]


static func rank_index(earned: int) -> int:
	var r := 0
	for i in RANKS.size():
		if earned >= RANKS[i]["earned"]:
			r = i
	return r


static func level(owned: Dictionary, id: String) -> int:
	return int(owned.get(id, 0))


static func find(id: String) -> Dictionary:
	for u in LIST:
		if u["id"] == id:
			return u
	return {}
