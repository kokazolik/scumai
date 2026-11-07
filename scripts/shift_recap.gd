extends RefCounted
class_name ShiftRecap
## Запись всех разговоров смены и «прикольные моменты» в конце.
## Лог смены: массив звонков {name, age, outcome, money, lines: [[кто, текст], ...]}.

const MAX_CHARS := 9000  # сколько текста смены отдаём модели


static func transcript(log: Array) -> String:
	var parts := []
	for i in log.size():
		var c: Dictionary = log[i]
		var t := "### Звонок %d: %s, %d лет. Итог: %s" % [i + 1, c["name"], c["age"], c["outcome"]]
		for l in c["lines"]:
			t += "\n%s: %s" % [l[0], l[1]]
		parts.append(t)
	var s := "\n\n".join(parts)
	if s.length() > MAX_CHARS:
		s = s.substr(s.length() - MAX_CHARS)
	return s


## Просит модель найти 3-5 смешных моментов. Возвращает массив {title, quote, comment}.
static func find_moments(log: Array) -> Array:
	var talk := 0
	for c in log:
		talk += c["lines"].size()
	if talk < 2:
		return []
	var sys := """Ты ведёшь ностальгическую рубрику «Лучшие моменты смены» в сатирической игре про телефонную контору-лохотрон.
Оператор (игрок, в логе «Вы») впаривает звонящим выдуманные услуги. Тебе дают записи разговоров за смену.
Найди 3-5 самых смешных, абсурдных или неловких моментов: странные выдуманные услуги, нелепые аргументы,
внезапные реакции клиентов, провалы и триумфы. Например: «Продал бабушке моральную поддержку за 3 000 ₽».
Для каждого момента:
- title: короткий смешной заголовок в прошедшем времени, до 60 символов;
- quote: точная короткая цитата из лога (до 140 символов), с именем говорящего в начале: «Имя: текст»;
- comment: одна тёплая ироничная фраза, как будто вспоминаешь это с улыбкой, до 120 символов.
Пиши по-русски. Не выдумывай реплик, которых нет в логе.
Ответь строго JSON без пояснений: {"moments":[{"title":"...","quote":"...","comment":"..."}]}"""
	var res: Dictionary = await LLM.chat([
		{"role": "system", "content": sys},
		{"role": "user", "content": transcript(log)},
	], 0.9, 900, 2)
	if not res["ok"]:
		return []
	return parse(str(res["text"]))


static func parse(raw: String) -> Array:
	var a := raw.find("{")
	var b := raw.rfind("}")
	if a == -1 or b <= a:
		return []
	var d = JSON.parse_string(raw.substr(a, b - a + 1))
	if not (d is Dictionary) or not (d.get("moments") is Array):
		return []
	var out := []
	for m in d["moments"]:
		if m is Dictionary and str(m.get("title", "")) != "":
			out.append({"title": str(m["title"]), "quote": str(m.get("quote", "")), "comment": str(m.get("comment", ""))})
	return out.slice(0, 5)
