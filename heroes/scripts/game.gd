extends Node
## «Хроники двоих»: нейронка — ведущий, игроки — герои. Механику (кубики, КД, урон, лут) считает игра,
## нейронка рассказывает и решает, что происходит в мире.
## Хост хранит кампанию, бросает кубики и вызывает нейронку; клиентам рассылается состояние целиком.
##
## Фазы: lobby ⚔ create ⚔ world ⚔ play ⇄ thinking (→ rolling) ⚔ play …
##       play ⚔ combat (пошагово по инициативе) ⚔ thinking (итоги боя) ⚔ play

signal state_changed
signal rolls_shown(rolls: Array)   # для анимации кубиков на всех телефонах
signal _asks_finished

const R = preload("res://scripts/rules.gd")
const MapView = preload("res://scripts/map_view.gd")

const SAVE_PATH := "user://campaign.json"
const SETTINGS := [
	"Классическое фэнтези: драконы, гномы, древние руины",
	"Сказочная Русь: леший, Кощей, богатыри, заколдованные леса",
	"Пиратские острова: моря, клады, морские чудища",
	"Мрачные земли: проклятия, туманы, нежить",
	"Паровой город: механизмы, гильдии, интриги и воздушные корабли",
]

var phase := "lobby"
var state := {}
var _busy := false
var _actions := {}   # имя игрока -> действие (только у хоста)
var _roll_seq := 0
var _seen_roll_seq := 0
var _rolls_until := 0
var _last_target := {}


func _ready() -> void:
	reset_local()


func reset_local() -> void:
	phase = "lobby"
	state = _fresh_state()
	_busy = false
	_actions = {}
	_seen_roll_seq = 0
	state_changed.emit()


func _fresh_state() -> Dictionary:
	return {"phase": "lobby", "campaign": {}, "heroes": {}, "log": [], "options": {},
		"pending": [], "error": "", "save_info": _save_info(), "turn": 0,
		"map": {"nodes": [], "edges": [], "cur": -1}, "combat": {}, "loot": {}, "shop": {},
		"rolls": [], "roll_seq": 0, "ask": []}


func hero_of(pname: String) -> Dictionary:
	return state.heroes.get(pname, {})


func my_pname() -> String:
	return str(Net.players.get(Net.my_id(), ""))


func my_hero() -> Dictionary:
	return hero_of(my_pname())


func can_rejoin(pname: String) -> bool:
	return state.heroes.has(pname) and not (pname in Net.players.values())


func has_free_hero() -> bool:
	for n in state.heroes:
		if not (n in Net.players.values()):
			return true
	return false


## Чей сейчас ход в бою: имя игрока или "" (ход врага / не бой).
func combat_actor() -> String:
	var c: Dictionary = state.combat
	if c.is_empty() or c.order.is_empty():
		return ""
	var o: Dictionary = c.order[int(c.turn)]
	return str(o.id) if o.k == "h" else ""


# ---------- синхронизация ----------

func _broadcast() -> void:
	if Net.is_host():
		_sync.rpc(state)


func send_state_to(id: int) -> void:
	_sync.rpc_id(id, state)


@rpc("authority", "call_local", "reliable")
func _sync(s: Dictionary) -> void:
	var seq := int(s.get("roll_seq", 0))
	var new_rolls := seq != _seen_roll_seq
	_seen_roll_seq = seq
	state = s
	phase = str(s.phase)
	state_changed.emit()
	if new_rolls and (s.rolls as Array).size() > 0:
		rolls_shown.emit(s.rolls)


func _set_phase(p: String) -> void:
	phase = p
	state.phase = p
	_broadcast()


func _show_rolls(rolls: Array) -> void:
	_roll_seq += 1
	state.rolls = rolls
	state.roll_seq = _roll_seq
	var groups := 1 if rolls.size() == 2 else rolls.size()
	_rolls_until = Time.get_ticks_msec() + 2300 * groups


## Ждёт, пока на телефонах докатятся кубики.
func _wait_rolls(extra := 0) -> void:
	var w := _rolls_until - Time.get_ticks_msec() + extra
	if w > 0:
		await get_tree().create_timer(w / 1000.0).timeout


# ---------- запросы игроков (все уходят хосту) ----------

func submit_hero(hero_name: String, race: String, cls: String, about: String) -> void:
	_hero.rpc_id(1, hero_name.strip_edges().left(20), race, cls, about.strip_edges().left(120))


func submit_action(text: String) -> void:
	_action.rpc_id(1, text.strip_edges().left(300))


func cancel_action() -> void:
	_action_cancel.rpc_id(1)


func combat_action(a: Dictionary) -> void:
	_cact.rpc_id(1, a)


func inv(op: String, a: Dictionary) -> void:
	_inv.rpc_id(1, op, a)


@rpc("any_peer", "call_local", "reliable")
func _hero(hero_name: String, race: String, cls: String, about: String) -> void:
	if not Net.is_host() or phase != "create" or not R.CLASSES.has(cls) or not R.RACES.has(race):
		return
	var pname := _sender_name()
	if hero_name == "":
		hero_name = pname
	state.heroes[pname] = R.new_hero(hero_name, race, cls, about)
	if _all_have_heroes():
		_make_world()
	else:
		_broadcast()


@rpc("any_peer", "call_local", "reliable")
func _action(text: String) -> void:
	if not Net.is_host() or phase != "play":
		return
	var pname := _sender_name()
	if not state.heroes.has(pname):
		return
	_actions[pname] = text if text != "" else "ждёт и наблюдает"
	if not (pname in state.pending):
		state.pending.append(pname)
	if _all_acted():
		_resolve()
	else:
		_broadcast()


@rpc("any_peer", "call_local", "reliable")
func _action_cancel() -> void:
	if not Net.is_host() or phase != "play":
		return
	var pname := _sender_name()
	_actions.erase(pname)
	state.pending.erase(pname)
	_broadcast()


func _sender_name() -> String:
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	return str(Net.players.get(id, "?"))


func _all_have_heroes() -> bool:
	for n in Net.players.values():
		if not state.heroes.has(n):
			return false
	return true


func _active_names() -> Array:
	var out := []
	for n in Net.players.values():
		if state.heroes.has(n):
			out.append(n)
	return out


func _all_acted() -> bool:
	var act := _active_names()
	if act.is_empty():
		return false
	for n in act:
		if not (n in state.pending):
			return false
	return true


func on_player_left(_id: int) -> void:
	for a in state.ask:
		if not a.done and not (str(a.who) in Net.players.values()):
			_do_roll(str(a.who))
	if phase == "play" and _all_acted():
		_resolve()
	elif phase == "create" and _all_have_heroes() and not state.heroes.is_empty():
		_make_world()
	elif phase == "combat":
		_broadcast()
		_combat_continue()
	else:
		_broadcast()


# ---------- кампания ----------

func new_campaign(setting: String, wishes: String) -> void:
	if not Net.is_host() or _busy:
		return
	state = _fresh_state()
	state.campaign = {"setting": setting, "wishes": wishes.strip_edges().left(200)}
	_set_phase("create")


func continue_campaign() -> void:
	if not Net.is_host() or _busy:
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		state.error = "Сохранение не найдено"
		_broadcast()
		return
	var d = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary) or not d.has("heroes"):
		state.error = "Сохранение повреждено"
		_broadcast()
		return
	d = R.intify(d)
	state = _fresh_state()
	state.campaign = d.campaign
	state.log = d.get("log", [])
	state.options = d.get("options", {})
	state.turn = int(d.get("turn", 0))
	state.map = d.get("map", state.map)
	# герои привязаны к кличкам; если кто-то зашёл под другой, отдаём ему свободного героя
	var heroes: Dictionary = d.heroes
	var free := []
	for n in heroes:
		if not (n in Net.players.values()):
			free.append(n)
	for n in Net.players.values():
		if not heroes.has(n) and free.size() > 0:
			var old: String = free.pop_front()
			heroes[n] = heroes[old]
			heroes.erase(old)
			if state.options.has(old):
				state.options[n] = state.options[old]
	state.heroes = heroes
	_log("sys", "", "Кампания продолжается. Ход %d." % (int(state.turn) + 1))
	_set_phase("play" if _all_have_heroes() else "create")


func back_to_lobby() -> void:
	if Net.is_host():
		state = _fresh_state()
		_set_phase("lobby")


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"campaign": state.campaign, "heroes": state.heroes,
		"log": state.log.slice(-150), "options": state.options, "turn": state.turn, "map": state.map}))
	f.close()
	state.save_info = _save_info()


func _save_info() -> String:
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return ""
	var d = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary) or not d.has("campaign"):
		return ""
	var names := []
	for n in d.get("heroes", {}):
		var h: Dictionary = d.heroes[n]
		names.append("%s, %s %d ур." % [h.get("name", n), h.get("cls", ""), int(h.get("level", 1))])
	return "«%s», ход %d (%s)" % [d.campaign.get("title", "Без названия"), int(d.get("turn", 0)), "; ".join(names)]


func _log(kind: String, who: String, text: String) -> void:
	state.log.append({"k": kind, "w": who, "t": text})
	if state.log.size() > 200:
		state.log = state.log.slice(-200)


func _tier() -> int:
	var lv := 0
	for n in state.heroes:
		lv += int(state.heroes[n].level)
	lv = lv / maxi(1, state.heroes.size())
	return 1 if lv <= 2 else (2 if lv <= 4 else (3 if lv <= 7 else 4))


func _make_world() -> void:
	if _busy:
		return
	if str(state.campaign.get("world", "")) != "":
		_set_phase("play")
		return
	_busy = true
	_set_phase("world")
	var my_state := state
	var res: Dictionary = await LLM.chat_json(_world_prompt(), 1.0, 1300)
	_busy = false
	if not is_same(state, my_state) or not Net.is_host():
		return
	if not res.ok or str(res.data.get("intro", "")) == "":
		state.error = "Ведущий не ответил: %s. Хост может нажать «Повторить»." % res.error
		_set_phase("create")
		return
	var d: Dictionary = res.data
	state.error = ""
	state.campaign.title = str(d.get("title", "Безымянная история"))
	state.campaign.world = str(d.get("world", ""))
	state.campaign.quest = str(d.get("quest", ""))
	state.campaign.chronicle = ""
	_apply_place(d.get("place"))
	_log("gm", "", str(d.intro))
	state.options = _map_options(d.get("options", {}))
	state.pending = []
	_actions = {}
	_save()
	_set_phase("play")


