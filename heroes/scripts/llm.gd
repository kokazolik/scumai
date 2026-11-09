extends Node
## Клиент OpenRouter (тот же подход, что в «Конторе»). Автозагрузка "LLM".
## Нейронку вызывает только хост комнаты, поэтому ключ нужен только на его телефоне.
##
## Ключ ищется так:
##   1) переменная окружения OPENROUTER_API_KEY;
##   2) файл user://secrets.cfg, секция [openrouter], ключ api_key (его пишет кнопка «Ключ ИИ»).
## Не кладите ключ в res:// — он попадёт в собранную игру и в git.
##
## ALIBI_MOCK=1 в окружении включает заглушку без сети (для автотестов).

const API_URL := "https://openrouter.ai/api/v1/chat/completions"
const MODEL := "google/gemma-4-26b-a4b-it"
const RETRY_CODES := [429, 500, 502, 503, 504]
## Выбор нейронки (кнопка в меню). Цена — примерно за один ход двоих игроков.
const MODELS := [
	{"id": "google/gemma-4-26b-a4b-it", "name": "Gemma 4", "note": "дёшево: ~0,1 коп. за ход, при пустом балансе сама переходит на бесплатную"},
	{"id": "deepseek/deepseek-v4-flash", "name": "DeepSeek V4 Flash", "note": "~0,1 коп. за ход, живее пишет по-русски"},
	{"id": "google/gemma-4-26b-a4b-it:free", "name": "Gemma 4 бесплатно", "note": "0 ₽, но OpenRouter ограничивает число запросов в день"},
]
const FREE_FALLBACK := "google/gemma-4-26b-a4b-it:free"

signal note(text: String)

var api_key := ""
var model := MODEL
var _broke := false   # на балансе OpenRouter кончились деньги — до перезапуска идём в бесплатную модель
var mock := false


func _ready() -> void:
	mock = OS.get_environment("ALIBI_MOCK") == "1"
	api_key = OS.get_environment("OPENROUTER_API_KEY")
	if api_key.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load("user://secrets.cfg") == OK:
			api_key = str(cfg.get_value("openrouter", "api_key", ""))
	var sc := ConfigFile.new()
	if sc.load("user://settings.cfg") == OK:
		model = str(sc.get_value("ai", "model", MODEL))
	if not MODELS.any(func(m): return m.id == model):
		model = MODEL


func model_info() -> Dictionary:
	for m in MODELS:
		if m.id == model:
			return m
	return MODELS[0]


## Следующая модель из списка (кнопка в меню).
func cycle_model() -> void:
	var i := 0
	for k in MODELS.size():
		if MODELS[k].id == model:
			i = k
	model = MODELS[(i + 1) % MODELS.size()].id
	_broke = false
	var sc := ConfigFile.new()
	sc.load("user://settings.cfg")
	sc.set_value("ai", "model", model)
	sc.save("user://settings.cfg")


func has_key() -> bool:
	return mock or not api_key.is_empty()


func save_key(key: String) -> void:
	api_key = key.strip_edges()
	var cfg := ConfigFile.new()
	cfg.load("user://secrets.cfg")
	cfg.set_value("openrouter", "api_key", api_key)
	cfg.save("user://secrets.cfg")


