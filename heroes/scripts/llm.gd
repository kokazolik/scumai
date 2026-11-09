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
## Промежуточные сертификаты Минцифры по обычному http (подлинность всё равно проверяется по вшитому корню).
const RU_CA_URLS := ["http://reestr-pki.ru/cdp/subca_ssl_rsa2022.crt", "http://reestr-pki.ru/cdp/subca_ssl_rsa2024.crt",
	"http://reestr-pki.ru/cdp/subca_ssl_rsa2025.crt", "http://reestr-pki.ru/cdp/subca_ssl_rsa2026.crt",
	"http://company.rt.ru/cdp/subca_ssl_rsa2022.crt", "http://company.rt.ru/cdp/subca_ssl_rsa2024.crt",
	"https://gu-st.ru/content/lending/russian_trusted_sub_ca_pem.crt"]
## Свой сервер-посредник (Yandex Cloud Functions, код в server/gigachat_proxy): телефон ходит на него,
## а он — в Сбер с правильной проверкой сертификата. Пусто — пока не задан; адрес можно вставить в игре.
const DEFAULT_GC_PROXY := ""
const GC_DOWNGRADE := {"GigaChat-2-Max": "GigaChat-2-Pro", "GigaChat-2-Pro": "GigaChat-2"}
const FREE_FALLBACK := "google/gemma-4-26b-a4b-it:free"

signal note(text: String)

var api_key := ""
var gc_key := ""
var gc_proxy := DEFAULT_GC_PROXY   # адрес посредника; "#пароль" в конце — X-App-Token
var _gc_token := ""
var _gc_exp := 0
var _gc_url := 0
var _gc_tls_mode := -1   # какой способ проверки сертификата сработал в прошлый раз
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
		gc_proxy = str(cfg2.get_value("gigachat", "proxy", gc_proxy))
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
	return not (gc_key.is_empty() and gc_proxy.is_empty()) if provider() == "gc" else not api_key.is_empty()


## Что лежит в буфере: "or" — ключ OpenRouter, "gc" — ключ авторизации GigaChat, "" — не ключ.
static func key_kind(k: String) -> String:
	k = k.strip_edges()
	if k.begins_with("https://") and not k.contains(" "):
		return "proxy"
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


func save_gc_proxy(url: String) -> void:
	gc_proxy = url.strip_edges()
	var cfg := ConfigFile.new()
	cfg.load("user://secrets.cfg")
	cfg.set_value("gigachat", "proxy", gc_proxy)
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
	var pem := RU_CA_PEM
	if FileAccess.file_exists("user://ru_extra.pem"):
		pem += "\n" + FileAccess.get_file_as_string("user://ru_extra.pem")
	var cert := X509Certificate.new()
	if cert.load_from_string(pem) == OK:
		_ru_tls = TLSOptions.client(cert)
		return
	cert = X509Certificate.new()
	if cert.load_from_string(RU_CA_PEM) == OK:
		_ru_tls = TLSOptions.client(cert)


static func _der_to_pem(raw: PackedByteArray) -> String:
	var txt := raw.get_string_from_utf8()
	if txt.contains("BEGIN CERTIFICATE"):
		return txt.strip_edges() + "\n"
	if raw.size() < 100 or raw[0] != 0x30:
		return ""
	var b := Marshalls.raw_to_base64(raw)
	var out := "-----BEGIN CERTIFICATE-----\n"
	for i in range(0, b.length(), 64):
		out += b.substr(i, 64) + "\n"
	return out + "-----END CERTIFICATE-----\n"


var _extra_tried := false