func retry_world() -> void:
	if Net.is_host() and phase == "create" and _all_have_heroes():
		_make_world()


func _apply_place(p) -> void:
	if p is Dictionary and str(p.get("name", "")) != "":
		var t := str(p.get("type", "road"))
		state.map = MapView.add_place(state.map, str(p.name).left(30), t)
		state.campaign.scene = str(p.name)


# ---------- ход вне боя ----------

func _resolve() -> void:
	if _busy:
		return
	_busy = true
	var acts := {}
	for n in _active_names():
		acts[n] = str(_actions.get(n, "ждёт и наблюдает"))
		_log("act", str(state.heroes[n].name), acts[n])
	_actions = {}
	_set_phase("thinking")

	# 1) какие нужны проверки
	var rolls := []
	var res: Dictionary = await LLM.chat_json(_checks_prompt(acts), 0.3, 500)
	if not Net.is_host():
		return
	var asks := []
	if res.ok and res.data.get("checks") is Array:
		var seen := {}
		for c in res.data.checks:
			if not (c is Dictionary):
				continue
			var pname := _player_by_hero(str(c.get("who", "")))
			if pname == "" or seen.has(pname) or not acts.has(pname):
				continue
			var a := _make_ask(pname, str(c.get("kind", "skill")), str(c.get("name", "")), int(c.get("dc", 12)),
				int(c.get("adv", 0)), str(c.get("why", "")))
			if a.is_empty():
				continue
			seen[pname] = true
			asks.append(a)
	if asks.size() > 0:
		rolls = await _ask_rolls(asks, "roll")
	var t0 := Time.get_ticks_msec()
	_set_phase("thinking")

	# 2) рассказ
	res = await LLM.chat_json(_narrate_prompt(_acts_text(acts), rolls, ""), 0.9, 1400)
	await _wait_rolls(300)
	_busy = false
	if not Net.is_host():
		return
	if not res.ok or str(res.data.get("story", "")) == "":
		_log("sys", "", "Ведущий задумался и не ответил (%s). Напишите действия ещё раз." % res.error)
		state.pending = []
		_set_phase("play")
		return
	_apply_narration(res.data, true)


## Применяет ответ ведущего: рассказ, изменения, место, сундук, лавка, бой, отдых.
func _apply_narration(d: Dictionary, allow_combat: bool) -> void:
	_log("gm", "", str(d.story))
	if allow_combat:
		_apply_changes(d.get("changes", []))
	_apply_place(d.get("place"))
	if str(d.get("quest", "")) != "":
		state.campaign.quest = str(d.quest)
	_apply_journal(d)
	state.options = _map_options(d.get("options", {}))
	var rest := str(d.get("rest", ""))
	if rest == "long" and int(state.turn) - int(state.campaign.get("last_long", -99)) < 6:
		rest = "short"
	if rest == "long":
		state.campaign.last_long = int(state.turn)
		for n in state.heroes:
			R.long_rest(state.heroes[n])
		_log("sys", "", "Долгий отдых: здоровье и заклинания восстановлены.")
	elif rest == "short":
		for n in state.heroes:
			var h: Dictionary = state.heroes[n]
			var v := R.short_rest(h)
			_log("sys", h.name, "Короткий отдых: %s восстанавливает %d хитов (%d/%d)." % [h.name, v, h.hp, h.max_hp])
	if allow_combat and str(d.get("chest", "")) != "" and int(state.turn) - int(state.campaign.get("last_chest", -99)) >= 2:
		state.campaign.last_chest = int(state.turn)
		_open_chest(str(d.chest))
	if allow_combat and str(d.get("shop", "")) != "":
		state.shop = {"title": str(d.shop).left(40), "items": R.shop_stock(_tier())}
	state.turn = int(state.turn) + 1
	state.pending = []
	_save()
	if allow_combat and d.get("combat") is Array and (d.combat as Array).size() > 0:
		if _start_combat(d.combat):
			return
	_set_phase("play")
	if int(state.turn) % 8 == 0:
		_update_chronicle()


## Дневник: задания и знакомые персонажи из ответа ведущего.
func _apply_journal(d: Dictionary) -> void:
	var c: Dictionary = state.campaign
	if not c.has("quests"):
		c.quests = []
	if not c.has("npcs"):
		c.npcs = []
	var qs = d.get("quests", [])
	if qs is Array:
		for q in qs:
			if not (q is Dictionary):
				continue
			var title := str(q.get("title", "")).strip_edges().left(60)
			if title == "":
				continue
			var st := str(q.get("status", "new"))
			var found: Dictionary = {}
			for e in c.quests:
				if str(e.t).to_lower() == title.to_lower():
					found = e
			if found.is_empty():
				if st in ["done", "failed"]:
					continue
				found = {"t": title, "d": str(q.get("note", "")).left(200), "s": "active", "turn": int(state.turn)}
				c.quests.append(found)
				_log("quest", "", "Новое задание: %s" % title)
			else:
				if str(q.get("note", "")) != "":
					found.d = str(q.note).left(200)
				if st == "done" and found.s == "active":
					found.s = "done"
					_log("quest", "", "Задание выполнено: %s" % title)
				elif st == "failed" and found.s == "active":
					found.s = "failed"
					_log("quest", "", "Задание провалено: %s" % title)
	var ns = d.get("npcs", [])
	if ns is Array:
		for n in ns:
			if not (n is Dictionary):
				continue
			var nm := str(n.get("name", "")).strip_edges().left(40)
			if nm == "":
				continue
			var known := false
			for e in c.npcs:
				if str(e.n).to_lower() == nm.to_lower():
					known = true
					if str(n.get("note", "")) != "":
						e.d = str(n.note).left(160)
			if not known and c.npcs.size() < 40:
				c.npcs.append({"n": nm, "d": str(n.get("note", "")).left(160)})


func _journal_text() -> String:
	var c: Dictionary = state.campaign
	var act := []
	for q in c.get("quests", []):
		if q.s == "active":
			act.append("%s (%s)" % [q.t, q.d])
	var who := []
	for n in c.get("npcs", []).slice(-12):
		who.append("%s — %s" % [n.n, n.d])
	return "\nАктивные задания: %s\nЗнакомые персонажи: %s" % ["; ".join(act) if act.size() > 0 else "нет", "; ".join(who) if who.size() > 0 else "нет"]


## Готовит проверку, которую игрок бросит сам: показываем сложность, ждём нажатия «Бросить».
func _make_ask(pname: String, kind: String, what: String, dc: int, adv: int, why: String) -> Dictionary:
	var h: Dictionary = state.heroes[pname]
	var info := _check_info(h, kind, what)
	if info.is_empty():
		return {}
	return {"who": pname, "hero": h.name, "kind": kind, "what": what, "label": info.label, "bonus": info.bonus,
		"dc": clampi(dc, 5, 25), "adv": clampi(adv, -1, 1), "why": why, "done": false}


## Ставит проверки игрокам и ждёт, пока все бросят. Отсутствующие бросают автоматически.
func _ask_rolls(asks: Array, ask_phase: String) -> Array:
	state.ask = asks
	if ask_phase != "":
		phase = ask_phase
		state.phase = ask_phase
	_broadcast()
	for a in asks:
		if not (str(a.who) in Net.players.values()):
			_do_roll(str(a.who))
	if not _asks_done():
		await _asks_finished
	var rolls := []
	for a in state.ask:
		if a.has("result"):
			rolls.append(a.result)
	state.ask = []
	return rolls


func _asks_done() -> bool:
	for a in state.ask:
		if not a.done:
			return false
	return true


func roll_now() -> void:
	_roll_rpc.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _roll_rpc() -> void:
	if Net.is_host():
		_do_roll(_sender_name())


func _do_roll(pname: String) -> void:
	for a in state.ask:
		if str(a.who) == pname and not a.done:
			var r := _check(pname, str(a.kind), str(a.what), int(a.dc), int(a.adv), str(a.why))
			if r.is_empty():
				r = _check(pname, "ability", "СИЛ", int(a.dc), 0, str(a.why))
			a.done = true
			a.result = r
			_show_rolls([r])
			_log("roll", r.hero, r.text)
			_broadcast()
			if _asks_done():
				# даём докатиться последнему кубику
				get_tree().create_timer(maxf(0.1, (_rolls_until - Time.get_ticks_msec()) / 1000.0)).timeout.connect(func(): _asks_finished.emit())
			return


func _check_info(h: Dictionary, kind: String, what: String) -> Dictionary:
	what = what.strip_edges()
	if kind == "save" or what.to_lower().begins_with("спас"):
		var a := _ability_from(what)
		return {} if a == "" else {"label": "спасбросок " + a, "bonus": R.save_bonus(h, a)}
	var s := _skill_from(what)
	if s != "":
		return {"label": s, "bonus": R.skill_bonus(h, s)}
	var a2 := _ability_from(what)
	return {} if a2 == "" else {"label": str(R.AB_NAME[a2]), "bonus": R.amod(h, a2)}


## Проверка навыка / спасбросок / характеристика. Возвращает описание броска.
func _check(pname: String, kind: String, what: String, dc: int, adv: int, why: String) -> Dictionary:
	var h: Dictionary = state.heroes[pname]
	var bonus := 0
	var label := ""
	what = what.strip_edges()
	if kind == "save" or what.begins_with("спас"):
		var a := _ability_from(what)
		if a == "":
			return {}
		bonus = R.save_bonus(h, a)
		label = "спасбросок " + a
	elif _skill_from(what) != "":
		var s := _skill_from(what)
		bonus = R.skill_bonus(h, s)
		label = s
	else:
		var a := _ability_from(what)
		if a == "":
			return {}
		bonus = R.amod(h, a)
		label = R.AB_NAME[a]
	dc = clampi(dc, 5, 25)
	var r := _d20(h, clampi(adv, -1, 1))
	var total: int = r.value + bonus + r.insp
	var outcome := "успех" if total >= dc else "провал"
	if r.value == 20:
		outcome = "критический успех"
	elif r.value == 1:
		outcome = "критический провал"
	var txt := "%s (%s): к20 = %d%s%s = %d против %d — %s" % [label, why, r.value, _sgn(bonus),
		(" + вдохновение %d" % r.insp) if r.insp > 0 else "", total, dc, outcome]
	return {"who": pname, "hero": h.name, "label": "%s · %s" % [h.name, label], "d20": r.value, "d20b": r.other,
		"adv": r.adv, "mod": bonus + r.insp, "total": total, "dc": dc, "outcome": outcome, "text": txt,
		"kind": "save" if label.begins_with("спас") else "check"}


