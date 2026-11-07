extends Node
## Клиент OpenRouter. Модель: google/gemma-4-26b-a4b-it (быстрая, ~1 с на ответ). Подключён как автозагрузка "LLM".
##
## Ключ ищется так:
##   1) переменная окружения OPENROUTER_API_KEY;
##   2) файл user://secrets.cfg, секция [openrouter], ключ api_key.
## Не кладите ключ в res:// — он попадёт в собранную игру и в git.
##
## Запасной вариант: "google/gemini-2.5-flash-lite" (так же быстро, в 2 раза дороже).
## Модели с обязательным рассуждением (например liquid/lfm-3-1.7b) отвечают
## 20-80 секунд; для них поднимите max_tokens до 2500 и timeout до 150.

const API_URL := "https://openrouter.ai/api/v1/chat/completions"
const MODEL := "google/gemma-4-26b-a4b-it"
const RETRY_CODES := [429, 500, 502, 503, 504]

var api_key := ""


func _ready() -> void:
	api_key = OS.get_environment("OPENROUTER_API_KEY")
	if api_key.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load("user://secrets.cfg") == OK:
			api_key = str(cfg.get_value("openrouter", "api_key", ""))
	if api_key.is_empty():
		api_key = _embedded_key()
	if api_key.is_empty():
		push_warning("OpenRouter: ключ не найден (OPENROUTER_API_KEY или user://secrets.cfg)")


## Ключ, вшитый при сборке APK (файл scripts/embedded_key.gd не хранится в git).
## Он лишь слегка спрятан (XOR), из APK его всё равно можно достать,
## поэтому для сборки нужен отдельный ключ с лимитом трат.
func _embedded_key() -> String:
	var path := "res://scripts/embedded_key.gd"
	if not ResourceLoader.exists(path):
		return ""
	var k = load(path)
	var data: Array = k.DATA
	var mask: Array = k.MASK
	var out := PackedByteArray()
	for i in data.size():
		out.append(int(data[i]) ^ int(mask[i % mask.size()]))
	return out.get_string_from_utf8()


## Сохраняет ключ, введённый в игре, в user://secrets.cfg (на телефоне это личная папка приложения).
func save_key(key: String) -> void:
	api_key = key.strip_edges()
	var cfg := ConfigFile.new()
	cfg.load("user://secrets.cfg")
	cfg.set_value("openrouter", "api_key", api_key)
	cfg.save("user://secrets.cfg")


## Отправляет сообщения и возвращает {"ok": bool, "text": String, "error": String}.
## Использование: var res = await LLM.chat([{"role": "user", "content": "Привет"}])
func chat(messages: Array, temperature := 0.8, max_tokens := 400, retries := 3, model := MODEL) -> Dictionary:
	if api_key.is_empty():
		return {"ok": false, "text": "", "error": "Нет API-ключа OpenRouter"}

	var body := JSON.stringify({
		"model": model,
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

		# result, response_code, headers, body
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
				continue  # пустой ответ, пробуем ещё
			return {"ok": true, "text": text, "error": ""}

		var retryable: bool = r[0] != HTTPRequest.RESULT_SUCCESS or code in RETRY_CODES
		if retryable and attempt < retries:
			await get_tree().create_timer(pow(2.0, attempt)).timeout
			continue

		var msg := "HTTP %d" % code if code != 0 else "нет сети (код %d)" % r[0]
		if data is Dictionary and data.has("error"):
			msg += ": " + str(data["error"].get("message", ""))
		return {"ok": false, "text": "", "error": msg}

	return {"ok": false, "text": "", "error": "Не удалось получить ответ"}

