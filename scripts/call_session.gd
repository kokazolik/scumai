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
signal transfer_done(rub: int)

## Корпоративный номер для перевода по номеру телефона (вымышленный).
const CORP_PHONE := "+7 900 555-01-23"
const CORP_BANK := "Восход-Банк"

const MAX_TRUST := 100
const REFUSE_PENALTY := 10
const START_TRUST_MIN := 20
const START_TRUST_MAX := 45

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
var offered_max := 0     # самая большая цена, которую оператор называл за звонок
var paid := false        # деньги уже получены (карта списана или перевод)
var _card_answer := ""
var _transfer_answer := ""  # "agree" | "refuse" | "no_price" | ""  # "agree" | "refuse" | "" на текущий ход


func _init(p: Dictionary) -> void:
	profile = p
	trust = randi_range(START_TRUST_MIN, START_TRUST_MAX)  # каждый звонок — случайное небольшое доверие
	card_number = Callers.fake_card()
	budget = randi_range(4, 40) * 500  # от 2 000 до 20 000 ₽


func _system_prompt() -> String:
	return """Это компьютерная игра. Ты играешь КЛИЕНТА, а не оператора. Ты сам(а) позвонил(а) по телефону в контору. Собеседник — оператор конторы, его фразы начинаются с «Оператор:».
Твой персонаж: %s, %d лет.
Откуда узнал номер: %s.
Зачем звонит: %s.
Характер: %s.
Сейчас твоё доверие к оператору: %d из 100. Чем ниже доверие, тем холоднее и подозрительнее ты отвечаешь.

Оцени последнюю реплику оператора честно, как живой человек:
- бессмыслица, детский лепет, набор звуков, издевательство, грубость: от -10 до -20;
- реплика не по теме, уход от твоей проблемы, странные или подозрительные просьбы: от -3 до -10;
- просто вежливая, но общая фраза: от 0 до +5;
- оператор понял твою проблему, предлагает решение, говорит уверенно и по делу: от +5 до +12;
- оператор отлично попал в твой характер и интересы: от +12 до +20.
Никогда сам не называй номер карты.

Деньги: у тебя есть примерно %d рублей, больше ты заплатить не можешь. Суммы до половины этого тебя не пугают, дороже ты торгуешься или сомневаешься.
Сейчас договорённая сумма: %s.
agreed_price: если в этой реплике оператор назвал цену и ты на неё СОГЛАСЕН(НА), поставь эту сумму в рублях. Если согласен(на) на меньшую, поставь её. Иначе 0.

Ты живой человек и можешь закончить разговор, когда захочешь: если тебя оскорбили, если стало подозрительно или скучно, если разговор зашёл в тупик. Тогда скажи что угодно (или ничего) и поставь hang_up: true. Не бросай трубку без причины.

Ответь ТОЛЬКО JSON-объектом, без пояснений:
{"reply": "реплика персонажа на грамотном русском, 1-3 предложения (может быть пустой, если бросаешь трубку молча)", "trust_delta": целое число от -20 до 20, "agreed_price": целое число, "hang_up": true или false}""" % [
		profile["name"], profile["age"], profile["source"], profile["reason"], profile["personality"], trust,
		budget, ("%d рублей" % agreed_price) if agreed_price > 0 else "пока нет"]


func _messages() -> Array:
	var sys := _system_prompt()
	if _card_answer == "agree":
		sys += "\n\nОператор просит номер твоей карты. Ты СОГЛАСЕН(НА). Коротко скажи, что сейчас пришлёшь номер сообщением. Сам номер не пиши."
	elif _card_answer == "refuse":
		sys += "\n\nОператор просит номер твоей карты. Ты ОТКАЗЫВАЕШЬСЯ его называть. Объясни отказ в духе своего характера."
	if _transfer_answer == "agree":
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
				"trust_delta": clampi(int(d.get("trust_delta", 0)), -20, 20),
				"agreed_price": maxi(0, int(d.get("agreed_price", 0))),
				"hang_up": hang == true or str(hang).to_lower() == "true",
			}
	return {"reply": raw.strip_edges(), "trust_delta": 0, "agreed_price": 0, "hang_up": false}


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
	if not paid and has_corp_phone(text):
		if agreed_price <= 0:
			_transfer_answer = "no_price"
		else:
			_transfer_answer = "agree" if randi() % 100 < trust else "refuse"  # шанс = доверие в %
	elif not card_given and not paid and asks_for_card(text):
		_card_answer = "agree" if randi() % 100 < trust else "refuse"  # шанс = доверие в %
	await _ask_model(true)
	if not active:
		return
	if _card_answer == "agree":
		card_given = true
		history.append({"role": "assistant", "content": "(прислал(а) номер карты сообщением)"})
		card_dictated.emit(card_number)
	elif _card_answer == "refuse":
		_set_trust(-REFUSE_PENALTY)
	if _transfer_answer == "agree":
		paid = true
		history.append({"role": "assistant", "content": "(перевёл(а) %d рублей по номеру телефона)" % agreed_price})
		transfer_done.emit(agreed_price)
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
		if is_gibberish(last_operator_line) and delta > -10:
			delta = -10  # «бе-бе-бе» никогда не вызывает доверия
		_set_trust(delta)


func hang_up() -> void:
	if active:
		_end("operator")
