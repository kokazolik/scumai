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

var api_key := ""
var mock := false


func _ready() -> void:
	mock = OS.get_environment("ALIBI_MOCK") == "1"
	api_key = OS.get_environment("OPENROUTER_API_KEY")
	if api_key.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load("user://secrets.cfg") == OK:
			api_key = str(cfg.get_value("openrouter", "api_key", ""))


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

	var body := JSON.stringify({
		"model": MODEL,
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
		http.timeout = 45.0
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

		var retryable: bool = r[0] != HTTPRequest.RESULT_SUCCESS or code in RETRY_CODES
		if retryable and attempt < retries:
			await get_tree().create_timer(pow(2.0, attempt)).timeout
			continue
		var msg := "HTTP %d" % code if code != 0 else "нет сети (код %d)" % r[0]
		if code == 401:
			msg = "ключ OpenRouter не подходит"
		elif data is Dictionary and data.get("error") is Dictionary:
			msg += ": " + str(data["error"].get("message", ""))
		return {"ok": false, "text": "", "error": msg}
	return {"ok": false, "text": "", "error": "Не удалось получить ответ"}


## Как chat(), но достаёт из ответа JSON-объект. {"ok", "data": Dictionary, "error"}.
## Если ответ не разобрался, пробует ещё раз.
func chat_json(messages: Array, temperature := 0.9, max_tokens := 600) -> Dictionary:
	var last_err := ""
	for attempt in 3:
		var res: Dictionary = await chat(messages, temperature, max_tokens)
		if not res.ok:
			return {"ok": false, "data": {}, "error": res.error}
		var d = parse_json_object(res.text)
		if d is Dictionary:
			return {"ok": true, "data": d, "error": ""}
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
		opts[n] = ["Осмотреться", "Пойти вперёд", "Заговорить с незнакомцем"]
	if sys.contains("Сейчас начало новой кампании"):
		return JSON.stringify({"title": "Тень над Вербой", "world": "Тихая долина, где пропадают дети.",
			"quest": "Найти, кто крадёт детей.", "place": {"name": "Деревня Верба", "type": "village"},
			"intro": "Вы стоите у колодца в деревне Верба. Что делаете?", "options": opts})
	if sys.contains("только решаешь, нужны ли броски"):
		var checks := []
		for n in names:
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
		d.story = "Из кустов выскакивают гоблины!"
	elif turn == 1:
		d.chest = "Старый сундук"
		d.place = {"name": "Тёмный лес", "type": "forest"}
	elif turn == 2:
		d.shop = "Кузнец Михей"
		d.changes = [{"who": names[0] if names.size() > 0 else "", "xp": 120, "gold": 5, "add": ["potion_heal"]}]
	return JSON.stringify(d)