## Возвращает {"ok": bool, "text": String, "error": String}.
func chat(messages: Array, temperature := 0.9, max_tokens := 600, retries := 3) -> Dictionary:
	if mock:
		await get_tree().create_timer(0.3).timeout
		return {"ok": true, "text": _mock_reply(messages), "error": ""}
	if api_key.is_empty():
		return {"ok": false, "text": "", "error": "Нет API-ключа OpenRouter"}

	var use_model := FREE_FALLBACK if _broke else model
	var body := JSON.stringify({
		"model": use_model,
		"messages": messages,
		"temperature": temperature,
		"max_tokens": max_tokens,
	})
	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
	])

	for attempt in range(retries + 1):
		var http := HTTPRequest.new()
		http.timeout = 40.0
		add_child(http)
		var err := http.request(API_URL, headers, HTTPClient.METHOD_POST, body)
		if err != OK:
			http.queue_free()
			return {"ok": false, "text": "", "error": "Не удалось отправить запрос (%d)" % err}
		var r: Array = await http.request_completed
		http.queue_free()
		var code: int = r[1]
		var raw_body := (r[3] as PackedByteArray).get_string_from_utf8()
		var data = null if raw_body.is_empty() else JSON.parse_string(raw_body)

		if r[0] == HTTPRequest.RESULT_SUCCESS and code == 200 and data is Dictionary:
			var text := ""
			if data.has("choices") and data["choices"].size() > 0:
				var c = data["choices"][0]["message"].get("content")
				text = "" if c == null else str(c)
			if text.strip_edges().is_empty() and attempt < retries:
				continue
			return {"ok": true, "text": text, "error": ""}

		var emsg := ""
		if data is Dictionary and data.get("error") is Dictionary:
			emsg = str(data["error"].get("message", ""))
		# деньги на OpenRouter кончились: тот же запрос — в бесплатную модель
		if (code == 402 or emsg.contains("afford") or emsg.contains("credits")) and use_model != FREE_FALLBACK:
			_broke = true
			note.emit("На балансе OpenRouter кончились деньги — ведущий перешёл на бесплатную Gemma 4")
			push_warning("OpenRouter: баланс пуст, переходим на " + FREE_FALLBACK)
			return await chat(messages, temperature, max_tokens, retries)
		if code == 429 and use_model.ends_with(":free") and attempt >= 1:
			return {"ok": false, "text": "", "error": "бесплатный лимит OpenRouter на сегодня исчерпан — пополни баланс или подожди до завтра"}
		var retryable: bool = r[0] != HTTPRequest.RESULT_SUCCESS or code in RETRY_CODES
		if retryable and attempt < retries:
			await get_tree().create_timer(pow(2.0, attempt)).timeout
			continue
		var msg := "HTTP %d" % code if code != 0 else "нет сети (код %d)" % r[0]
		if code == 401:
			msg = "ключ OpenRouter не подходит"
		elif code == 402:
			msg = "на балансе OpenRouter кончились деньги"
		elif data is Dictionary and data.get("error") is Dictionary:
			msg += ": " + str(data["error"].get("message", ""))
		return {"ok": false, "text": "", "error": msg}
	return {"ok": false, "text": "", "error": "Не удалось получить ответ"}


## Как chat(), но достаёт из ответа JSON-объект. {"ok", "data": Dictionary, "error"}.
## Если ответ не разобрался, пробует ещё раз.
func chat_json(messages: Array, temperature := 0.9, max_tokens := 600) -> Dictionary:
	var last_err := ""
	var t0 := Time.get_ticks_msec()
	for attempt in 3:
		if attempt > 0 and Time.get_ticks_msec() - t0 > 60000:
			break
		var res: Dictionary = await chat(messages, temperature, max_tokens, 1 if attempt > 0 else 2)
		if not res.ok:
			return {"ok": false, "data": {}, "error": res.error}
		var d = parse_json_object(res.text)
		if d is Dictionary:
			return {"ok": true, "data": d, "error": ""}
		# частая поломка — кавычки внутри рассказа; спасаем хотя бы сам рассказ
		var rx := RegEx.create_from_string("\"story\"\\s*:\\s*\"([\\s\\S]*?)\"\\s*,\\s*\"(changes|options|place)\"")
		var m := rx.search(res.text)
		if m and attempt == 2:
			return {"ok": true, "data": {"story": m.get_string(1).replace("\\n", "\n")}, "error": ""}
		last_err = "нейронка ответила не в том формате"
	return {"ok": false, "data": {}, "error": last_err}


static func parse_json_object(text: String):
	var a := text.find("{")
	var b := text.rfind("}")
	if a < 0 or b <= a:
		return null
	var d = JSON.parse_string(text.substr(a, b - a + 1))
	return d if d is Dictionary else null


