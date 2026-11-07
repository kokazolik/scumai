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


## Схемы конторы, от дешёвых к прибыльным. Каждая купленная схема приводит своих клиентов
## (бюджет × mult, жара × heat), а все купленные схемы вместе складываются:
## +5% к каждой сделке за каждую схему и пассивный доход в конце смены.
const SCHEMES := [
	{"id": "repair", "name": "Ремонт на дому", "price": 0, "rank": 0, "mult": 1.0, "heat": 1.0, "passive": 0,
		"desc": "Стартовая схема: объявления «Ремонт любой техники».",
		"premise": "объявление о ремонте техники на дому или похожая бытовая услуга"},
	{"id": "prize", "name": "Призы и розыгрыши", "price": 15000, "rank": 0, "mult": 1.3, "heat": 1.0, "passive": 1500,
		"desc": "«Вы выиграли!» Клиенты звонят забрать приз.",
		"premise": "сообщение, что он выиграл приз в розыгрыше, и теперь звонит его забрать"},
	{"id": "courses", "name": "Марафоны успеха", "price": 35000, "rank": 1, "mult": 1.7, "heat": 1.1, "passive": 4000,
		"desc": "Курсы «Как стать миллионером за 7 дней».",
		"premise": "реклама курса или марафона успеха от инфобизнесмена"},
	{"id": "gadgets", "name": "Чудо-товары", "price": 70000, "rank": 1, "mult": 2.2, "heat": 1.15, "passive": 8000,
		"desc": "Магнитные браслеты, пояса для похудения, «квантовые» фильтры.",
		"premise": "телемагазин с чудо-товаром: браслет от всех болезней, пояс для похудения и т. п."},
	{"id": "lottery", "name": "Наследство из-за границы", "price": 140000, "rank": 2, "mult": 3.0, "heat": 1.3, "passive": 16000,
		"desc": "Дальний родственник оставил миллионы, осталось оплатить пошлину.",
		"premise": "письмо о наследстве от дальнего заграничного родственника"},
	{"id": "crypto", "name": "Крипто-инвестиции", "price": 300000, "rank": 3, "mult": 4.2, "heat": 1.45, "passive": 35000,
		"desc": "Монета «КонтораКоин» вырастет в 1000 раз. Обязательно.",
		"premise": "реклама инвестиций в новую криптовалюту с гарантированной доходностью"},
	{"id": "moon", "name": "Участки на Луне", "price": 650000, "rank": 4, "mult": 6.0, "heat": 1.6, "passive": 80000,
		"desc": "Элитная недвижимость с видом на Землю. Вершина карьеры.",
		"premise": "реклама продажи элитных участков на Луне с видом на Землю"},
]


static func scheme(id: String) -> Dictionary:
	for s in SCHEMES:
		if s["id"] == id:
			return s
	return SCHEMES[0]


## Случайная купленная схема; новые выпадают чаще старых.
static func pick_scheme(owned: Array) -> Dictionary:
	var pool := []
	var total := 0
	for i in SCHEMES.size():
		if SCHEMES[i]["id"] in owned:
			total += i + 1
			pool.append([SCHEMES[i], total])
	var r := randi_range(1, maxi(total, 1))
	for p in pool:
		if r <= p[1]:
			return p[0]
	return SCHEMES[0]


static func passive_income(owned: Array) -> int:
	var sum := 0
	for s in SCHEMES:
		if s["id"] in owned:
			sum += int(s["passive"])
	return sum