## Докачать промежуточные сертификаты Минцифры (если сервер Сбера их не присылает). Возвращает, сколько нашлось.
func _fetch_ru_ca() -> int:
	_extra_tried = true
	var pem := ""
	var n := 0
	for u in RU_CA_URLS:
		var http := HTTPRequest.new()
		http.timeout = 10.0
		add_child(http)
		if http.request(u) != OK:
			http.queue_free()
			continue
		var r: Array = await http.request_completed
		http.queue_free()
		if r[0] != HTTPRequest.RESULT_SUCCESS or int(r[1]) != 200:
			continue
		var one := _der_to_pem(r[3])
		var test := X509Certificate.new()
		if one != "" and test.load_from_string(one) == OK and not pem.contains(one):
			pem += one
			n += 1
	if n == 0:
		return 0
	var f := FileAccess.open("user://ru_extra.pem", FileAccess.WRITE)
	if f == null:
		return 0
	f.store_string(pem)
	f.close()
	_load_ru_ca()
	return n


## Один HTTP-запрос с учётом сертификата Минцифры. Возвращает массив request_completed.
func _gc_http(url: String, headers: PackedStringArray, body: String) -> Array:
	# сначала обычная проверка (или уже скачанный сертификат Минцифры), при ошибке TLS — другой вариант
	# 0 — обычная проверка, 1 — сертификат Минцифры, 2 — без проверки сертификата (крайний случай,
	# выбран автором: на некоторых телефонах цепочка Сбера не проходит проверку движка)
	var order: Array = [1, 0, 2] if _ru_tls != null else [0, 1, 2]
	if _gc_tls_mode >= 0:
		order.erase(_gc_tls_mode)
		order.push_front(_gc_tls_mode)
	var r: Array = [HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR, 0, PackedStringArray(), PackedByteArray()]
	for mode in order:
		if mode == 1 and _ru_tls == null:
			continue
		var http := HTTPRequest.new()
		http.timeout = 60.0
		if mode == 1:
			http.set_tls_options(_ru_tls)
		elif mode == 2:
			# в Godot 4.3 проверка отключается, только если передать какую-нибудь цепочку
			var any_ca := X509Certificate.new()
			any_ca.load_from_string(RU_CA_PEM)
			http.set_tls_options(TLSOptions.client_unsafe(any_ca))
		add_child(http)
		if http.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
			http.queue_free()
			return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
		r = await http.request_completed
		http.queue_free()
		if r[0] != HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			_gc_tls_mode = mode
			return r
		if mode == 1 and not _extra_tried and await _fetch_ru_ca() > 0:
			return await _gc_http(url, headers, body)   # с докачанными сертификатами — ещё раз
	return r


## Проверка связи со Сбером: какие способы подключения проходят. Текст для пересылки разработчику.
func gc_diagnose() -> String:
	var lines := PackedStringArray(["Godot " + Engine.get_version_info().string + ", " + OS.get_name()])
	if not gc_proxy.is_empty():
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = await _gc_chat([{"role": "user", "content": "Ответь одним словом: привет"}], 0.3, 10, 0)
		lines.append("сервер-посредник: %s (%.1f с)" % ["✔ " + str(r.text).strip_edges().left(20) if r.ok else "✘ " + str(r.error).left(80), (Time.get_ticks_msec() - t0) / 1000.0])
	else:
		lines.append("сервер-посредник: не задан")
	var n := await _fetch_ru_ca()
	lines.append("доп. сертификаты Минцифры: %d" % n)
	var any_ca := X509Certificate.new()
	any_ca.load_from_string(RU_CA_PEM)
	var modes := {"обычн": TLSOptions.client(), "Минцифры": _ru_tls, "без проверки": TLSOptions.client_unsafe(any_ca)}
	for hp in [["ngw.devices.sberbank.ru", 9443], ["gigachat.devices.sberbank.ru", 443], ["api.giga.chat", 443]]:
		var line: String = "%s:%d —" % hp
		for mname in modes:
			line += " %s %s" % [mname, await _tls_probe(hp[0], hp[1], modes[mname])]
		lines.append(line)
	return "\n".join(lines)


