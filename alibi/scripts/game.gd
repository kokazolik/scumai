extends Node
## Логика «Алиби». Хост ведёт игру и вызывает нейронку, клиенты получают состояние целиком.
##
## Фазы: lobby → loading → plot (сговор, общий чат) → question (тайные ответы)
##       → judging → verdict (все ответы и реплика следователя) → question … → final → end.

signal state_changed

const ROUNDS := 6
const PLOT_TIME := 120.0
const ANSWER_TIME := 75.0
const VERDICT_TIME := 25.0
const START_SUSPICION := 20

var phase := "lobby"
var state := {}           # то, что видят все
var deadline_msec := 0    # локальный момент конца таймера (0 = нет таймера)

# только у хоста
var _answers := {}        # peer_id -> текст, пока идёт вопрос
var _busy := false


func _ready() -> void:
	reset_local()


func reset_local() -> void:
	phase = "lobby"
	state = _fresh_state()
	deadline_msec = 0
	_answers = {}
	_busy = false
	state_changed.emit()


func _fresh_state() -> Dictionary:
	return {"phase": "lobby", "case": {}, "round": 0, "rounds": ROUNDS, "suspicion": START_SUSPICION,
		"question": "", "answered": [], "ready": [], "history": [], "chat": [],
		"result": "", "speech": "", "error": "", "time_left": 0.0}


func time_left() -> float:
	if deadline_msec <= 0:
		return 0.0
	return maxf(0.0, (deadline_msec - Time.get_ticks_msec()) / 1000.0)


# ---------- синхронизация ----------

func _broadcast() -> void:
	state.time_left = time_left()
	_sync.rpc(state)


func send_state_to(id: int) -> void:
	state.time_left = time_left()
	_sync.rpc_id(id, state)


@rpc("authority", "call_local", "reliable")
func _sync(s: Dictionary) -> void:
	state = s
	phase = str(s.phase)
	var tl := float(s.get("time_left", 0.0))
	deadline_msec = Time.get_ticks_msec() + int(tl * 1000.0) if tl > 0.0 else 0
	state_changed.emit()


# ---------- запросы игроков к хосту ----------

func send_chat(text: String) -> void:
	text = text.strip_edges().left(200)
	if text != "":
		_chat.rpc_id(1, text)


func send_answer(text: String) -> void:
	_answer.rpc_id(1, text.strip_edges().left(300))


func press_ready() -> void:
	_ready_press.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _chat(text: String) -> void:
	if not Net.is_host():
		return
	if phase == "question" or phase == "judging":
		return  # во время допроса шептаться нельзя
	var id := _sender()
	state.chat.append({"n": Net.players.get(id, "?"), "t": text, "id": id})
	if state.chat.size() > 80:
		state.chat = state.chat.slice(-80)
	_broadcast()


@rpc("any_peer", "call_local", "reliable")
func _answer(text: String) -> void:
	if not Net.is_host() or phase != "question":
		return
	var id := _sender()
	if _answers.has(id):
		return
	_answers[id] = text
	state.answered.append(id)
	if _everyone_in(state.answered):
		_judge()
	else:
		_broadcast()


@rpc("any_peer", "call_local", "reliable")
func _ready_press() -> void:
	if not Net.is_host() or not (phase in ["plot", "verdict"]):
		return
	var id := _sender()
	if not (id in state.ready):
		state.ready.append(id)
	if _everyone_in(state.ready):
		_advance()
	else:
		_broadcast()


func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return 1 if id == 0 else id


func _everyone_in(ids: Array) -> bool:
	for id in Net.players.keys():
		if not (id in ids):
			return false
	return true


func on_player_left(_id: int) -> void:
	if phase == "question" and _everyone_in(state.answered):
		_judge()
	elif phase in ["plot", "verdict"] and _everyone_in(state.ready):
		_advance()


# ---------- ход игры (хост) ----------

func _process(_d: float) -> void:
	if not Net.is_host() or _busy or deadline_msec <= 0:
		return
	if Time.get_ticks_msec() >= deadline_msec:
		deadline_msec = 0
		if phase == "question":
			_judge()
		else:
			_advance()