func _skill_from(s: String) -> String:
	var low := s.to_lower()
	for k in R.SKILLS:
		if low.contains(str(k).to_lower()):
			return k
	return ""


func _ability_from(s: String) -> String:
	var low := s.to_lower()
	for a in R.AB:
		if low.contains(a.to_lower()) or low.contains(str(R.AB_NAME[a]).to_lower().left(4)):
			return a
	return ""


func _sgn(v: int) -> String:
	return (" + %d" % v) if v >= 0 else (" − %d" % absi(v))


## Бросок к20 с преимуществом/помехой, везением полурослика и вдохновением барда.
func _d20(h: Dictionary, adv: int, use_insp := true) -> Dictionary:
	var a := randi_range(1, 20)
	var lucky := bool(R.RACES.get(h.race, {}).get("lucky", false))
	if lucky and a == 1:
		a = randi_range(1, 20)
	var b := -1
	var v := a
	if adv != 0:
		b = randi_range(1, 20)
		if lucky and b == 1:
			b = randi_range(1, 20)
		v = maxi(a, b) if adv > 0 else mini(a, b)
	var insp := 0
	if use_insp and h.get("inspired", false):
		insp = randi_range(1, 6)
		h.inspired = false
	return {"value": v, "other": b if b < 0 else (b if v == a else a), "adv": adv, "insp": insp}


func _apply_changes(changes) -> void:
	if not (changes is Array):
		return
	var reward_gold := _apply_changes_each(changes)
	if reward_gold > 0:
		_split_gold("Награда", mini(reward_gold, 1000))


## Предмет уже выдан игрой недавно (добыча, сундук) — ведущий не должен выдать его второй раз.
func _recently_got(item_name: String, upto: int) -> bool:
	var low := item_name.to_lower()
	for e in state.log.slice(maxi(0, upto - 25), upto):
		if str(e.k) in ["loot", "sys"] and (str(e.t).contains("забирает") or str(e.t).contains("получает")) and str(e.t).to_lower().contains(low):
			return true
	return false


func _apply_changes_each(changes: Array) -> int:
	var reward_gold := 0
	var log_start: int = state.log.size()
	for c in changes:
		if not (c is Dictionary):
			continue
		var pname := _player_by_hero(str(c.get("who", "")))
		if pname == "":
			continue
		var h: Dictionary = state.heroes[pname]
		var hn := str(h.name)
		var dhp := clampi(int(c.get("hp", 0)), -20, 30)
		if dhp < 0:
			var d := mini(-dhp, int(h.hp) - 1)
			if d > 0:
				var msg := _damage_hero(pname, d, false)
				_log("sys", hn, "%s: −%d хитов (%d/%d)%s" % [hn, d, h.hp, h.max_hp, (" " + msg) if msg != "" else ""])
		elif dhp > 0:
			_heal_hero(pname, dhp)
		var dg := clampi(int(c.get("gold", 0)), -1000, 1000)
		if dg > 0:
			if int(state.turn) - int(state.campaign.get("last_loot_turn", -99)) > 1:
				reward_gold += dg
			dg = 0
		if dg != 0:
			var before := int(h.gold)
			h.gold = maxi(0, int(h.gold) + dg)
			_log("sys", hn, "%s: %+d золота (теперь %d)" % [hn, int(h.gold) - before, h.gold])
		var add = c.get("add", [])
		if add is Array:
			for v in add:
				var it := R.item_from_ai(v)
				if not it.is_empty() and _recently_got(R.item_name(it), log_start):
					continue
				if not it.is_empty() and h.items.size() < 30:
					h.items.append(it)
					_log("sys", hn, "%s получает: %s" % [hn, R.item_name(it)])
		var rem = c.get("remove", [])
		if rem is Array:
			for v in rem:
				var idx := _find_item(h.items, str(v))
				if idx >= 0:
					_log("sys", hn, "%s теряет: %s" % [hn, R.item_name(h.items[idx])])
					h.items.remove_at(idx)
		_give_xp(pname, clampi(int(c.get("xp", 0)), 0, 400))
	return reward_gold


func _give_xp(pname: String, xp: int) -> void:
	if xp <= 0:
		return
	var h: Dictionary = state.heroes[pname]
	h.xp = int(h.xp) + xp
	_log("sys", h.name, "%s: +%d опыта" % [h.name, xp])
	while int(h.level) < 10 and int(h.xp) >= R.xp_next(h):
		_log("lvl", h.name, R.level_up(h))


func _damage_hero(pname: String, dmg: int, crit: bool) -> String:
	var h: Dictionary = state.heroes[pname]
	if h.get("dead", false):
		return ""
	if int(h.hp) <= 0:
		h.stable = false
		if dmg >= int(h.max_hp):
			h.dead = true
			return "%s погибает от страшного удара!" % h.name
		h.death_f = int(h.death_f) + (2 if crit else 1)
		if int(h.death_f) >= 3:
			h.dead = true
			return "%s получает удар, лёжа без сознания, и погибает!" % h.name
		return "%s без сознания: провал спасброска от смерти (%d/3)" % [h.name, h.death_f]
	var left := int(h.hp) - dmg
	if left <= 0 and h.get("relentless", false) and left > -int(h.max_hp):
		h.relentless = false
		h.hp = 1
		return "%s падает… но ярость полуорка держит на ногах! 1 хит." % h.name
	if left <= -int(h.max_hp):
		h.hp = 0
		h.dead = true
		return "%s сражён наповал!" % h.name
	h.hp = maxi(0, left)
	if int(h.hp) == 0:
		h.death_s = 0
		h.death_f = 0
		h.stable = false
		return "%s падает без сознания!" % h.name
	return ""


func _heal_hero(pname: String, v: int) -> void:
	var h: Dictionary = state.heroes[pname]
	if h.get("dead", false):
		return
	var was_down := int(h.hp) <= 0
	h.hp = mini(int(h.max_hp), int(h.hp) + v)
	h.death_s = 0
	h.death_f = 0
	h.stable = false
	_log("sys", h.name, "%s: +%d хитов (%d/%d)%s" % [h.name, v, h.hp, h.max_hp, ", приходит в себя!" if was_down else ""])


func _find_item(items: Array, name: String) -> int:
	name = name.to_lower().strip_edges()
	if name == "":
		return -1
	for i in items.size():
		var it := R.item_name(items[i]).to_lower()
		if it == name or it.contains(name) or name.contains(it) or str(items[i].get("id", "")) == name:
			return i
	return -1


func _update_chronicle() -> void:
	var my_state := state
	var res: Dictionary = await LLM.chat_json(_chronicle_prompt(), 0.4, 600)
	if not is_same(state, my_state) or not Net.is_host():
		return
	if res.ok and str(res.data.get("chronicle", "")) != "":
		state.campaign.chronicle = str(res.data.chronicle)
		_save()


func _player_by_hero(hero: String) -> String:
	hero = hero.strip_edges().to_lower()
	if hero == "":
		return ""
	for n in state.heroes:
		var hn := str(state.heroes[n].name).to_lower()
		if hn == hero or n.to_lower() == hero:
			return n
	for n in state.heroes:
		var hn := str(state.heroes[n].name).to_lower()
		if hn.contains(hero) or hero.contains(hn):
			return n
	return ""


func _map_options(opts) -> Dictionary:
	var out := {}
	if opts is Dictionary:
		for k in opts:
			var pname := _player_by_hero(str(k))
			if pname != "" and opts[k] is Array:
				var arr := []
				for o in opts[k]:
					arr.append(str(o).left(90))
				out[pname] = arr.slice(0, 3)
	return out


# ---------- сундуки и лавка ----------

func _open_chest(title: String) -> void:
	var loot := R.roll_loot(_tier())
	_add_loot(title, int(loot.gold), loot.items)


## Золото делится поровну между всеми героями отряда; остаток округляем вверх, чтобы суммы сходились.
func _split_gold(title: String, gold: int) -> void:
	var names: Array = []
	for n in state.heroes:
		if not state.heroes[n].get("dead", false):
			names.append(n)
	if gold <= 0 or names.is_empty():
		return
	gold = int(ceil(float(gold) / names.size())) * names.size()
	var share := gold / names.size()
	for n in names:
		state.heroes[n].gold = int(state.heroes[n].gold) + share
	_log("loot", "", "%s: %d золота, каждому по %d." % [title, gold, share])


func _add_loot(title: String, gold: int, items: Array) -> void:
	_split_gold(title, gold)
	var cur: Dictionary = state.loot
	if not cur.is_empty() and (cur.items as Array).size() > 0:
		cur.items.append_array(items)
	else:
		state.loot = {"title": title.left(40), "items": items}
	if items.is_empty():
		state.loot = {} if cur.is_empty() else cur