func _tls_probe(host: String, port: int, opts: TLSOptions) -> String:
	if opts == null:
		return "—"
	var tcp := StreamPeerTCP.new()
	var ip := IP.resolve_hostname(host, IP.TYPE_ANY)
	if ip == "":
		return "нет DNS"
	if tcp.connect_to_host(ip, port) != OK:
		return "нет TCP"
	var t0 := Time.get_ticks_msec()
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - t0 < 8000:
		tcp.poll()
		await get_tree().process_frame
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return "нет TCP"
	var tls := StreamPeerTLS.new()
	if tls.connect_to_stream(tcp, host, opts) != OK:
		return "✘"
	while tls.get_status() == StreamPeerTLS.STATUS_HANDSHAKING and Time.get_ticks_msec() - t0 < 12000:
		tls.poll()
		await get_tree().process_frame
	var ok := tls.get_status() == StreamPeerTLS.STATUS_CONNECTED
	tls.disconnect_from_stream()
	return "✔" if ok else "✘"


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
		return "не удалось проверить сертификат Сбера (проверь дату и время на телефоне)"
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
	if gc_key.is_empty() and gc_proxy.is_empty():
		return {"ok": false, "text": "", "error": "Нет ключа GigaChat"}
	var use := model
	var via_proxy := not gc_proxy.is_empty()
	for attempt in range(retries + 2):
		var body := JSON.stringify({"model": use, "messages": messages, "temperature": clampf(temperature, 0.05, 1.5), "max_tokens": max_tokens})
		var r: Array
		if via_proxy:
			var parts := gc_proxy.split("#", true, 1)
			var ph := PackedStringArray(["Content-Type: application/json", "Accept: application/json", "User-Agent: Chronicles"])
			# ключ телефона серверу не шлём: у сервера свой (в переменных функции), а старый ключ на телефоне мог устареть
			if parts.size() > 1 and parts[1] != "":
				ph.append("X-App-Token: " + parts[1])
			var http := HTTPRequest.new()
			http.timeout = 90.0
			add_child(http)
			if http.request(parts[0], ph, HTTPClient.METHOD_POST, body) != OK:
				http.queue_free()
				return {"ok": false, "text": "", "error": "неверный адрес сервера GigaChat"}
			r = await http.request_completed
			http.queue_free()
		else:
			var ae: String = await _gc_auth()
			if ae != "":
				return {"ok": false, "text": "", "error": ae}
			var headers := PackedStringArray(["Authorization: Bearer " + _gc_token, "Content-Type: application/json",
				"Accept: application/json", "User-Agent: Chronicles"])
			var url: String = GC_URLS[_gc_url] if OS.get_environment("ALIBI_GC_BASE") == "" else OS.get_environment("ALIBI_GC_BASE") + "/chat"
			r = await _gc_http(url, headers, body)
		var code: int = r[1]
		var data = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
		if r[0] == HTTPRequest.RESULT_SUCCESS and code == 200 and data is Dictionary and data.get("choices") is Array and (data.choices as Array).size() > 0:
			var c = data.choices[0].get("message", {}).get("content")
			var text := "" if c == null else str(c)
			if data.get("usage") is Dictionary:
				_count_tokens(int(data.usage.get("total_tokens", 0)))
			if text.strip_edges() != "":
				return {"ok": true, "text": text, "error": ""}
			continue
		if code == 401 and via_proxy:
			return {"ok": false, "text": "", "error": "сервер GigaChat не принял ключ"}
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
		if not via_proxy and (r[0] != HTTPRequest.RESULT_SUCCESS or code == 404) and _gc_url == 0:
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


## Сколько токенов GigaChat потрачено в этом году (бесплатно — 25 млн на Max/Pro/Lite в год).
func gc_tokens_used() -> int:
	var sc := ConfigFile.new()
	sc.load("user://settings.cfg")
	if int(sc.get_value("ai", "tokens_year", 0)) != Time.get_date_dict_from_system().year:
		return 0
	return int(sc.get_value("ai", "tokens_used", 0))


