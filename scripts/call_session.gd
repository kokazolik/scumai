class_name CallSession
extends RefCounted
## Один телефонный звонок. ИИ играет клиента, игрок — оператора конторы.
## Модель после каждой реплики игрока возвращает ответ и изменение доверия.
## Если игрок в реплике просит номер карты, согласие решает не модель,
## а бросок по шкале доверия. Модель лишь озвучивает решение.
## Модель также сообщает, на какую сумму клиент согласился (agreed_price),
## и может в любой момент бросить трубку (hang_up).

signal caller_spoke(text: String)
signal trust_changed(value: int, delta: int)
signal thinking(is_thinking: bool)
signal call_ended(reason: String)  # "hung_up" | "card_given" | "operator"
signal card_dictated(card: String)
signal price_agreed(rub: int)
signal transfer_done(rub: int, method: String)
signal gift_dictated(code: String)
signal method_locked(name: String)

## Корпоративный номер для перевода по номеру телефона (вымышленный).
const CORP_PHONE := "+7 900 555-01-23"
const CORP_BANK := "Восход-Банк"

const MAX_TRUST := 100
const REFUSE_PENALTY := 10
const START_TRUST_MIN := 20
const START_TRUST_MAX := 45
## Сколько доверия даёт каждая категория реплики. Модель только выбирает категорию,
## очки считает игра, поэтому одинаковые реплики оцениваются одинаково.
const RATING_DELTA := {
	"nonsense": -15, "rude": -12, "suspicious": -8, "off_topic": -4, "neutral": 2,
	"question": 4, "helpful": 8, "good_offer": 11, "perfect": 15,
}

var profile: Dictionary
var trust: int
var card_number: String
var history: Array = []  # сообщения для модели: user = оператор, assistant = клиент
var active := true
var busy := false
var card_given := false
var last_operator_line := ""
var agreed_price := 0  # сколько клиент согласился заплатить, ₽
var budget := 0        # сколько у клиента примерно есть денег, ₽
var roll_bonus := 0      # улучшения: прибавка к шансу карты и перевода, %
var neg_mult := 1.0      # улучшения: доля штрафа доверия, которая доходит до клиента
var offered_max := 0     # самая большая цена, которую оператор называл за звонок
var paid := false        # деньги уже получены (карта списана или перевод)
var _card_answer := ""
var _pay_method := "phone"   # каким способом идёт перевод на этом ходу
var methods: Array = ["card", "phone"]  # купленные способы оплаты
var base_budget := 0     # сколько у клиента на карте; остальное доступно только продвинутыми способами
var gift_code := ""
var _transfer_answer := ""  # "agree" | "refuse" | "no_price" | ""  # "agree" | "refuse" | "" на текущий ход


func _init(p: Dictionary) -> void:
	profile = p
	trust = randi_range(START_TRUST_MIN, START_TRUST_MAX)  # каждый звонок — случайное небольшое доверие
	card_number = Callers.fake_card()
	budget = randi_range(4, 40) * 500  # от 2 000 до 20 000 ₽
	base_budget = budget