@rpc("any_peer", "call_local", "reliable")
func _inv(op: String, a: Dictionary) -> void:
	if not Net.is_host():
		return
	var pname := _sender_name()
	if not state.heroes.has(pname):
		return
	var h: Dictionary = state.heroes[pname]
	var idx := int(a.get("idx", -1))
	var in_combat := phase == "combat"
	match op:
		"choose":
			var txt := R.apply_choice(h, str(a.get("pick", "")))
			if txt != "":
				_log("lvl", h.name, txt)
				_save()
		"equip":
			if idx < 0 or idx >= h.items.size():
				return
			if in_combat and combat_actor() != pname:
				return
			var it: Dictionary = h.items[idx]
			var slot := R.item_slot(it)
			if slot == "":
				return
			if in_combat and slot in ["armor", "clothes"]:
				_log("sys", h.name, "Переодеваться посреди боя некогда.")
				_broadcast()
				return
			var cat := str(R.item_def(it).get("cat", "shield" if slot == "offhand" else ""))
			if slot in ["armor", "offhand"] and not (cat in R.CLASSES[h.cls].get("armor", [])):
				_log("sys", h.name, "%s не умеет носить: %s." % [h.name, R.item_name(it)])
				_broadcast()
				return
			h.items.remove_at(idx)
			if h.equip.get(slot) is Dictionary and not h.equip[slot].is_empty():
				h.items.append(h.equip[slot])
			h.equip[slot] = it
			var d := R.item_def(it)
			if slot == "weapon" and d.get("two", false) and h.equip.get("offhand") is Dictionary and not h.equip.offhand.is_empty():
				h.items.append(h.equip.offhand)
				h.equip.offhand = {}
			if slot == "offhand" and h.equip.get("weapon") is Dictionary and not h.equip.weapon.is_empty() and R.item_def(h.equip.weapon).get("two", false):
				h.items.append(h.equip.weapon)
				h.equip.weapon = {}
			_log("sys", h.name, "%s надевает: %s" % [h.name, R.item_name(it)])
		"unequip":
			var slot := str(a.get("slot", ""))
			if h.equip.get(slot) is Dictionary and not h.equip[slot].is_empty():
				if in_combat and combat_actor() != pname:
					return
				h.items.append(h.equip[slot])
				h.equip[slot] = {}
		"use":
			if in_combat or idx < 0 or idx >= h.items.size():
				return
			_use_consumable(pname, idx, str(a.get("target", pname)))
		"give":
			var to := str(a.get("to", ""))
			if idx < 0 or idx >= h.items.size() or not state.heroes.has(to) or to == pname:
				return
			var it: Dictionary = h.items[idx]
			h.items.remove_at(idx)
			state.heroes[to].items.append(it)
			_log("sys", h.name, "%s передаёт %s: %s" % [h.name, state.heroes[to].name, R.item_name(it)])
		"give_gold":
			var to := str(a.get("to", ""))
			var amount := clampi(int(a.get("amount", 0)), 0, int(h.gold))
			if amount > 0 and state.heroes.has(to) and to != pname:
				h.gold = int(h.gold) - amount
				state.heroes[to].gold = int(state.heroes[to].gold) + amount
				_log("sys", h.name, "%s передаёт %s %d золота" % [h.name, state.heroes[to].name, amount])
		"drop":
			if idx >= 0 and idx < h.items.size():
				_log("sys", h.name, "%s выбрасывает: %s" % [h.name, R.item_name(h.items[idx])])
				h.items.remove_at(idx)
		"loot_take":
			var items: Array = state.loot.get("items", [])
			if idx >= 0 and idx < items.size():
				var it: Dictionary = items[idx]
				items.remove_at(idx)
				h.items.append(it)
				_log("loot", h.name, "%s забирает: %s" % [h.name, R.item_name(it)])
				if items.is_empty():
					state.loot = {}
		"loot_close":
			state.loot = {}
		"buy":
			var items: Array = state.shop.get("items", [])
			if idx < 0 or idx >= items.size():
				return
			var it: Dictionary = items[idx]
			var price := R.item_price(it)
			if int(h.gold) < price:
				return
			h.gold = int(h.gold) - price
			h.items.append(it.duplicate())
			if R.item_def(it).type != "potion":
				items.remove_at(idx)
			_log("sys", h.name, "%s покупает %s за %d зол." % [h.name, R.item_name(it), price])
		"sell":
			if state.shop.is_empty() or idx < 0 or idx >= h.items.size():
				return
			var it: Dictionary = h.items[idx]
			var price := maxi(1, R.item_price(it) / 2)
			h.items.remove_at(idx)
			h.gold = int(h.gold) + price
			_log("sys", h.name, "%s продаёт %s за %d зол." % [h.name, R.item_name(it), price])
		"shop_close":
			state.shop = {}
		"cast":
			if in_combat:
				return
			_cast_outside(pname, str(a.get("spell", "")), str(a.get("target", pname)))
		"second_wind":
			if in_combat or not h.get("second_wind", false):
				return
			h.second_wind = false
			_heal_hero(pname, randi_range(1, 10) + int(h.level))
		_:
			return
	if not in_combat:
		_save()
	_broadcast()


func _use_consumable(pname: String, idx: int, target: String) -> String:
	var h: Dictionary = state.heroes[pname]
	var it: Dictionary = h.items[idx]
	var d := R.item_def(it)
	if not state.heroes.has(target):
		target = pname
	if d.type == "potion":
		h.items.remove_at(idx)
		var v := R.roll(str(d.heal)) + R.talent_sum(h, "heal")
		_log("sys", h.name, "%s выпивает %s%s." % [h.name, R.item_name(it), "" if target == pname else " и поит " + str(state.heroes[target].name)])
		_heal_hero(target, v)
		return "potion"
	if d.type == "scroll" and R.SPELLS.has(str(d.spell)):
		var sp: Dictionary = R.SPELLS[str(d.spell)]
		if sp.kind == "heal" and phase != "combat":
			h.items.remove_at(idx)
			_heal_hero(target, R.roll(str(sp.dmg)) + 3 + R.talent_sum(h, "heal"))
			return "scroll"
	return ""


func _cast_outside(pname: String, spell: String, target: String) -> void:
	var h: Dictionary = state.heroes[pname]
	if not (spell in R.known_spells(h)):
		return
	var sp: Dictionary = R.SPELLS[spell]
	if sp.kind != "heal":
		return
	var slot := R.slot_for(h, spell)
	if slot < 0:
		return
	if slot > 0:
		h.slots[slot - 1] = int(h.slots[slot - 1]) - 1
	var targets: Array = state.heroes.keys() if sp.get("all", false) else [target if state.heroes.has(target) else pname]
	_log("sys", h.name, "%s читает «%s»." % [h.name, sp.name])
	for t in targets:
		_heal_hero(t, R.roll(str(sp.dmg)) + R.caster_mod(h) + R.talent_sum(h, "heal") + maxi(0, slot - int(sp.lvl)) * R.parse_dice(str(sp.dmg)).sides / 2)


# ---------- бой ----------

func _start_combat(spec: Array) -> bool:
	var enemies := []
	var counts := {}
	for e in spec:
		if not (e is Dictionary):
			continue
		var n := clampi(int(e.get("count", 1)), 1, 6)
		var base := {}
		var id := str(e.get("id", ""))
		if R.MONSTERS.has(id):
			base = R.MONSTERS[id].duplicate()
		else:
			base = {"name": str(e.get("name", "Враг")), "ac": clampi(int(e.get("ac", 12)), 8, 20),
				"hp": clampi(int(e.get("hp", 15)), 3, 150), "atk": clampi(int(e.get("atk", 4)), 1, 10),
				"dmg": _safe_dice(str(e.get("dmg", "1d6+2"))), "dex": 1, "xp": clampi(int(e.get("xp", 50)), 10, 3900)}
		if str(e.get("name", "")) != "":
			base.name = str(e.name).left(30)
		for i in n:
			if enemies.size() >= 8:
				break
			var en: Dictionary = base.duplicate()
			en.max_hp = int(en.hp)
			en.asleep = false
			en.dead = false
			counts[en.name] = int(counts.get(en.name, 0)) + 1
			en.base_name = en.name
			# каждый второй гоблин/кобольд/бандит — стрелок в тылу
			en.ranged = bool(base.get("bow", false)) and counts[en.name] % 2 == 0
			en.pos = "back" if en.ranged else "front"
			enemies.append(en)
	if enemies.is_empty():
		return false
	_fit_budget(enemies)
	for en in enemies:
		if int(counts[en.base_name]) > 1:
			var k := 1
			for other in enemies:
				if other == en:
					break
				if other.base_name == en.base_name:
					k += 1
			en.name = "%s %d" % [en.base_name, k]
	var order := []
	var lines := []
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		if h.get("dead", false):
			continue
		h.temp_ac = 0
		var r := _d20(h, 0, false)
		var init: int = r.value + R.amod(h, "ЛОВ") + R.talent_sum(h, "init")
		order.append({"k": "h", "id": n, "init": init + 0.1})
		lines.append("%s %d" % [h.name, init])
	for i in enemies.size():
		var init := randi_range(1, 20) + int(enemies[i].get("dex", 0))
		order.append({"k": "e", "id": i, "init": init})
		lines.append("%s %d" % [enemies[i].name, init])
	order.sort_custom(func(a, b): return float(a.init) > float(b.init))
	var pos := {}
	for n in state.heroes:
		var hh: Dictionary = state.heroes[n]
		pos[n] = "back" if (hh.cls in ["Маг", "Бард", "Следопыт"] or R.attack_info(hh).ranged) else "front"
	state.combat = {"round": 1, "turn": 0, "order": order, "enemies": enemies, "dodge": {}, "sneak": {}, "pos": pos, "moved": {}}
	state.pending = []
	_log("cbt", "", "Бой! Инициатива: " + ", ".join(lines) + ".")
	_set_phase("combat")
	_combat_continue()
	return true


## Ведёт бой, пока ход не дойдёт до живого игрока (ходы врагов и бессознательных героев — автоматически).
func _safe_dice(expr: String) -> String:
	var p := R.parse_dice(expr)
	return "%dd%d+%d" % [clampi(int(p.n), 1, 4), clampi(int(p.sides), 2, 12), clampi(int(p.bonus), 0, 6)]


## Не даём нейронке выставить непосильный бой: урезаем врагов до порога «смертельной» встречи 5e.
const DEADLY := [100, 200, 400, 500, 1100, 1400, 1700, 2100, 2400, 2800]


func _fit_budget(enemies: Array) -> void:
	var lv := 0
	for n in state.heroes:
		lv += int(state.heroes[n].level)
	lv = clampi(roundi(float(lv) / maxf(1.0, state.heroes.size())), 1, 10)
	var budget := int(DEADLY[lv - 1] * maxi(1, state.heroes.size()))
	while enemies.size() > 1:
		var total := 0
		for en in enemies:
			total += int(en.xp)
		var mult := 1.0 if enemies.size() == 1 else (1.5 if enemies.size() == 2 else 2.0)
		if total * mult <= budget:
			break
		enemies.pop_back()