func _mock_reply(messages: Array) -> String:
	var sys := str(messages[0].get("content", ""))
	var user := str(messages[-1].get("content", ""))
	var names := []
	for line in user.split("\n"):
		if line.begins_with("- ") and line.contains(":"):
			names.append(line.substr(2, line.find(":") - 2))
	var opts := {}
	for n in names:
		opts[n] = ["Осмотреться", {"t": "Припугнуть стражника", "check": {"name": "Запугивание", "ability": "СИЛ", "dc": 12}}, "Заговорить с незнакомцем"]
	if sys.contains("Сейчас начало новой кампании"):
		return JSON.stringify({"title": "Тень над Вербой", "world": "Тихая долина, где пропадают дети.",
			"quest": "Найти, кто крадёт детей.", "place": {"name": "Деревня Верба", "type": "village"},
			"intro": "Вы стоите у колодца в деревне Верба. Что делаете?", "options": opts})
	if sys.contains("только решаешь, нужны ли броски"):
		var checks := []
		for n in names:
			if randi() % 3 == 0:
				checks.append({"who": n, "kind": "save", "name": "ЛОВ", "dc": 12, "adv": 0, "why": "ловушка", "trap_dmg": "1d4", "cond": "poisoned"})
			elif randi() % 2 == 0:
				checks.append({"who": n, "kind": "skill", "name": "Ловкость рук", "dc": 12, "adv": 0, "why": "замок", "tools": true})
			else:
				checks.append({"who": n, "kind": "skill", "name": "Восприятие", "dc": 12, "adv": 0, "why": "осмотр"})
		return JSON.stringify({"checks": checks})
	if sys.contains("необычное действие"):
		return JSON.stringify({"check": {"kind": "skill", "name": "Атлетика", "dc": 10}, "effect": {"damage": "2d6"},
			"success": "Получилось!", "fail": "Не вышло."})
	if sys.contains("[CHRONICLE]"):
		return JSON.stringify({"chronicle": "Герои пришли в Вербу и подрались с гоблинами."})
	var turn := randi() % 4
	var d := {"story": "Мир живёт своей жизнью. Что дальше?", "changes": [], "options": opts,
		"place": null, "quest": "", "chest": "", "shop": "", "combat": [], "rest": ""}
	if sys.contains("закончился бой"):
		d.story = "Враги повержены."
	elif turn == 0:
		d.combat = [{"id": "goblin", "count": 2}]
		d.env = ["barrel", "cliff", "high"]
		d.story = "Из кустов выскакивают гоблины!"
	elif turn == 1:
		d.quests = [{"title": "Найти пропавшую козу", "note": "Бабка Агафья просила поискать у реки", "status": "new", "steps": ["Расспросить пастуха", "Найти следы у реки", "Вернуть козу"], "place": {"name": "Волчий овраг", "type": "forest", "dist": 2}}]
		d.goal = {"t": "Доплыть до маяка на Скалистом мысу", "steps": ["Найти лодку", "Пережить бурю", "Подняться на маяк"], "place": {"name": "Маяк на Скалистом мысу", "type": "tower", "dist": 3}}
		d.npcs = [{"name": "Бабка Агафья", "note": "Старушка с козой, знает все слухи", "attitude": 1}, {"name": "Кузнец Михей", "note": "ворчливый кузнец", "attitude": 2}]
		d.rep = [{"name": "Деревня Верба", "change": 1, "why": "помогли старушке"}]
		d.consequences = ["Пощадили гоблина Шныря — может вернуться"]
		d.companions = [{"name": "Серый", "kind": "волк", "monster": "wolf", "owner": names[0] if names.size() > 0 else ""}]
		d.chest = "Старый сундук"
		d.place = {"name": "Тёмный лес", "type": "forest"}
	elif turn == 2:
		d.shop = "Кузнец Михей"
		d.changes = [{"who": names[0] if names.size() > 0 else "", "xp": 120, "gold": 5, "add": ["potion_heal"]}]
		d.quests = [{"title": "Найти пропавшую козу", "status": "done"}]
		d.changes[0]["add"] = ["potion_heal", "herb", "herb", "venom_sac"]
	elif turn == 3 and randi() % 2 == 0:
		d.vote = {"q": "Кого спасать первым?", "opts": ["Мельника", "Старосту"]}
	elif turn == 3:
		d.place = {"name": "Хутор у брода %d" % (randi() % 50), "type": "village"}
		d.goal = {"t": "Доплыть до маяка на Скалистом мысу", "done_steps": ["Найти лодку"]}
		d.quests = [{"title": "Найти пропавшую козу", "status": "new", "done_steps": ["Расспросить пастуха"]}]
	return JSON.stringify(d)