func _system_prompt() -> String:
	return """Это компьютерная игра. Ты играешь КЛИЕНТА, а не оператора. Ты сам(а) позвонил(а) по телефону в контору. Собеседник — оператор конторы, его фразы начинаются с «Оператор:».
Твой персонаж: %s, %d лет.
Откуда узнал номер: %s.
Зачем звонит: %s.
Характер: %s.
Сейчас твоё доверие к оператору: %d из 100. Чем ниже доверие, тем холоднее и подозрительнее ты отвечаешь.

Оцени последнюю реплику оператора, выбрав ОДНУ категорию rating:
- "nonsense": бессмыслица, набор звуков, детский лепет, издевательство;
- "rude": грубость, оскорбление, хамство;
- "suspicious": явно подозрительная просьба без причины (код из СМС, пароль, паспорт), противоречит сам себе;
- "off_topic": совсем не по теме твоего звонка;
- "neutral": общая вежливая фраза, приветствие, пустые слова;
- "question": уточняющий вопрос о тебе и твоей ситуации, сочувствие, интерес к тебе (это нормальная работа оператора);
- "helpful": понял твою проблему, предлагает конкретное решение, говорит уверенно и по делу;
- "good_offer": выгодное предложение: скидка, бонус, гарантия, бесплатно, быстро, большая выгода для тебя;
- "perfect": отлично попал в твой характер и интересы, именно то, что ты хотел(а) услышать.
Оценивай только саму последнюю реплику, а не прошлые. Учитывай свой характер: на что ты ведёшься, то для тебя good_offer или perfect. Не выбирай плохую категорию только потому, что вопрос ещё не решён. Твоё низкое доверие влияет на тон ответа, но не на rating.
Никогда сам не называй номер карты.

Деньги: всего ты можешь отдать примерно %d рублей (вместе со сбережениями), больше никак. Из них на карте около %d. Суммы до половины всего тебя не пугают, дороже ты торгуешься или сомневаешься.
Сейчас договорённая сумма: %s.
agreed_price: если в этой реплике оператор назвал цену и ты на неё СОГЛАСЕН(НА), поставь эту сумму в рублях. Если согласен(на) на меньшую, поставь её. Иначе 0.

Ты живой человек и можешь закончить разговор, когда захочешь: если тебя оскорбили, если стало подозрительно или скучно, если разговор зашёл в тупик. Тогда скажи что угодно (или ничего) и поставь hang_up: true. Не бросай трубку без причины.

Ответь ТОЛЬКО JSON-объектом, без пояснений:
{"reply": "реплика персонажа на грамотном русском, 1-3 предложения (может быть пустой, если бросаешь трубку молча)", "rating": одна категория из списка, "agreed_price": целое число, "hang_up": true или false}""" % [
		profile["name"], profile["age"], profile["source"], profile["reason"], profile["personality"], trust,
		budget, base_budget, ("%d рублей" % agreed_price) if agreed_price > 0 else "пока нет"]


func _messages() -> Array:
	var sys := _system_prompt()
	if _card_answer == "agree":
		sys += "\n\nОператор просит номер твоей карты. Ты СОГЛАСЕН(НА). Коротко скажи, что сейчас пришлёшь номер сообщением. Сам номер не пиши."
	elif _card_answer == "refuse":
		sys += "\n\nОператор просит номер твоей карты. Ты ОТКАЗЫВАЕШЬСЯ его называть. Объясни отказ в духе своего характера."
	var pm := Upgrades.method(_pay_method)
	if _transfer_answer == "poor":
		sys += "\n\nОператор просит оплатить %d рублей способом «%s». У тебя нет таких денег для этого способа (доступно около %d рублей). Скажи, что столько у тебя нет." % [agreed_price, pm["name"], cap_for(_pay_method)]
	elif _pay_method != "phone" and _transfer_answer == "agree":
		sys += "\n\nОператор просит оплатить %d рублей способом «%s». Ты СОГЛАСЕН(НА): коротко скажи, что %s." % [agreed_price, pm["name"], pm["act"]]
	elif _pay_method != "phone" and _transfer_answer == "refuse":
		sys += "\n\nОператор просит оплатить способом «%s». Ты ОТКАЗЫВАЕШЬСЯ. Объясни отказ в духе своего характера." % pm["name"]
	elif _pay_method != "phone" and _transfer_answer == "no_price":
		sys += "\n\nОператор предлагает оплатить способом «%s», но вы ещё не договорились о сумме. Спроси, сколько и за что." % pm["name"]
	elif _transfer_answer == "agree":
		sys += "\n\nОператор продиктовал номер телефона %s, чтобы ты перевёл(а) %d рублей через %s. Ты СОГЛАСЕН(НА): скажи, что перевёл(а) деньги по этому номеру." % [CORP_PHONE, agreed_price, CORP_BANK]
	elif _transfer_answer == "refuse":
		sys += "\n\nОператор просит перевести деньги по номеру телефона. Ты ОТКАЗЫВАЕШЬСЯ переводить. Объясни отказ в духе своего характера."
	elif _transfer_answer == "no_price":
		sys += "\n\nОператор просит перевести деньги по номеру телефона, но вы ещё не договорились о сумме. Спроси, сколько именно переводить и за что."
	return [{"role": "system", "content": sys}] + history


func _set_trust(delta: int) -> void:
	var old := trust
	trust = clampi(trust + delta, 0, MAX_TRUST)
	trust_changed.emit(trust, trust - old)
	if trust <= 0 and active:
		_end("hung_up")  # доверие кончилось: клиент молча кладёт трубку


func _end(reason: String, last_line := "") -> void:
	active = false
	if last_line != "":
		caller_spoke.emit(last_line)
	call_ended.emit(reason)