func _combat_continue() -> void:
	if _busy or phase != "combat":
		return
	_busy = true
	while phase == "combat":
		if await _combat_check_end():
			break
		var c: Dictionary = state.combat
		var o: Dictionary = c.order[int(c.turn)]
		if o.k == "e":
			var en: Dictionary = c.enemies[int(o.id)]
			if not en.dead:
				await _wait_rolls(700)
				if not Net.is_host() or phase != "combat":
					break
				_enemy_turn(int(o.id))
				_broadcast()
			_next_turn()
			continue
		var pname := str(o.id)
		var h: Dictionary = state.heroes.get(pname, {})
		if h.is_empty() or h.get("dead", false):
			_next_turn()
			continue
		c.dodge.erase(pname)
		c.sneak.erase(pname)
		if int(h.hp) <= 0:
			if not h.get("stable", false):
				await _wait_rolls(400)
				_death_save(pname)
				_broadcast()
				if int(h.hp) > 0 and pname in Net.players.values():
					break   # 20 на спасброске: встаёт и сразу ходит
			_next_turn()
			continue
		if not (pname in Net.players.values()):
			await _wait_rolls(300)
			_log("cbt", h.name, "%s сражается сам, пока напарник не вернётся." % h.name)
			_hero_attack(pname, -1)
			_broadcast()
			_next_turn()
			continue
		_broadcast()   # ждём действие игрока
		break
	_busy = false


func _next_turn() -> void:
	var c: Dictionary = state.combat
	if c.is_empty():
		return
	c.turn = int(c.turn) + 1
	c.moved = {}
	if int(c.turn) >= c.order.size():
		c.turn = 0
		c.round = int(c.round) + 1


func hero_pos(pname: String) -> String:
	return str(state.combat.get("pos", {}).get(pname, "front"))


func _front_enemies() -> Array:
	var out := []
	for i in _alive_enemies():
		if str(state.combat.enemies[i].get("pos", "front")) == "front":
			out.append(i)
	return out


## Один удар врага по конкретному герою (удар вдогонку при отходе).
func _enemy_strike(i: int, target: String) -> void:
	var en: Dictionary = state.combat.enemies[i]
	var h: Dictionary = state.heroes[target]
	var v := randi_range(1, 20)
	var total := v + int(en.atk)
	var hac := R.ac(h)
	var hit := (total >= hac or v == 20) and v != 1
	var line := "%s атакует %s вдогонку: %d против КД %d — " % [en.name, h.name, total, hac]
	var dealt := -1
	if hit:
		var dmg := _roll_damage(str(en.dmg), v == 20)
		dealt = dmg
		line += "попадание, %d урона." % dmg
		var extra := _damage_hero(target, dmg, v == 20)
		if extra != "":
			line += " " + extra
	else:
		line += "промах."
	_log("cbt", en.name, line)
	_show_rolls([{"label": "%s ⚔ %s" % [en.name, h.name], "d20": v, "d20b": -1, "adv": 0, "mod": int(en.atk),
		"total": total, "dc": hac, "outcome": "попадание" if hit else "промах", "kind": "enemy", "dmg": dealt, "target": target}])


func _alive_enemies() -> Array:
	var out := []
	var c: Dictionary = state.combat
	for i in c.enemies.size():
		if not c.enemies[i].dead:
			out.append(i)
	return out


func _conscious_heroes() -> Array:
	var out := []
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		if int(h.hp) > 0 and not h.get("dead", false) and _in_combat(n):
			out.append(n)
	return out


func _in_combat(pname: String) -> bool:
	for o in state.combat.get("order", []):
		if o.k == "h" and str(o.id) == pname:
			return true
	return false


func _enemy_turn(i: int) -> void:
	var c: Dictionary = state.combat
	var en: Dictionary = c.enemies[i]
	if en.asleep:
		if int(c.round) >= int(en.get("wake_round", 0)):
			en.asleep = false
			_log("cbt", "", "%s просыпается!" % en.name)
		else:
			_log("cbt", "", "%s спит." % en.name)
			return
	var targets := _conscious_heroes()
	if targets.is_empty():
		for n in state.heroes:
			if _in_combat(n) and not state.heroes[n].get("dead", false):
				targets.append(n)
	if targets.is_empty():
		return
	# ближний бой: сначала те, кто впереди; тыл достижим, только если передняя линия пала
	if not en.get("ranged", false):
		var front := []
		for n in targets:
			if hero_pos(n) == "front":
				front.append(n)
		if not front.is_empty():
			targets = front
	var target: String = targets[randi() % targets.size()]
	if randf() < 0.35:
		for n in targets:
			if int(state.heroes[n].hp) < int(state.heroes[target].hp):
				target = n
	var h: Dictionary = state.heroes[target]
	var rolls := []
	for k in int(en.get("multi", 1)):
		if k > 0 and (int(h.hp) <= 0 or h.get("dead", false)):
			var alive := _conscious_heroes()
			if alive.is_empty():
				break
			target = alive[randi() % alive.size()]
			h = state.heroes[target]
		if h.get("dead", false):
			break
		var adv := -1 if c.dodge.get(target, false) else 0
		if int(h.hp) <= 0:
			adv = 1
		var a := randi_range(1, 20)
		var b := randi_range(1, 20)
		var v := a if adv == 0 else (maxi(a, b) if adv > 0 else mini(a, b))
		var total := v + int(en.atk)
		var hac := R.ac(h)
		if en.get("ranged", false) and hero_pos(target) == "back":
			hac += 2  # укрытие в тылу против стрел
		var hit := (total >= hac or v == 20) and v != 1
		var crit := v == 20 or (hit and int(h.hp) <= 0)
		var line := "%s атакует %s: %d против КД %d — " % [en.name, h.name, total, hac]
		var outcome := "промах"
		var dealt := -1
		if hit:
			var dmg := _roll_damage(str(en.dmg), crit)
			dealt = dmg
			outcome = "критическое попадание" if crit else "попадание"
			line += "%s, %d урона." % [outcome, dmg]
			var extra := _damage_hero(target, dmg, crit)
			if int(h.hp) > 0:
				line += " (%d/%d)" % [h.hp, h.max_hp]
			if extra != "":
				line += " " + extra
		else:
			line += "промах."
		_log("cbt", en.name, line)
		rolls.append({"label": "%s ⚔ %s" % [en.name, h.name], "d20": v, "d20b": -1 if adv == 0 else (b if v == a else a),
			"adv": adv, "mod": int(en.atk), "total": total, "dc": hac, "outcome": outcome,
			"kind": "enemy", "dmg": dealt, "target": target})
	_show_rolls(rolls)


func _roll_damage(expr: String, crit: bool) -> int:
	var p := R.parse_dice(expr)
	var n: int = p.n * (2 if crit else 1)
	var total: int = p.bonus
	for i in n:
		total += randi_range(1, p.sides)
	return maxi(1, total)


func _death_save(pname: String) -> void:
	var h: Dictionary = state.heroes[pname]
	var v := randi_range(1, 20)
	var outcome := ""
	if v == 20:
		h.hp = 1
		h.death_s = 0
		h.death_f = 0
		outcome = "критический успех"
		_log("cbt", h.name, "%s: спасбросок от смерти — 20! Приходит в себя с 1 хитом." % h.name)
	elif v >= 10:
		h.death_s = int(h.death_s) + 1
		outcome = "успех"
		if int(h.death_s) >= 3:
			h.stable = true
			_log("cbt", h.name, "%s: спасбросок от смерти %d — успех. Состояние стабильно." % [h.name, v])
		else:
			_log("cbt", h.name, "%s: спасбросок от смерти %d — успех (%d/3)." % [h.name, v, h.death_s])
	else:
		h.death_f = int(h.death_f) + (2 if v == 1 else 1)
		outcome = "провал"
		if int(h.death_f) >= 3:
			h.dead = true
			_log("cbt", h.name, "%s: спасбросок от смерти %d — провал. %s погибает…" % [h.name, v, h.name])
		else:
			_log("cbt", h.name, "%s: спасбросок от смерти %d — провал (%d/3)." % [h.name, v, h.death_f])
	_show_rolls([{"label": "%s · спасбросок от смерти" % h.name, "d20": v, "d20b": -1, "adv": 0, "mod": 0,
		"total": v, "dc": 10, "outcome": outcome, "kind": "death"}])


## Конец боя: победа, поражение или бегство. Возвращает true, если бой закончен.
func _combat_check_end() -> bool:
	var c: Dictionary = state.combat
	if c.is_empty():
		return true
	if int(c.round) > 30:
		c.fled = true   # затянувшийся бой: враги отступают
	var won := _alive_enemies().is_empty()
	var lost := _conscious_heroes().is_empty()
	if not won and not lost and not c.get("fled", false):
		return false
	await _wait_rolls(300)
	await _end_combat("won" if won else ("fled" if c.get("fled", false) else "lost"))
	return true


var _loot_note := ""


