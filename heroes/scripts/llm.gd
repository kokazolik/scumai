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
	{"id": "GigaChat-2-Max", "prov": "gc", "name": "GigaChat 2 Max (Сбер)", "note": "бесплатно 25 млн токенов в год (~2500 ходов), лучший русский; потом сама перейдёт на Pro и Lite"},
	{"id": "GigaChat-2-Pro", "prov": "gc", "name": "GigaChat 2 Pro (Сбер)", "note": "бесплатно 40 млн токенов в год"},
	{"id": "GigaChat-2", "prov": "gc", "name": "GigaChat 2 Lite (Сбер)", "note": "бесплатно 250 млн токенов в год, попроще"},
	{"id": "google/gemma-4-26b-a4b-it", "prov": "or", "name": "Gemma 4 (OpenRouter)", "note": "~0,1 коп. за ход, при пустом балансе сама переходит на бесплатную"},
	{"id": "deepseek/deepseek-v4-flash", "prov": "or", "name": "DeepSeek V4 Flash (OpenRouter)", "note": "~0,1 коп. за ход"},
	{"id": "google/gemma-4-26b-a4b-it:free", "prov": "or", "name": "Gemma 4 бесплатно (OpenRouter)", "note": "0 ₽, но мало запросов в день"},
]
## GigaChat (Сбер): ключ авторизации -> токен на 30 минут -> запросы. Доступен из России без VPN.
const GC_OAUTH := "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
const GC_URLS := ["https://api.giga.chat/v1/chat/completions", "https://gigachat.devices.sberbank.ru/api/v1/chat/completions"]
## Корневой сертификат Минцифры: серверы Сбера подписаны им, а в общем наборе его нет. Берём с Госуслуг и храним у себя.
const RU_CA_URLS := ["https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt", "https://gu-st.ru/content/lending/russian_trusted_sub_ca_pem.crt"]
const GC_DOWNGRADE := {"GigaChat-2-Max": "GigaChat-2-Pro", "GigaChat-2-Pro": "GigaChat-2"}
const FREE_FALLBACK := "google/gemma-4-26b-a4b-it:free"

signal note(text: String)

var api_key := ""
var gc_key := ""
var _gc_token := ""
var _gc_exp := 0
var _gc_url := 0
var _ru_tls: TLSOptions = null   # null — пробуем обычную проверку сертификатов
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
	var cfg2 := ConfigFile.new()
	if cfg2.load("user://secrets.cfg") == OK:
		gc_key = str(cfg2.get_value("gigachat", "auth_key", ""))
	if OS.get_environment("GIGACHAT_AUTH_KEY") != "":
		gc_key = OS.get_environment("GIGACHAT_AUTH_KEY")
	_load_ru_ca()
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
	set_model(MODELS[(i + 1) % MODELS.size()].id)


func provider() -> String:
	return str(model_info().get("prov", "or"))


func has_key() -> bool:
	if mock:
		return true
	return not gc_key.is_empty() if provider() == "gc" else not api_key.is_empty()


## Что лежит в буфере: "or" — ключ OpenRouter, "gc" — ключ авторизации GigaChat, "" — не ключ.
static func key_kind(k: String) -> String:
	k = k.strip_edges()
	if k.begins_with("sk-or-"):
		return "or"
	if k.length() >= 40 and RegEx.create_from_string("^[A-Za-z0-9+/=]+$").search(k) != null:
		var dec := Marshalls.base64_to_raw(k).get_string_from_utf8()
		if dec.contains(":"):
			return "gc"
	return ""


func save_gc_key(key: String) -> void:
	gc_key = key.strip_edges()
	_gc_token = ""
	var cfg := ConfigFile.new()
	cfg.load("user://secrets.cfg")
	cfg.set_value("gigachat", "auth_key", gc_key)
	cfg.save("user://secrets.cfg")
	if provider() != "gc":
		set_model("GigaChat-2-Max")


func set_model(id: String) -> void:
	model = id
	_broke = false
	var sc := ConfigFile.new()
	sc.load("user://settings.cfg")
	sc.set_value("ai", "model", model)
	sc.save("user://settings.cfg")


func _load_ru_ca() -> void:
	if not FileAccess.file_exists("user://ru_ca.pem"):
		return
	var cert := X509Certificate.new()
	if cert.load("user://ru_ca.pem") == OK:
		_ru_tls = TLSOptions.client(cert)