## Достаёт JSON из ответа модели, даже если он обёрнут в ``` или лишний текст.
static func parse_reply(raw: String) -> Dictionary:
	var a := raw.find("{")
	var b := raw.rfind("}")
	if a != -1 and b > a:
		var d = JSON.parse_string(raw.substr(a, b - a + 1))
		if d is Dictionary and d.has("reply"):
			var hang = d.get("hang_up", false)
			return {
				"reply": str(d["reply"]).strip_edges(),
				"trust_delta": rating_delta(str(d.get("rating", "")), d.get("trust_delta", 0)),
				"agreed_price": maxi(0, int(d.get("agreed_price", 0))),
				"hang_up": hang == true or str(hang).to_lower() == "true",
			}
	return {"reply": raw.strip_edges(), "trust_delta": 0, "agreed_price": 0, "hang_up": false}


## Очки за категорию с небольшим разбросом ±1, чтобы не было совсем одинаково.
static func rating_delta(rating: String, fallback) -> int:
	rating = rating.strip_edges().to_lower()
	if RATING_DELTA.has(rating):
		var v: int = RATING_DELTA[rating]
		return v + randi_range(-1, 1) if absi(v) > 2 else v
	return clampi(int(fallback), -20, 20)


## Вызывается после настройки улучшений: общий бюджет растёт от лучшего купленного способа оплаты.
func set_methods(owned: Array) -> void:
	methods = owned.duplicate()
	if not "card" in methods:
		methods.append("card")
	if not "phone" in methods:
		methods.append("phone")
	base_budget = budget
	var best := 1.0
	for id in methods:
		best = maxf(best, float(Upgrades.method(id)["cap"]))
	budget = int(round(budget * best / 500.0)) * 500


func cap_for(id: String) -> int:
	return int(base_budget * float(Upgrades.method(id)["cap"]))


func _roll(id: String) -> String:
	if agreed_price > cap_for(id):
		return "poor"
	return "agree" if randi() % 100 < trust + roll_bonus + int(Upgrades.method(id)["chance"]) else "refuse"


## Какой продвинутый способ оплаты предлагает оператор (по ключевым словам), "" если никакой.
static func detect_method(text: String) -> String:
	var t := text.to_lower()
	for m in Upgrades.METHODS:
		if m["words"] != "" and RegEx.create_from_string(m["words"]).search(t):
			return m["id"]
	return ""


static func make_gift_code() -> String:
	var abc := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var out := ""
	for i in 12:
		if i > 0 and i % 4 == 0:
			out += "-"
		out += abc[randi() % abc.length()]
	return out


## Клиент начинает разговор сам (он же позвонил).
func start() -> void:
	history.append({"role": "user", "content": "(Оператор снял трубку и молчит. Начни разговор: поздоровайся и скажи, зачем звонишь.)"})
	await _ask_model(false)


## Реплика игрока.
func say(text: String) -> void:
	if not active or busy or text.strip_edges().is_empty():
		return
	history.append({"role": "user", "content": "Оператор: " + text})
	last_operator_line = text
	if not has_corp_phone(text):
		offered_max = maxi(offered_max, mentioned_price(text))
	_card_answer = ""
	_transfer_answer = ""
	_pay_method = "phone"
	var adv := detect_method(text)
	if adv != "" and not adv in methods:
		method_locked.emit(Upgrades.method(adv)["name"])
		adv = ""
	if not paid and adv != "":
		_pay_method = adv
		_transfer_answer = "no_price" if agreed_price <= 0 else _roll(adv)
	elif not paid and has_corp_phone(text):
		_transfer_answer = "no_price" if agreed_price <= 0 else _roll("phone")  # шанс = доверие в %
	elif not card_given and not paid and asks_for_card(text):
		_card_answer = _roll("card")
		if _card_answer == "poor":
			_card_answer = "refuse"
	await _ask_model(true)
	if not active:
		return
	if _card_answer == "agree":
		card_given = true
		history.append({"role": "assistant", "content": "(прислал(а) номер карты сообщением)"})
		card_dictated.emit(card_number)
	elif _card_answer == "refuse":
		_set_trust(-REFUSE_PENALTY)
	if _transfer_answer == "agree" and _pay_method == "gift":
		gift_code = make_gift_code()
		history.append({"role": "assistant", "content": "(продиктовал(а) коды подарочных карт на %d рублей)" % agreed_price})
		gift_dictated.emit(gift_code)
	elif _transfer_answer == "agree":
		paid = true
		history.append({"role": "assistant", "content": "(перевёл(а) %d рублей: %s)" % [agreed_price, Upgrades.method(_pay_method)["name"]]})
		transfer_done.emit(agreed_price, _pay_method)
	elif _transfer_answer == "refuse":
		_set_trust(-REFUSE_PENALTY)
	_card_answer = ""
	_transfer_answer = ""