func _set_phase(p: String, seconds := 0.0) -> void:
	phase = p
	state.phase = p
	state.ready = []
	deadline_msec = Time.get_ticks_msec() + int(seconds * 1000.0) if seconds > 0.0 else 0
	_broadcast()


func start_game() -> void:
	if not Net.is_host() or _busy:
		return
	var chat: Array = state.chat
	state = _fresh_state()
	state.chat = chat.slice(-10)
	_busy = true
	_set_phase("loading")
	var res: Dictionary = await LLM.chat_json(_case_prompt(), 1.0, 700)
	_busy = false
	if not res.ok or str(res.data.get("crime", "")) == "":
		state.error = "Нейронка не ответила: %s" % res.error
		_set_phase("lobby")
		return
	var d: Dictionary = res.data
	state.case = {
		"title": str(d.get("title", "Дело №%d" % randi_range(100, 999))),
		"crime": str(d.get("crime", "")),
		"detective": str(d.get("detective", "следователь Сидоров")),
		"style": str(d.get("style", "строго")),
		"hint": str(d.get("hint", "")),
	}
	state.question = str(d.get("question", "Где вы были в момент преступления?"))
	state.chat = []
	_set_phase("plot", PLOT_TIME)


func _advance() -> void:
	match phase:
		"plot":
			_start_question()
		"verdict":
			if int(state.suspicion) >= 100 or int(state.round) >= ROUNDS:
				_finish()
			else:
				_start_question()


func _start_question() -> void:
	state.round = int(state.round) + 1
	state.answered = []
	_answers = {}
	_set_phase("question", ANSWER_TIME)


func _judge() -> void:
	if _busy or phase != "question":
		return
	_busy = true
	var answers := {}
	for id in Net.players.keys():
		var t := str(_answers.get(id, "")).strip_edges()
		answers[Net.players[id]] = t if t != "" else "(молчит)"
	_set_phase("judging")
	var res: Dictionary = await LLM.chat_json(_judge_prompt(answers), 0.8, 600)
	_busy = false
	if not Net.is_host():
		return
	var delta := 10
	var comment := "Хм. Я всё записал."
	var next_q := "Повторите-ка ещё раз, что вы делали в тот вечер?"
	if res.ok:
		delta = clampi(int(res.data.get("delta", 10)), -15, 40)
		comment = str(res.data.get("comment", comment))
		next_q = str(res.data.get("question", next_q))
	else:
		comment = "(следователь отвлёкся на звонок: %s)" % res.error
		delta = 0
	state.suspicion = clampi(int(state.suspicion) + delta, 0, 100)
	state.history.append({"q": state.question, "answers": answers, "comment": comment, "delta": delta})
	state.question = next_q
	_set_phase("verdict", VERDICT_TIME)


func _finish() -> void:
	_busy = true
	var caught := int(state.suspicion) >= 100
	state.result = "caught" if caught else "free"
	_set_phase("final")
	var res: Dictionary = await LLM.chat_json(_final_prompt(caught), 0.9, 300)
	_busy = false
	state.speech = str(res.data.get("speech", "")) if res.ok else ""
	if state.speech == "":
		state.speech = "Дело закрыто. В камеру!" if caught else "Свободны. Пока что."
	_set_phase("end")


func back_to_lobby() -> void:
	if not Net.is_host():
		return
	state = _fresh_state()
	_set_phase("lobby")


# ---------- промпты ----------

func _names() -> Array:
	return Net.players.values()