func _count_tokens(n: int) -> void:
	if n <= 0:
		return
	var sc := ConfigFile.new()
	sc.load("user://settings.cfg")
	var y: int = Time.get_date_dict_from_system().year
	var used := int(sc.get_value("ai", "tokens_used", 0)) if int(sc.get_value("ai", "tokens_year", 0)) == y else 0
	sc.set_value("ai", "tokens_year", y)
	sc.set_value("ai", "tokens_used", used + n)
	sc.save("user://settings.cfg")


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
	if sys.contains("Сейчас ночь в лагере"):
		return JSON.stringify({"story": "У костра Серый рассказывает о брате, пропавшем на болотах. На рассвете туман редеет.", "options": opts,
			"approval": [{"who": "Серый", "d": 2, "why": "вы пощадили пленного"}], "rest": "long", "combat": [{"id": "goblin", "count": 1}],
			"quests": [{"title": "Личное: Серый — найти брата", "status": "new", "steps": ["Расспросить на болотах"]}]})
	var turn := randi() % 4
	var d := {"story": "Мир живёт своей жизнью. Что дальше?", "changes": [], "options": opts,
		"place": null, "quest": "", "chest": "", "shop": "", "combat": [], "rest": ""}
	if user.contains("ТАЙНО"):
		for n in names:
			d["secret"] = {n: "Втайне ты находишь под половицей записку с печатью."}
			break
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
		d.companions = [{"name": "Серый", "kind": "волк", "monster": "wolf", "owner": names[0] if names.size() > 0 else "", "about": "угрюмый волк, ищет стаю"}]
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