## Скачать сертификат Минцифры (один раз), чтобы доверять серверам Сбера.
func _fetch_ru_ca() -> bool:
	var pem := ""
	for u in RU_CA_URLS:
		var http := HTTPRequest.new()
		http.timeout = 20.0
		add_child(http)
		if http.request(u) != OK:
			http.queue_free()
			continue
		var r: Array = await http.request_completed
		http.queue_free()
		var txt := (r[3] as PackedByteArray).get_string_from_utf8()
		if r[0] == HTTPRequest.RESULT_SUCCESS and int(r[1]) == 200 and txt.contains("BEGIN CERTIFICATE"):
			pem += txt.strip_edges() + "\n"
	if pem == "":
		return false
	var f := FileAccess.open("user://ru_ca.pem", FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(pem)
	f.close()
	_load_ru_ca()
	return _ru_tls != null


## Один HTTP-запрос с учётом сертификата Минцифры. Возвращает массив request_completed.
func _gc_http(url: String, headers: PackedStringArray, body: String) -> Array:
	# сначала обычная проверка (или уже скачанный сертификат Минцифры), при ошибке TLS — другой вариант
	var order := [_ru_tls != null, _ru_tls == null]
	var r: Array = [HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR, 0, PackedStringArray(), PackedByteArray()]
	for use_ru in order:
		if use_ru and _ru_tls == null and not await _fetch_ru_ca():
			continue
		var http := HTTPRequest.new()
		http.timeout = 60.0
		if use_ru:
			http.set_tls_options(_ru_tls)
		add_child(http)
		if http.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
			http.queue_free()
			return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
		r = await http.request_completed
		http.queue_free()
		if r[0] != HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return r
	return r


func _gc_auth() -> String:
	if _gc_token != "" and Time.get_unix_time_from_system() < _gc_exp - 60:
		return ""
	var rq := "%08x-%04x-4%03x-%04x-%012x" % [randi(), randi() & 0xFFFF, randi() & 0xFFF, (randi() & 0x3FFF) | 0x8000, (randi() << 16) ^ randi()]
	var headers := PackedStringArray(["Content-Type: application/x-www-form-urlencoded", "Accept: application/json",
		"RqUID: " + rq.left(36), "Authorization: Basic " + gc_key, "User-Agent: Chronicles"])
	var oauth := GC_OAUTH if OS.get_environment("ALIBI_GC_BASE") == "" else OS.get_environment("ALIBI_GC_BASE") + "/oauth"
	var r: Array = await _gc_http(oauth, headers, "scope=GIGACHAT_API_PERS")
	var data = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
	if r[0] == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
		return "не удалось проверить сертификат Сбера (нужен сертификат Минцифры, скачать его не вышло)"
	if r[0] != HTTPRequest.RESULT_SUCCESS:
		return "нет связи с GigaChat (код %d)" % r[0]
	if int(r[1]) != 200 or not (data is Dictionary) or str(data.get("access_token", "")) == "":
		return "ключ GigaChat не подошёл (HTTP %d)" % int(r[1])
	_gc_token = str(data.access_token)
	var exp := float(data.get("expires_at", 0))
	_gc_exp = int(exp / 1000.0) if exp > 1e11 else int(exp)
	if _gc_exp <= 0:
		_gc_exp = int(Time.get_unix_time_from_system()) + 1700
	return ""


func _gc_chat(messages: Array, temperature: float, max_tokens: int, retries: int) -> Dictionary:
	if gc_key.is_empty():
		return {"ok": false, "text": "", "error": "Нет ключа GigaChat"}
	var use := model
	for attempt in range(retries + 2):
		var ae: String = await _gc_auth()
		if ae != "":
			return {"ok": false, "text": "", "error": ae}
		var body := JSON.stringify({"model": use, "messages": messages, "temperature": clampf(temperature, 0.05, 1.5), "max_tokens": max_tokens})
		var headers := PackedStringArray(["Authorization: Bearer " + _gc_token, "Content-Type: application/json",
			"Accept: application/json", "User-Agent: Chronicles"])
		var url: String = GC_URLS[_gc_url] if OS.get_environment("ALIBI_GC_BASE") == "" else OS.get_environment("ALIBI_GC_BASE") + "/chat"
		var r: Array = await _gc_http(url, headers, body)
		var code: int = r[1]
		var data = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
		if r[0] == HTTPRequest.RESULT_SUCCESS and code == 200 and data is Dictionary and data.get("choices") is Array and (data.choices as Array).size() > 0:
			var c = data.choices[0].get("message", {}).get("content")
			var text := "" if c == null else str(c)
			if text.strip_edges() != "":
				return {"ok": true, "text": text, "error": ""}
			continue
		if code == 401:
			_gc_token = ""   # токен истёк раньше срока
			continue
		if code == 402 and GC_DOWNGRADE.has(use):
			var nxt: String = GC_DOWNGRADE[use]
			note.emit("Бесплатные токены %s на этот год кончились — ведущий перешёл на %s" % [use, nxt])
			set_model(nxt)
			use = nxt
			continue
		if code == 402:
			return {"ok": false, "text": "", "error": "бесплатные токены GigaChat кончились"}
		if (r[0] != HTTPRequest.RESULT_SUCCESS or code == 404) and _gc_url == 0:
			_gc_url = 1   # новый адрес недоступен — старый
			continue
		if attempt < retries + 1 and (r[0] != HTTPRequest.RESULT_SUCCESS or code in RETRY_CODES):
			await get_tree().create_timer(pow(2.0, attempt)).timeout
			continue
		var msg := "GigaChat: HTTP %d" % code if code != 0 else "GigaChat: нет сети (код %d)" % r[0]
		if data is Dictionary and data.has("message"):
			msg += ": " + str(data.message)
		return {"ok": false, "text": "", "error": msg}
	return {"ok": false, "text": "", "error": "GigaChat не ответил"}


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
	if provider() == "gc":
		return await _gc_chat(messages, temperature, max_tokens, retries)
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