func _case_prompt() -> Array:
	var names := ", ".join(_names())
	var sys := """[CASE] Ты ведущий кооперативной игры «Алиби». Игроки — компания друзей, которых подозревают в нелепом преступлении. Они заранее договорятся о общем алиби, потом их по отдельности допросит следователь (это тоже ты).
Придумай новое смешное, абсурдное, но бытовое преступление в российском городе: без насилия, крови и политики. Примеры уровня: из учительской пропал юбилейный торт, у гаишника угнали самокат, с дачи соседа исчез садовый гном. Каждый раз новое, не повторяй примеры.
Укажи конкретное время (например, «вчера с 19:00 до 21:00») и место. Следователь — колоритный персонаж с говорящей фамилией и своей манерой речи.
Ответь строго JSON без markdown:
{"title": "название дела, 2-5 слов", "crime": "2-3 предложения: что случилось, где, когда и какая улика есть", "detective": "звание, имя и фамилия", "style": "манера речи следователя, 3-6 слов", "hint": "одна фраза банде: о каких деталях стоит договориться", "question": "первый вопрос следователя ко всем подозреваемым сразу"}
Первый вопрос — про конкретные проверяемые детали (где были, с кем, что делали), чтобы ответы можно было сравнить."""
	return [
		{"role": "system", "content": sys},
		{"role": "user", "content": "Подозреваемые: %s. Придумай дело." % names},
	]


func _case_text() -> String:
	var c: Dictionary = state.case
	return "Дело: %s\n%s\nТы — %s, говоришь %s." % [c.get("title", ""), c.get("crime", ""), c.get("detective", ""), c.get("style", "")]


func _history_text() -> String:
	var lines := []
	var i := 1
	for h in state.history:
		lines.append("Вопрос %d: %s" % [i, h.q])
		for n in h.answers:
			lines.append("  %s: %s" % [n, h.answers[n]])
		lines.append("  Твоя реплика: %s" % h.comment)
		i += 1
	return "\n".join(lines) if lines.size() > 0 else "(это первый вопрос)"


func _judge_prompt(answers: Dictionary) -> Array:
	var solo := answers.size() == 1
	var last := int(state.round) >= ROUNDS
	var sys := """Ты следователь в кооперативной игре «Алиби». %s
Подозреваемые до допроса договорились об общей легенде. Теперь каждый ответил на твой вопрос тайно, не видя ответов остальных. Твоя задача — поймать их на нестыковках.
Правила оценки (поле delta, изменение подозрения от -15 до +40):
- явные противоречия между ответами в фактах (место, время, еда, кто что делал, цвета, числа): +20..+40;
- уклончивые, пустые, издевательские или нелепые ответы, «(молчит)»: +8..+15 за каждого такого;
- противоречие с их же прошлыми ответами: +15..+30;
- ответы сходятся в конкретных деталях: -5..-15;
- разные формулировки одного и того же — это нормально, не наказывай.
%s
Реплика (comment): 1-3 предложения в твоей манере, обращайся к подозреваемым по именам, цитируй, где они разошлись или где сошлись. Смешно, но без грубости.
%s
Ответь строго JSON без markdown: {"delta": число, "comment": "реплика", "question": "следующий вопрос"}""" % [
		_case_text(),
		"Подозреваемый один: оценивай правдоподобие и последовательность с его прошлыми ответами." if solo else "",
		"Это последний вопрос, поле question оставь пустым." if last else "Следующий вопрос (question) — ко всем сразу, про одну новую конкретную деталь того вечера, которую легко забыть обсудить (что было на столе, во что был одет, какая песня играла, кто первым ушёл, сколько стоило). Иногда копай туда, где они уже путаются. Не повторяй прошлые вопросы.",
	]
	var lines := []
	for n in answers:
		lines.append("%s: %s" % [n, answers[n]])
	var user := "Прошлые вопросы:\n%s\n\nТекущий вопрос %d из %d: %s\nОтветы:\n%s\nТекущее подозрение: %d из 100." % [
		_history_text(), int(state.round), ROUNDS, state.question, "\n".join(lines), int(state.suspicion)]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


func _final_prompt(caught: bool) -> Array:
	var sys := "[FINAL] Ты следователь из игры «Алиби». %s\nДопрос окончен. %s Скажи заключительную речь в своей манере, 2-3 предложения, вспомни самую смешную нестыковку или деталь. Ответь строго JSON: {\"speech\": \"речь\"}" % [
		_case_text(),
		"Подозрение дошло до 100: ты их раскусил и задерживаешь." if caught else "Улик не хватило, ты нехотя отпускаешь подозреваемых.",
	]
	return [{"role": "system", "content": sys}, {"role": "user", "content": _history_text()}]
