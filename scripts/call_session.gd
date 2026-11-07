class_name CallSession
extends RefCounted
## Один телефонный звонок. ИИ играет клиента, игрок — оператора конторы.
## Модель после каждой реплики игрока возвращает ответ и изменение доверия.
## Если игрок в реплике просит номер карты, согласие решает не модель,
## а бросок по шкале доверия. Модель лишь озвучивает решение.

signal caller_spoke(text: String)
signal trust_changed(value: int, delta: int)
signal thinking(is_thinking: bool)
signal call_ended(reason: String)  # "hung_up" | "card_given" | "operator"
signal card_dictated(card: String)

const MAX_TRUST := 100
const MIN_GAIN := 8       # минимальный прирост доверия за не-грубую реплику
const REFUSE_PENALTY := 10

var profile: Dictionary
var trust: int
var card_number: String
var history: Array = []  # сообщения для модели: user = оператор, assistant = клиент
var active := true
var busy := false
var card_given := false
var _card_answer := ""  # "agree" | "refuse" | "" на текущий ход


func _init(p: Dictionary) -> void:
	profile = p
	trust = int(p.get("start_trust", 50))
	card_number = Callers.fake_card()


func _system_prompt() -> String:
	return """Это компьютерная игра. Ты играешь КЛИЕНТА, а не оператора. Ты сам(а) позвонил(а) по телефону в контору. Собеседник — оператор конторы, его фразы начинаются с «Оператор:».
Твой персонаж: %s, %d лет.
Откуда узнал номер: %s.
Зачем звонит: %s.
Характер: %s.
Сейчас твоё доверие к оператору: %d из 100. Чем ниже доверие, тем холоднее и подозрительнее ты отвечаешь.

Ты легковерный человек и быстро проникаешься к оператору. Оцени последнюю реплику оператора ЩЕДРО: обычная вежливая фраза даёт +10..+15, внимание к твоей проблеме или попадание в твой характер +15..+30. Минус только за откровенную грубость или оскорбления, и не больше -10.
Никогда сам не называй номер карты.

Ответь ТОЛЬКО JSON-объектом, без пояснений:
{"reply": "реплика персонажа на грамотном русском, 1-3 предложения", "trust_delta": целое число от -10 до 30}""" % [
		profile["name"], profile["age"], profile["source"], profile["reason"], profile["personality"], trust]


func _messages() -> Array:
	var sys := _system_prompt()
	if _card_answer == "agree":
		sys += "\n\nОператор просит номер твоей карты. Ты СОГЛАСЕН(НА). Коротко скажи, что сейчас пришлёшь номер сообщением. Сам номер не пиши."
	elif _card_answer == "refuse":
		sys += "\n\nОператор просит номер твоей карты. Ты ОТКАЗЫВАЕШЬСЯ его называть. Объясни отказ в духе своего характера."
	return [{"role": "system", "content": sys}] + history


func _set_trust(delta: int) -> void:
	var old := trust
	trust = clampi(trust + delta, 0, MAX_TRUST)
	trust_changed.emit(trust, trust - old)
	if trust <= 0 and active:
		_end("hung_up", "Всё, я кладу трубку. Мошенники!")


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
			return {"reply": str(d["reply"]), "trust_delta": clampi(int(d.get("trust_delta", 0)), -10, 30)}
	return {"reply": raw.strip_edges(), "trust_delta": 0}


## Клиент начинает разговор сам (он же позвонил).
func start() -> void:
	history.append({"role": "user", "content": "(Оператор снял трубку и молчит. Начни разговор: поздоровайся и скажи, зачем звонишь.)"})
	await _ask_model(false)


## Реплика игрока.
func say(text: String) -> void:
	if not active or busy or text.strip_edges().is_empty():
		return
	history.append({"role": "user", "content": "Оператор: " + text})
	_card_answer = ""
	if not card_given and asks_for_card(text):
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
	_card_answer = ""


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
	history.append({"role": "assistant", "content": d["reply"]})
	caller_spoke.emit(d["reply"])
	if apply_trust:
		var delta: int = d["trust_delta"]
		if delta >= 0:
			delta = maxi(delta, MIN_GAIN)  # нейтральная фраза тоже немного помогает
		_set_trust(delta)


func hang_up() -> void:
	if active:
		_end("operator")