func _end_combat(result: String) -> void:
	var c: Dictionary = state.combat
	var total_xp := 0
	var gold := 0
	var foes := []
	for en in c.enemies:
		foes.append(en.name)
		if en.dead:
			total_xp += int(en.xp)
			gold += int(en.xp) / 8 + randi_range(0, 6)
	var summary := ""
	match result:
		"won":
			summary = "Победа! Повержены: %s." % ", ".join(foes)
			_log("cbt", "", summary)
			var names := []
			for n in state.heroes:
				if _in_combat(n):
					names.append(n)
			for n in names:
				_give_xp(n, total_xp / maxi(1, names.size()))
		"fled":
			summary = "Герои сбежали из боя."
			_log("cbt", "", summary)
			total_xp = 0
		"lost":
			summary = "Поражение: все герои пали."
			_log("cbt", "", summary)
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		h.temp_ac = 0
		if h.get("dead", false) or (result == "lost" and int(h.hp) <= 0):
			h.dead = false
			h.hp = 1
			h.gold = int(h.gold) / 2
			h.death_s = 0
			h.death_f = 0
			_log("sys", h.name, "%s чудом выжил(а), но потерял(а) половину золота." % h.name)
		elif int(h.hp) <= 0:
			h.hp = 1
			h.stable = false
			h.death_s = 0
			h.death_f = 0
			_log("sys", h.name, "%s приходит в себя с 1 хитом." % h.name)
	state.combat = {}
	_loot_note = ""
	if result == "won" and gold > 0:
		var items := []
		if randf() < 0.45:
			items = R.roll_loot(_tier()).items.slice(0, randi_range(1, 2))
		_add_loot("Добыча с врагов", gold, items)
		var nm := []
		for it in items:
			nm.append(R.item_name(it))
		_loot_note = "Игра уже выдала добычу: %d золота%s. Не придумывай другой добычи и не повторяй эту." % [gold, (", " + ", ".join(nm)) if nm.size() > 0 else ""]
		state.campaign.last_loot_turn = int(state.turn)
	_set_phase("thinking")
	var res: Dictionary = await LLM.chat_json(_narrate_prompt("", [], summary + " " + _combat_recap() + " " + _loot_note), 0.9, 1200)
	if not Net.is_host():
		return
	if res.ok and str(res.data.get("story", "")) != "":
		_apply_narration(res.data, false)
	else:
		state.pending = []
		_save()
		_set_phase("play")


func _combat_recap() -> String:
	var lines := []
	for e in state.log.slice(-12):
		if e.k == "cbt":
			lines.append(str(e.t))
	return "Ход боя: " + " ".join(lines)


@rpc("any_peer", "call_local", "reliable")
func _cact(a: Dictionary) -> void:
	if not Net.is_host() or phase != "combat" or _busy:
		return
	var pname := _sender_name()
	if combat_actor() != pname:
		return
	var h: Dictionary = state.heroes[pname]
	var c: Dictionary = state.combat
	var t := str(a.get("t", ""))
	var ok := true
	match t:
		"attack":
			ok = _hero_attack(pname, int(a.get("target", -1)))
		"spell":
			ok = _hero_spell(pname, str(a.get("spell", "")), a.get("target", -1), false)
		"item":
			var idx := int(a.get("idx", -1))
			if idx < 0 or idx >= h.items.size():
				return
			var d := R.item_def(h.items[idx])
			if d.type == "scroll":
				var sp := str(d.spell)
				ok = _hero_spell(pname, sp, a.get("target", -1), true)
				if ok:
					h.items.remove_at(idx)
			else:
				ok = _use_consumable(pname, idx, str(a.get("target", pname))) != ""
		"move":
			if c.moved.get(pname, false):
				return
			c.moved[pname] = true
			var to := "back" if hero_pos(pname) == "front" else "front"
			c.pos[pname] = to
			if to == "back":
				_log("cbt", h.name, "%s отходит в тыл." % h.name)
				var fe: Array = _front_enemies()
				var ready := []
				for i in fe:
					if not c.enemies[i].asleep and not c.enemies[i].get("ranged", false):
						ready.append(i)
				if ready.size() > 0:
					var ei: int = ready[randi() % ready.size()]
					_log("cbt", "", "%s бьёт вдогонку!" % c.enemies[ei].name)
					_enemy_strike(ei, pname)
					if int(h.hp) <= 0:
						_next_turn()
						_broadcast()
						_combat_continue()
						return
			else:
				_log("cbt", h.name, "%s выходит вперёд." % h.name)
			_broadcast()
			return
		"dodge":
			c.dodge[pname] = true
			_log("cbt", h.name, "%s уходит в глухую оборону (враги атакуют с помехой)." % h.name)
		"second_wind":
			if not h.get("second_wind", false):
				return
			h.second_wind = false
			var v := randi_range(1, 10) + int(h.level)
			_log("cbt", h.name, "%s: второе дыхание!" % h.name)
			_heal_hero(pname, v)
		"inspire":
			var to := str(a.get("target", ""))
			if int(h.get("inspire", 0)) <= 0 or not state.heroes.has(to) or to == pname:
				return
			h.inspire = int(h.inspire) - 1
			state.heroes[to].inspired = true
			_log("cbt", h.name, "%s вдохновляет %s песней: +1к6 к следующему броску." % [h.name, state.heroes[to].name])
		"flee":
			_busy = true
			var rr: Array = await _ask_rolls([_make_ask(pname, "skill", "Акробатика", 10 + _alive_enemies().size(), 0, "сбежать")], "")
			_busy = false
			if rr.size() > 0 and str(rr[0].outcome).contains("успех"):
				c.fled = true
		"free":
			_busy = true
			await _hero_free(pname, str(a.get("text", "")).left(200))
			_busy = false
		_:
			return
	if not ok:
		return
	_next_turn()
	_broadcast()
	_combat_continue()


func _target_enemy(i: int) -> int:
	var alive := _alive_enemies()
	if alive.is_empty():
		return -1
	return i if i in alive else alive[0]


func _hit_enemy(i: int, dmg: int, src: String) -> String:
	var en: Dictionary = state.combat.enemies[i]
	en.hp = int(en.hp) - dmg
	en.asleep = false
	if int(en.hp) <= 0:
		en.hp = 0
		en.dead = true
		return "%s пал%s!" % [en.name, "" if src == "" else " (" + src + ")"]
	return "(%s: %d/%d)" % [en.name, en.hp, en.max_hp]


func _hero_attack(pname: String, target: int) -> bool:
	_last_target[pname] = target
	var h: Dictionary = state.heroes[pname]
	var c: Dictionary = state.combat
	var info := R.attack_info(h)
	var rolls := []
	if not info.ranged and hero_pos(pname) != "front":
		c.pos[pname] = "front"
		_log("cbt", h.name, "%s выходит вперёд." % h.name)
	for k in int(info.attacks):
		var ti := _target_enemy(target)
		if ti < 0:
			break
		if not info.ranged and c.enemies[ti].get("pos", "front") == "back" and _front_enemies().size() > 0:
			var fe: Array = _front_enemies()
			_log("cbt", h.name, "%s прикрыт: до него не добраться, пока впереди стоят враги." % c.enemies[ti].name)
			ti = fe[0]
		var en: Dictionary = c.enemies[ti]
		var adv := 1 if en.asleep else 0
		if info.ranged and hero_pos(pname) == "front" and _front_enemies().size() > 0:
			adv -= 1  # стрелять в упор неудобно
		var r := _d20(h, clampi(adv, -1, 1))
		var total: int = r.value + int(info.atk) + r.insp
		var hit: bool = (total >= int(en.ac) or r.value == 20) and r.value != 1
		var crit: bool = (hit and r.value >= int(info.get("crit", 20))) or (hit and en.asleep and not info.ranged)
		var line := "%s бьёт %s (%s): %d против КД %d — " % [h.name, en.name, info.name, total, en.ac]
		var outcome := "промах"
		var dealt := -1
		if hit:
			var dmg := _roll_damage(str(info.dice), crit) + int(info.bonus)
			var sneak := ""
			if h.cls == "Плут" and info.fin and not c.sneak.get(pname, false) and (_conscious_heroes().size() > 1 or adv > 0):
				c.sneak[pname] = true
				var sd := _roll_damage("%dd6" % (ceili(int(h.level) / 2.0) + R.talent_sum(h, "sneak_dice")), crit)
				dmg += sd
				sneak = " + скрытая атака"
			dmg = maxi(1, dmg)
			dealt = dmg
			outcome = "критическое попадание" if crit else "попадание"
			line += "%s%s, %d урона. %s" % [outcome, sneak, dmg, _hit_enemy(ti, dmg, "")]
		else:
			line += "промах."
		_log("cbt", h.name, line)
		rolls.append({"label": "%s ⚔ %s" % [h.name, en.name], "d20": r.value, "d20b": r.other, "adv": r.adv,
			"mod": int(info.atk) + r.insp, "total": total, "dc": int(en.ac), "outcome": outcome,
			"kind": "attack", "dmg": dealt, "dmg_text": "%s%+d" % [R.dice_ru(str(info.dice)), int(info.bonus)]})
	_show_rolls(rolls)
	return true