## Похожа ли реплика на бессмыслицу: мало настоящих слов или одни повторы.
static func is_gibberish(text: String) -> bool:
	var words := []
	var re := RegEx.create_from_string("[а-яёa-z]{2,}")
	for m in re.search_all(text.to_lower()):
		words.append(m.get_string())
	if words.size() == 0:
		return true
	var uniq := {}
	for w in words:
		uniq[w] = true
	var short_ok := ["да", "нет", "ок", "ага", "угу", "так", "вот", "хорошо"]
	if words.all(func(w): return w in short_ok):
		return false  # короткий ответ «да»/«нет» пусть оценивает модель
	var long_words := words.filter(func(w): return w.length() >= 4)
	return long_words.is_empty() or (uniq.size() == 1 and words.size() >= 3)


## Самая большая сумма, которую оператор назвал в реплике («2000», «2 000», «2 тысячи»).
## Клиент может согласиться только на названную оператором цену или меньше.
static func mentioned_price(text: String) -> int:
	var best := 0
	var t := text.to_lower()
	var re := RegEx.create_from_string("(\\d[\\d\\s.,]*\\d|\\d)(\\s*(тыс|к(?![а-яё])))?")
	for m in re.search_all(t):
		var raw := m.get_string(1).replace(" ", "").replace("\u00a0", "")
		var parts := raw.replace(",", ".").split(".")
		var n := 0.0
		if parts.size() == 1:
			n = float(raw)
		else:
			var thousands := true  # «14.000», «1,500,000» — точки и запятые между тройками цифр
			for i in range(1, parts.size()):
				if parts[i].length() != 3:
					thousands = false
			if thousands:
				n = float("".join(parts))
			elif parts.size() == 2:
				n = float(parts[0] + "." + parts[1])  # «2,5 тыс»
			else:
				continue
		if str(int(n)).length() > 7:
			continue  # это номер телефона или карты, а не цена
		if m.get_string(2) != "":
			n *= 1000.0
		best = maxi(best, int(round(n)))
	return best


## Продиктовал ли игрок корпоративный номер (цифры в любом формате).
static func has_corp_phone(text: String) -> bool:
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	var corp := ""
	for ch in CORP_PHONE:
		if ch >= "0" and ch <= "9":
			corp += ch
	return digits.contains(corp.substr(1))  # без первой цифры: +7 / 8 / без кода


## Просит ли реплика игрока номер карты.
static func asks_for_card(text: String) -> bool:
	var t := text.to_lower()
	if not t.contains("карт"):
		return false
	for w in ["номер", "цифр", "лицев", "продиктуй", "назов", "скаж", "пришл", "отправ", "напиш", "данные", "реквизит"]:
		if t.contains(w):
			return true
	return false


func _ask_model(apply_trust: bool) -> void:
	busy = true
	thinking.emit(true)
	var res: Dictionary = await LLM.chat(_messages(), 0.7)
	busy = false  # до сигнала: интерфейс по нему включает кнопки
	thinking.emit(false)
	if not active:
		return
	if not res["ok"]:
		caller_spoke.emit("[связь прервалась: %s]" % res["error"])
		history.pop_back()
		return
	var d := parse_reply(res["text"])
	history.append({"role": "assistant", "content": d["reply"] if d["reply"] != "" else "(молчит)"})
	if d["reply"] != "":
		caller_spoke.emit(d["reply"])
	var offered := maxi(mentioned_price(last_operator_line), offered_max)
	if apply_trust and d["agreed_price"] > 0 and d["agreed_price"] <= mini(budget, offered) and d["agreed_price"] != agreed_price:
		agreed_price = d["agreed_price"]
		price_agreed.emit(agreed_price)
	if apply_trust and d["hang_up"] and _card_answer != "agree" and _transfer_answer != "agree":
		_end("hung_up")
		return
	if apply_trust:
		var delta: int = d["trust_delta"]
		if _card_answer != "" or _transfer_answer != "":
			delta = 0  # просьбу о карте решает бросок, а не оценка модели
		if delta < 0:
			delta = mini(-1, int(round(delta * neg_mult)))
		if is_gibberish(last_operator_line) and delta > -10:
			delta = -10  # «бе-бе-бе» никогда не вызывает доверия
		_set_trust(delta)


func hang_up() -> void:
	if active:
		_end("operator")
