class_name CallSession
extends RefCounted
## Один телефонный звонок. ИИ играет клиента, игрок — оператора конторы.
## Модель после каждой реплики игрока возвращает ответ и изменение доверия.
## Согласие на сделку решает не модель, а бросок по шкале доверия (try_ask_card).

signal caller_spoke(text: String)
signal trust_changed(value: int, delta: int)
signal thinking(is_thinking: bool)
signal call_ended(reason: String)  # "hung_up" | "card_given" | "operator"
signal card_dictated(card: String)

const MAX_TRUST := 100

var profile: Dictionary
var trust: int
var card_number: String
var history: Array = []  # сообщения для модели: user = оператор, assistant = клиент
var active := true
var busy := false


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

Оцени последнюю реплику оператора. Вежливость, внимание к твоей проблеме, попадание в твой характер и понятные объяснения повышают доверие. Грубость, давление, спешка, непонятные слова и подозрительные просьбы понижают.
Никогда сам не называй номер карты.

Ответь ТОЛЬКО JSON-объектом, без пояснений:
{"reply": "реплика персонажа на грамотном русском, 1-3 предложения", "trust_delta": целое число от -20 до 20}""" % [
		profile["name"], profile["age"], profile["source"], profile["reason"], profile["personality"], trust]


func _messages() -> Array:
	return [{"role": "system", "content": _system_prompt()}] + history


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
			return {"reply": str(d["reply"]), "trust_delta": clampi(int(d.get("trust_delta", 0)), -20, 20)}
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
	await _ask_model(true)


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
		_set_trust(d["trust_delta"])


## Игрок просит назвать номер карты. Шанс согласия = доверие.
func try_ask_card() -> bool:
	if not active or busy:
		return false
	var roll := randi() % 100
	if roll < trust:
		var line := "Ну ладно... записывайте: %s." % card_number
		history.append({"role": "user", "content": "Оператор: Назовите, пожалуйста, номер карты с лицевой стороны."})
		history.append({"role": "assistant", "content": line})
		caller_spoke.emit(line)
		card_dictated.emit(card_number)
		return true
	history.append({"role": "user", "content": "Оператор: Назовите, пожалуйста, номер карты с лицевой стороны."})
	await _ask_model(false)  # пусть клиент сам откажет своими словами
	_set_trust(-15)
	return false


func hang_up() -> void:
	if active:
		_end("operator")