func _hero_spell(pname: String, spell: String, target, from_scroll: bool) -> bool:
	var h: Dictionary = state.heroes[pname]
	if not R.SPELLS.has(spell):
		return false
	if not from_scroll and not (spell in R.known_spells(h)):
		return false
	var sp: Dictionary = R.SPELLS[spell]
	var slot := 0
	if not from_scroll:
		slot = R.slot_for(h, spell)
		if slot < 0:
			return false
		if slot > 0:
			h.slots[slot - 1] = int(h.slots[slot - 1]) - 1
	var c: Dictionary = state.combat
	var upcast := maxi(0, slot - int(sp.lvl))
	var dice := str(sp.dmg)
	var p := R.parse_dice(dice)
	if int(sp.lvl) == 0 and int(h.level) >= 5:
		dice = "%dd%d" % [p.n * 2, p.sides]
	elif upcast > 0 and sp.kind != "auto":
		dice = "%dd%d%s" % [p.n + upcast, p.sides, ("+%d" % p.bonus) if p.bonus > 0 else ""]
	var sa := R.spell_attack(h) if not from_scroll else 5
	var sdc := R.spell_dc(h) if not from_scroll else 13
	var rolls := []
	var head := "%s %s «%s»" % [h.name, "читает свиток" if from_scroll else "колдует", sp.name]
	match str(sp.kind):
		"attack":
			for k in int(sp.get("rays", 1)):
				var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
				if ti < 0:
					break
				var en: Dictionary = c.enemies[ti]
				var sadv := 1 if en.asleep else 0
				if hero_pos(pname) == "front" and _front_enemies().size() > 0:
					sadv -= 1
				var r := _d20(h, clampi(sadv, -1, 1))
				var total: int = r.value + sa + r.insp
				var hit: bool = (total >= int(en.ac) or r.value == 20) and r.value != 1
				var crit: bool = r.value == 20
				var line := "%s в %s: %d против КД %d — " % [head, en.name, total, en.ac]
				var dealt := -1
				if hit:
					var dmg := _roll_damage(dice, crit) + R.talent_sum(h, "spell_dmg")
					dealt = dmg
					line += "попадание, %d урона. %s" % [dmg, _hit_enemy(ti, dmg, "")]
				else:
					line += "промах."
				_log("cbt", h.name, line)
				rolls.append({"label": "%s · %s" % [h.name, sp.name], "d20": r.value, "d20b": r.other, "adv": r.adv,
					"mod": sa + r.insp, "total": total, "dc": int(en.ac), "outcome": ("попадание" if hit else "промах"),
					"kind": "spell", "dmg": dealt})
		"auto":
			var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
			if ti < 0:
				return false
			var dmg := R.roll(dice) + upcast * (randi_range(1, 4) + 1) + R.talent_sum(h, "spell_dmg")
			_log("cbt", h.name, "%s: %d урона по %s. %s" % [head, dmg, c.enemies[ti].name, _hit_enemy(ti, dmg, "")])
		"save":
			var targets := _alive_enemies() if sp.get("aoe", false) else [_target_enemy(int(target) if (target is int or target is float) else -1)]
			var parts := []
			for ti in targets:
				if ti < 0:
					continue
				var en: Dictionary = c.enemies[ti]
				var sv := randi_range(1, 20) + _msave(en, str(sp.save))
				if en.asleep and str(sp.save) in ["ЛОВ", "СИЛ"]:
					sv = 0
				var dmg := _roll_damage(dice, false)
				var saved := sv >= sdc
				if saved:
					dmg = dmg / 2 if sp.get("aoe", false) else 0
				parts.append("%s %s (%d), %d урона %s" % [en.name, "увернулся" if saved else "не увернулся", sv, dmg, _hit_enemy(ti, dmg, "") if dmg > 0 else ""])
			_log("cbt", h.name, "%s (СЛ %d): %s" % [head, sdc, "; ".join(parts)])
		"heal":
			var who: Array = []
			if sp.get("all", false):
				who = _conscious_heroes() + []
				for n in state.heroes:
					if _in_combat(n) and int(state.heroes[n].hp) <= 0 and not state.heroes[n].dead and not (n in who):
						who.append(n)
			else:
				var tn := str(target)
				who = [tn if state.heroes.has(tn) else pname]
			_log("cbt", h.name, head + ".")
			for n in who:
				_heal_hero(n, R.roll(dice) + R.caster_mod(h) + R.talent_sum(h, "heal"))
		"buff":
			var tn := str(target)
			if not state.heroes.has(tn):
				tn = pname
			state.heroes[tn].temp_ac = int(sp.get("ac", 2))
			_log("cbt", h.name, "%s: %s получает +%d к КД до конца боя." % [head, state.heroes[tn].name, int(sp.get("ac", 2))])
		"sleep":
			var pool := R.roll(dice) + upcast * R.roll("2d8")
			var alive := _alive_enemies()
			alive.sort_custom(func(x, y): return int(c.enemies[x].hp) < int(c.enemies[y].hp))
			var slept := []
			for ti in alive:
				var en: Dictionary = c.enemies[ti]
				if en.asleep or int(en.hp) > pool:
					continue
				if en.get("undead", false):
					continue
				pool -= int(en.hp)
				en.asleep = true
				en.wake_round = int(c.round) + 10
				slept.append(en.name)
			_log("cbt", h.name, "%s: %s" % [head, ("засыпают: " + ", ".join(slept)) if slept.size() > 0 else "никто не уснул."])
	if rolls.size() > 0:
		_show_rolls(rolls)
	return true


## Свободное действие в бою: нейронка решает, какую проверку бросить и что будет при успехе.
func _b(v) -> bool:
	return v == true or str(v).to_lower() in ["true", "1", "да"]


func _msave(en: Dictionary, a: String) -> int:
	var sv = en.get("saves", {})
	if sv is Dictionary and sv.has(a):
		return int(sv[a])
	return int(en.get("dex", 0)) if a == "ЛОВ" else 0


func _hero_free(pname: String, text: String) -> void:
	var h: Dictionary = state.heroes[pname]
	_log("act", h.name, text)
	state.combat.wait = true
	_broadcast()
	var res: Dictionary = await LLM.chat_json(_free_combat_prompt(pname, text), 0.5, 700)
	if state.combat.is_empty():
		return
	state.combat.erase("wait")
	var low := text.to_lower()
	var plain_attack := false
	for w in ["бью", "бьёт", "бить", "удар", "атак", "рублю", "рубан", "колю", "режу", "стреля", "пронза", "мечом", "топором", "кинжал"]:
		if low.contains(w):
			plain_attack = true
	if not res.ok or (plain_attack and not low.contains("толк") and not low.contains("брос")):
		# обычный удар своими словами — просто атакуем, ход не теряется
		var target: int = int(_last_target.get(pname, -1))
		for i in _alive_enemies():
			var nm := str(state.combat.enemies[i].base_name).to_lower()
			if nm.length() >= 4 and low.contains(nm.left(nm.length() - 2)):
				target = i
				break
		_hero_attack(pname, target)
		return
	var d: Dictionary = res.data
	var chk = d.get("check")
	if not (chk is Dictionary) or str(chk.get("name", "")) == "":
		chk = {"kind": "skill", "name": "Атлетика", "dc": 13}
	var a := _make_ask(pname, str(chk.get("kind", "skill")), str(chk.name), clampi(int(chk.get("dc", 13)), 10, 20), int(chk.get("adv", 0)), "затея")
	if a.is_empty():
		a = _make_ask(pname, "skill", "Атлетика", 13, 0, "затея")
	var rr: Array = await _ask_rolls([a], "")
	if state.combat.is_empty() or rr.is_empty():
		return
	var r: Dictionary = rr[0]
	var success: bool = r.outcome.contains("успех")
	var txt := str(d.get("success" if success else "fail", ""))
	if txt != "":
		_log("gm", "", txt)
	if not success:
		return
	var eff = d.get("effect", {})
	if not (eff is Dictionary):
		return
	var t := _tier()
	var named := -1
	var tname := str(eff.get("target", "")).to_lower()
	for i in _alive_enemies():
		if tname != "" and str(state.combat.enemies[i].name).to_lower().contains(tname):
			named = i
			break
	if named < 0:
		named = _target_enemy(_last_target.get(pname, -1))
	var dmg_expr := str(eff.get("damage", ""))
	if dmg_expr != "" and named >= 0:
		var p := R.parse_dice(dmg_expr)
		var all := _b(eff.get("all"))
		var n := clampi(int(p.n), 1, 1 + t)
		var safe_expr := ("%dd6" % n) if all else ("%dd8+%d" % [n, clampi(int(p.bonus), 0, 3)])
		for ti in (_alive_enemies() if all else [named]):
			var dmg := R.roll(safe_expr)
			_log("cbt", h.name, "%d урона по %s. %s" % [dmg, state.combat.enemies[ti].name, _hit_enemy(ti, dmg, "")])
	if _b(eff.get("sleep")) and named >= 0:
		var en: Dictionary = state.combat.enemies[named]
		if not en.dead and int(en.max_hp) <= 10 + 10 * t and not en.get("undead", false):
			en.asleep = true
			en.wake_round = int(state.combat.round) + 1
			_log("cbt", h.name, "%s обездвижен на раунд." % en.name)
	if _b(eff.get("end_combat")):
		state.combat.fled = true


# ---------- промпты ----------

const GM_RULES := """Ты ведущий настольной ролевой игры по правилам 5-й редакции для двоих друзей (часто это пара, играющая вечером). Ты живой, остроумный рассказчик: описываешь мир ярко, но коротко, играешь всех персонажей с их голосами, даёшь героям свободу и последствия.
Правила ведения:
- Пиши по-русски, обращайся к героям по именам.
- Каждому герою давай что делать, строй сцены так, чтобы им было выгодно действовать вместе и пользоваться способностями класса.
- Не решай за героев, что они говорят и делают. Мир реагирует на их поступки.
- Чередуй: разговоры с персонажами, загадки, исследование, ловушки, сундуки и тайники, бои, торговля, смешные и трогательные моменты.
- Механику (броски, урон в бою, лут сундуков, цены в лавке) считает игра. Ты только описываешь и сообщаешь игре события через поля JSON.
- Двигай главный квест: каждые несколько ходов — новая зацепка, поворот, встреча. Кампания длинная, глав много.
- Без жестокости ради жестокости и откровенных сцен.
- Прямую речь пиши через тире или в «ёлочках»; символ " внутри текстов не используй, иначе JSON сломается."""


func _heroes_text() -> String:
	var lines := []
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		var sc := []
		for a in R.AB:
			sc.append("%s %d" % [a, R.score(h, a)])
		var eq := []
		for s in h.equip:
			if h.equip[s] is Dictionary and not h.equip[s].is_empty():
				eq.append(R.item_name(h.equip[s]))
		var bag := []
		for it in h.items:
			bag.append(R.item_name(it))
		var status := ""
		if int(h.hp) <= 0:
			status = " БЕЗ СОЗНАНИЯ."
		if not (n in Net.players.values()):
			status += " (сейчас отсутствует, держится в тени)"
		lines.append("- %s: %s %s %d ур., %s. Хиты %d/%d, КД %d, золото %d. %s. Навыки: %s. Умения: %s. Надето: %s. В сумке: %s.%s" % [
			h.name, h.race, h.cls, h.level, h.about if str(h.about) != "" else "без описания", h.hp, h.max_hp, R.ac(h), h.gold,
			", ".join(sc), ", ".join(h.skills), R.CLASSES[h.cls].features, ", ".join(eq), ", ".join(bag) if bag.size() > 0 else "пусто", status])
	return "\n".join(lines)


func _names_rule() -> String:
	var names := []
	for n in state.heroes:
		names.append(str(state.heroes[n].name))
	return "\nПоле who и ключи options — строго имена героев: " + ", ".join(names) + "."


func _campaign_text() -> String:
	var c: Dictionary = state.campaign
	return "Кампания «%s». Мир: %s\nГлавный квест: %s\nТекущее место: %s\nЛетопись прошлого: %s" % [
		c.get("title", ""), c.get("world", ""), c.get("quest", ""), c.get("scene", ""),
		c.get("chronicle", "") if str(c.get("chronicle", "")) != "" else "(пока пусто)"] + _journal_text()