## Публичные корневой и промежуточные сертификаты Минцифры (Russian Trusted Root CA / Sub CA).
## Нужны, чтобы доверять серверам Сбера. Секретов тут нет.
const RU_CA_PEM := """-----BEGIN CERTIFICATE-----
MIIFwjCCA6qgAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUx
PzA9BgNVBAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFu
ZCBDb21tdW5pY2F0aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3Qg
Q0EwHhcNMjIwMzAxMjEwNDE1WhcNMzIwMjI3MjEwNDE1WjBwMQswCQYDVQQGEwJS
VTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQg
YW5kIENvbW11bmljYXRpb25zMSAwHgYDVQQDDBdSdXNzaWFuIFRydXN0ZWQgUm9v
dCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMfFOZ8pUAL3+r2n
qqE0Zp52selXsKGFYoG0GM5bwz1bSFtCt+AZQMhkWQheI3poZAToYJu69pHLKS6Q
XBiwBC1cvzYmUYKMYZC7jE5YhEU2bSL0mX7NaMxMDmH2/NwuOVRj8OImVa5s1F4U
zn4Kv3PFlDBjjSjXKVY9kmjUBsXQrIHeaqmUIsPIlNWUnimXS0I0abExqkbdrXbX
YwCOXhOO2pDUx3ckmJlCMUGacUTnylyQW2VsJIyIGA8V0xzdaeUXg0VZ6ZmNUr5Y
Ber/EAOLPb8NYpsAhJe2mXjMB/J9HNsoFMBFJ0lLOT/+dQvjbdRZoOT8eqJpWnVD
U+QL/qEZnz57N88OWM3rabJkRNdU/Z7x5SFIM9FrqtN8xewsiBWBI0K6XFuOBOTD
4V08o4TzJ8+Ccq5XlCUW2L48pZNCYuBDfBh7FxkB7qDgGDiaftEkZZfApRg2E+M9
G8wkNKTPLDc4wH0FDTijhgxR3Y4PiS1HL2Zhw7bD3CbslmEGgfnnZojNkJtcLeBH
BLa52/dSwNU4WWLubaYSiAmA9IUMX1/RpfpxOxd4Ykmhz97oFbUaDJFipIggx5sX
ePAlkTdWnv+RWBxlJwMQ25oEHmRguNYf4Zr/Rxr9cS93Y+mdXIZaBEE0KS2iLRqa
OiWBki9IMQU4phqPOBAaG7A+eP8PAgMBAAGjZjBkMB0GA1UdDgQWBBTh0YHlzlpf
BKrS6badZrHF+qwshzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzAS
BgNVHRMBAf8ECDAGAQH/AgEEMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsF
AAOCAgEAALIY1wkilt/urfEVM5vKzr6utOeDWCUczmWX/RX4ljpRdgF+5fAIS4vH
tmXkqpSCOVeWUrJV9QvZn6L227ZwuE15cWi8DCDal3Ue90WgAJJZMfTshN4OI8cq
W9E4EG9wglbEtMnObHlms8F3CHmrw3k6KmUkWGoa+/ENmcVl68u/cMRl1JbW2bM+
/3A+SAg2c6iPDlehczKx2oa95QW0SkPPWGuNA/CE8CpyANIhu9XFrj3RQ3EqeRcS
AQQod1RNuHpfETLU/A2gMmvn/w/sx7TB3W5BPs6rprOA37tutPq9u6FTZOcG1Oqj
C/B7yTqgI7rbyvox7DEXoX7rIiEqyNNUguTk/u3SZ4VXE2kmxdmSh3TQvybfbnXV
4JbCZVaqiZraqc7oZMnRoWrXRG3ztbnbes/9qhRGI7PqXqeKJBztxRTEVj8ONs1d
WN5szTwaPIvhkhO3CO5ErU2rVdUr89wKpNXbBODFKRtgxUT70YpmJ46VVaqdAhOZ
D9EUUn4YaeLaS8AjSF/h7UkjOibNc4qVDiPP+rkehFWM66PVnP1Msh93tc+taIfC
EYVMxjh8zNbFuoc7fzvvrFILLe7ifvEIUqSVIC/AzplM/Jxw7buXFeGP1qVCBEHq
391d/9RAfaZ12zkwFsl+IKwE/OZxW8AHa9i1p4GO0YSNuczzEm4=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIG6DCCBNCgAwIBAgICEAUwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUx
PzA9BgNVBAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFu
ZCBDb21tdW5pY2F0aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3Qg
Q0EwHhcNMjQwNzE1MTI1MDQxWhcNMjkwNzE5MTI1MDQxWjBvMQswCQYDVQQGEwJS
VTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQg
YW5kIENvbW11bmljYXRpb25zMR8wHQYDVQQDDBZSdXNzaWFuIFRydXN0ZWQgU3Vi
IENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA1j0rkZECOt1S8o7I
JY+4YKAxuEa5xaHKHXT2EpkuC/0krqMOjUy2oPIRNgR5g8X0Jl6jamxeGLc4Q1tf
ju6or9oSRYThIUhRsFDQNBiBBEXoBgWxTfiKB2eyT97+pz5TBtBiRCPaLGRHYLRb
9Jz2HkJlxbtNPjtDrF5DPHym+mZ1M1z3hIQYAqJwLpsEBnsw/VxWMlxqHoeewd0h
uJMd71KQ5vOKlz7KrIZ6EobNNa6wItuvsfj3kYCK7O78uLHGXXFxdr8Hae9lMUmC
8F7AFwa+bO1LRlTlqW7rE3rLf+jj70N01N8T3o22v14YBaFBWQWncAVYD2JuL3tH
252+kdNOERf1fLbLRigJAbd+hOhWYlNf963TFDgnNPliHNIW72SygVBnI2V3JwO1
dp1hVKpK/zt8ziGdHW4gmOLTsH50YKdR4jNqUgQv4wASlKn9OpN6zHYc5G8h86fY
BM+zxE5ikGI+I/vIqBuI0eaDU92AWN/YjFLpu8tMu9kLRSCf1vug6FIfDPWVo7iP
ac/SI2v8jnnpaW7ph/Pz3WkzaG7ZZJsfFs+8dploWc6LOoDtbFBhMdGMxu024msC
0PSjZb5ODXPIaO2NsA7fMiAtZcoK6anTUJh4zOP/stA9qsJGNxdrEmiPXSmBZY/N
Y0wkZgZ6JTDhw7038bPvctkblJkCAwEAAaOCAYswggGHMB0GA1UdDgQWBBR3Pdk5
r0K93FvKduru/c4+YSkwXzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qws
hzAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADCBmAYIKwYBBQUH
AQEEgYswgYgwQAYIKwYBBQUHMAKGNGh0dHA6Ly9udWMtY2RwLnZvc2tob2QucnUv
Y2RwL3Jvb3RjYV9zc2xfcnNhMjAyMi5jcnQwRAYIKwYBBQUHMAKGOGh0dHA6Ly9u
dWMtY2RwLmRpZ2l0YWwuZ292LnJ1L2NkcC9yb290Y2Ffc3NsX3JzYTIwMjIuY3J0
MIGFBgNVHR8EfjB8MDqgOKA2hjRodHRwOi8vbnVjLWNkcC52b3NraG9kLnJ1L2Nk
cC9yb290Y2Ffc3NsX3JzYTIwMjIuY3JsMD6gPKA6hjhodHRwOi8vbnVjLWNkcC5k
aWdpdGFsLmdvdi5ydS9jZHAvcm9vdGNhX3NzbF9yc2EyMDIyLmNybDANBgkqhkiG
9w0BAQsFAAOCAgEAmsINXtQ7wwUWvIeOr80MdJS/5G4xhyZOVEmeUorThquT672y
cCg3XCxc4fwbiZqSSbBqntQ7RtiTAKMYMvBageKoVHbzz+R4jX01tKcTx8cDePrz
dJ73bLNUorE7RU9QsW4KyiUeRmjMDV23AUlEvuQFTwgkHXvbac1BBdPn9CrssQuF
5EGohZKcQPFiAAc4SHbRNhlr7uAwgpc/erzI9EAcvA6BVAXcVKoeGpV01uexUgZ6
St5RP9UmDWNA7T4yVXWJ233N0Q8bl+6AswINQ3PosPu6yQQHQjr65YS06epK+AeI
6j+oGR4xI7EhTQhQvaobnGmX/8QQ7XDRYCP2HXYxiffnn/CfZ/BVyKLYeY1ZipjE
nzqdQIC2+Q3WtY8jsVRQMP38WFRmtsIt5snehnPTs5bKGVIcYzj3o3Ex/K7agEz0
zAJ0JR5ivXZOvNkT0g9x1v+S1IkU3e/nX1a+tpRquMtnHX0L2lXArNHUbaOO9EJt
d57WaIpofV5cVhhwShOgAuBc9UMJF3/n4t4RKiPxtsK8P67gcmphMhslj7AMYrYM
ej2NvQZY4m3ub3CPC/PrTjDONvb+8g5xrKtxBjYqC74HSB4dg9G3WimSDUuP2Su6
G2y2TUeyJuCvCLz289VoO0vg7cNdMobE3KCqAiiNhN2VBFxHAUKmUoRcRdw=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIHQjCCBSqgAwIBAgICEAIwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUx
PzA9BgNVBAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFu
ZCBDb21tdW5pY2F0aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3Qg
Q0EwHhcNMjIwMzAyMTEyNTE5WhcNMjcwMzA2MTEyNTE5WjBvMQswCQYDVQQGEwJS
VTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQg
YW5kIENvbW11bmljYXRpb25zMR8wHQYDVQQDDBZSdXNzaWFuIFRydXN0ZWQgU3Vi
IENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA9YPqBKOk19NFymrE
wehzrhBEgT2atLezpduB24mQ7CiOa/HVpFCDRZzdxqlh8drku408/tTmWzlNH/br
HuQhZ/miWKOf35lpKzjyBd6TPM23uAfJvEOQ2/dnKGGJbsUo1/udKSvxQwVHpVv3
S80OlluKfhWPDEXQpgyFqIzPoxIQTLZ0deirZwMVHarZ5u8HqHetRuAtmO2ZDGQn
vVOJYAjls+Hiueq7Lj7Oce7CQsTwVZeP+XQx28PAaEZ3y6sQEt6rL06ddpSdoTMp
BnCqTbxW+eWMyjkIn6t9GBtUV45yB1EkHNnj2Ex4GwCiN9T84QQjKSr+8f0psGrZ
vPbCbQAwNFJjisLixnjlGPLKa5vOmNwIh/LAyUW5DjpkCx004LPDuqPpFsKXNKpa
L2Dm6uc0x4Jo5m+gUTVORB6hOSzWnWDj2GWfomLzzyjG81DRGFBpco/O93zecsIN
3SL2Ysjpq1zdoS01CMYxie//9zWvYwzI25/OZigtnpCIrcd2j1Y6dMUFQAzAtHE+
qsXflSL8HIS+IJEFIQobLlYhHkoE3avgNx5jlu+OLYe0dF0Ykx1PGNjbwqvTX37R
Cn32NMjlotW2QcGEZhDKj+3urZizp5xdTPZitA+aEjZM/Ni71VOdiOP0igbw6asZ
2fxdozZ1TnSSYNYvNATwthNmZysCAwEAAaOCAeUwggHhMBIGA1UdEwEB/wQIMAYB
Af8CAQAwDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBTR4XENCy2BTm6KSo9MI7NM
XqtpCzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzCBxwYIKwYBBQUH
AQEEgbowgbcwOwYIKwYBBQUHMAKGL2h0dHA6Ly9yb3N0ZWxlY29tLnJ1L2NkcC9y
b290Y2Ffc3NsX3JzYTIwMjIuY3J0MDsGCCsGAQUFBzAChi9odHRwOi8vY29tcGFu
eS5ydC5ydS9jZHAvcm9vdGNhX3NzbF9yc2EyMDIyLmNydDA7BggrBgEFBQcwAoYv
aHR0cDovL3JlZXN0ci1wa2kucnUvY2RwL3Jvb3RjYV9zc2xfcnNhMjAyMi5jcnQw
gbAGA1UdHwSBqDCBpTA1oDOgMYYvaHR0cDovL3Jvc3RlbGVjb20ucnUvY2RwL3Jv
b3RjYV9zc2xfcnNhMjAyMi5jcmwwNaAzoDGGL2h0dHA6Ly9jb21wYW55LnJ0LnJ1
L2NkcC9yb290Y2Ffc3NsX3JzYTIwMjIuY3JsMDWgM6Axhi9odHRwOi8vcmVlc3Ry
LXBraS5ydS9jZHAvcm9vdGNhX3NzbF9yc2EyMDIyLmNybDANBgkqhkiG9w0BAQsF
AAOCAgEARBVzZls79AdiSCpar15dA5Hr/rrT4WbrOfzlpI+xrLeRPrUG6eUWIW4v
Sui1yx3iqGLCjPcKb+HOTwoRMbI6ytP/ndp3TlYua2advYBEhSvjs+4vDZNwXr/D
anbwIWdurZmViQRBDFebpkvnIvru/RpWud/5r624Wp8voZMRtj/cm6aI9LtvBfT9
cfzhOaexI/99c14dyiuk1+6QhdwKaCRTc1mdfNQmnfWNRbfWhWBlK3h4GGE9JK33
Gk8ZS8DMrkdAh0xby4xAQ/mSWAfWrBmfzlOqGyoB1U47WTOeqNbWkkoAP2ys94+s
Jg4NTkiDVtXRF6nr6fYi0bSOvOFg0IQrMXO2Y8gyg9ARdPJwKtvWX8VPADCYMiWH
h4n8bZokIrImVKLDQKHY4jCsND2HHdJfnrdL2YJw1qFskNO4cSNmZydw0Wkgjv9k
F+KxqrDKlB8MZu2Hclph6v/CZ0fQ9YuE8/lsHZ0Qc2HyiSMnvjgK5fDc3TD4fa8F
E8gMNurM+kV8PT8LNIM+4Zs+LKEV8nqRWBaxkIVJGekkVKO8xDBOG/aN62AZKHOe
GcyIdu7yNMMRihGVZCYr8rYiJoKiOzDqOkPkLOPdhtVlgnhowzHDxMHND/E2WA5p
ZHuNM/m0TXt2wTTPL7JH2YC0gPz/BvvSzjksgzU5rLbRyUKQkgU=
-----END CERTIFICATE-----
"""