func _recent_log(n := 16) -> String:
	var lines := []
	for e in state.log.slice(-n):
		match str(e.k):
			"gm": lines.append("Ведущий: " + str(e.t))
			"act": lines.append("%s делает: %s" % [e.w, e.t])
			"roll": lines.append("Бросок %s: %s" % [e.w, e.t])
			_: lines.append("(" + str(e.t) + ")")
	return "\n".join(lines)


func _acts_text(acts: Dictionary) -> String:
	var lines := []
	for n in acts:
		lines.append("%s: %s" % [state.heroes[n].name, acts[n]])
	return "\n".join(lines)


const NARRATE_FORMAT := """Ответь строго JSON без markdown:
{"story": "4-8 предложений", "changes": [{"who": "имя героя", "hp": 0, "gold": 0, "add": [], "remove": [], "xp": 0}], "options": {"Имя героя": ["вариант", "вариант", "вариант"]}, "place": null, "quest": "", "quests": [], "npcs": [], "chest": "", "shop": "", "combat": [], "rest": ""}
Поля:
- story: последствия действий каждого героя, реакция мира и персонажей (с прямой речью), новая ситуация; закончи тем, что ждёт ответа героев.
- changes: золото-награда делится игрой поровну на всех, укажи общую сумму у любого героя. Не выдавай повторно то, что игра уже выдала (строки «Добыча», «забирает», «получает» в недавних событиях). Только реальные изменения вне боя: урон от ловушек и падений (hp отрицательный, 1-10), лечение (hp положительный), награды золотом, найденные или отданные вещи, опыт xp (10-50 за умное действие или убеждение, 50-200 за решённую загадку или выполненное поручение). add — id из каталога, можно с улучшением {"id": "longsword", "plus": 1, "name": "Меч «Рассвет»"}, или сюжетная вещь строкой ПО-РУССКИ («Древний цилиндр», «Письмо мэра»), никогда не латинский id. Пустой список, если ничего.
- options: по три коротких варианта (до 8 слов) для каждого героя: осторожный, смелый, неожиданный.
- place: {"name": "название", "type": "тип"} только если герои пришли в новое место или вернулись в известное, иначе null. Типы: village, city, tavern, forest, road, cave, dungeon, castle, ruins, swamp, mountain, lake, camp, temple, tower, field, sea, port.
- quests: дополнительные задания и поручения. Новое: {"title": "Найти пропавшую козу", "note": "кто дал и где искать", "status": "new"}; выполнено: {"title": то же название, "status": "done"}; провалено: "failed". Пусто, если ничего не изменилось. Названия активных заданий бери из списка выше точно.
- npcs: важные персонажи, которых герои встретили впервые или узнали о них новое: [{"name": "Мельник Тарас", "note": "кто он, 1 фраза"}]. Пусто, если никого.
- chest: короткое название, если герои открыли сундук, тайник или нашли клад (содержимое выдаст игра), иначе "".
- shop: имя торговца, если герои пришли торговать к лавке/рынку/кузнецу, иначе "".
- combat: если начинается бой, в story опиши только появление врагов, без ударов и исхода (бой отыграет игра). Если начинается бой, список врагов [{"id": "goblin", "count": 2, "name": "Гоблин-разбойник"}], id из списка монстров; можно своего: {"name": "...", "hp": 20, "ac": 13, "atk": 4, "dmg": "1d8+2", "xp": 100}. Бой — не каждый ход, примерно каждые 3-5 ходов, когда это оправдано сюжетом. Сила врагов по уровню героев: на 1-2 уровне 1-4 слабых врага (25-50 опыта каждый), дальше сильнее.
- rest: "short" если герои отдыхают час, "long" если ночуют в безопасном месте, иначе ""."""


func _world_prompt() -> Array:
	var c: Dictionary = state.campaign
	var sys := GM_RULES + """
Сейчас начало новой кампании. Придумай оригинальный мир в заданном сеттинге, главный квест на много вечеров (с тайной, которую раскроют не сразу) и первую сцену, в которой герои уже вместе. Учитывай их расы, классы и описания.
Ответь строго JSON без markdown:
{"title": "название кампании, 2-4 слова", "world": "мир в 3-4 предложениях: место, главная беда, важные силы", "quest": "главная цель героев, 1 предложение", "place": {"name": "название места первой сцены", "type": "тип"}, "intro": "вступление 5-8 предложений: как герои оказались вместе и что происходит прямо сейчас, закончи вопросом, что они делают", "options": {"Имя героя": ["вариант действия", "вариант", "вариант"]}}
Типы мест: village, city, tavern, forest, road, cave, dungeon, castle, ruins, swamp, mountain, lake, camp, temple, tower, field, sea, port.
В options ключи — имена героев, по три коротких варианта (до 8 слов) для каждого, разные и в духе его класса.""" + _names_rule()
	var user := "Сеттинг: %s\nПожелания игроков: %s\nГерои:\n%s" % [c.get("setting", SETTINGS[0]),
		c.get("wishes", "") if str(c.get("wishes", "")) != "" else "нет", _heroes_text()]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


func _checks_prompt(acts: Dictionary) -> Array:
	var sys := GM_RULES + """
Сейчас ты только решаешь, нужны ли броски к20. Проверка нужна, если действие рискованное, трудное или против кого-то: прыжок, взлом, обман, убеждение, поиск скрытого, ловушка, погоня. Простые действия, обычные разговоры и ожидание — без проверки. Максимум одна проверка на героя.
kind: "skill" (навык), "save" (спасбросок от ловушки, яда, магии), "ability" (чистая характеристика).
Навыки: Атлетика, Акробатика, Ловкость рук, Скрытность, Магия, История, Анализ, Природа, Религия, Уход за животными, Проницательность, Медицина, Восприятие, Выживание, Обман, Запугивание, Выступление, Убеждение.
Характеристики (для save и ability): СИЛ, ЛОВ, ТЕЛ, ИНТ, МДР, ХАР.
Сложность dc: 5 очень легко, 10 легко, 15 средне, 20 трудно, 25 почти невозможно.
adv: 1 преимущество (герою помогают, у него отличные условия), -1 помеха (темнота, ранен, спешка), иначе 0.
Ответь строго JSON: {"checks": [{"who": "имя героя", "kind": "skill", "name": "Скрытность", "dc": 12, "adv": 0, "why": "2-4 слова"}]} или {"checks": []}.""" + _names_rule()
	var user := "%s\nГерои:\n%s\n\nНедавние события:\n%s\n\nДействия сейчас:\n%s" % [
		_campaign_text(), _heroes_text(), _recent_log(6), _acts_text(acts)]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


func _narrate_prompt(acts_text: String, rolls: Array, combat_result: String) -> Array:
	var sys := GM_RULES + "\n"
	if combat_result != "":
		sys += "Только что закончился бой. Опиши, чем он завершился и что герои видят после. Добычу и опыт уже выдала игра: changes оставь пустым, бой не начинай снова.\n"
	else:
		sys += "Расскажи, что произошло после действий героев. Результаты бросков уже посчитаны игрой, строго следуй им: успех — получилось, провал — не вышло или вышло с неприятностью, критический успех — блестяще с бонусом, критический провал — смешная или опасная неудача.\n"
	sys += NARRATE_FORMAT + _names_rule() + "\nКаталог предметов (id=название): " + R.catalog_text() + "\nМонстры (id=название): " + R.monsters_text()
	var rl := []
	for r in rolls:
		rl.append("%s: %s" % [r.hero, r.text])
	var user := "%s\nГерои:\n%s\n\nНедавние события:\n%s\n\n" % [_campaign_text(), _heroes_text(), _recent_log(16)]
	if combat_result != "":
		user += "Итог боя: " + combat_result
	else:
		user += "Действия сейчас:\n%s\n\nБроски:\n%s" % [acts_text, "\n".join(rl) if rl.size() > 0 else "бросков не было"]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


func _free_combat_prompt(pname: String, text: String) -> Array:
	var h: Dictionary = state.heroes[pname]
	var foes := []
	for i in _alive_enemies():
		var en: Dictionary = state.combat.enemies[i]
		foes.append("%s (%d/%d хитов)" % [en.name, en.hp, en.max_hp])
	var sys := GM_RULES + """
Идёт пошаговый бой. Герой делает необычное действие. Реши: нужна ли проверка (обычно да), что будет при успехе и при провале. Эффект при успехе умеренный: урон до 3d8 одному врагу, или до 2d6 всем, или усыпить/обездвижить одного врага (sleep), или позволить всем сбежать (end_combat). Провал — без эффекта или с мелкой неприятностью.
Проверка нужна всегда. Ответь строго JSON, например:
{"check": {"kind": "skill", "name": "Атлетика", "dc": 13, "adv": 0}, "effect": {"damage": "2d6", "target": "имя врага", "all": false, "sleep": false, "end_combat": false}, "success": "1-2 предложения, если получилось", "fail": "1-2 предложения, если нет"}
или без урона:
{"check": {"kind": "save", "name": "ЛОВ", "dc": 12, "adv": 0}, "effect": {"damage": "", "target": "имя врага", "all": false, "sleep": true, "end_combat": false}, "success": "...", "fail": "..."}"""
	var user := "%s\nГерой: %s\nВраги: %s\nНедавно: %s\nДействие героя %s: %s" % [_campaign_text(), _heroes_text(), ", ".join(foes), _combat_recap(), h.name, text]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


func _chronicle_prompt() -> Array:
	var sys := """[CHRONICLE] Ты летописец ролевой кампании. Сожми прошлую летопись и недавние события в новую летопись до 170 слов: ключевые события, важные персонажи (по именам), обещания, долги, найденные тайны, отношения героев с персонажами, посещённые места. Это память ведущего, пиши сухо и по фактам.
Ответь строго JSON: {"chronicle": "текст"}"""
	var user := "Прошлая летопись: %s\n\nНедавние события:\n%s" % [state.campaign.get("chronicle", ""), _recent_log(40)]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]
