extends Node
## «Хроники двоих»: нейронка — ведущий, игроки — герои. Механику (кубики, КД, урон, лут) считает игра,
## нейронка рассказывает и решает, что происходит в мире.
## Хост хранит кампанию, бросает кубики и вызывает нейронку; клиентам рассылается состояние целиком.
##
## Фазы: lobby ⚔ create ⚔ world ⚔ play ⇄ thinking (→ rolling) ⚔ play …
##       play ⚔ combat (пошагово по инициативе) ⚔ thinking (итоги боя) ⚔ play

signal save_received(slot: int, title: String)
signal state_changed
signal rolls_shown(rolls: Array)   # для анимации кубиков на всех телефонах
signal _asks_finished

const R = preload("res://scripts/rules.gd")
const MapView = preload("res://scripts/map_view.gd")

const OLD_SAVE_PATH := "user://campaign.json"   # до 0.27: одна ячейка
const SLOTS := 3
var slot := 0   # в какую ячейку пишется текущая кампания


static func slot_path(i: int) -> String:
	return "user://save_%d.json" % i
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
var _helps := {}     # кто кому помогает в этом ходу (только у хоста)
var _optchk := {}    # выбранная реплика с готовой проверкой


var _secret := {}


func _ready() -> void:
	var cf := ConfigFile.new()
	if cf.load("user://settings.cfg") == OK:
		karmic = bool(cf.get_value("game", "karmic", true))
	reset_local()


## Кармические кости (как в BG3): после двух неудачных бросков подряд следующий к20 кидается ещё раз и берётся лучший.
var karmic := true


func set_karmic(v: bool) -> void:
	karmic = v
	var cf := ConfigFile.new()
	cf.load("user://settings.cfg")
	cf.set_value("game", "karmic", v)
	cf.save("user://settings.cfg")


## Вдохновение группы (как в BG3): копится за двадцатки, выполненные цели и яркий отыгрыш; тратится на преимущество перед проверкой.
const INSP_MAX := 4


func insp_pool() -> int:
	return int(state.get("campaign", {}).get("insp", 0))


func _gain_insp(why: String) -> void:
	if not state.has("campaign") or state.campaign.is_empty():
		return
	var n := insp_pool()
	if n >= INSP_MAX:
		return
	state.campaign.insp = n + 1
	_log("sys", "", "✨ Вдохновение группы +1 (%s): теперь %d из %d. Его можно потратить перед проверкой — бросок с преимуществом." % [why, n + 1, INSP_MAX])


func reset_local() -> void:
	phase = "lobby"
	state = _fresh_state()
	_busy = false
	_actions = {}
	_seen_roll_seq = 0
	_sent_hash = {}
	_sent_log = []
	_patch_seen = -1
	_resync_asked = false
	state_changed.emit()


func _fresh_state() -> Dictionary:
	return {"phase": "lobby", "campaign": {}, "heroes": {}, "log": [], "options": {},
		"pending": [], "error": "", "saves": save_infos(), "turn": 0,
		"map": {"nodes": [], "edges": [], "cur": -1}, "combat": {}, "loot": {}, "shop": {},
		"rolls": [], "roll_seq": 0, "ask": [], "sess": new_sess()}


## Итоги вечера: копятся с момента запуска кампании, не сохраняются.
static func new_sess() -> Dictionary:
	return {"t0": int(Time.get_unix_time_from_system()), "turn0": -1, "kills": 0, "crits": 0, "fails": 0, "won": 0, "gold": 0, "xp": 0,
		"dmg": {}, "best": {}, "lvls": [], "places": [], "deaths": 0}


func _sess() -> Dictionary:
	if not state.has("sess"):
		state.sess = new_sess()
	return state.sess


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
		# что именно выбрал каждый, кто уже сходил, — чтобы напарник видел
		var acts := {}
		for n in state.get("pending", []):
			if _actions.has(n):
				var t := str(_actions[n])
				if _helps.has(n) and state.heroes.has(_helps[n]):
					t += " (помогает: %s)" % str(state.heroes[_helps[n]].name)
				acts[n] = t
		state.acts = acts
		_apply_state(state)
		var patch := _make_patch()
		if not patch.is_empty():
			_sync_patch.rpc(patch)


func send_state_to(id: int) -> void:
	_sync_full.rpc_id(id, state, _patch_seq)


# По сети уходят только изменившиеся части состояния; журнал — только новыми записями.
var _story_all := []   # вся история кампании для «Летописи» (живёт только у хоста и в сохранении)
signal chronicle_ready(text: String)
var _sent_hash := {}
var _sent_log := []
var _patch_seq := 0
var _patch_seen := -1   # у клиента: номер последнего применённого пакета (-1 — ещё не было полного состояния)
var _resync_asked := false


func _make_patch() -> Dictionary:
	var patch := {}
	for k in state:
		if k == "log":
			continue
		var h := hash(state[k])
		if not _sent_hash.has(k) or int(_sent_hash[k]) != h:
			patch[k] = state[k]
			_sent_hash[k] = h
	var dels := []
	for k in _sent_hash.keys():
		if k != "log" and not state.has(k):
			dels.append(k)
			_sent_hash.erase(k)
	if dels.size() > 0:
		patch["__del"] = dels
	var log_now: Array = state.get("log", [])
	var lh := hash(log_now)
	if not _sent_hash.has("log") or int(_sent_hash.log) != lh:
		var last_i := -1
		for e in _sent_log:
			last_i = maxi(last_i, int(e.get("i", -1)))
		var add := []
		for e in log_now:
			if int(e.get("i", -1)) > last_i:
				add.append(e)
		var expect: Array = (_sent_log + add).slice(-200)
		if _sent_hash.has("log") and hash(expect) == lh:
			patch["__log_add"] = add
		else:
			patch["log"] = log_now
		_sent_hash.log = lh
		_sent_log = log_now.duplicate(true)
	if patch.is_empty():
		return {}
	patch["__base"] = _patch_seq
	_patch_seq += 1
	patch["__seq"] = _patch_seq
	return patch


@rpc("authority", "call_remote", "reliable")
func _sync_full(s: Dictionary, seq: int) -> void:
	_patch_seen = seq
	_resync_asked = false
	_apply_state(s)


@rpc("authority", "call_remote", "reliable")
func _sync_patch(p: Dictionary) -> void:
	if _patch_seen < 0:
		return   # ещё ждём полное состояние
	if int(p.get("__base", -1)) != _patch_seen:
		if not _resync_asked:
			_resync_asked = true
			Net.request_resync()   # пропустили пакет — просим всё целиком
		return
	var s := state.duplicate(false)
	for k in p:
		if not str(k).begins_with("__"):
			s[k] = p[k]
	for k in p.get("__del", []):
		s.erase(k)
	if p.has("__log_add"):
		s.log = ((s.get("log", []) as Array) + (p.__log_add as Array)).slice(-200)
	_patch_seen = int(p.__seq)
	_apply_state(s)


func _apply_state(s: Dictionary) -> void:
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


func submit_action(text: String, help := "", opt := -1, secret := false) -> void:
	_action.rpc_id(1, text.strip_edges().left(300), help, opt, secret)


func send_chat(text: String) -> void:
	text = text.strip_edges().left(300)
	if text != "":
		_chat.rpc_id(1, text)


func vote(op: String, a: Dictionary) -> void:
	_vote_rpc.rpc_id(1, op, a)


## Лавка у каждого игрока своя: открыл один — у второго ничего не всплывает.
func shop_of(pname: String) -> Dictionary:
	return state.get("shops", {}).get(pname, {})


func my_shop() -> Dictionary:
	return shop_of(my_pname())


## Цена у торговца с учётом его отношения к героям.
func shop_price(it: Dictionary, pname := "") -> int:
	var sh := shop_of(pname if pname != "" else my_pname())
	return maxi(1, roundi(R.item_price(it) * float(sh.get("mult", 1.0))))


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
func _action(text: String, help := "", opt := -1, secret := false) -> void:
	if not Net.is_host() or phase != "play" or not state.get("vote", {}).is_empty():
		return
	var pname := _sender_name()
	if not state.heroes.has(pname):
		return
	if text.begins_with("{"):
		var m := RegEx.create_from_string("\"t\"\\s*:\\s*\"([^\"]+)\"").search(text)
		if m:
			text = m.get_string(1)
	_actions[pname] = text if text != "" else "ждёт и наблюдает"
	if secret and text != "" and help == "":
		_secret[pname] = true
	else:
		_secret.erase(pname)
	_helps.erase(pname)
	_optchk.erase(pname)
	if help != "" and help != pname and state.heroes.has(help):
		_helps[pname] = help
	var my_opts: Array = state.options.get(pname, [])
	if opt >= 0 and opt < my_opts.size() and my_opts[opt] is Dictionary and my_opts[opt].has("chk") and str(my_opts[opt].t) == text:
		_optchk[pname] = my_opts[opt].chk
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
	_helps.erase(pname)
	_optchk.erase(pname)
	state.pending.erase(pname)
	_broadcast()


# ---------- чат между игроками ----------

@rpc("any_peer", "call_local", "reliable")
func _chat(text: String) -> void:
	if not Net.is_host():
		return
	var pname := _sender_name()
	if not state.has("chat"):
		state.chat = []
	state.chat_n = int(state.get("chat_n", 0)) + 1
	state.chat.append({"p": pname, "w": str(state.heroes.get(pname, {}).get("name", pname)), "t": text.left(300), "n": int(state.chat_n)})
	if (state.chat as Array).size() > 80:
		state.chat = (state.chat as Array).slice(-80)
	_broadcast()


# ---------- голосование группы ----------

@rpc("any_peer", "call_local", "reliable")
func _vote_rpc(op: String, a: Dictionary) -> void:
	if not Net.is_host():
		return
	var pname := _sender_name()
	if not state.heroes.has(pname):
		return
	match op:
		"start":
			if phase != "play" or _busy or not state.get("vote", {}).is_empty():
				return
			var kind := str(a.get("kind", ""))
			var hn := str(state.heroes[pname].name)
			if kind == "rest_short":
				_begin_vote("%s предлагает короткий привал (час отдыха, тратите кости хитов)." % hn, ["Да, отдохнём", "Нет, идём дальше"], kind, pname)
			elif kind == "rest_long":
				_begin_vote("%s предлагает заночевать (всё восстановится, но в диких местах могут напасть)." % hn, ["Да, разбиваем лагерь", "Нет, не сейчас"], kind, pname)
		"pick":
			var v: Dictionary = state.get("vote", {})
			if v.is_empty():
				return
			var i := int(a.get("pick", -1))
			if i < 0 or i >= (v.opts as Array).size():
				return
			v.votes[pname] = i
			_broadcast()
			_vote_check()
		"cancel":
			var v2: Dictionary = state.get("vote", {})
			if not v2.is_empty() and str(v2.get("by", "")) == pname:
				state.vote = {}
				_broadcast()


func _begin_vote(q: String, opts: Array, kind: String, by: String) -> void:
	state.vote = {"q": q.left(200), "opts": opts.slice(0, 4), "votes": {}, "kind": kind, "by": by}
	if by != "":
		state.vote.votes[by] = 0
	_log("vote", "", "Голосование: " + q.left(200))
	_broadcast()
	_vote_check()


func _vote_check() -> void:
	var v: Dictionary = state.get("vote", {})
	if v.is_empty():
		return
	var voters := []
	for n in _active_names():
		if n in Net.players.values():
			voters.append(n)
	for n in voters:
		if not v.votes.has(n):
			return
	var picks := {}
	for n in voters:
		picks[int(v.votes[n])] = true
	var win := int(v.votes[voters[0]]) if voters.size() > 0 else 0
	if picks.size() > 1:
		# мнения разошлись: решает бросок к20 + Харизма
		var best := -99
		var parts := []
		for n in voters:
			var h: Dictionary = state.heroes[n]
			var r := randi_range(1, 20) + R.amod(h, "ХАР")
			parts.append("%s %d" % [h.name, r])
			if r > best:
				best = r
				win = int(v.votes[n])
		_log("vote", "", "Мнения разошлись, спор решил бросок (к20 + ХАР): %s." % ", ".join(parts))
	var choice := str(v.opts[win])
	_log("vote", "", "Решено: " + choice)
	state.vote = {}
	match str(v.kind):
		"rest_short", "rest_long":
			if win == 0:
				_do_rest("long" if str(v.kind) == "rest_long" else "short", true)
				return
			_broadcast()
		"story":
			for n in _active_names():
				_actions[n] = "Группа решила: " + choice
				if not (n in state.pending):
					state.pending.append(n)
			_broadcast()
			_resolve()
		_:
			_broadcast()


const COMBAT_GAP := 5

const SAFE_PLACES := ["village", "city", "tavern", "temple", "castle", "port"]
const SHORT_RESTS := 2   # как в BG3: два привала между ночлегами


func short_rests_left() -> int:
	return int(state.get("campaign", {}).get("short_left", SHORT_RESTS))


func rations_total() -> int:
	var n := 0
	for k in state.heroes:
		n += _count_item(state.heroes[k], "rations")
	return n


## Съесть пайки на ночлег: сначала каждый свой, потом делятся. Возвращает, сколько съели.
func _eat_rations(need: int) -> int:
	var eaten := 0
	for pass_i in 2:
		for k in state.heroes:
			var h: Dictionary = state.heroes[k]
			var take := 1 if pass_i == 0 else need
			while take > 0 and eaten < need:
				var idx := -1
				for i in h.items.size():
					if str(h.items[i].get("id", "")) == "rations":
						idx = i
						break
				if idx < 0:
					break
				h.items.remove_at(idx)
				eaten += 1
				take -= 1
	return eaten
const AMBUSH := [
	[["wolf", 2], ["goblin", 3], ["giant_rat", 3], ["kobold", 3], ["bandit", 2]],
	[["orc", 2], ["dire_wolf", 1], ["bugbear", 1], ["ghoul", 1], ["giant_spider", 1]],
	[["ogre", 1], ["wight", 1], ["harpy", 2], ["dire_wolf", 2]],
	[["troll", 1], ["minotaur", 1], ["wyvern", 1]],
]


## Отдых. Ночлег в диких местах — риск ночного нападения.
func _do_rest(kind: String, may_ambush: bool) -> void:
	if kind == "long" and int(state.turn) - int(state.campaign.get("last_long", -99)) < 6:
		_log("sys", "", "Для ночлега рано: устраиваете короткий привал.")
		kind = "short"
	if kind == "long":
		var m: Dictionary = state.get("map", {})
		var nodes: Array = m.get("nodes", [])
		var cur := int(m.get("cur", -1))
		var ptype := str(nodes[cur].get("type", "")) if cur >= 0 and cur < nodes.size() else "road"
		if may_ambush and not (ptype in SAFE_PLACES) and randf() < 0.3:
			var pool: Array = AMBUSH[clampi(_tier(), 1, 4) - 1]
			var pick: Array = pool[randi() % pool.size()]
			_log("gm", "", "Костёр почти догорел, когда из темноты донёсся шорох. Ночлег сорван — на лагерь напали!")
			state.campaign.last_long = int(state.turn) - 3
			if _start_combat([{"id": pick[0], "count": pick[1]}]):
				return
		state.campaign.last_long = int(state.turn)
		state.campaign.short_left = SHORT_RESTS
		var need: int = state.heroes.size()
		if ptype in SAFE_PLACES:
			for n in state.heroes:
				R.long_rest(state.heroes[n])
			_log("sys", "", "Ночлег под крышей, с горячим ужином: здоровье, заклинания и силы восстановлены, недуги прошли.")
		else:
			var eaten := _eat_rations(need)
			if eaten >= need:
				for n in state.heroes:
					R.long_rest(state.heroes[n])
				_log("sys", "", "Лагерь у костра: съедено пайков — %d. Здоровье, заклинания и силы восстановлены, недуги прошли." % eaten)
			else:
				for n in state.heroes:
					R.partial_rest(state.heroes[n])
				_log("sys", "", "Еды не хватило (нужно пайков: %d, нашлось %d): ночь впроголодь — вернулась только половина хитов и ячеек. Купите пайки у торговца." % [need, eaten])
		for cp in state.get("companions", []):
			cp.hp = cp.max_hp
		if state.combat.is_empty():
			call_deferred("_camp_night")
	else:
		var left := int(state.campaign.get("short_left", SHORT_RESTS))
		if left <= 0:
			_log("sys", "", "Сил на привал больше нет: два привала уже было, теперь нужен ночлег.")
		else:
			state.campaign.short_left = left - 1
			for n in state.heroes:
				var h: Dictionary = state.heroes[n]
				var v := R.short_rest(h)
				_log("sys", h.name, "Привал: %s восстанавливает %d хитов (%d/%d)." % [h.name, v, h.hp, h.max_hp])
			_log("sys", "", "Привалов до ночлега осталось: %d." % (left - 1))
	_save()
	_broadcast()


func _sender_name() -> String:
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	return str(Net.players.get(id, "?"))


## Видна ли запись журнала игроку: тайные — только своему, «!имя» — всем, кроме него.
static func log_visible(e: Dictionary, pname: String) -> bool:
	var to := str(e.get("to", ""))
	if to == "":
		return true
	if to.begins_with("!"):
		return to.substr(1) != pname
	return to == pname


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
	if not state.get("vote", {}).is_empty():
		_vote_check()   # ушедший игрок не держит голосование
	if phase == "play" and _all_acted() and state.get("vote", {}).is_empty():
		_resolve()
	elif phase == "create" and _all_have_heroes() and not state.heroes.is_empty():
		_make_world()
	elif phase == "combat":
		_broadcast()
		_combat_continue()
	else:
		_broadcast()


# ---------- кампания ----------

func new_campaign(setting: String, wishes: String, to_slot := -1) -> void:
	if not Net.is_host() or _busy:
		return
	slot = to_slot if to_slot >= 0 else free_slot()
	state = _fresh_state()
	state.campaign = {"setting": setting, "wishes": wishes.strip_edges().left(200)}
	_story_all = []
	_set_phase("create")


func continue_campaign(from_slot := 0) -> void:
	if not Net.is_host() or _busy:
		return
	var d = _read_save(from_slot)
	if not (d is Dictionary):
		state.error = "Сохранение не найдено или повреждено"
		_broadcast()
		return
	slot = from_slot
	load_campaign_dict(d)


## Запустить кампанию из словаря сохранения (из ячейки или из файла, присланного напарником).
func load_campaign_dict(d: Dictionary) -> void:
	d = R.intify(d)
	_story_all = d.get("story_all", [])
	if _story_all.is_empty():   # старое сохранение: берём что есть в журнале
		for e in d.get("log", []):
			if str(e.get("k", "")) in ["gm", "act", "quest", "lvl", "loot"]:
				_story_all.append({"k": e.k, "w": e.get("w", ""), "t": e.t, "turn": 0})
	state = _fresh_state()
	state.campaign = d.campaign
	state.log = d.get("log", [])
	state.options = d.get("options", {})
	state.turn = int(d.get("turn", 0))
	state.map = d.get("map", state.map)
	state.companions = d.get("companions", [])
	state.chat = d.get("chat", [])
	state.chat_n = int(d.get("chat_n", 0))
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
	_fix_bug_gold()
	_dedup_quests()
	_log("sys", "", "Кампания продолжается. Ход %d." % (int(state.turn) + 1))
	state.loot = d.get("loot", {})
	if d.has("shops"):
		state.shops = d.shops
	var cb: Dictionary = d.get("combat", {})
	if not cb.is_empty() and _all_have_heroes():
		state.combat = cb
		cb.wait = false
		_log("cbt", "", "Бой продолжается с того места, где прервался.")
		_set_phase("combat")
		_combat_continue()
		return
	_set_phase("play" if _all_have_heroes() else "create")


## Разовая починка старых сохранений: до 0.10 ведущий раздавал «Награду» золотом за каждый разговор.
func _fix_bug_gold() -> void:
	if state.campaign.get("gold_fix", false):
		return
	state.campaign.gold_fix = true
	var rx := RegEx.create_from_string("^Награда: \\d+ золота, каждому по (\\d+)")
	var extra := 0
	for e in state.log:
		var m := rx.search(str(e.get("t", "")))
		if m:
			extra += int(m.get_string(1))
	var parts := []
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		var before := int(h.gold)
		var g := maxi(0, before - extra)
		if g > 300:
			g = 30   # остальное тоже пришло через ту ошибку: оставляем честный походный кошелёк
		if g != before:
			h.gold = g
			parts.append("%s: %d → %d" % [h.name, before, g])
	if parts.size() > 0:
		_log("sys", "", "Исправлено золото, выданное по ошибке: " + ", ".join(parts) + ".")


## Передать кампанию напарнику: она ляжет в свободную ячейку на его телефоне, и он сможет стать хостом.
func give_save_to_partner(i: int) -> void:
	if not Net.is_host():
		return
	var d = _read_save(i)
	if not (d is Dictionary):
		return
	for id in Net.players:
		if int(id) != Net.my_id():
			_receive_save.rpc_id(int(id), JSON.stringify(d))


@rpc("authority", "call_remote", "reliable")
func _receive_save(txt: String) -> void:
	var d = JSON.parse_string(txt)
	if not (d is Dictionary) or not d.has("heroes"):
		return
	var to := free_slot()
	var f := FileAccess.open(slot_path(to), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(txt)
	f.close()
	save_received.emit(to, str(d.get("campaign", {}).get("title", "кампания")))


## «Летопись»: вся история кампании одним текстом.
func chronicle_text() -> String:
	var c: Dictionary = state.campaign
	var out := PackedStringArray()
	out.append("ХРОНИКИ ДВОИХ — «%s»" % str(c.get("title", "Без названия")))
	var heroes := []
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		heroes.append("%s (%s %s, %d ур.)" % [h.name, h.get("race", ""), h.get("cls", ""), int(h.get("level", 1))])
	out.append("Герои: " + ", ".join(heroes))
	if str(c.get("world", "")) != "":
		out.append("Мир: " + str(c.world))
	if str(c.get("chronicle", "")) != "":
		out.append("\nКратко: " + str(c.chronicle))
	out.append("")
	for e in _story_all:
		match str(e.k):
			"gm":
				out.append(str(e.t) + "\n")
			"act":
				out.append("— %s: %s" % [e.w, e.t])
			_:
				out.append("✦ " + str(e.t))
	return "\n".join(out)


func request_chronicle() -> void:
	if Net.is_host():
		chronicle_ready.emit(chronicle_text())
	else:
		_ask_chronicle.rpc_id(1)


@rpc("any_peer", "reliable")
func _ask_chronicle() -> void:
	if Net.is_host():
		_send_chronicle.rpc_id(multiplayer.get_remote_sender_id(), chronicle_text())


@rpc("authority", "reliable")
func _send_chronicle(text: String) -> void:
	chronicle_ready.emit(text)


func back_to_lobby() -> void:
	if Net.is_host():
		state = _fresh_state()
		_set_phase("lobby")


func save_dict() -> Dictionary:
	return {"campaign": state.campaign, "heroes": state.heroes,
		"log": state.log.slice(-150), "options": state.options, "turn": state.turn, "map": state.map,
		"companions": state.get("companions", []), "chat": state.get("chat", []).slice(-40), "chat_n": int(state.get("chat_n", 0)),
		"combat": state.combat if phase == "combat" else {}, "loot": state.get("loot", {}), "shops": state.get("shops", {}),
		"saved_at": Time.get_datetime_string_from_system(false, true), "story_all": _story_all}


## Запись без риска потерять кампанию: сначала во временный файл, прошлая версия остаётся как .bak.
func _save() -> void:
	if state.get("campaign", {}).is_empty() or state.heroes.is_empty():
		return
	var path := slot_path(slot)
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(save_dict()))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path + ".bak")
		DirAccess.rename_absolute(path, path + ".bak")
	DirAccess.rename_absolute(path + ".tmp", path)
	state.saves = save_infos()


static func _parse_save(path: String):
	if not FileAccess.file_exists(path):
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary and d.has("heroes") and d.has("campaign") else null


## Ячейка: основной файл, при поломке — резервная копия.
static func _read_save(i: int):
	_migrate_old_save()
	var d = _parse_save(slot_path(i))
	if d == null:
		d = _parse_save(slot_path(i) + ".bak")
	return d


static func _migrate_old_save() -> void:
	if FileAccess.file_exists(OLD_SAVE_PATH) and not FileAccess.file_exists(slot_path(0)):
		DirAccess.rename_absolute(OLD_SAVE_PATH, slot_path(0))


static func free_slot() -> int:
	for i in SLOTS:
		if _read_save(i) == null:
			return i
	return 0


func delete_slot(i: int) -> void:
	if not Net.is_host():
		return
	for ext in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(slot_path(i) + ext)
	state.saves = save_infos()
	_broadcast()


## Описание всех ячеек для меню: [{"slot", "info"}], info пустой — ячейка свободна.
static func save_infos() -> Array:
	var out := []
	for i in SLOTS:
		var d = _read_save(i)
		var info := ""
		if d is Dictionary:
			var names := []
			for n in d.get("heroes", {}):
				var h: Dictionary = d.heroes[n]
				names.append("%s, %s %d ур." % [h.get("name", n), h.get("cls", ""), int(h.get("level", 1))])
			info = "«%s», ход %d (%s)%s" % [d.campaign.get("title", "Без названия"), int(d.get("turn", 0)), "; ".join(names),
				" · идёт бой" if not d.get("combat", {}).is_empty() else ""]
		out.append({"slot": i, "info": info})
	return out


func _log(kind: String, who: String, text: String, to := "") -> void:
	# сквозной номер записи: журнал обрезается до 200 строк, а телефоны по номеру понимают, что появилось новое
	if not state.has("log_n"):
		var mx: int = state.log.size()
		for e in state.log:
			mx = maxi(mx, int(e.get("i", 0)))
		state.log_n = mx
	state.log_n = int(state.log_n) + 1
	var e := {"k": kind, "w": who, "t": text, "i": int(state.log_n)}
	if to != "":
		e.to = to
	state.log.append(e)
	if kind in ["gm", "act", "quest", "lvl", "loot"] and to == "":
		_story_all.append({"k": kind, "w": who, "t": text, "turn": int(state.get("turn", 0))})
	if state.log.size() > 200:
		state.log = state.log.slice(-200)


## Сложность от ведущего не выше разумного для уровня героев: 1–2 ур. — до 18, 3–4 — до 20, дальше выше.
func _dc_fair(dc: int) -> int:
	return clampi(dc, 5, 16 + 2 * _tier())


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
		var pn := str(p.name).left(30)
		var known := false
		for n in state.map.get("nodes", []):
			if str(n.name).strip_edges().to_lower() == pn.strip_edges().to_lower():
				known = true
		var ti := MapView.target_index(MapView._sanitize(state.map), pn)
		if ti >= 0:
			_log("quest", "", "Вы добрались: %s" % pn)
		elif not known:
			state.map = MapView.tick_targets(state.map)   # новое место в пути — до цели на событие ближе
		state.map = MapView.add_place(state.map, pn, t)
		state.campaign.scene = str(p.name)


# ---------- ход вне боя ----------

func _resolve() -> void:
	if _busy:
		return
	_busy = true
	var acts := {}
	var helps := _helps.duplicate()
	var optchk := _optchk.duplicate()
	var secret := _secret.duplicate()
	_helps = {}
	_optchk = {}
	_secret = {}
	for n in _active_names():
		acts[n] = str(_actions.get(n, "ждёт и наблюдает"))
		if helps.has(n):
			acts[n] = "(помогает %s) %s" % [state.heroes[helps[n]].name, acts[n]]
		if secret.has(n):
			_log("act", str(state.heroes[n].name), "🤫 " + acts[n], n)
			_log("act", str(state.heroes[n].name), "…что-то делает втайне от тебя.", "!" + n)
			acts[n] = "(ТАЙНО от напарника) " + acts[n]
		else:
			_log("act", str(state.heroes[n].name), acts[n])
	_actions = {}
	_set_phase("thinking")

	# 1) какие нужны проверки
	var rolls := []
	var res: Dictionary = await LLM.chat_json(_checks_prompt(acts), 0.3, 500)
	if not Net.is_host():
		return
	var asks := []
	var seen := {}
	for n in optchk:
		if acts.has(n):
			var oc: Dictionary = optchk[n]
			var pa := _make_ask(n, str(oc.kind), str(oc.what), int(oc.dc), 0, "выбранная реплика")
			if not pa.is_empty():
				seen[n] = true
				asks.append(pa)
	for n in helps:
		seen[n] = true   # помощник не кидает: он даёт преимущество напарнику
	if res.ok and res.data.get("checks") is Array:
		for c in res.data.checks:
			if not (c is Dictionary):
				continue
			var pname := _player_by_hero(str(c.get("who", "")))
			if pname == "" or seen.has(pname) or not acts.has(pname):
				continue
			var cname := str(c.get("name", ""))
			if str(c.get("ability", "")).strip_edges() != "":
				cname += "|" + str(c.get("ability", ""))
			var a := _make_ask(pname, str(c.get("kind", "skill")), cname, _dc_fair(int(c.get("dc", 12))),
				int(c.get("adv", 0)), str(c.get("why", "")))
			if a.is_empty():
				continue
			if _b(c.get("tools", false)):
				a.tools = true
				if _find_item(state.heroes[pname].items, "thieves_tools") < 0:
					a.adv = clampi(int(a.adv) - 1, -1, 1)
					a.why = str(a.why) + " · без инструментов"
			if str(c.get("trap_dmg", "")) != "":
				a.trap_dmg = _safe_dice(str(c.trap_dmg))
				a.trap_cond = R.cond_from(str(c.get("cond", "")))
			seen[pname] = true
			asks.append(a)
	for a in asks:
		for hn in helps:
			if str(helps[hn]) == str(a.who):
				a.adv = clampi(int(a.adv) + 1, -1, 1)
				a.why = (str(a.why) + " · помогает " + str(state.heroes[hn].name)).strip_edges()
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


## Ночь в лагере после ночлега: сцена у костра, разговоры, одобрение спутников, личные просьбы.
func _camp_night() -> void:
	if not Net.is_host() or _busy or phase != "play" or not state.combat.is_empty():
		return
	_busy = true
	_set_phase("thinking")
	var res: Dictionary = await LLM.chat_json(_camp_prompt(), 0.95, 1300)
	_busy = false
	if not Net.is_host():
		return
	if not res.ok or str(res.data.get("story", "")) == "":
		_set_phase("play")
		return
	var d: Dictionary = res.data
	d.erase("rest")
	d.erase("combat")
	_log("sys", "", "🔥 Ночь у костра")
	_apply_narration(d, false)


func _camp_prompt() -> Array:
	var sys := GM_RULES + """
Сейчас ночь в лагере: герои отдыхают у костра. Это тихая сцена без боя (combat пустой, rest пустой), как ночи в лагере в больших ролевых играх.
Опиши 5-8 предложений: о чём говорят герои, с прямой речью; вспомни их недавние решения и поступки.
Если есть спутники — один из них говорит по душам: рассказывает о себе, спорит или хвалит решения героев (отрази это в approval). Если спутник верный (одобрение 5 и выше) и у него ещё нет личного задания — он открывает свою личную просьбу: добавь её в quests с названием «Личное: <имя спутника> — <суть>».
Если спутников нет — герои говорят друг с другом о прошлом, страхах и цели, или ночью случается тихое странное событие (знак, сон, гость у костра), без боя.
Закончи рассветом и тем, что ждёт героев утром. options — реплики или утренние действия.
""" + NARRATE_FORMAT + _names_rule() + "\nКаталог предметов (id=название): " + R.catalog_text()
	var user := "%s\nГерои:\n%s\n\nНедавние события:\n%s" % [_campaign_text(), _heroes_text(), _recent_log(20)]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


## Одобрение спутников: как в BG3 — им нравятся или не нравятся решения героев.
func _apply_approval(arr) -> void:
	if not (arr is Array):
		return
	for a in arr:
		if not (a is Dictionary):
			continue
		var nm := str(a.get("who", "")).strip_edges().to_lower()
		var dv := clampi(int(a.get("d", 0)), -2, 2)
		if nm == "" or dv == 0:
			continue
		var cps: Array = state.get("companions", [])
		for i in range(cps.size() - 1, -1, -1):
			var cp: Dictionary = cps[i]
			if str(cp.name).to_lower() != nm and not str(cp.name).to_lower().begins_with(nm.left(5)):
				continue
			if cp.get("beast", false):
				break
			cp.appr = clampi(int(cp.get("appr", 0)) + dv, -10, 10)
			var why := str(a.get("why", "")).left(80)
			_log("sys", "", "%s %s%s (%+d, теперь %d)." % [cp.name, "одобряет" if dv > 0 else "не одобряет", (": " + why) if why != "" else "", dv, int(cp.appr)])
			if int(cp.appr) >= 5 and not cp.get("loyal", false):
				cp.loyal = true
				cp.atk = int(cp.atk) + 1
				cp.max_hp = int(cp.max_hp) + 6
				cp.hp = int(cp.hp) + 6
				_log("sys", "", "💛 %s теперь верный друг отряда: бьётся яростнее (+1 к атаке, +6 хитов). У костра может открыть личную просьбу." % cp.name)
			elif int(cp.appr) <= -5:
				_log("sys", "", "💔 %s больше не может терпеть ваши решения и уходит из отряда." % cp.name)
				cps.remove_at(i)
			break


## Применяет ответ ведущего: рассказ, изменения, место, сундук, лавка, бой, отдых.
func _apply_narration(d: Dictionary, allow_combat: bool) -> void:
	_log("gm", "", str(d.story))
	var sec = d.get("secret", {})
	if sec is Dictionary:
		for k in sec:
			var pn := _player_by_hero(str(k))
			if pn == "" and state.heroes.has(str(k)):
				pn = str(k)
			if pn != "" and str(sec[k]).strip_edges() != "":
				_log("gm", "", "🤫 " + str(sec[k]).strip_edges(), pn)
	_apply_approval(d.get("approval", []))
	_apply_journal(d)
	if allow_combat:
		_apply_changes(d.get("changes", []), str(d.story))
	_apply_place(d.get("place"))
	if str(d.get("quest", "")) != "":
		state.campaign.quest = str(d.quest)
	state.options = _map_options(d.get("options", {}))
	var ins := str(d.get("inspire", "")).strip_edges()
	if ins != "" and int(state.turn) - int(state.campaign.get("insp_turn", -99)) >= 3:
		for n in state.heroes:
			if str(state.heroes[n].name) == ins or n == ins:
				state.campaign.insp_turn = int(state.turn)
				_gain_insp("%s — яркий отыгрыш" % state.heroes[n].name)
				break
	var rest := str(d.get("rest", ""))
	if rest in ["long", "short"]:
		_do_rest(rest, false)
	_apply_world(d)
	if allow_combat and str(d.get("chest", "")) != "" and int(state.turn) - int(state.campaign.get("last_chest", -99)) >= 2:
		state.campaign.last_chest = int(state.turn)
		_open_chest(str(d.chest))
	if allow_combat and str(d.get("shop", "")) != "":
		_open_shop(str(d.shop).left(40), _active_names())
	state.turn = int(state.turn) + 1
	state.pending = []
	_save()
	_apply_goal(d.get("goal", ""))
	if allow_combat and d.get("combat") is Array and (d.combat as Array).size() > 0:
		if int(state.turn) - int(state.campaign.get("last_combat", -99)) < COMBAT_GAP:
			print("[combat] отклонён: слишком часто")
			_log("sys", "", "Противники не решаются напасть и отступают в тень.")
		elif _start_combat(d.combat, d.get("env", []) if d.get("env") is Array else []):
			return
	_set_phase("play")
	var gd = d.get("goal")
	var marked: bool = gd is Dictionary and gd.has("done_steps")
	if d.get("quests") is Array:
		for q in d.quests:
			if q is Dictionary and (q.has("done_steps") or str(q.get("status", "")) == "done"):
				marked = true
	_extract_quests(str(d.story), d.get("quests") is Array and (d.quests as Array).size() > 0, marked)
	var vd = d.get("vote")
	if vd is Dictionary and str(vd.get("q", "")) != "" and vd.get("opts") is Array and (vd.opts as Array).size() >= 2:
		var vo := []
		for o in vd.opts:
			vo.append(str(o).left(60))
		_begin_vote(str(vd.q), vo, "story", "")
	if int(state.turn) % 8 == 0:
		_update_chronicle()


const ATT_NAMES := {-3: "враг", -2: "неприязнь", -1: "настороженно", 0: "нейтрально", 1: "дружелюбно", 2: "друг", 3: "верный союзник"}


func att_name(v: int) -> String:
	return str(ATT_NAMES.get(clampi(v, -3, 3), "нейтрально"))


## Репутация, последствия решений и спутники из ответа ведущего.
func _apply_world(d: Dictionary) -> void:
	var c: Dictionary = state.campaign
	var rp = d.get("rep", [])
	if rp is Array:
		if not c.has("rep"):
			c.rep = {}
		for r in rp:
			if not (r is Dictionary) or str(r.get("name", "")) == "":
				continue
			var nm := str(r.name).strip_edges().left(40)
			var ch := clampi(int(r.get("change", 0)), -2, 2)
			if ch == 0:
				continue
			c.rep[nm] = clampi(int(c.rep.get(nm, 0)) + ch, -5, 5)
			_log("rep", "", "Репутация: %s %s (%+d)%s" % [nm, "растёт" if ch > 0 else "падает", int(c.rep[nm]),
				(" — " + str(r.get("why", "")).left(80)) if str(r.get("why", "")) != "" else ""])
	var cq = d.get("consequences", [])
	if cq is Array:
		if not c.has("threads"):
			c.threads = []
		for t in cq:
			var tx := str(t).strip_edges().left(140)
			var dup := false
			for e in c.threads:
				if str(e.t).to_lower() == tx.to_lower():
					dup = true
			if tx != "" and not dup and (c.threads as Array).size() < 30:
				c.threads.append({"t": tx, "turn": int(state.turn), "s": "open"})
				_log("quest", "", "Это решение ещё аукнется: " + tx)
	var rs = d.get("resolved", [])
	if rs is Array:
		for t in rs:
			var key := str(t).strip_edges().to_lower().left(14)
			for e in c.get("threads", []):
				if e.s == "open" and key != "" and str(e.t).to_lower().contains(key):
					e.s = "done"
	var cps = d.get("companions", [])
	if cps is Array:
		if not state.has("companions"):
			state.companions = []
		for cp in cps:
			if not (cp is Dictionary) or str(cp.get("name", "")) == "":
				continue
			var nm := str(cp.name).left(30)
			if _b(cp.get("leave", false)):
				for i in range(state.companions.size() - 1, -1, -1):
					if str(state.companions[i].name).to_lower() == nm.to_lower():
						_log("sys", "", "%s покидает отряд." % nm)
						state.companions.remove_at(i)
				continue
			var exists := false
			for e in state.companions:
				if str(e.name).to_lower() == nm.to_lower():
					exists = true
			if exists or (state.companions as Array).size() >= 2:
				continue
			var mid := str(cp.get("monster", "bandit"))
			var base: Dictionary = R.MONSTERS.get(mid, R.MONSTERS["bandit"])
			var owner := _player_by_hero(str(cp.get("owner", "")))
			var hpv := clampi(int(base.hp), 5, 40)
			state.companions.append({"name": nm, "kind": str(cp.get("kind", "спутник")).left(20), "mon": mid if R.MONSTERS.has(mid) else "bandit",
				"hp": hpv, "max_hp": hpv, "ac": int(base.ac), "atk": int(base.atk), "dmg": str(base.dmg), "owner": owner,
				"appr": 0, "about": str(cp.get("about", "")).left(120)})
			_log("sys", "", "К отряду присоединяется %s (%s): будет сражаться рядом с героями." % [nm, str(cp.get("kind", "спутник"))])


const QUEST_HINTS := ["прос", "поруч", "задани", "помоги", "помож", "нужно", "надо", "найдите", "принесите", "доставь", "награ", "заплачу", "если вы", "работ", "услуг"]


## Ведущий иногда забывает записать поручение: если в рассказе похоже на просьбу, отдельно спрашиваем, есть ли новое задание.
func _extract_quests(story: String, got_quests := false, got_marks := false) -> void:
	if OS.get_environment("ALIBI_MOCK") != "":
		return
	var low := story.to_lower()
	var hit := false
	for k in QUEST_HINTS:
		if low.contains(k):
			hit = true
			break
	var c: Dictionary = state.campaign
	var act := []
	var open_steps := []
	for q in c.get("quests", []):
		if q.s == "active":
			var sts := []
			for e in q.get("st", []):
				if not e.ok:
					sts.append(str(e.t))
					open_steps.append(str(e.t))
			act.append(str(q.t) + ((" [пункты: " + "; ".join(sts) + "]") if sts.size() > 0 else ""))
	for e in c.get("goal_steps", []):
		if not e.ok:
			open_steps.append(str(e.t))
	var need_new := hit and not got_quests
	var need_marks := not got_marks and (open_steps.size() > 0 or act.size() > 0)
	if not need_new and not need_marks:
		return
	var goal_line := ""
	if str(c.get("goal", "")) != "":
		var gs := []
		for e in c.get("goal_steps", []):
			if not e.ok:
				gs.append(str(e.t))
		goal_line = "\nЦель группы: %s%s" % [c.goal, (" [пункты: " + "; ".join(gs) + "]") if gs.size() > 0 else ""]
	var sys := """Ты секретарь ролевой игры, ведёшь дневник. Прочитай отрывок и сверь с записанными заданиями.
1) Если в отрывке кто-то дал героям НОВОЕ поручение или герои взяли новую цель, которой нет в списке и которая не совпадает с целью группы или её пунктами — верни в quests.
2) Если в отрывке что-то из пунктов УЖЕ сделано (механизм активировали, лодку нашли, до места добрались) — верни точный текст этих пунктов в done_steps.
3) Если задание целиком выполнено — его точное название в done_quests.
Не выдумывай: только то, что прямо случилось в отрывке. Ответь строго JSON: {"quests": [{"title": "до 6 слов", "note": "кто дал и что нужно", "status": "new"}], "done_steps": [], "done_quests": []}"""
	var user := "Записанные задания: %s%s\n\nОтрывок:\n%s" % ["; ".join(act) if act.size() > 0 else "нет", goal_line, story]
	var res: Dictionary = await LLM.chat_json([{"role": "system", "content": sys}, {"role": "user", "content": user}], 0.2, 400)
	if not Net.is_host() or not res.ok:
		return
	var r: Dictionary = res.data
	var qs := []
	if need_new and r.get("quests") is Array:
		qs = (r.quests as Array).duplicate()
	var ds = r.get("done_steps", [])
	if ds is Array and ds.size() > 0:
		for q in c.get("quests", []):
			if q.s == "active":
				_merge_steps(q, "st", {"done_steps": ds}, "задания", str(q.t))
		if str(c.get("goal", "")) != "":
			_merge_steps(c, "goal_steps", {"done_steps": ds}, "цели", str(c.goal))
	var dq = r.get("done_quests", [])
	if dq is Array:
		for t in dq:
			qs.append({"title": str(t), "status": "done"})
	if qs.size() > 0:
		_apply_journal({"quests": qs})
	_save()
	_broadcast()


## Похожи ли два названия задания/пункта: «Найти зацепку» и «Найти зацепку (через карту…)» — одно и то же.
static func _qkey(t: String) -> String:
	var x := t.to_lower().replace("ё", "е")
	var p := x.find("(")
	if p > 0:
		x = x.left(p)
	for ch in ["«", "»", "\"", ".", ",", "!", "?", ":", "—", "-"]:
		x = x.replace(ch, " ")
	return " ".join(x.split(" ", false))


static func _same_quest(a: String, b: String) -> bool:
	var x := _qkey(a)
	var y := _qkey(b)
	if x == "" or y == "":
		return false
	if x == y or (x.length() >= 10 and y.begins_with(x)) or (y.length() >= 10 and x.begins_with(y)):
		return true
	# совпадение по смыслу: большинство значимых слов одинаковы (по основе из 5 букв)
	var wa := {}
	for w in x.split(" ", false):
		if w.length() >= 4:
			wa[w.left(5)] = true
	var wb := {}
	for w in y.split(" ", false):
		if w.length() >= 4:
			wb[w.left(5)] = true
	if wa.size() < 2 or wb.size() < 2:
		return false
	var common := 0
	for k in wa:
		if wb.has(k):
			common += 1
	return float(common) / float(mini(wa.size(), wb.size())) >= 0.75


## Убираем дубли: одинаковые задания склеиваем, задания-копии цели группы или её пунктов убираем.
func _dedup_quests() -> void:
	var c: Dictionary = state.campaign
	var qs: Array = c.get("quests", [])
	var keep := []
	for q in qs:
		if q.s == "active":
			if str(c.get("goal", "")) != "" and _same_quest(str(q.t), str(c.goal)):
				_merge_steps(c, "goal_steps", {"steps": (q.get("st", []) as Array).map(func(e): return e.t)}, "цели", str(c.goal))
				continue
			var is_step := false
			for e in c.get("goal_steps", []):
				if _same_quest(str(q.t), str(e.t)):
					is_step = true
			if is_step:
				continue
		var twin: Dictionary = {}
		for k in keep:
			if k.s == q.s and _same_quest(str(k.t), str(q.t)):
				twin = k
				break
		if twin.is_empty():
			keep.append(q)
			continue
		if _qkey(str(q.t)).length() < _qkey(str(twin.t)).length():
			twin.t = q.t   # оставляем короткое, без хвоста в скобках
		if str(twin.get("d", "")) == "":
			twin.d = q.get("d", "")
		var st: Array = twin.get("st", [])
		for e in q.get("st", []):
			var f := false
			for e2 in st:
				if _same_quest(str(e2.t), str(e.t)):
					e2.ok = e2.ok or e.ok
					f = true
			if not f and st.size() < 8:
				st.append(e)
		twin.st = st
	c.quests = keep


## Цель группы: строка или {"t", "steps", "done_steps", "place"}. Пункты видны в дневнике.
func _apply_goal(g) -> void:
	var c: Dictionary = state.campaign
	var gd: Dictionary = {}
	if g is Dictionary:
		gd = g
	elif g is String:
		var gs := str(g).strip_edges()
		if gs.begins_with("{"):
			var j = JSON.parse_string(gs)
			if j is Dictionary:
				gd = j
		if gd.is_empty():
			gd = {"t": gs}
	var gl := str(gd.get("t", gd.get("title", ""))).strip_edges()
	if gl == "done" or _b(gd.get("done", false)):
		if str(c.get("goal", "")) != "":
			_log("quest", "", "Цель достигнута: " + str(c.goal))
			_gain_insp("цель достигнута")
			state.map = MapView.drop_targets(state.map, "★" + str(c.goal))
		c.goal = ""
		c.goal_steps = []
		return
	var cur_goal := str(c.get("goal", ""))
	if gl != "" and cur_goal != "" and not _same_quest(gl, cur_goal):
		# ведущий подсунул пункт текущей цели вместо неё самой — цель не меняем, пункт отметится отдельно
		for e in c.get("goal_steps", []):
			if not e.ok and _same_quest(gl, str(e.t)):
				gl = cur_goal
				break
	if gl != "" and not _same_quest(gl, cur_goal):
		if cur_goal != "":
			var left := 0
			for e in c.get("goal_steps", []):
				if not e.ok:
					left += 1
			_log("quest", "", "Цель сменилась: «%s»%s." % [cur_goal, (" осталась незаконченной (%d пунктов)" % left) if left > 0 else ""])
			state.map = MapView.drop_targets(state.map, "★" + cur_goal)
		c.goal = gl.left(100)
		c.goal_turn = int(state.turn)
		c.goal_steps = []
		_log("quest", "", "Цель группы: " + gl.left(100))
	if str(c.get("goal", "")) == "":
		return
	_merge_steps(c, "goal_steps", gd, "цели", str(c.goal))
	_add_target_from(gd.get("place"), "★" + str(c.goal))
	_dedup_quests()


## Пункты задания или цели: новые добавляются, выполненные отмечаются галочкой.
func _merge_steps(holder: Dictionary, key: String, d: Dictionary, what: String, title := "") -> void:
	if not holder.has(key) or not (holder[key] is Array):
		holder[key] = []
	var st: Array = holder[key]
	var steps = d.get("steps", [])
	if steps is Array:
		for x in steps:
			var tx := str(x.get("t", "") if x is Dictionary else x).strip_edges().left(70)
			if tx == "" or st.size() >= 8 or (title != "" and _same_quest(tx, title)):
				continue
			if not st.any(func(e): return _same_quest(str(e.t), tx)):
				st.append({"t": tx, "ok": false})
	var done = d.get("done_steps", [])
	if done is String:
		done = [done]
	if done is Array:
		for x in done:
			var tx := str(x).strip_edges()
			for e in st:
				if not e.ok and _same_quest(str(e.t), tx):
					e.ok = true
					_log("quest", "", "Пункт %s выполнен: %s" % [what, e.t])
					break


## Место из задания, если известно, где оно: сразу на карту.
func _add_target_from(pl, quest: String) -> void:
	if not (pl is Dictionary) or str(pl.get("name", "")).strip_edges() == "":
		return
	var had := MapView.target_index(MapView._sanitize(state.map), str(pl.name)) >= 0
	state.map = MapView.add_target(state.map, str(pl.name), str(pl.get("type", "ruins")), int(pl.get("dist", 3)), quest)
	var m := MapView._sanitize(state.map)
	var ti := MapView.target_index(m, str(pl.name))
	if ti >= 0 and not had:
		var left := int(m.targets[ti].left)
		_log("quest", "", "На карте отмечено: %s — в пути %d %s." % [str(m.targets[ti].name), left, MapView._events_word(left)])


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
				if _same_quest(str(e.t), title) and (found.is_empty() or e.s == "active"):
					found = e
			if found.is_empty():
				if st in ["done", "failed"]:
					continue
				var dup_goal := str(c.get("goal", "")) != "" and _same_quest(title, str(c.goal))
				for e in c.get("goal_steps", []):
					if _same_quest(title, str(e.t)):
						dup_goal = true
				if dup_goal:
					continue   # это и так цель группы или её пункт — второй раз не пишем
				found = {"t": title, "d": str(q.get("note", "")).left(200), "s": "active", "turn": int(state.turn)}
				c.quests.append(found)
				_log("quest", "", "Новое задание: %s" % title)
				_merge_steps(found, "st", q, "задания", title)
				_add_target_from(q.get("place"), title)
			elif found.s == "active":
				_merge_steps(found, "st", q, "задания", str(found.t))
				_add_target_from(q.get("place"), title)
				if str(q.get("note", "")) != "":
					found.d = str(q.note).left(200)
				if st == "done" and found.s == "active":
					for e2 in c.quests:
						if e2.s == "active" and _same_quest(str(e2.t), title):
							e2.s = "done"   # и его дубли тоже
					state.map = MapView.drop_targets(state.map, title)
					_log("quest", "", "Задание выполнено: %s" % found.t)
				elif st == "failed" and found.s == "active":
					found.s = "failed"
					state.map = MapView.drop_targets(state.map, title)
					_log("quest", "", "Задание провалено: %s" % title)
	_dedup_quests()
	var ns = d.get("npcs", [])
	if ns is Array:
		for n in ns:
			if not (n is Dictionary):
				continue
			var nm := str(n.get("name", "")).strip_edges().left(40)
			if nm == "":
				continue
			var known: Dictionary = {}
			for e in c.npcs:
				if str(e.n).to_lower() == nm.to_lower():
					known = e
					if str(n.get("note", "")) != "":
						e.d = str(n.note).left(160)
			if known.is_empty() and c.npcs.size() < 40:
				known = {"n": nm, "d": str(n.get("note", "")).left(160), "a": 0}
				c.npcs.append(known)
			var da := clampi(int(n.get("attitude", 0)), -2, 1)
			# дружба растёт медленно: не чаще раза в 4 хода, а выше «друга» — только раз в 8 ходов
			if da > 0 and not known.is_empty():
				var gap := 8 if int(known.get("a", 0)) >= 1 else 4
				if int(state.turn) - int(known.get("up", -99)) < gap:
					da = 0
				else:
					known.up = int(state.turn)
			if not known.is_empty() and da != 0:
				var before := int(known.get("a", 0))
				known.a = clampi(before + da, -3, 3)
				if int(known.a) != before:
					_log("rel", "", "%s: отношение %s — %s" % [nm, "улучшилось" if da > 0 else "испортилось", att_name(int(known.a))])


func _journal_text() -> String:
	var c: Dictionary = state.campaign
	var act := []
	for q in c.get("quests", []):
		if q.s == "active":
			var sts := []
			for e in q.get("st", []):
				sts.append(("[x] " if e.ok else "[ ] ") + str(e.t))
			act.append("%s (%s)%s" % [q.t, q.d, (" пункты: " + "; ".join(sts)) if sts.size() > 0 else ""])
	var who := []
	for n in c.get("npcs", []).slice(-12):
		who.append("%s — %s [отношение к героям: %s]" % [n.n, n.d, att_name(int(n.get("a", 0)))])
	var reps := []
	for k in c.get("rep", {}):
		reps.append("%s %+d" % [k, int(c.rep[k])])
	var th := []
	for e in c.get("threads", []):
		if e.s == "open" and int(state.turn) - int(e.turn) >= 3:
			th.append(str(e.t))
	var cps := []
	for cp in state.get("companions", []):
		cps.append("%s (%s, %d/%d хитов%s%s)" % [cp.name, cp.kind, int(cp.hp), int(cp.max_hp),
			"" if cp.get("beast", false) else ", одобрение %d%s" % [int(cp.get("appr", 0)), ", ВЕРНЫЙ" if cp.get("loyal", false) else ""],
			(", " + str(cp.about)) if str(cp.get("about", "")) != "" else ""])
	var conds := []
	for n in state.heroes:
		for k in state.heroes[n].get("conds", {}):
			conds.append("%s: %s" % [state.heroes[n].name, R.CONDS[k].name])
	var shop_ctx := []
	for mn in merchants_here():
		var md: Dictionary = c.merchants[mn]
		var goods := []
		for it in md.get("items", []):
			goods.append("%s (%d зол.)" % [R.item_name(it), R.item_price(it)])
		shop_ctx.append("%s продаёт: %s" % [mn, ", ".join(goods) if goods.size() > 0 else "всё распродано"])
	return ("\nТорговцы здесь и их товар (торговец знает свой товар и цены, предлагает только это; ничего другого у него нет): %s" % "; ".join(shop_ctx) if shop_ctx.size() > 0 else "") + "\nАктивные задания: %s\nЗнакомые персонажи: %s\nРепутация героев (от -5 до 5): %s\nОтложенные последствия прошлых решений (когда уместно, верни одно в сюжет и отметь в resolved): %s\nСпутники отряда: %s\nСостояния героев: %s" % [
		"; ".join(act) if act.size() > 0 else "нет", "; ".join(who) if who.size() > 0 else "нет",
		", ".join(reps) if reps.size() > 0 else "пока никто не знает", "; ".join(th) if th.size() > 0 else "нет",
		", ".join(cps) if cps.size() > 0 else "нет", ", ".join(conds) if conds.size() > 0 else "нет"]


## Готовит проверку, которую игрок бросит сам: показываем сложность, ждём нажатия «Бросить».
func _make_ask(pname: String, kind: String, what: String, dc: int, adv: int, why: String) -> Dictionary:
	var h: Dictionary = state.heroes[pname]
	var info := _check_info(h, kind, what)
	if info.is_empty():
		return {}
	if kind != "save":
		adv += R.check_adv(h)
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
			_ask_effects(a)
			rolls.append(a.result)
	state.ask = []
	return rolls


## Последствия бросков, которые считает сама игра: урон ловушки, сломанные отмычки.
func _ask_effects(a: Dictionary) -> void:
	var r: Dictionary = a.result
	var pname := str(a.who)
	if not state.heroes.has(pname) or r.is_empty():
		return
	var h: Dictionary = state.heroes[pname]
	var failed := str(r.outcome).contains("провал")
	if str(a.get("trap_dmg", "")) != "" and failed:
		var dmg := mini(R.roll(str(a.trap_dmg)), int(h.hp) - 1)
		if dmg > 0:
			_damage_hero(pname, dmg, false)
		var extra := ""
		var cn := str(a.get("trap_cond", ""))
		if cn != "":
			_add_cond(h, cn, 3)
			extra = ", " + str(R.CONDS[cn].name).to_lower()
		_log("sys", h.name, "Ловушка: %s получает %d урона%s (%d/%d)." % [h.name, maxi(0, dmg), extra, h.hp, h.max_hp])
		r.text = str(r.text) + " (ловушка сработала: %d урона%s)" % [maxi(0, dmg), extra]
	# опыт за удачную проверку получает тот, кто кидал, — каждому игроку поровну по сложности
	if not failed and int(r.get("dc", 0)) >= 10:
		var xp := int(r.dc) * (2 if str(r.outcome).begins_with("крит") else 1)
		_give_xp(pname, xp)
	if a.get("tools", false) and failed and (int(r.dc) - int(r.total) >= 5 or int(r.d20) == 1):
		var ti := _find_item(h.items, "thieves_tools")
		if ti >= 0:
			h.items.remove_at(ti)
			_log("sys", h.name, "Отмычка ломается в замке! %s лишается воровских инструментов." % h.name)
			r.text = str(r.text) + " (отмычки сломались)"


func _asks_done() -> bool:
	for a in state.ask:
		if not a.done:
			return false
	return true


func roll_now(use_insp := false) -> void:
	_roll_rpc.rpc_id(1, use_insp)


@rpc("any_peer", "call_local", "reliable")
func _roll_rpc(use_insp: bool) -> void:
	if Net.is_host():
		_do_roll(_sender_name(), use_insp)


func _do_roll(pname: String, use_insp := false) -> void:
	for a in state.ask:
		if str(a.who) == pname and not a.done:
			if use_insp and insp_pool() > 0 and int(a.adv) < 1:
				state.campaign.insp = insp_pool() - 1
				a.adv = int(a.adv) + 1
				_log("sys", str(a.hero), "✨ %s тратит вдохновение группы: бросок %s." % [a.hero, "с преимуществом" if int(a.adv) > 0 else "без помехи"])
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
	var ab_over := ""
	if what.contains("|"):
		ab_over = _ability_from(what.get_slice("|", 1))
		what = what.get_slice("|", 0).strip_edges()
	if kind == "save" or what.to_lower().begins_with("спас"):
		var a := _ability_from(what)
		return {} if a == "" else {"label": "спасбросок " + a, "bonus": R.save_bonus(h, a)}
	var s := _skill_from(what)
	if s != "":
		var base: String = R.SKILLS.get(s, "СИЛ")
		if ab_over != "" and ab_over != base:
			# навык на другой характеристике: угрозы силой, обман умом и т.п.
			return {"label": "%s (%s)" % [s, ab_over], "bonus": R.skill_bonus(h, s) - R.amod(h, base) + R.amod(h, ab_over)}
		return {"label": s, "bonus": R.skill_bonus(h, s)}
	var a2 := _ability_from(what) if ab_over == "" else ab_over
	return {} if a2 == "" else {"label": str(R.AB_NAME[a2]), "bonus": R.amod(h, a2)}


## Проверка навыка / спасбросок / характеристика. Возвращает описание броска.
func _check(pname: String, kind: String, what: String, dc: int, adv: int, why: String) -> Dictionary:
	var h: Dictionary = state.heroes[pname]
	var info := _check_info(h, kind, what)
	if info.is_empty():
		return {}
	var bonus: int = int(info.bonus)
	var label: String = str(info.label)
	dc = clampi(dc, 5, 25)
	var r := _d20(h, clampi(adv, -1, 1))
	var total: int = r.value + bonus + r.insp
	var outcome := "успех" if total >= dc else "провал"
	if r.value == 20:
		outcome = "критический успех"
		_gain_insp("%s выбросил 20" % h.name)
	elif r.value == 1:
		outcome = "критический провал"
	var txt := "%s (%s): к20 = %d%s%s = %d против %d — %s" % [label, why, r.value, _sgn(bonus),
		(" + бонус %d" % r.insp) if r.insp > 0 else "", total, dc, outcome]
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
	if karmic and int(h.get("bad", 0)) >= 2 and v < 10:
		var k := randi_range(1, 20)
		if k > v:
			if v == a:
				a = k
			v = k
	h.bad = 0 if v >= 8 else int(h.get("bad", 0)) + 1
	var insp := 0
	if use_insp and h.get("inspired", false):
		insp = randi_range(1, 6)
		h.inspired = false
	if use_insp and h.get("blessed", false) and not state.get("combat", {}).is_empty():
		insp += randi_range(1, 4)
	return {"value": v, "other": b if b < 0 else (b if v == a else a), "adv": adv, "insp": insp}


func _apply_changes(changes, story := "") -> void:
	if not (changes is Array):
		return
	var reward_gold := _apply_changes_each(changes)
	# золото только если в рассказе о нём прямо сказано: ведущий не должен «откупаться» деньгами вместо вещи
	var low := story.to_lower()
	var money_words := low.contains("золот") or low.contains("монет") or low.contains("деньг") or low.contains("денег") or low.contains("кошел") or low.contains("плат")
	# награда — только если о деньгах прямо сказано и это заметное событие: названа сумма или выполнено задание
	var quest_done := false
	for e in state.log.slice(-6):
		if str(e.k) == "quest" and str(e.t).begins_with("Задание выполнено"):
			quest_done = true
	if story != "" and (not money_words or not (low.contains(str(reward_gold)) or quest_done)):
		if reward_gold > 0:
			print("[gold] отклонено %d: в рассказе нет суммы" % reward_gold)
		reward_gold = 0
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
	var group_xp := 0
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
		var cn := R.cond_from(str(c.get("cond", "")))
		if cn != "":
			_add_cond(h, cn, 3)
			_log("sys", hn, "%s: %s (%s)." % [hn, R.CONDS[cn].name, R.CONDS[cn].desc])
		var cu := R.cond_from(str(c.get("cure", "")))
		if cu != "" and h.get("conds", {}).has(cu):
			h.conds.erase(cu)
			_log("sys", hn, "%s больше не %s." % [hn, str(R.CONDS[cu].name).to_lower()])
		group_xp = maxi(group_xp, clampi(int(c.get("xp", 0)), 0, 400))
	# опыт за общее дело — всем героям одинаково, а не только тому, кого назвал ведущий
	if group_xp > 0:
		for n in _active_names():
			_give_xp(n, group_xp)
	return reward_gold


func _give_xp(pname: String, xp: int) -> void:
	if xp <= 0:
		return
	var h: Dictionary = state.heroes[pname]
	h.xp = int(h.xp) + xp
	_sess().xp = int(_sess().xp) + xp
	_log("sys", h.name, "%s: +%d опыта" % [h.name, xp])
	while int(h.level) < 10 and int(h.xp) >= R.xp_next(h):
		_log("lvl", h.name, R.level_up(h))
		_sess().lvls.append("%s → %d" % [h.name, int(h.level)])


func _damage_hero(pname: String, dmg: int, crit: bool) -> String:
	var h: Dictionary = state.heroes[pname]
	var rnote := ""
	if h.get("raging", false) and dmg > 1 and int(h.hp) > 0:
		dmg = maxi(1, dmg / 2)
		rnote = "Ярость: только %d урона. " % dmg
	var out := rnote + _damage_hero_raw(pname, dmg, crit)
	if h.get("conc", {}).is_empty() or dmg <= 0:
		return out
	if int(h.hp) <= 0 or h.get("dead", false):
		return (out + " " + _end_conc(pname, "без сознания")).strip_edges()
	var dc := maxi(10, dmg / 2)
	var sv := randi_range(1, 20) + R.save_bonus(h, "ТЕЛ") + (randi_range(1, 4) if h.get("blessed", false) else 0)
	if sv < dc:
		return (out + " " + _end_conc(pname, "ТЕЛ %d против %d" % [sv, dc])).strip_edges()
	return (out + " Концентрация удержана (ТЕЛ %d против %d)." % [sv, dc]).strip_edges()


func _damage_hero_raw(pname: String, dmg: int, crit: bool) -> String:
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
				for o0 in opts[k]:
					var o = o0
					# иногда нейронка присылает реплику как строку с JSON внутри — разбираем её
					if o is String and str(o).strip_edges().begins_with("{"):
						var pj = JSON.parse_string(str(o))
						if pj is Dictionary:
							o = pj
						else:
							var m := RegEx.create_from_string("\"t\"\\s*:\\s*\"([^\"]+)\"").search(str(o))
							o = m.get_string(1) if m else ""
					if o is String and str(o).strip_edges() == "":
						continue
					if o is Dictionary and str(o.get("t", "")) != "":
						var e := {"t": str(o.t).left(90)}
						var ck = o.get("check")
						if ck is Dictionary and str(ck.get("name", "")) != "":
							var what := str(ck.name)
							if str(ck.get("ability", "")) != "":
								what += "|" + str(ck.ability)
							var info := _check_info(state.heroes[pname], str(ck.get("kind", "skill")), what)
							if not info.is_empty():
								e.chk = {"kind": str(ck.get("kind", "skill")), "what": what, "dc": _dc_fair(int(ck.get("dc", 12))),
									"label": info.label, "bonus": info.bonus}
						arr.append(e)
					else:
						arr.append(str(o.get("t", o) if o is Dictionary else o).left(90))
				out[pname] = arr.slice(0, 4)
	return out


# ---------- сундуки и лавка ----------

func _open_chest(title: String) -> void:
	var loot := R.roll_loot(_tier())
	_add_loot(title, int(loot.gold), loot.items)


## Торговец запоминается вместе с местом и своим (ограниченным) товаром; новый завоз — раз в 10 ходов.
func _open_shop(merchant: String, who: Array) -> void:
	var c: Dictionary = state.campaign
	if not c.has("merchants"):
		c.merchants = {}
	var m: Dictionary = c.merchants.get(merchant, {})
	if m.is_empty() or int(state.turn) - int(m.get("turn", 0)) >= 10:
		var stock: Array = R.shop_stock(_tier()).slice(0, 7)
		stock.append({"id": "potion_heal"})
		m = {"name": merchant, "items": stock, "turn": int(state.turn), "place": _place_name()}
		c.merchants[merchant] = m
	else:
		m.place = _place_name()
	var att := 0
	for e in c.get("npcs", []):
		if str(e.n).to_lower() == merchant.to_lower():
			att = int(e.get("a", 0))
	if not state.has("shops"):
		state.shops = {}
	for p in who:
		state.shops[p] = {"title": merchant, "items": (m.items as Array).duplicate(true), "merchant": merchant,
			"mult": 1.0 - 0.08 * att, "att": att}


func _place_name() -> String:
	var mp: Dictionary = state.get("map", {})
	var nodes: Array = mp.get("nodes", [])
	var cur := int(mp.get("cur", -1))
	return str(nodes[cur].get("name", "")) if cur >= 0 and cur < nodes.size() else ""


func _save_shop_stock(pname: String) -> void:
	var sh := shop_of(pname)
	var mn := str(sh.get("merchant", ""))
	if mn != "" and state.campaign.get("merchants", {}).has(mn):
		state.campaign.merchants[mn].items = (sh.items as Array).duplicate(true)
		# у второго игрока у того же торговца — тот же (уменьшившийся) товар
		for p in state.get("shops", {}):
			if p != pname and str(state.shops[p].get("merchant", "")) == mn:
				state.shops[p].items = (sh.items as Array).duplicate(true)


## Торговцы в текущем месте: для кнопки «Торговать».
func merchants_here() -> Array:
	var out := []
	var here := _place_name()
	for k in state.campaign.get("merchants", {}):
		if str(state.campaign.merchants[k].get("place", "")) == here:
			out.append(k)
	return out


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
	_sess().gold = int(_sess().gold) + gold
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
				if str(h.get("sub", "")) == "beast_master" and str(a.get("pick", "")) == "beast_master":
					_add_beast(pname)
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
			if slot in ["armor", "offhand"] and not (cat in R.CLASSES[h.cls].get("armor", []) or cat in h.get("extra_armor", [])):
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
			var items: Array = shop_of(pname).get("items", [])
			if idx < 0 or idx >= items.size():
				return
			var it: Dictionary = items[idx]
			var price := shop_price(it)
			if int(h.gold) < price:
				return
			h.gold = int(h.gold) - price
			h.items.append(it.duplicate())
			items.remove_at(idx)
			_save_shop_stock(pname)
			_log("sys", h.name, "%s покупает %s за %d зол." % [h.name, R.item_name(it), price])
		"sell":
			var my_sh := shop_of(pname)
			if my_sh.is_empty() or idx < 0 or idx >= h.items.size():
				return
			var it: Dictionary = h.items[idx]
			var price := maxi(1, R.item_price(it) / 2)
			h.items.remove_at(idx)
			h.gold = int(h.gold) + price
			if (my_sh.items as Array).size() < 12:
				my_sh.items.append(it.duplicate())
				_save_shop_stock(pname)
			_log("sys", h.name, "%s продаёт %s за %d зол." % [h.name, R.item_name(it), price])
		"shop_close":
			_save_shop_stock(pname)
			if state.has("shops"):
				state.shops.erase(pname)
		"shop_open":
			var mn := str(a.get("merchant", ""))
			if in_combat or phase != "play" or not (mn in merchants_here()):
				return
			for e in state.campaign.get("npcs", []):
				if str(e.n).to_lower() == mn.to_lower() and int(e.get("a", 0)) <= -3:
					_log("sys", h.name, "%s не желает с вами торговать." % mn)
					_broadcast()
					return
			_open_shop(mn, [pname])
			_log("sys", h.name, "%s заходит к торговцу: %s." % [h.name, mn])
		"craft":
			var rid := str(a.get("r", ""))
			if in_combat or not R.RECIPES.has(rid):
				return
			var need: Dictionary = R.RECIPES[rid].need
			for k in need:
				if _count_item(h, k) < int(need[k]):
					return
			for k in need:
				for i in int(need[k]):
					h.items.remove_at(_find_item(h.items, k))
			h.items.append({"id": rid})
			_log("sys", h.name, "⚗ %s готовит: %s." % [h.name, R.ITEMS[rid].name])
		"cast":
			if in_combat:
				return
			_cast_outside(pname, str(a.get("spell", "")), str(a.get("target", pname)))
		"second_wind":
			if in_combat or not h.get("second_wind", false):
				return
			h.second_wind = false
			_heal_hero(pname, randi_range(1, 10) + int(h.level))
		"lay_hands":
			if in_combat:
				return
			if not _lay_hands(pname, str(a.get("target", pname))):
				return
		"respec":
			if in_combat:
				return
			if int(h.gold) < RESPEC_COST:
				_log("sys", h.name, "Переобучение стоит %d зм — у %s только %d." % [RESPEC_COST, h.name, int(h.gold)])
				_broadcast()
				return
			h.gold = int(h.gold) - RESPEC_COST
			_log("lvl", h.name, respec(h))
			if str(h.get("sub", "")) == "" and _beast_of(pname) >= 0:
				state.companions.remove_at(_beast_of(pname))
		_:
			return
	if not in_combat:
		_save()
	_broadcast()


const RESPEC_COST := 100


## Переобучение (как у Уизерса в BG3): характеристики — к стартовым, таланты, +2 и подкласс — выбрать заново.
static func respec(h: Dictionary) -> String:
	var c: Dictionary = R.CLASSES[h.cls]
	var r: Dictionary = R.RACES.get(h.race, R.RACES["Человек"])
	for a in R.AB:
		h.scores[a] = int(c.scores[a]) + int(r.bonus.get(a, 0))
	h.talents = []
	h.erase("sub")
	h.erase("extra_armor")
	h.choices = []
	# хиты по формуле, как при честном повышении уровней
	var con := R.mod(int(h.scores["ТЕЛ"]))
	var rh := int(r.get("hp_per_level", 0))
	var mhp := int(c.hd) + con + rh
	for lv in range(2, int(h.level) + 1):
		mhp += maxi(1, int(c.hd) / 2 + 1 + con + rh)
	var lost := int(h.max_hp) - int(h.hp)
	h.max_hp = mhp
	h.hp = clampi(mhp - lost, 1, mhp)
	for lv in range(2, int(h.level) + 1):
		var ch := R.make_choice(h, lv)
		if not ch.is_empty():
			h.choices.append(ch)
	if h.cls == "Бард":
		h.inspire = maxi(1, R.amod(h, "ХАР"))
	return "%s проходит переобучение: характеристики вернулись к стартовым, таланты и путь — выбрать заново (%d выбор%s)." % [
		h.name, (h.choices as Array).size(), "" if (h.choices as Array).size() == 1 else "ов"]


func _beast_of(pname: String) -> int:
	var cps: Array = state.get("companions", [])
	for i in cps.size():
		if cps[i].get("beast", false) and str(cps[i].get("owner", "")) == pname:
			return i
	return -1


## Волк Повелителя зверей: растёт с уровнем хозяина.
func _add_beast(pname: String) -> void:
	var h: Dictionary = state.heroes[pname]
	if not state.has("companions"):
		state.companions = []
	var lv := int(h.level)
	var hpv := 11 + 4 * lv
	var cp := {"name": "Волк %s" % str(h.name), "kind": "зверь", "mon": "wolf", "hp": hpv, "max_hp": hpv, "ac": 13 + lv / 4,
		"atk": 2 + R.prof(lv) + 2, "dmg": "2d4+%d" % (2 + R.prof(lv)), "owner": pname, "beast": true}
	var bi := _beast_of(pname)
	if bi >= 0:
		state.companions[bi] = cp
	else:
		state.companions.append(cp)
	_log("sys", h.name, "Из чащи выходит волк и садится у ног %s: теперь он сражается рядом." % h.name)


func _lay_hands(pname: String, to: String) -> bool:
	var h: Dictionary = state.heroes[pname]
	if not state.heroes.has(to):
		to = pname
	var th: Dictionary = state.heroes[to]
	var pool := int(h.get("lay", 0))
	var need := int(th.max_hp) - int(th.hp)
	if pool <= 0 or need <= 0 or th.get("dead", false):
		return false
	var v := mini(pool, need)
	h.lay = pool - v
	_fx_event("act_lay_hands", "ffe08a", "Наложение рук", "%s: +%d хитов · в запасе %d" % [th.name, v, int(h.lay)], true)
	_log("cbt" if phase == "combat" else "sys", h.name, "%s возлагает ладони на %s: свет закрывает раны." % [h.name, "себя" if to == pname else th.name])
	_heal_hero(to, v)
	return true


func _count_item(h: Dictionary, id: String) -> int:
	var n := 0
	for it in h.items:
		if str(it.get("id", "")) == id:
			n += 1
	return n


func _use_consumable(pname: String, idx: int, target: String) -> String:
	var h: Dictionary = state.heroes[pname]
	var it: Dictionary = h.items[idx]
	var d := R.item_def(it)
	if not state.heroes.has(target):
		target = pname
	if d.type == "coat":
		h.items.remove_at(idx)
		h.coat = {"dice": str(d.get("dice", "1d6")), "hits": int(d.get("hits", 3))}
		_log("sys", h.name, "%s смазывает оружие ядом: следующие %d попаданий +%s урона и отравление." % [h.name, int(h.coat.hits), R.dice_ru(str(h.coat.dice))])
		return "coat"
	if d.type == "potion":
		h.items.remove_at(idx)
		var th: Dictionary = state.heroes[target]
		for cn in d.get("cure", []):
			if th.get("conds", {}).has(cn):
				th.conds.erase(cn)
				_log("sys", th.name, "%s больше не %s." % [th.name, str(R.CONDS[cn].name).to_lower()])
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

func _start_combat(spec: Array, env_ids: Array = []) -> bool:
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
			en.mid = id
			en.max_hp = int(en.hp)
			en.asleep = false
			en.dead = false
			counts[en.name] = int(counts.get(en.name, 0)) + 1
			en.base_name = en.name
			# каждый второй гоблин/кобольд/бандит — стрелок в тылу
			en.ranged = (bool(base.get("bow", false)) and counts[en.name] % 2 == 0) or bool(base.get("caster", false))
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
	var comps: Array = state.get("companions", [])
	for i in comps.size():
		if int(comps[i].hp) > 0:
			var ci := randi_range(1, 20) + 2
			order.append({"k": "c", "id": i, "init": ci})
			lines.append("%s %d" % [comps[i].name, ci])
	for i in enemies.size():
		var init := randi_range(1, 20) + int(enemies[i].get("dex", 0))
		order.append({"k": "e", "id": i, "init": init})
		lines.append("%s %d" % [enemies[i].name, init])
	order.sort_custom(func(a, b): return float(a.init) > float(b.init))
	var pos := {}
	for n in state.heroes:
		var hh: Dictionary = state.heroes[n]
		pos[n] = "back" if (hh.cls in ["Маг", "Бард", "Следопыт", "Колдун"] or R.attack_info(hh).ranged) else "front"
	state.campaign.last_combat = int(state.turn)
	state.combat = {"round": 1, "turn": 0, "order": order, "enemies": enemies, "dodge": {}, "sneak": {}, "pos": pos, "moved": {}, "help": {},
		"used": {}, "hidden": {}, "high": {}, "env": _pick_env(env_ids), "surf": {}, "diseng": {}, "dip": {}, "thrown": [], "hsurf": {}, "react": {}}
	state.pending = []
	_log("cbt", "", "Бой! Инициатива: " + ", ".join(lines) + ".")
	var envn := []
	for e in state.combat.env:
		envn.append(str(R.ENV[e.id].name).to_lower())
	if envn.size() > 0:
		_log("cbt", "", "Вокруг: " + ", ".join(envn) + ". Это можно обратить против врага.")
	_set_phase("combat")
	_combat_continue()
	return true


## Окружение боя: что предложила нейронка, иначе по типу места.
func _pick_env(ids: Array) -> Array:
	var out := []
	for x in ids:
		var k := str(x).strip_edges().to_lower()
		if R.ENV.has(k) and out.size() < 3 and not out.any(func(e): return e.id == k):
			out.append({"id": k, "used": false})
	if out.is_empty():
		var m: Dictionary = state.get("map", {})
		var nodes: Array = m.get("nodes", [])
		var cur := int(m.get("cur", -1))
		var ptype := str(nodes[cur].get("type", "")) if cur >= 0 and cur < nodes.size() else "road"
		var pool: Array = (R.ENV_BY_PLACE.get(ptype, ["rocks", "high", "barrel"]) as Array).duplicate()
		pool.shuffle()
		for k in pool.slice(0, 2):
			out.append({"id": k, "used": false})
	return out


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
		if o.k == "c":
			var cps: Array = state.get("companions", [])
			if int(o.id) < cps.size() and int(cps[int(o.id)].hp) > 0:
				await _wait_rolls(500)
				if not Net.is_host() or phase != "combat":
					break
				_companion_turn(int(o.id))
				_broadcast()
			_next_turn()
			continue
		if o.k == "e":
			var en: Dictionary = c.enemies[int(o.id)]
			if not en.dead:
				await _wait_rolls(700)
				if not Net.is_host() or phase != "combat":
					break
				if _tick_conds(en, str(en.name)) and _held_tick(int(o.id)) and _surface_tick(int(o.id)) and not en.dead:
					_enemy_turn(int(o.id))
				_broadcast()
			_next_turn()
			continue
		var pname := str(o.id)
		var h: Dictionary = state.heroes.get(pname, {})
		if h.is_empty() or h.get("dead", false):
			_next_turn()
			continue
		if int(h.hp) <= 0:
			if not h.get("stable", false):
				await _wait_rolls(400)
				_death_save(pname)
				_broadcast()
				if int(h.hp) > 0 and pname in Net.players.values():
					if not c.has("ticked"):
						c.ticked = {}
					c.ticked["%s_%d" % [pname, int(c.round)]] = true
					if not c.has("used"):
						c.used = {}
					c.used[pname] = {"a": false, "b": false}
					break   # 20 на спасброске: встаёт и сразу ходит
			_next_turn()
			continue
		if not c.get("ticked", {}).has("%s_%d" % [pname, int(c.round)]):
			if not c.has("ticked"):
				c.ticked = {}
			c.ticked["%s_%d" % [pname, int(c.round)]] = true
			c.dodge.erase(pname)
			c.sneak.erase(pname)
			c.get("once", {}).erase(pname)
			c.get("diseng", {}).erase(pname)
			if not c.has("used"):
				c.used = {}
			c.used[pname] = {"a": false, "b": false}
			_hero_surf_tick(pname)
			if int(h.hp) <= 0:
				_broadcast()
				_next_turn()
				continue
			if h.get("conds", {}).has("prone"):
				h.conds.erase("prone")
				c.moved[pname] = true
				_log("cbt", h.name, "%s поднимается на ноги (перемещение потрачено)." % h.name)
			if not _tick_conds(h, str(h.name)):
				_broadcast()
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
		_save()
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
		var hsf: Dictionary = c.get("hsurf", {})
		if not hsf.is_empty():
			hsf.r = int(hsf.r) - 1
			if int(hsf.r) <= 0:
				c.hsurf = {}
				_log("cbt", "", "%s под ногами героев %s." % [R.SURFACES[str(hsf.t)].name, "догорает" if str(hsf.t) == "fire" else "уходит"])
		var sf: Dictionary = c.get("surf", {})
		if not sf.is_empty():
			sf.r = int(sf.r) - 1
			if int(sf.r) <= 0:
				if str(sf.t) == "shock":
					c.surf = {"t": "water", "r": 2}
					_log("cbt", "", "Ток в воде утих, лужи остались.")
				else:
					c.surf = {}
					_log("cbt", "", "%s под ногами врагов %s." % [R.SURFACES[str(sf.t)].name, "догорает" if str(sf.t) == "fire" else "уходит"])


## В начале хода: отсчитываем раунды состояний. false — существо пропускает ход (оглушено).
func _tick_conds(who: Dictionary, nm: String) -> bool:
	var cs: Dictionary = who.get("conds", {})
	if cs.is_empty():
		return true
	var stunned := cs.has("stunned")
	if cs.has("prone") and who.has("atk"):
		cs.erase("prone")
		_log("cbt", "", "%s поднимается на ноги." % nm)
	for k in cs.keys():
		cs[k] = int(cs[k]) - 1
		if int(cs[k]) <= 0:
			cs.erase(k)
	if stunned:
		_log("cbt", "", "%s оглушён и пропускает ход." % nm)
		return false
	return true


func _add_cond(who: Dictionary, cond: String, rounds: int) -> void:
	if not who.has("conds"):
		who.conds = {}
	if not R.CONDS.has(cond):
		return
	var was: bool = who.conds.has(cond)
	who.conds[cond] = maxi(int(who.conds.get(cond, 0)), rounds)
	if not was:
		_fx_event(str(R.CONDS[cond].icon), "ff9a7a" if cond != "poisoned" else "b8ff7a", "%s: %s" % [who.get("name", "?"), R.CONDS[cond].name], str(R.CONDS[cond].desc), true)


## Событие для анимации на всех телефонах (заклинание, наложенное состояние).
func _fx_event(icon: String, col: String, title: String, sub: String, status := false) -> void:
	state.fx_seq = int(state.get("fx_seq", 0)) + 1
	if not state.has("fx"):
		state.fx = []
	state.fx.append({"n": int(state.fx_seq), "icon": icon, "col": col, "title": title.left(60), "sub": sub.left(90), "status": status})
	if (state.fx as Array).size() > 6:
		state.fx = (state.fx as Array).slice(-6)


## Ход спутника: бьёт ближайшего врага.
func _companion_turn(i: int) -> void:
	var cp: Dictionary = state.companions[i]
	var c: Dictionary = state.combat
	var alive := _front_enemies()
	if alive.is_empty():
		alive = _alive_enemies()
	if alive.is_empty():
		return
	var ti: int = alive[randi() % alive.size()]
	var owner := str(cp.get("owner", ""))
	if _last_target.has(owner) and int(_last_target[owner]) in alive:
		ti = int(_last_target[owner])
	var en: Dictionary = c.enemies[ti]
	var adv := R.cond_adv({}, en, true) + (1 if en.asleep else 0)
	var a := randi_range(1, 20)
	var b := randi_range(1, 20)
	var v := a if adv == 0 else (maxi(a, b) if adv > 0 else mini(a, b))
	var total := v + int(cp.atk)
	var hit := (total >= int(en.ac) or v == 20) and v != 1
	var line := "%s бросается на %s: %d против КД %d — " % [cp.name, en.name, total, en.ac]
	var dealt := -1
	if hit:
		var dmg := _roll_damage(str(cp.dmg), v == 20)
		dealt = dmg
		line += "попадание, %d урона. %s" % [dmg, _hit_enemy(ti, dmg, "")]
	else:
		line += "промах."
	_log("cbt", str(cp.name), line)
	_show_rolls([{"label": "%s ⚔ %s" % [cp.name, en.name], "d20": v, "d20b": -1 if adv == 0 else (b if v == a else a), "adv": clampi(adv, -1, 1),
		"mod": int(cp.atk), "total": total, "dc": int(en.ac), "outcome": "попадание" if hit else "промах", "kind": "attack", "dmg": dealt}])


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
	if int(en.get("regen", 0)) > 0:
		if en.get("burned", false):
			en.erase("burned")
			_log("cbt", "", "%s шипит от ожогов: раны не затягиваются." % en.name)
		elif int(en.hp) < int(en.max_hp):
			en.hp = mini(int(en.max_hp), int(en.hp) + int(en.regen))
			_log("cbt", "", "%s регенерирует: +%d хитов (%d/%d). Огонь остановит это." % [en.name, int(en.regen), int(en.hp), int(en.max_hp)])
	# мораль: тяжело раненый враг, чья сторона проигрывает, может сбежать
	if not en.get("undead", false) and not en.get("boss", false) and int(en.hp) * 4 <= int(en.max_hp):
		var alive_n := _alive_enemies().size()
		if (alive_n * 2 <= c.enemies.size() or alive_n == 1) and randf() < 0.4:
			_log("cbt", "", "%s в ужасе бросает оружие и бежит с поля боя!" % en.name)
			if str(en.get("pos", "front")) == "front":
				for n in _conscious_heroes():
					if hero_pos(n) == "front" and _can_react(n) and not R.attack_info(state.heroes[n]).ranged:
						_reaction_strike(n, i, "бьёт вдогонку убегающему")
						break
			if not en.dead:
				en.dead = true
				en.fled = true
			return
	if _enemy_tactic(i):
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
	var comps := []
	for ci in state.get("companions", []).size():
		if int(state.companions[ci].hp) > 0 and _comp_in_combat(ci):
			comps.append(ci)
	if comps.size() > 0 and randf() < 0.3:
		_enemy_hits_companion(i, comps[randi() % comps.size()])
		return
	# спрятавшихся не видят: ищут, а если все в тени — озираются
	var seen := []
	for n in targets:
		if not c.get("hidden", {}).get(n, false):
			seen.append(n)
	if seen.is_empty():
		if randf() < 0.35:
			var found: String = targets[randi() % targets.size()]
			c.hidden.erase(found)
			_log("cbt", "", "%s замечает %s в тени!" % [en.name, state.heroes[found].name])
		else:
			_log("cbt", "", "%s озирается, но никого не видит." % en.name)
		return
	targets = seen
	var target := _enemy_pick(en, targets)
	var h: Dictionary = state.heroes[target]
	var rolls := []
	for k in int(en.get("multi", 1)):
		if k > 0 and (int(h.hp) <= 0 or h.get("dead", false)):
			var alive := []
			for n in _conscious_heroes():
				if not c.get("hidden", {}).get(n, false):
					alive.append(n)
			if alive.is_empty():
				break
			target = _enemy_pick(en, alive)
			h = state.heroes[target]
		if h.get("dead", false):
			break
		var adv := -1 if c.dodge.get(target, false) else 0
		adv += R.cond_adv(en, h, not en.get("ranged", false))
		if int(h.hp) <= 0:
			adv = 1
		adv = clampi(adv, -1, 1)
		var a := randi_range(1, 20)
		var b := randi_range(1, 20)
		var v := a if adv == 0 else (maxi(a, b) if adv > 0 else mini(a, b))
		var total := v + int(en.atk)
		var hac := R.ac(h) + (5 if int(c.get("shield", {}).get(target, -1)) == int(c.round) else 0)
		if en.get("ranged", false) and hero_pos(target) == "back":
			hac += 2  # укрытие в тылу против стрел
		var hit := (total >= hac or v == 20) and v != 1
		var shield_note := ""
		if hit and v != 20 and total < hac + 5 and int(h.hp) > 0 and _can_shield(target):
			_use_reaction(target)
			h.slots[0] = int(h.slots[0]) - 1
			c.shield = c.get("shield", {})
			c.shield[target] = int(c.round)
			hac += 5
			hit = false
			shield_note = " %s вскидывает «Щит» (реакция, ячейка 1 ур.): КД +5 до конца раунда." % h.name
			_fx_event("sp_shield_of_faith", "9fd0ff", "%s: Щит" % h.name, "реакция: КД +5", true)
		var crit := v == 20 or (hit and int(h.hp) <= 0)
		var line := shield_note + "%s атакует %s: %d против КД %d — " % [en.name, h.name, total, hac]
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
				var oh: Dictionary = en.get("on_hit", {})
				if not oh.is_empty():
					var sv := randi_range(1, 20) + R.save_bonus(h, str(oh.save)) + (randi_range(1, 4) if h.get("blessed", false) else 0)
					if sv < int(oh.dc):
						_add_cond(h, str(oh.cond), int(oh.get("rounds", 1)))
						line += " %s: %s! (спасбросок %s %d против %d)" % [h.name, str(R.CONDS[str(oh.cond)].name).to_lower(), oh.save, sv, int(oh.dc)]
			if extra != "":
				line += " " + extra
		else:
			line += "промах."
		_log("cbt", en.name, line)
		if not hit and not en.get("ranged", false) and int(h.hp) > 0 and _has_riposte(target) and _can_react(target) and not en.dead:
			_reaction_strike(target, i, "отвечает выпадом")
		rolls.append({"label": "%s ⚔ %s" % [en.name, h.name], "d20": v, "d20b": -1 if adv == 0 else (b if v == a else a),
			"adv": adv, "mod": int(en.atk), "total": total, "dc": hac, "outcome": outcome,
			"kind": "enemy", "dmg": dealt, "target": target})
	_show_rolls(rolls)


## Умный выбор цели: слабая броня, мало хитов, лежит или оглушён — но с долей случайности.
func _enemy_pick(en: Dictionary, targets: Array) -> String:
	var best := str(targets[0])
	var best_s := -999.0
	for n in targets:
		var h: Dictionary = state.heroes[n]
		var sc := float(22 - R.ac(h)) + (1.0 - float(h.hp) / maxf(1.0, float(h.max_hp))) * 6.0 + randf() * 6.0
		var cs: Dictionary = h.get("conds", {})
		if cs.has("prone") and not en.get("ranged", false):
			sc += 3.0
		if cs.has("stunned"):
			sc += 3.0
		if h.cls in ["Маг", "Жрец", "Бард", "Колдун"]:
			sc += 1.5   # заклинатели опасны — их стараются сбить первыми
		if sc > best_s:
			best_s = sc
			best = str(n)
	return best


func _comp_in_combat(ci: int) -> bool:
	for o in state.combat.get("order", []):
		if o.k == "c" and int(o.id) == ci:
			return true
	return false


func _enemy_hits_companion(i: int, ci: int) -> void:
	var en: Dictionary = state.combat.enemies[i]
	var cp: Dictionary = state.companions[ci]
	var v := randi_range(1, 20)
	var total := v + int(en.atk)
	var hit := (total >= int(cp.ac) or v == 20) and v != 1
	var line := "%s атакует %s: %d против КД %d — " % [en.name, cp.name, total, int(cp.ac)]
	var dealt := -1
	if hit:
		var dmg := _roll_damage(str(en.dmg), v == 20)
		dealt = dmg
		cp.hp = maxi(0, int(cp.hp) - dmg)
		line += "попадание, %d урона." % dmg
		line += (" %s без сил и выходит из боя." % cp.name) if int(cp.hp) <= 0 else " (%d/%d)" % [int(cp.hp), int(cp.max_hp)]
	else:
		line += "промах."
	_log("cbt", en.name, line)
	_show_rolls([{"label": "%s ⚔ %s" % [en.name, cp.name], "d20": v, "d20b": -1, "adv": 0, "mod": int(en.atk),
		"total": total, "dc": int(cp.ac), "outcome": "попадание" if hit else "промах", "kind": "enemy", "dmg": dealt}])


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
		if en.get("fled", false):
			total_xp += int(en.xp) / 2
		elif en.dead:
			total_xp += int(en.xp)
			gold += int(en.xp) / 8 + randi_range(0, 6)
	var summary := ""
	match result:
		"won":
			_sess().won = int(_sess().won) + 1
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
	var back := []
	for th in (c.get("thrown", []) if result != "fled" else []):
		if state.heroes.has(str(th.who)):
			state.heroes[str(th.who)].items.append(th.it)
			back.append(R.item_name(th.it))
	if back.size() > 0:
		_log("sys", "", "Брошенное подобрали: %s." % ", ".join(back))
	for n in state.heroes:
		var h: Dictionary = state.heroes[n]
		h.temp_ac = 0
		h.erase("coat")
		h.erase("conc")
		h.erase("blessed")
		h.erase("raging")
		h.erase("brand")
		h.get("conds", {}).erase("wet")
		for k in ["prone", "stunned", "frightened", "blinded"]:
			h.get("conds", {}).erase(k)
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
		for en in c.enemies:
			if en.dead and not en.get("fled", false) and str(en.get("drop", "")) != "" and randf() < 0.6:
				items.append({"id": str(en.drop)})
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
	if not c.has("used"):
		c.used = {}
	if not c.used.has(pname):
		c.used[pname] = {"a": false, "b": false}
	var used: Dictionary = c.used[pname]
	if t == "end":
		_log("cbt", h.name, "%s завершает ход." % h.name)
		_end_hero_turn()
		return
	var cost := action_cost(pname, a)
	if cost == "":
		return
	if cost == "a" and used.a:
		return
	if cost == "b" and used.b:
		return
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
			elif d.type == "bomb":
				var ti := _target_enemy(int(a.get("target", -1)) if (a.get("target", -1) is int or a.get("target", -1) is float) else -1)
				if ti < 0:
					return
				var bname := R.item_name(h.items[idx])
				h.items.remove_at(idx)
				var en: Dictionary = c.enemies[ti]
				var sv := randi_range(1, 20) + _msave(en, str(d.get("save", "ЛОВ")))
				var dmg := R.roll(str(d.dmg))
				var saved := sv >= int(d.get("dc", 12))
				if saved:
					dmg = dmg / 2
				var note := _hit_enemy(ti, dmg, "", str(d.get("dt", "огонь"))) if dmg > 0 else ""
				if str(d.get("dt", "огонь")) == "огонь" and str(en.get("pos", "front")) == "front":
					note += " " + _add_surface("fire")
				_fx_event("it_bomb", "ff7a3d", bname, "%d урона · %s" % [_last_dmg if dmg > 0 else 0, en.name])
				_log("cbt", h.name, "%s швыряет %s в %s: %s (%d против %d), %d урона. %s" % [h.name, bname, en.name,
					"увернулся наполовину" if saved else "прямое попадание", sv, int(d.get("dc", 12)), dmg, note])
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
				if not c.get("hidden", {}).get(pname, false) and not c.get("diseng", {}).get(pname, false):
					var fe: Array = _front_enemies()
					var ready := []
					for i in fe:
						if not c.enemies[i].asleep and not c.enemies[i].get("ranged", false) and not c.enemies[i].get("conds", {}).has("stunned") and not c.enemies[i].get("conds", {}).has("held"):
							ready.append(i)
					if ready.size() > 0:
						var ei: int = ready[randi() % ready.size()]
						_log("cbt", "", "%s бьёт вдогонку!" % c.enemies[ei].name)
						_enemy_strike(ei, pname)
						if int(h.hp) <= 0:
							_end_hero_turn()
							return
			else:
				c.get("high", {}).erase(pname)
				_log("cbt", h.name, "%s выходит вперёд." % h.name)
			_broadcast()
			return
		"help":
			var to := str(a.get("target", ""))
			if not state.heroes.has(to) or to == pname:
				return
			if not c.has("help"):
				c.help = {}
			c.help[to] = true
			_log("cbt", h.name, "%s отвлекает врагов и прикрывает: следующая атака %s — с преимуществом." % [h.name, state.heroes[to].name])
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
		"shove":
			var ti := _target_enemy(int(a.get("target", -1)) if (a.get("target", -1) is int or a.get("target", -1) is float) else -1)
			if ti < 0:
				return
			var en: Dictionary = c.enemies[ti]
			if str(en.get("pos", "front")) == "back" and _front_enemies().size() > 0:
				ti = _front_enemies()[0]
				en = c.enemies[ti]
			if hero_pos(pname) != "front":
				c.pos[pname] = "front"
				_log("cbt", h.name, "%s выходит вперёд." % h.name)
			# как в BG3: состязание — Атлетика героя против Атлетики/Акробатики врага (крупные упираются сильнее)
			var foe := randi_range(1, 20) + maxi(int(en.get("dex", 0)), int(en.atk) - 2) + (4 if int(en.max_hp) >= 50 else 0)
			var helpless: bool = en.asleep or en.get("conds", {}).has("stunned") or en.get("conds", {}).has("held")
			_busy = true
			var rr: Array = await _ask_rolls([_make_ask(pname, "skill", "Атлетика", 0 if helpless else foe, 1 if helpless else 0, "толкнуть: %s (упирается на %d)" % [en.name, foe])], "")
			_busy = false
			if state.combat.is_empty():
				return
			if rr.size() > 0 and str(rr[0].outcome).contains("успех") and not en.dead:
				var edge := _env_find("cliff")
				if edge >= 0:
					var dmg := R.roll(str(R.ENV.cliff.dmg))
					var note := _hit_enemy(ti, dmg, "падение", "дробящий")
					_fx_event("env_cliff", "c9a27a", "Толчок с обрыва", "%s · %d урона" % [en.name, _last_dmg])
					_log("cbt", h.name, "%s сталкивает %s с обрыва: %d урона от падения. %s" % [h.name, en.name, dmg, note])
					if not en.dead:
						_add_cond(en, "stunned", 1)
						_log("cbt", "", "%s карабкается обратно наверх — ход потерян." % en.name)
				else:
					_add_cond(en, "prone", 1)
					en.pos = "front"
					var into := ""
					match str(_surf().get("t", "")):
						"fire":
							var fd := R.roll("2d6")
							into = " Прямо в огонь: %s" % _hit_enemy(ti, fd, "огонь", "огонь")
						"web":
							_add_cond(en, "stunned", 1)
							into = " Прямо в паутину — запутался на ход."
					_log("cbt", h.name, "%s сбивает %s с ног! Пока он лежит, удары вблизи — с преимуществом.%s" % [h.name, en.name, into])
			else:
				_log("cbt", h.name, "%s пытается толкнуть %s, но тот устоял." % [h.name, en.name])
		"hide":
			if c.get("hidden", {}).get(pname, false):
				return
			var awake := 0
			for i in _alive_enemies():
				if not c.enemies[i].asleep:
					awake += 1
			var dc := mini(10 + awake + (2 if hero_pos(pname) == "front" else 0), 16)
			_busy = true
			var rr: Array = await _ask_rolls([_make_ask(pname, "skill", "Скрытность", dc, 0, "спрятаться")], "")
			_busy = false
			if state.combat.is_empty():
				return
			if rr.size() > 0 and str(rr[0].outcome).contains("успех"):
				if not c.has("hidden"):
					c.hidden = {}
				c.hidden[pname] = true
				_fx_event("act_hide", "9aa7c7", "%s в тени" % h.name, "враги не видят · следующая атака с преимуществом", true)
				_log("cbt", h.name, "%s растворяется в тенях: враги потеряли его из виду. Следующая атака — с преимуществом." % h.name)
			else:
				_log("cbt", h.name, "%s пытается спрятаться, но враги замечают движение." % h.name)
		"stabilize":
			var to := str(a.get("target", ""))
			if not state.heroes.has(to) or to == pname:
				return
			var th: Dictionary = state.heroes[to]
			if int(th.hp) > 0 or th.get("dead", false):
				return
			# как в BG3 «Помочь»: без броска, упавший встаёт с 1 хитом; спасатель заслоняет его, а раненого оттаскивает в тыл
			var shield_txt := ""
			if hero_pos(pname) != "front":
				c.pos[pname] = "front"
				c.get("high", {}).erase(pname)
				shield_txt = " %s встаёт впереди и заслоняет собой." % h.name
			c.pos[to] = "back"
			th.hp = 1
			th.stable = false
			th.death_s = 0
			th.death_f = 0
			_fx_event("act_revive", "6fe3a0", "%s на ногах" % th.name, "%s поднимает напарника: 1 хит" % h.name, true)
			_log("cbt", h.name, "%s тормошит %s, ставит на ноги (1 хит) и оттаскивает в тыл.%s" % [h.name, th.name, shield_txt])
		"disengage":
			if not c.has("diseng"):
				c.diseng = {}
			c.diseng[pname] = true
			if hero_pos(pname) == "front" and not c.moved.get(pname, false):
				c.moved[pname] = true
				c.pos[pname] = "back"
				_log("cbt", h.name, "%s осторожно отступает в тыл — враги не успевают ударить вдогонку." % h.name)
			else:
				_log("cbt", h.name, "%s держит дистанцию: в этот ход можно уйти без удара вдогонку." % h.name)
		"dip":
			if not can_dip(pname):
				return
			if not c.has("dip"):
				c.dip = {}
			c.dip[pname] = int(c.round) + 1
			var near_fire := str(_surf().get("t", "")) == "fire" and hero_pos(pname) == "front"
			for e in c.get("env", []):
				if str(e.id) == "brazier" and not e.used:
					near_fire = true
			if not near_fire:
				var tix := -1
				for k in h.items.size():
					if str(h.items[k].get("id", "")) == "torch":
						tix = k
				if tix >= 0:
					h.items.remove_at(tix)
					_log("cbt", h.name, "Факел догорает, но клинок уже в огне.")
			_fx_event("act_dip", "ff9a4a", "%s: оружие в огне" % h.name, "+1к4 огнём к ударам до конца следующего хода", true)
			_log("cbt", h.name, "%s окунает оружие в огонь: удары +1к4 огнём до конца следующего хода." % h.name)
		"throw":
			ok = _hero_throw(pname, int(a.get("idx", -1)), a.get("target", -1))
		"react_toggle":
			h.react_off = not h.get("react_off", false)
			_broadcast()
			return
		"smite_toggle":
			h.smite_on = not h.get("smite_on", false)
			_broadcast()
			return
		"rage":
			if h.cls != "Варвар" or h.get("raging", false) or int(h.get("rages", 0)) <= 0:
				return
			h.rages = int(h.rages) - 1
			h.raging = true
			_fx_event("act_rage", "ff5a3d", "%s в ярости!" % h.name, "+%d урона вблизи · урон по тебе вдвое меньше" % (2 if int(h.level) < 9 else 3), true)
			_log("cbt", h.name, "%s впадает в ярость! Удары вблизи сильнее, раны — вдвое легче. Осталось ярости: %d." % [h.name, int(h.rages)])
		"extra_attack":
			if not can_extra_attack(pname):
				return
			if str(h.get("sub", "")) == "war_domain" and not (h.cls == "Варвар" and h.get("raging", false)):
				h.war_left = int(h.get("war_left", 0)) - 1
			_log("cbt", h.name, "%s: %s" % [h.name, "бешенство берсерка — лишний удар!" if h.cls == "Варвар" else "боевой жрец — удар во славу бога!"])
			ok = _hero_attack(pname, int(a.get("target", -1)), 1)
		"lay_hands":
			ok = _lay_hands(pname, str(a.get("target", pname)))
		"insp":
			if insp_pool() <= 0 or c.get("help", {}).get(pname, false):
				return
			state.campaign.insp = insp_pool() - 1
			if not c.has("help"):
				c.help = {}
			c.help[pname] = true
			_log("cbt", h.name, "✨ %s тратит вдохновение группы: следующая атака — с преимуществом." % h.name)
		"env":
			var ei := int(a.get("idx", -1))
			var envs: Array = c.get("env", [])
			if ei < 0 or ei >= envs.size() or envs[ei].used:
				return
			var ok_env := _use_env(pname, ei, a.get("target", -1))
			if not ok_env:
				return
		"free":
			_busy = true
			await _hero_free(pname, str(a.get("text", "")).left(200))
			_busy = false
		_:
			return
	if not ok or state.combat.is_empty():
		return
	if t in ["attack", "spell", "help", "shove", "env", "free", "flee", "throw"] or (t == "item" and cost == "a"):
		c.get("hidden", {}).erase(pname)
	if cost == "a":
		used.a = true
	elif cost == "b":
		used.b = true
	if _turn_over(pname):
		_end_hero_turn()
	else:
		_broadcast()
		_combat_continue()


func _end_hero_turn() -> void:
	_next_turn()
	_broadcast()
	_combat_continue()


## Чем оплачивается действие в бою: "a" — основное действие, "b" — бонусное, "" — нельзя.
func action_cost(pname: String, a: Dictionary) -> String:
	var h: Dictionary = state.heroes.get(pname, {})
	if h.is_empty():
		return ""
	var t := str(a.get("t", ""))
	match t:
		"move":
			return "m"
		"second_wind", "inspire", "shove", "dip", "rage", "extra_attack":
			return "b"
		"smite_toggle":
			return "f"
		"lay_hands":
			return "a"
		"hide", "disengage":
			return "b" if h.cls == "Плут" else "a"
		"throw":
			return "b" if str(h.get("sub", "")) == "thief" else "a"
		"insp", "react_toggle":
			return "f"
		"spell":
			var sp := str(a.get("spell", ""))
			return "b" if R.SPELLS.has(sp) and R.SPELLS[sp].get("bonus", false) else "a"
		"item":
			var idx := int(a.get("idx", -1))
			if idx < 0 or idx >= h.items.size():
				return ""
			var d := R.item_def(h.items[idx])
			if d.type == "potion" and str(a.get("target", pname)) != pname and state.heroes.has(str(a.get("target", ""))):
				return "a"   # напоить напарника — как в BG3, это действие
			if d.type in ["potion", "coat"] or (str(h.get("sub", "")) == "thief" and d.type == "bomb"):
				return "b"
			if d.type == "scroll" and R.SPELLS.has(str(d.get("spell", ""))) and R.SPELLS[str(d.spell)].get("bonus", false):
				return "b"
			return "a"
		"attack", "help", "dodge", "flee", "stabilize", "env", "free":
			return "a"
	return ""


## Остались ли у героя бонусные действия, которые можно сделать прямо сейчас.
func has_bonus_left(pname: String) -> bool:
	var h: Dictionary = state.heroes.get(pname, {})
	var c: Dictionary = state.combat
	if h.is_empty() or c.is_empty():
		return false
	if c.get("used", {}).get(pname, {}).get("b", false):
		return false
	if h.get("second_wind", false):
		return true
	if h.cls == "Варвар" and not h.get("raging", false) and int(h.get("rages", 0)) > 0:
		return true
	if can_extra_attack(pname):
		return true
	if h.cls == "Плут" and not c.get("hidden", {}).get(pname, false):
		return true
	for it in h.items:
		if R.item_def(it).type in ["potion", "coat"]:
			return true
	if int(h.get("inspire", 0)) > 0 and _conscious_heroes().size() > 1:
		return true
	for sp in R.known_spells(h):
		if R.SPELLS[sp].get("bonus", false) and R.slot_for(h, sp) >= 0:
			return true
	if can_dip(pname) and _count_item(h, "torch") == 0:
		return true   # жаровня или горящая земля рядом — окунуть оружие стоит
	if hero_pos(pname) == "front" and _front_enemies().size() > 0 and (_env_find("cliff") >= 0 or str(_surf().get("t", "")) in ["fire", "web"]):
		return true   # толкнуть с обрыва или в огонь/паутину — это имеет смысл
	return false


## Лишний удар бонусным действием: берсерк в ярости или жрец войны.
func can_extra_attack(pname: String) -> bool:
	var h: Dictionary = state.heroes.get(pname, {})
	if h.is_empty() or state.combat.is_empty() or _alive_enemies().is_empty():
		return false
	if str(h.get("sub", "")) == "berserker" and h.get("raging", false):
		return true
	return str(h.get("sub", "")) == "war_domain" and int(h.get("war_left", 0)) > 0


func _turn_over(pname: String) -> bool:
	var h: Dictionary = state.heroes[pname]
	if state.combat.is_empty() or int(h.hp) <= 0 or h.get("dead", false) or state.combat.get("fled", false):
		return true
	if _alive_enemies().is_empty():
		return true
	var used: Dictionary = state.combat.get("used", {}).get(pname, {})
	return used.get("a", false) and (used.get("b", false) or not has_bonus_left(pname))


func _env_find(id: String) -> int:
	var envs: Array = state.combat.get("env", [])
	for i in envs.size():
		if envs[i].id == id and not envs[i].used:
			return i
	return -1


## Использовать предмет окружения.
func _use_env(pname: String, ei: int, target) -> bool:
	var c: Dictionary = state.combat
	var h: Dictionary = state.heroes[pname]
	var e: Dictionary = c.env[ei]
	var d: Dictionary = R.ENV[e.id]
	match str(d.kind):
		"edge":
			return false   # обрыв работает через «Толкнуть»
		"high":
			if c.moved.get(pname, false) or hero_pos(pname) != "back":
				return false
			c.moved[pname] = true
			if not c.has("high"):
				c.high = {}
			c.high[pname] = true
			_log("cbt", h.name, "%s занимает возвышенность: +2 к стрельбе и заклинаниям-атакам." % h.name)
			return true
	var targets := []
	if str(d.kind) == "aoe":
		targets = _front_enemies()
		if targets.is_empty():
			targets = _alive_enemies()
	else:
		var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
		if ti >= 0:
			targets = [ti]
	if targets.is_empty():
		return false
	e.used = true
	var parts := []
	for ti in targets:
		var en: Dictionary = c.enemies[ti]
		var sv := randi_range(1, 20) + _msave(en, str(d.get("save", "ЛОВ")))
		if en.asleep or en.get("conds", {}).has("stunned"):
			sv = 0
		var saved := sv >= int(d.get("dc", 12)) and int(d.get("dc", 12)) > 0
		var part := ("%s %s (%d)" % [en.name, "увернулся" if saved else "не увернулся", sv]) if int(d.get("dc", 12)) > 0 else str(en.name)
		if str(d.get("dmg", "")) != "":
			var dmg := R.roll(str(d.dmg))
			if saved:
				dmg = dmg / 2
			if dmg > 0:
				var note := _hit_enemy(ti, dmg, str(d.name).to_lower(), str(d.dt))
				part += ", %d урона %s" % [dmg, note]
		if not saved and str(d.get("cond", "")) != "" and not en.dead:
			_add_cond(en, str(d.cond), 1)
			part += ", " + str(R.CONDS[str(d.cond)].name).to_lower()
		parts.append(part)
	_fx_event("env_" + str(e.id), "ffb36b", str(d.name), str(d.desc))
	var stx := ""
	if str(d.get("surf", "")) != "" and _front_enemies().size() > 0:
		stx = " " + _add_surface(str(d.surf))
	_log("cbt", h.name, "%s использует окружение — %s: %s%s" % [h.name, str(d.name).to_lower(), "; ".join(parts), stx])
	return true


func _target_enemy(i: int) -> int:
	var alive := _alive_enemies()
	if alive.is_empty():
		return -1
	return i if i in alive else alive[0]


var _last_dmg := 0


## Урон врагу; огонь, холод и молния по врагам впереди меняют поверхность под ними (масло вспыхивает, вода мёрзнет…).
func _hit_enemy(i: int, dmg: int, src: String, dt := "") -> String:
	var front := str(state.combat.enemies[i].get("pos", "front")) == "front"
	var note := _hit_enemy_raw(i, dmg, src, dt)
	if front and dt in ["огонь", "холод", "молния"] and not _surf().is_empty():
		var keep := _last_dmg
		var rx := _surface_react(dt)
		_last_dmg = keep
		if rx != "":
			note += " " + rx
	return note


## Урон врагу с учётом типа: уязвимость ×2, стойкость ½, огонь останавливает регенерацию, нежить может встать.
func _hit_enemy_raw(i: int, dmg: int, src: String, dt := "") -> String:
	var en: Dictionary = state.combat.enemies[i]
	var note := ""
	if dt != "":
		var g := str(R.DT_GEN.get(dt, dt))
		if dt in en.get("vuln", []):
			dmg *= 2
			note = "Уязвим к %s — урон ×2: %d! " % [g, dmg]
		elif dt in en.get("res", []):
			dmg = maxi(1, dmg / 2)
			note = "Стоек к %s — только %d урона. " % [g, dmg]
		if en.get("conds", {}).has("wet"):
			if dt in ["холод", "молния"]:
				dmg *= 2
				note += "Мокрый — урон ×2: %d! " % dmg
			elif dt == "огонь":
				dmg = maxi(1, dmg / 2)
				note += "Мокрый — огонь шипит, только %d. " % dmg
		if int(en.get("regen", 0)) > 0 and dt in ["огонь", "кислота"]:
			en.burned = true
			note += "Ожог не даст ранам затянуться. "
	_last_dmg = dmg
	var actor := combat_actor()
	if state.heroes.has(actor):
		var ss := _sess()
		ss.dmg[actor] = int(ss.dmg.get(actor, 0)) + mini(dmg, maxi(0, int(en.hp)))
		if dmg > int(ss.best.get("v", 0)):
			ss.best = {"v": dmg, "who": str(state.heroes[actor].name), "on": str(en.name)}
	en.hp = int(en.hp) - dmg
	en.asleep = false
	if int(en.hp) <= 0:
		if en.get("fort", false) and dt != "излучение" and not en.get("fort_used", false):
			var sv := randi_range(1, 20) + _msave(en, "ТЕЛ")
			if sv >= 5 + dmg:
				en.hp = 1
				en.fort_used = true
				return note + "%s падает… и снова поднимается (стойкость нежити, %d против %d)!" % [en.name, sv, 5 + dmg]
		en.hp = 0
		en.dead = true
		_sess().kills = int(_sess().kills) + 1
		var killer := combat_actor()
		var fnote := ""
		if state.heroes.has(killer) and str(state.heroes[killer].get("sub", "")) == "fiend" and int(state.heroes[killer].hp) > 0:
			var kh: Dictionary = state.heroes[killer]
			var fv := maxi(1, R.amod(kh, "ХАР") + int(kh.level))
			kh.hp = mini(int(kh.max_hp), int(kh.hp) + fv)
			fnote = " Тёмное благословение: %s +%d хитов." % [kh.name, fv]
		return note + "%s пал%s!%s" % [en.name, "" if src == "" else " (" + src + ")", fnote]
	return note + "(%s: %d/%d)" % [en.name, en.hp, en.max_hp]


func _hero_attack(pname: String, target: int, n_attacks := -1) -> bool:
	_last_target[pname] = target
	var h: Dictionary = state.heroes[pname]
	var c: Dictionary = state.combat
	var info := R.attack_info(h)
	var rolls := []
	if not c.has("once"):
		c.once = {}
	if not c.once.has(pname):
		c.once[pname] = {}
	var once: Dictionary = c.once[pname]
	if not info.ranged and hero_pos(pname) != "front":
		c.pos[pname] = "front"
		_log("cbt", h.name, "%s выходит вперёд." % h.name)
	for k in (int(info.attacks) if n_attacks < 0 else n_attacks):
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
		adv += R.cond_adv(h, en, not info.ranged)
		if c.get("help", {}).get(pname, false):
			adv += 1
			c.help.erase(pname)
		var from_shadow := false
		if c.get("hidden", {}).get(pname, false):
			adv += 1
			from_shadow = true
			c.hidden.erase(pname)
		var assassinate: bool = str(h.get("sub", "")) == "assassin_sub" and int(c.round) == 1
		if assassinate:
			adv += 1
		var r := _d20(h, clampi(adv, -1, 1))
		var high := 2 if info.ranged and c.get("high", {}).get(pname, false) else 0
		var total: int = r.value + int(info.atk) + r.insp + high
		var hit: bool = (total >= int(en.ac) or r.value == 20) and r.value != 1
		var crit: bool = (hit and r.value >= int(info.get("crit", 20))) or (hit and (en.asleep or en.get("conds", {}).has("held")) and not info.ranged) or (hit and assassinate)
		var line := "%s%s бьёт %s (%s): %d против КД %d — " % ["Из тени! " if from_shadow else "", h.name, en.name, info.name, total, en.ac]
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
			var coat: Dictionary = h.get("coat", {})
			if int(coat.get("hits", 0)) > 0:
				dmg += R.roll(str(coat.dice))
				coat.hits = int(coat.hits) - 1
				sneak += " + яд"
				if not en.get("undead", false):
					_add_cond(en, "poisoned", 2)
				if int(coat.hits) <= 0:
					h.erase("coat")
			dmg = maxi(1, dmg)
			outcome = "критическое попадание" if crit else "попадание"
			if crit:
				_sess().crits = int(_sess().crits) + 1
			var note := _hit_enemy(ti, dmg, "", str(info.get("dt", "")))
			dealt = _last_dmg
			line += "%s%s, %d урона. %s" % [outcome, sneak, dmg, note]
			if int(c.get("dip", {}).get(pname, -1)) >= int(c.round) and not en.dead:
				var fd := _roll_damage("1d4", crit)
				line += " Пылающее оружие: +%d огнём. %s" % [fd, _hit_enemy(ti, fd, "", "огонь")]
			line += _on_hit_extras(pname, ti, info, crit, once)
		else:
			line += "промах."
		_log("cbt", h.name, line)
		rolls.append({"label": "%s ⚔ %s" % [h.name, en.name], "d20": r.value, "d20b": r.other, "adv": r.adv,
			"mod": int(info.atk) + r.insp + high, "total": total, "dc": int(en.ac), "outcome": outcome,
			"kind": "attack", "dmg": dealt, "dmg_text": "%s%+d" % [R.dice_ru(str(info.dice)), int(info.bonus)]})
	_show_rolls(rolls)
	return true


## Добавки к попаданию оружием: магическое оружие, кара, порча, мантия, подклассы.
func _on_hit_extras(pname: String, ti: int, info: Dictionary, crit: bool, once: Dictionary) -> String:
	var h: Dictionary = state.heroes[pname]
	var c: Dictionary = state.combat
	var en: Dictionary = c.enemies[ti]
	var out := ""
	var ex: Dictionary = info.get("extra", {})
	if not ex.is_empty() and not en.dead and (not ex.get("undead", false) or en.get("undead", false)):
		var xd := _roll_damage(str(ex.dice), crit)
		out += " %s: +%d (%s). %s" % [info.name, xd, str(ex.dt), _hit_enemy(ti, xd, "", str(ex.dt))]
	if str(info.get("drain", "")) != "" and not en.dead and not en.get("undead", false):
		var dd := _roll_damage(str(info.drain), crit)
		var dn := _hit_enemy(ti, dd, "", "некротический")
		h.hp = mini(int(h.max_hp), int(h.hp) + _last_dmg)
		out += " Клинок пьёт кровь: +%d, %s лечится (%d/%d). %s" % [_last_dmg, h.name, int(h.hp), int(h.max_hp), dn]
	if info.get("stun", false) and crit and not en.dead and int(en.max_hp) < 80:
		_add_cond(en, "stunned", 1)
		out += " Громовой удар оглушает %s!" % en.name
	if not info.ranged and h.get("smite_on", false) and not en.dead:
		var sl := -1
		for si in (h.slots as Array).size():
			if int(h.slots[si]) > 0:
				sl = si
				break
		if sl >= 0:
			h.slots[sl] = int(h.slots[sl]) - 1
			var nd := 2 + sl + (1 if en.get("undead", false) else 0)
			var sd := _roll_damage("%dd8" % nd, crit)
			_fx_event("act_smite", "ffe08a", "Божественная кара", "%d излучением · ячейка %d ур." % [sd, sl + 1])
			out += " ⚡ Божественная кара (ячейка %d ур.): +%d излучением. %s" % [sl + 1, sd, _hit_enemy(ti, sd, "", "излучение")]
	if int(h.get("brand", 0)) > 0 and not en.dead:
		var bd := _roll_damage("%dd6" % int(h.brand), crit)
		h.erase("brand")
		out += " Клеймо света: +%d излучением, %s больше не спрячется. %s" % [bd, en.name, _hit_enemy(ti, bd, "", "излучение")]
	if c.has("mantle") and not en.dead:
		var md := _roll_damage("1d4", crit)
		out += " Мантия: +%d. %s" % [md, _hit_enemy(ti, md, "", "излучение")]
	out += _hex_hit(pname, ti, crit)
	var sub := str(h.get("sub", ""))
	if sub == "hunter_sub" and not once.get("colossus", false) and not en.dead and int(en.hp) < int(en.max_hp):
		once.colossus = true
		var gd := _roll_damage("1d8", crit)
		out += " Убийца великанов: +%d. %s" % [gd, _hit_enemy(ti, gd, "", str(info.get("dt", "")))]
	if sub == "battle_master" and not once.get("trip", false) and not en.dead:
		once.trip = true
		var td := _roll_damage("1d8", crit)
		out += " Подсечка: +%d. %s" % [td, _hit_enemy(ti, td, "", str(info.get("dt", "")))]
		if not en.dead and int(en.max_hp) < 60:
			_add_cond(en, "prone", 1)
			out += " %s падает!" % en.name
	return out


func _hex_hit(pname: String, ti: int, crit: bool) -> String:
	var c: Dictionary = state.combat
	if int(c.get("hex", {}).get(pname, -1)) != ti or c.enemies[ti].dead:
		return ""
	var hd := _roll_damage("1d6", crit)
	return " Порча: +%d некротикой. %s" % [hd, _hit_enemy(ti, hd, "", "некротический")]


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
	var dice := str(sp.get("dmg", ""))
	var p := R.parse_dice(dice if dice != "" else "1d4")
	if dice == "":
		pass
	elif int(sp.lvl) == 0 and int(h.level) >= 5 and spell != "eldritch_blast":
		dice = "%dd%d" % [p.n * 2, p.sides]
	elif upcast > 0 and sp.kind != "auto":
		dice = "%dd%d%s" % [p.n + upcast, p.sides, ("+%d" % p.bonus) if p.bonus > 0 else ""]
	var sa := R.spell_attack(h) if not from_scroll else 5
	var sdc := R.spell_dc(h) if not from_scroll else 13
	var rolls := []
	var head := "%s %s «%s»" % [h.name, "читает свиток" if from_scroll else "колдует", sp.name]
	match str(sp.kind):
		"attack":
			var nrays := int(sp.get("rays", 1)) + upcast * int(sp.has("rays"))
			if spell == "eldritch_blast" and int(h.level) >= 5:
				nrays = 2
			for k in nrays:
				var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
				if ti < 0:
					break
				var en: Dictionary = c.enemies[ti]
				var sadv := 1 if en.asleep else 0
				if hero_pos(pname) == "front" and _front_enemies().size() > 0:
					sadv -= 1
				sadv += R.cond_adv(h, en, false)
				if k == 0 and c.get("help", {}).get(pname, false):
					sadv += 1
					c.help.erase(pname)
				if k == 0 and c.get("hidden", {}).get(pname, false):
					sadv += 1
					c.hidden.erase(pname)
				var r := _d20(h, clampi(sadv, -1, 1))
				var shigh := 2 if c.get("high", {}).get(pname, false) else 0
				var total: int = r.value + sa + r.insp + shigh
				var hit: bool = (total >= int(en.ac) or r.value == 20) and r.value != 1
				var crit: bool = r.value == 20
				var line := "%s в %s: %d против КД %d — " % [head, en.name, total, en.ac]
				var dealt := -1
				if hit:
					var dmg := _roll_damage(dice, crit) + R.talent_sum(h, "spell_dmg") + (R.caster_mod(h) if sp.get("add_mod", false) and int(h.level) >= 2 else 0)
					var note := _hit_enemy(ti, dmg, "", str(sp.get("dt", "")))
					dealt = _last_dmg
					line += "попадание, %d урона. %s%s" % [dmg, note, _hex_hit(pname, ti, crit)]
					if str(sp.get("cond", "")) != "" and not en.dead:
						_add_cond(en, str(sp.cond), 1)
						line += " %s %s." % [en.name, str(R.CONDS[str(sp.cond)].name).to_lower()]
				else:
					line += "промах."
				_log("cbt", h.name, line)
				rolls.append({"label": "%s · %s" % [h.name, sp.name], "d20": r.value, "d20b": r.other, "adv": r.adv,
					"mod": sa + r.insp + shigh, "total": total, "dc": int(en.ac), "outcome": ("попадание" if hit else "промах"),
					"kind": "spell", "dmg": dealt})
		"auto":
			var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
			if ti < 0:
				return false
			var dmg := R.roll(dice) + upcast * (randi_range(1, 4) + 1) + R.talent_sum(h, "spell_dmg")
			var anote := _hit_enemy(ti, dmg, "", str(sp.get("dt", "")))
			_fx_event("sp_" + spell, str(R.SPELLS[spell].get("col", "b98cff")), sp.name, "%d урона · %s" % [_last_dmg, c.enemies[ti].name])
			_log("cbt", h.name, "%s: %d урона по %s. %s" % [head, dmg, c.enemies[ti].name, anote])
		"save":
			var targets := _alive_enemies() if sp.get("aoe", false) else [_target_enemy(int(target) if (target is int or target is float) else -1)]
			var parts := []
			for ti in targets:
				if ti < 0:
					continue
				var en: Dictionary = c.enemies[ti]
				if sp.get("no_undead", false) and en.get("undead", false):
					parts.append("%s — нежить, не действует" % en.name)
					continue
				var sv := randi_range(1, 20) + _msave(en, str(sp.save))
				if en.asleep and str(sp.save) in ["ЛОВ", "СИЛ"]:
					sv = 0
				var dmg := _roll_damage(dice, false)
				var saved := sv >= sdc
				if saved:
					dmg = dmg / 2 if sp.get("aoe", false) else 0
				var cnote := ""
				if not saved and str(sp.get("cond", "")) != "" and not en.dead:
					_add_cond(en, str(sp.cond), 1)
					cnote = ", " + str(R.CONDS[str(sp.cond)].name).to_lower()
				parts.append("%s %s (%d), %d урона%s %s" % [en.name, "увернулся" if saved else "не увернулся", sv, dmg, cnote, _hit_enemy(ti, dmg, "", str(sp.get("dt", ""))) if dmg > 0 else ""])
			_fx_event("sp_" + spell, str(sp.get("col", "ff7a3d")), sp.name, "спасбросок %s против СЛ %d · целей: %d" % [sp.save, sdc, parts.size()])
			var snote := ""
			if str(sp.get("surf", "")) != "" and _front_enemies().size() > 0:
				snote = " " + _add_surface(str(sp.surf))
			_log("cbt", h.name, "%s (СЛ %d): %s%s" % [head, sdc, "; ".join(parts), snote])
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
			var wn := []
			for n in who:
				wn.append(str(state.heroes[n].name))
			_fx_event("sp_" + spell, str(sp.get("col", "6fe3a0")), sp.name, "лечение: " + ", ".join(wn))
			for n in who:
				_heal_hero(n, R.roll(dice) + R.caster_mod(h) + R.talent_sum(h, "heal"))
		"buff":
			var tn := str(target)
			if not state.heroes.has(tn):
				tn = pname
			var prev := _start_conc(pname, spell, tn)
			state.heroes[tn].temp_ac = int(sp.get("ac", 2))
			_fx_event("sp_" + spell, str(sp.get("col", "ffe08a")), sp.name, "%s: +%d к КД" % [state.heroes[tn].name, int(sp.get("ac", 2))])
			_log("cbt", h.name, "%s%s: %s получает +%d к КД, пока %s держит концентрацию." % [prev, head, state.heroes[tn].name, int(sp.get("ac", 2)), h.name])
		"bless":
			var prev := _start_conc(pname, spell, "")
			var wn := []
			for n in _conscious_heroes():
				state.heroes[n].blessed = true
				wn.append(str(state.heroes[n].name))
			_fx_event("sp_" + spell, str(sp.get("col", "ffe08a")), sp.name, "+1к4 к атакам и спасброскам: " + ", ".join(wn))
			_log("cbt", h.name, "%s%s: %s — +1к4 к атакам и спасброскам, пока %s держит концентрацию." % [prev, head, ", ".join(wn), h.name])
		"hold":
			var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
			if ti < 0:
				return false
			var en: Dictionary = c.enemies[ti]
			if en.get("undead", false) or str(en.get("mid", "")) in BEASTS:
				_log("cbt", h.name, "%s: на %s не действует — это заклинание сковывает только людей и им подобных." % [head, en.name])
			else:
				var sv := randi_range(1, 20) + _msave(en, "МДР")
				if en.asleep:
					sv = 0
				if sv >= sdc:
					_log("cbt", h.name, "%s на %s: спасбросок МДР %d против СЛ %d — устоял." % [head, en.name, sv, sdc])
				else:
					var prev := _start_conc(pname, spell, str(ti))
					_add_cond(en, "held", 10)
					en.held_dc = sdc
					en.held_by = pname
					_log("cbt", h.name, "%s%s на %s: спасбросок МДР %d против СЛ %d — скован! Удары вблизи по нему — критические." % [prev, head, en.name, sv, sdc])
		"hex":
			var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
			if ti < 0:
				return false
			var prev := _start_conc(pname, spell, str(ti))
			if not c.has("hex"):
				c.hex = {}
			c.hex[pname] = ti
			_fx_event("sp_hex", str(sp.get("col", "a35bff")), sp.name, "%s проклят: +1к6 некротикой" % c.enemies[ti].name)
			_log("cbt", h.name, "%s%s на %s: каждое попадание %s по нему — +1к6 некротикой." % [prev, head, c.enemies[ti].name, h.name])
		"smite_buff":
			h.brand = 2 + upcast
			_fx_event("sp_" + spell, str(sp.get("col", "ffe08a")), sp.name, "следующий удар +%dк6 излучением" % int(h.brand), true)
			_log("cbt", h.name, "%s: клинок сияет — следующий удар +%dк6 излучением." % [head, int(h.brand)])
		"mantle":
			var prev := _start_conc(pname, spell, "")
			c.mantle = pname
			_fx_event("sp_" + spell, str(sp.get("col", "ffd75e")), sp.name, "удары союзников +1к4 излучением", true)
			_log("cbt", h.name, "%s%s: оружие союзников сияет — +1к4 излучением к каждому удару." % [prev, head])
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
			_fx_event("sp_" + spell, str(sp.get("col", "a9a0ff")), sp.name, ("засыпают: " + ", ".join(slept)) if slept.size() > 0 else "никто не уснул")
			_log("cbt", h.name, "%s: %s" % [head, ("засыпают: " + ", ".join(slept)) if slept.size() > 0 else "никто не уснул."])
	if rolls.size() > 0:
		_show_rolls(rolls)
	return true


# ---------- реакции героев (как в BG3: одна за раунд) ----------

func _can_react(pname: String) -> bool:
	var h: Dictionary = state.heroes.get(pname, {})
	if h.is_empty() or int(h.hp) <= 0 or h.get("react_off", false):
		return false
	var cs: Dictionary = h.get("conds", {})
	if cs.has("stunned") or cs.has("held"):
		return false
	return int(state.combat.get("react", {}).get(pname, -1)) != int(state.combat.round)


func _use_reaction(pname: String) -> void:
	if not state.combat.has("react"):
		state.combat.react = {}
	state.combat.react[pname] = int(state.combat.round)


## «Щит» мага: реакция, тратит ячейку 1 уровня.
func _can_shield(pname: String) -> bool:
	var h: Dictionary = state.heroes[pname]
	return has_shield(h) and (h.slots as Array).size() > 0 and int(h.slots[0]) > 0 and _can_react(pname)


static func has_shield(h: Dictionary) -> bool:
	return str(h.get("cls", "")) == "Маг"


## Ответный выпад: Воин с 3 уровня (у Мастера боевых искусств — с 1-го после выбора).
static func has_riposte(h: Dictionary) -> bool:
	return (str(h.get("cls", "")) == "Воин" and int(h.get("level", 1)) >= 3) or str(h.get("sub", "")) == "battle_master"


func _has_riposte(pname: String) -> bool:
	return has_riposte(state.heroes[pname]) and hero_pos(pname) == "front"


## Один удар реакцией.
func _reaction_strike(pname: String, i: int, what: String) -> void:
	_use_reaction(pname)
	var h: Dictionary = state.heroes[pname]
	var en: Dictionary = state.combat.enemies[i]
	var info := R.attack_info(h)
	var r := _d20(h, 0)
	var total: int = r.value + int(info.atk) + r.insp
	var hit: bool = (total >= int(en.ac) or r.value == 20) and r.value != 1
	var line := "⚡ %s %s %s: %d против КД %d — " % [h.name, what, en.name, total, en.ac]
	if hit:
		var dmg := maxi(1, _roll_damage(str(info.dice), r.value == 20) + int(info.bonus))
		line += "попадание, %d урона. %s" % [dmg, _hit_enemy(i, dmg, "", str(info.get("dt", "")))]
	else:
		line += "промах."
	_log("cbt", h.name, line)


# ---------- тактика врагов ----------

func _hsurf() -> Dictionary:
	return state.combat.get("hsurf", {})


func _front_heroes() -> Array:
	var out := []
	for n in _conscious_heroes():
		if hero_pos(n) == "front":
			out.append(n)
	return out


## Поверхность под героями впереди.
func _hero_surf_add(t: String, rounds: int) -> void:
	state.combat.hsurf = {"t": t, "r": rounds}
	var d: Dictionary = R.SURFACES[t]
	var icon := {"fire": "surf_fire", "oil": "env_oil", "web": "env_web"}
	_fx_event(str(icon.get(t, "env_oil")), str(d.col), "Под ногами героев: " + str(d.name), "впереди опасно — можно отойти в тыл", true)


## Огонь по героям впереди (спасбросок ЛОВ 12 — половина).
func _hero_burst(dice: String) -> String:
	var parts := []
	for n in _front_heroes():
		var h: Dictionary = state.heroes[n]
		var dmg := R.roll(dice)
		var sv := randi_range(1, 20) + R.save_bonus(h, "ЛОВ") + (randi_range(1, 4) if h.get("blessed", false) else 0)
		if sv >= 12:
			dmg = dmg / 2
		var extra := _damage_hero(n, dmg, false)
		parts.append("%s −%d%s" % [h.name, dmg, (" " + extra) if extra != "" else ""])
	return ", ".join(parts)


## В начале хода героя: что с ним делает поверхность под ногами (только впереди).
func _hero_surf_tick(pname: String) -> void:
	var hs := _hsurf()
	if hs.is_empty() or hero_pos(pname) != "front":
		return
	var h: Dictionary = state.heroes[pname]
	match str(hs.t):
		"fire":
			var dmg := R.roll("1d6")
			var extra := _damage_hero(pname, dmg, false)
			_log("cbt", h.name, "%s стоит в огне: %d урона. %s Отойди в тыл!" % [h.name, dmg, extra])
		"oil":
			var sv := randi_range(1, 20) + R.save_bonus(h, "ЛОВ")
			if sv < 11:
				_add_cond(h, "prone", 1)
				_log("cbt", h.name, "%s поскальзывается на масле (ЛОВ %d против 11)." % [h.name, sv])
		"web":
			var sv := randi_range(1, 20) + maxi(R.save_bonus(h, "СИЛ"), R.save_bonus(h, "ЛОВ"))
			if sv < 11:
				state.combat.moved[pname] = true
				_log("cbt", h.name, "%s увяз в паутине (%d против 11): с места не сдвинуться в этот ход." % [h.name, sv])


## Особый приём врага вместо обычной атаки. true — ход потрачен.
func _enemy_tactic(i: int) -> bool:
	var c: Dictionary = state.combat
	var en: Dictionary = c.enemies[i]
	var tac: Array = en.get("tac", [])
	if tac.is_empty() or en.get("conds", {}).has("prone"):
		return false
	if int(en.get("tac_cd", 0)) > int(c.round):
		return false
	var fh := _front_heroes()
	var hs := str(_hsurf().get("t", ""))
	# лекарь: поднимает тяжело раненого союзника
	if "heal" in tac:
		for j in _alive_enemies():
			var al: Dictionary = c.enemies[j]
			if j != i and int(al.hp) * 2 < int(al.max_hp) and randf() < 0.7:
				var v := R.roll("1d8+2")
				al.hp = mini(int(al.max_hp), int(al.hp) + v)
				en.tac_cd = int(c.round) + 2
				_fx_event("sp_cure_wounds", "6fe3a0", "%s лечит" % en.name, "%s +%d хитов" % [al.name, v], true)
				_log("cbt", "", "%s бормочет заклинание и затягивает раны %s: +%d хитов (%d/%d). Убейте лекаря первым!" % [en.name, al.name, v, al.hp, al.max_hp])
				return true
	# поджечь масло под героями
	if ("ignite" in tac or "fire_arrow" in tac) and hs == "oil" and fh.size() > 0 and randf() < (0.85 if "ignite" in tac else 0.5):
		_hero_surf_add("fire", 2)
		en.tac_cd = int(c.round) + 2
		_log("cbt", "", "%s пускает огненную стрелу в масло под героями — вспышка! %s" % [en.name, _hero_burst("2d6")])
		return true
	# разлить масло
	if "oil" in tac and hs == "" and fh.size() > 0 and randf() < 0.45:
		_hero_surf_add("oil", 3)
		en.tac_cd = int(c.round) + 3
		_log("cbt", "", "%s швыряет под ноги героям флягу с маслом. Скользко — и одна искра всё подожжёт!" % en.name)
		return true
	# паутина
	if "web" in tac and hs == "" and fh.size() > 0 and randf() < 0.35:
		_hero_surf_add("web", 2)
		en.tac_cd = int(c.round) + 3
		_log("cbt", "", "%s плюётся липкой паутиной: герои впереди вязнут." % en.name)
		return true
	# громила толкает героя (с обрыва, если есть)
	if "shove" in tac and fh.size() > 0 and str(en.get("pos", "front")) == "front" and randf() < 0.3:
		var tn: String = fh[randi() % fh.size()]
		var h: Dictionary = state.heroes[tn]
		en.tac_cd = int(c.round) + 2
		var me := randi_range(1, 20) + int(en.atk) - 2 + (4 if int(en.max_hp) >= 50 else 0)
		var them := randi_range(1, 20) + maxi(R.skill_bonus(h, "Атлетика"), R.skill_bonus(h, "Акробатика"))
		if me <= them:
			_log("cbt", "", "%s пытается сбить %s с ног (%d против %d), но тот устоял." % [en.name, h.name, me, them])
			return true
		if _env_find("cliff") >= 0:
			var dmg := R.roll("2d6")
			var extra := _damage_hero(tn, dmg, false)
			_add_cond(h, "prone", 1)
			_log("cbt", "", "%s сталкивает %s с обрыва (%d против %d): %d урона от падения. %s" % [en.name, h.name, me, them, dmg, extra])
		else:
			_add_cond(h, "prone", 1)
			_log("cbt", "", "%s сбивает %s с ног (%d против %d): лёжа — помеха на атаки, а по нему бьют с преимуществом." % [en.name, h.name, me, them])
		return true
	return false


const BEASTS := ["giant_rat", "wolf", "dire_wolf", "giant_spider", "giant_spider_small", "harpy", "wyvern", "young_dragon", "minotaur", "troll", "ogre"]


## Концентрация (как в BG3): одно такое заклинание за раз; урон заставляет кинуть ТЕЛ, при провале чары спадают.
func _start_conc(pname: String, spell: String, target: String) -> String:
	var h: Dictionary = state.heroes[pname]
	var prev := ""
	if not h.get("conc", {}).is_empty():
		prev = _end_conc(pname, "новое заклинание") + " "
	h.conc = {"sp": spell, "t": target}
	return prev


func _end_conc(pname: String, why: String) -> String:
	var h: Dictionary = state.heroes[pname]
	var cc: Dictionary = h.get("conc", {})
	if cc.is_empty():
		return ""
	h.erase("conc")
	var sp := str(cc.get("sp", ""))
	var t := str(cc.get("t", ""))
	match sp:
		"shield_of_faith":
			if state.heroes.has(t):
				state.heroes[t].temp_ac = 0
		"bless":
			for n in state.heroes:
				state.heroes[n].erase("blessed")
		"hold_person":
			var c: Dictionary = state.combat
			if not c.is_empty() and t.is_valid_int() and int(t) < c.enemies.size():
				c.enemies[int(t)].get("conds", {}).erase("held")
		"hex":
			state.combat.get("hex", {}).erase(pname)
		"crusaders_mantle":
			state.combat.erase("mantle")
	return "%s теряет концентрацию (%s): «%s» спадает." % [h.name, why, R.SPELLS[sp].name if R.SPELLS.has(sp) else sp]


## Ход скованного врага: в начале хода пытается вырваться (спасбросок МДР). false — ход пропущен.
func _held_tick(i: int) -> bool:
	var en: Dictionary = state.combat.enemies[i]
	if not en.get("conds", {}).has("held"):
		return true
	var dc := int(en.get("held_dc", 13))
	var sv := randi_range(1, 20) + _msave(en, "МДР")
	if sv >= dc:
		en.conds.erase("held")
		var by := str(en.get("held_by", ""))
		if state.heroes.has(by) and str(state.heroes[by].get("conc", {}).get("sp", "")) == "hold_person":
			state.heroes[by].erase("conc")
		_log("cbt", "", "%s сбрасывает оковы (спасбросок МДР %d против %d)!" % [en.name, sv, dc])
		return true
	_log("cbt", "", "%s скован и не может пошевелиться (МДР %d против %d)." % [en.name, sv, dc])
	return false


# ---------- поверхности (как в BG3) ----------

func _surf() -> Dictionary:
	return state.combat.get("surf", {})


func surface_now() -> Dictionary:
	return state.get("combat", {}).get("surf", {})


func _set_surf(t: String, rounds: int) -> void:
	var cur := _surf()
	if str(cur.get("t", "")) == t:
		cur.r = maxi(int(cur.r), rounds)
		return
	state.combat.surf = {"t": t, "r": rounds}
	var d: Dictionary = R.SURFACES[t]
	var icon := {"fire": "surf_fire", "oil": "env_oil", "web": "env_web", "water": "env_water", "ice": "env_water", "shock": "sp_shocking_grasp"}
	_fx_event(str(icon.get(t, "env_oil")), str(d.col), "Под ногами врагов: " + str(d.name), str(d.desc), true)
	if t in ["water", "shock"]:
		for i in _front_enemies():
			var en: Dictionary = state.combat.enemies[i]
			if not en.has("conds"):
				en.conds = {}
			en.conds.wet = maxi(int(en.conds.get("wet", 0)), 2)
	if t in ["fire", "ice"]:
		for i in _front_enemies():
			state.combat.enemies[i].get("conds", {}).erase("wet")


## Вспышка огня по всем врагам впереди.
func _flame_burst(dice: String) -> String:
	var parts := []
	for i in _front_enemies():
		var en: Dictionary = state.combat.enemies[i]
		_hit_enemy(i, R.roll(dice), "огонь", "огонь")
		parts.append("%s −%d%s" % [en.name, _last_dmg, " (пал)" if en.dead else ""])
	return ", ".join(parts)


func _burst_msg(head: String, dice: String) -> String:
	var b := _flame_burst(dice)
	return head + ((": " + b) if b != "" else "") + "."


## Новая поверхность под врагами с учётом старой.
func _add_surface(t: String) -> String:
	var cur := str(_surf().get("t", ""))
	match t:
		"oil":
			if cur == "fire":
				_set_surf("fire", 3)
				return _burst_msg("Масло льётся в огонь и вспыхивает", "2d6")
			_set_surf("oil", 3)
			return "Земля под врагами залита маслом."
		"web":
			if cur == "fire":
				_set_surf("fire", 2)
				return _burst_msg("Паутина падает в огонь и сгорает", "1d6")
			_set_surf("web", 3)
			return "Враги впереди облеплены паутиной."
		"water":
			if cur == "fire":
				_set_surf("water", 3)
				return "Вода с шипением гасит огонь — враги мокрые."
			if cur == "shock":
				return ""
			_set_surf("water", 3)
			return "Враги впереди промокли: холод и молния ранят их вдвое."
		"fire":
			if cur in ["oil", "web"]:
				return _surface_react("огонь")
			if cur in ["water", "shock"]:
				return "Вода шипит — огню здесь не разгореться."
			if cur == "ice":
				_set_surf("water", 2)
				return "Лёд тает в лужи."
			_set_surf("fire", 2)
			return "Земля под врагами горит."
		"ice":
			if cur == "fire":
				_set_surf("water", 2)
				return "Град гасит огонь — остаются лужи."
			_set_surf("ice", 3)
			return "Земля под врагами покрылась льдом: на нём легко поскользнуться."
	return ""


## Реакция поверхности на огонь / холод / молнию по врагу впереди.
func _surface_react(dt: String) -> String:
	var cur := str(_surf().get("t", ""))
	match dt:
		"огонь":
			if cur == "oil":
				_set_surf("fire", 3)
				return _burst_msg("Масло вспыхивает! Взрыв", "2d6")
			if cur == "web":
				_set_surf("fire", 2)
				return _burst_msg("Паутина вспыхивает", "1d6")
			if cur == "ice":
				_set_surf("water", 2)
				return "Лёд тает в лужи."
		"холод":
			if cur in ["water", "shock"]:
				_set_surf("ice", 3)
				return "Вода под врагами замерзает — скользко!"
			if cur == "fire":
				state.combat.surf = {}
				return "Холод гасит пламя."
		"молния":
			if cur == "water":
				_set_surf("shock", 1)
				var parts := []
				for i in _front_enemies():
					var en: Dictionary = state.combat.enemies[i]
					var sv := randi_range(1, 20) + _msave(en, "ТЕЛ")
					if sv < 12:
						_add_cond(en, "stunned", 1)
						parts.append(str(en.name))
				return "Ток бежит по воде!" + (" Оцепенели: " + ", ".join(parts) + "." if parts.size() > 0 else "")
	return ""


## В начале хода врага: что делает с ним поверхность. false — ход потерян.
func _surface_tick(i: int) -> bool:
	var sf := _surf()
	var en: Dictionary = state.combat.enemies[i]
	if sf.is_empty() or en.dead or str(en.get("pos", "front")) != "front":
		return true
	match str(sf.t):
		"fire":
			var dmg := R.roll("1d6")
			_log("cbt", "", "%s горит: %d урона огнём. %s" % [en.name, dmg, _hit_enemy(i, dmg, "огонь", "огонь")])
			return not en.dead
		"oil", "ice":
			var sv := randi_range(1, 20) + _msave(en, "ЛОВ")
			if sv < 11 - (4 if int(en.max_hp) >= 50 else 0):
				_add_cond(en, "prone", 1)
				_log("cbt", "", "%s поскальзывается (%s, ЛОВ %d) и падает — ход потерян." % [en.name, "масло" if str(sf.t) == "oil" else "лёд", sv])
				return false
		"web":
			var sv := randi_range(1, 20) + maxi(_msave(en, "СИЛ"), int(en.atk) - 3)
			if sv < 11 - (4 if int(en.max_hp) >= 50 else 0):
				_log("cbt", "", "%s вязнет в паутине (СИЛ %d) и не может атаковать." % [en.name, sv])
				return false
		"shock":
			var sv := randi_range(1, 20) + _msave(en, "ТЕЛ")
			if sv < 11 - (4 if int(en.max_hp) >= 50 else 0):
				_log("cbt", "", "%s бьётся в судорогах от тока (ТЕЛ %d) — ход потерян." % [en.name, sv])
				return false
		"water":
			if not en.has("conds"):
				en.conds = {}
			en.conds.wet = maxi(int(en.conds.get("wet", 0)), 2)
	return true


## Шанс толкнуть врага (состязание к20 + Атлетика против к20 + его модификатора), в процентах.
func shove_chance(pname: String, ti: int) -> int:
	var c: Dictionary = state.get("combat", {})
	if c.is_empty() or ti < 0 or ti >= c.enemies.size():
		return 0
	var en: Dictionary = c.enemies[ti]
	if en.asleep or en.get("conds", {}).has("stunned") or en.get("conds", {}).has("held"):
		return 95
	var a := R.skill_bonus(state.heroes[pname], "Атлетика")
	var b := maxi(int(en.get("dex", 0)), int(en.atk) - 2) + (4 if int(en.max_hp) >= 50 else 0)
	var win := 0
	for x in range(1, 21):
		for y in range(1, 21):
			if x + a >= maxi(5, y + b):
				win += 1
	return roundi(win / 4.0)


## Можно ли окунуть оружие в огонь: жаровня, горящая земля или факел в сумке.
func can_dip(pname: String) -> bool:
	var c: Dictionary = state.get("combat", {})
	var h: Dictionary = state.heroes.get(pname, {})
	if c.is_empty() or h.is_empty():
		return false
	if int(c.get("dip", {}).get(pname, -1)) >= int(c.round):
		return false
	if str(c.get("surf", {}).get("t", "")) == "fire" and hero_pos(pname) == "front":
		return true
	for e in c.get("env", []):
		if str(e.id) == "brazier" and not e.used:
			return true
	return _count_item(h, "torch") > 0


## Что можно метнуть: зелья (лечат союзника), оружие (своим уроном), факел (огнём), прочее (1к4).
static func throw_info(it: Dictionary) -> Dictionary:
	var d := R.item_def(it)
	var id := str(it.get("id", ""))
	if d.type == "potion":
		return {"kind": "potion"}
	if id == "torch":
		return {"kind": "hit", "dmg": "1d4", "dt": "огонь"}
	if d.type == "weapon" and not d.get("ranged", false):
		return {"kind": "hit", "dmg": str(d.dmg), "dt": R.weapon_dt(d), "weapon": true}
	return {}   # прочий хлам метать бессмысленно — не загромождаем меню


func _hero_throw(pname: String, idx: int, target) -> bool:
	var h: Dictionary = state.heroes[pname]
	var c: Dictionary = state.combat
	if idx < 0 or idx >= h.items.size():
		return false
	var it: Dictionary = h.items[idx]
	var ti_info := throw_info(it)
	if ti_info.is_empty():
		return false
	if ti_info.kind == "potion":
		var to := str(target)
		if not state.heroes.has(to):
			to = pname
		var d := R.item_def(it)
		h.items.remove_at(idx)
		var th: Dictionary = state.heroes[to]
		for cn in d.get("cure", []):
			th.get("conds", {}).erase(cn)
		_log("cbt", h.name, "%s бросает %s %s — склянка разбивается, брызги лечат." % [h.name, R.item_name(it), th.name])
		_heal_hero(to, R.roll(str(d.heal)) + R.talent_sum(h, "heal"))
		return true
	var ti := _target_enemy(int(target) if (target is int or target is float) else -1)
	if ti < 0:
		return false
	h.items.remove_at(idx)
	if not c.has("thrown"):
		c.thrown = []
	c.thrown.append({"who": pname, "it": it})
	var en: Dictionary = c.enemies[ti]
	var adv := (1 if en.asleep else 0) + R.cond_adv(h, en, false)
	var r := _d20(h, clampi(adv, -1, 1))
	var mod := maxi(R.amod(h, "СИЛ"), R.amod(h, "ЛОВ"))
	var atk: int = mod + (R.prof(int(h.level)) if ti_info.get("weapon", false) else 0)
	var total: int = r.value + atk + r.insp
	var hit: bool = (total >= int(en.ac) or r.value == 20) and r.value != 1
	var crit: bool = hit and r.value == 20
	var line := "%s метает %s в %s: %d против КД %d — " % [h.name, R.item_name(it), en.name, total, en.ac]
	var dealt := -1
	if hit:
		var dmg := maxi(1, _roll_damage(str(ti_info.dmg), crit) + mod)
		line += "попадание, %d урона. %s" % [dmg, _hit_enemy(ti, dmg, "", str(ti_info.dt))]
		dealt = _last_dmg
	else:
		line += "промах."
		if str(ti_info.dt) == "огонь" and str(en.get("pos", "front")) == "front":
			var rx := _surface_react("огонь")
			if rx != "":
				line += " Но факел падает под ноги: " + rx
	_log("cbt", h.name, line)
	_show_rolls([{"label": "%s ➶ %s" % [h.name, en.name], "d20": r.value, "d20b": r.other, "adv": r.adv,
		"mod": atk + r.insp, "total": total, "dc": int(en.ac), "outcome": "попадание" if hit else "промах",
		"kind": "attack", "dmg": dealt, "dmg_text": "%s%+d" % [R.dice_ru(str(ti_info.dmg)), mod]}])
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
			bag.append(R.item_name(it) + ((" (" + str(it.note).left(80) + ")") if str(it.get("note", "")) != "" else ""))
		var status := ""
		if int(h.hp) <= 0:
			status = " БЕЗ СОЗНАНИЯ."
		if not (n in Net.players.values()):
			status += " (сейчас отсутствует, держится в тени)"
		lines.append("- %s: %s %s %d ур., %s. Хиты %d/%d, КД %d, золото %d. %s. Навыки: %s. Умения: %s. Надето: %s. В сумке: %s.%s" % [
			h.name, h.race, h.cls, h.level, h.about if str(h.about) != "" else "без описания", h.hp, h.max_hp, R.ac(h), h.gold,
			", ".join(sc), ", ".join(h.skills), str(R.CLASSES[h.cls].features) + ((". Путь: " + str(R.SUBCLASSES[str(h.sub)].name)) if R.SUBCLASSES.has(str(h.get("sub", ""))) else ""), ", ".join(eq), ", ".join(bag) if bag.size() > 0 else "пусто", status])
	return "\n".join(lines)


func _names_rule() -> String:
	var names := []
	for n in state.heroes:
		names.append(str(state.heroes[n].name))
	return "\nПоле who и ключи options — строго имена героев: " + ", ".join(names) + "."


func _campaign_text() -> String:
	var c: Dictionary = state.campaign
	var goal := ""
	if str(c.get("goal", "")) != "":
		goal = "\nТЕКУЩАЯ ЦЕЛЬ ГРУППЫ (решили %d ходов назад): %s. Веди сюжет к ней: каждый ход герои заметно продвигаются, никаких петель и посторонних находок, которые уводят в сторону. Если герои сами не свернули — следующая сцена приближает их к цели или приводит к ней." % [int(state.turn) - int(c.get("goal_turn", state.turn)), c.goal]
	var gst := []
	for e in c.get("goal_steps", []):
		gst.append(("[x] " if e.ok else "[ ] ") + str(e.t))
	if goal != "" and gst.size() > 0:
		goal += " Пункты цели: " + "; ".join(gst) + ". Отмечай выполненные в goal.done_steps."
	for t in MapView._sanitize(state.get("map", {}))["targets"]:
		if int(t.left) > 0:
			goal += "\nПУТЬ К «%s»: ещё %d %s в дороге. Не приводи героев туда раньше: каждый ход в пути — новое событие (встреча, препятствие, находка) и новое место в поле place. Когда останется 0 — можно прибыть (place с тем же названием)." % [t.name, int(t.left), MapView._events_word(int(t.left))]
		else:
			goal += "\nПУТЬ К «%s»: герои у самой цели — если идут туда, они прибывают (place с тем же названием «%s»)." % [t.name, t.name]
	return "Кампания «%s». Мир: %s\nГлавный квест: %s\nТекущее место: %s%s\nЛетопись прошлого: %s" % [
		c.get("title", ""), c.get("world", ""), c.get("quest", ""), c.get("scene", ""), goal,
		c.get("chronicle", "") if str(c.get("chronicle", "")) != "" else "(пока пусто)"] + _journal_text()


func _recent_log(n := 16) -> String:
	var lines := []
	for e in state.log.slice(-n):
		match str(e.k):
			"gm": lines.append(("Ведущий (только для %s): " % str(state.heroes.get(str(e.to), {}).get("name", e.to)) if e.has("to") else "Ведущий: ") + str(e.t))
			"act":
				if not str(e.get("to", "")).begins_with("!"):
					lines.append("%s делает%s: %s" % [e.w, " (тайно)" if e.has("to") else "", e.t])
			"roll": lines.append("Бросок %s: %s" % [e.w, e.t])
			_: lines.append("(" + str(e.t) + ")")
	return "\n".join(lines)


func _acts_text(acts: Dictionary) -> String:
	var lines := []
	for n in acts:
		lines.append("%s: %s" % [state.heroes[n].name, acts[n]])
	return "\n".join(lines)


const NARRATE_FORMAT := """Ответь строго JSON без markdown:
{"story": "4-8 предложений", "changes": [{"who": "имя героя", "hp": 0, "gold": 0, "add": [], "remove": [], "xp": 0}], "options": {"Имя героя": ["вариант", "вариант", "вариант"]}, "place": null, "quest": "", "quests": [], "npcs": [], "chest": "", "shop": "", "combat": [], "env": [], "rest": "", "rep": [], "consequences": [], "resolved": [], "companions": [], "vote": null, "goal": "", "inspire": "", "approval": [], "secret": {}}
Поля:
- story: последствия действий каждого героя, реакция мира и персонажей (с прямой речью), новая ситуация; закончи тем, что ждёт ответа героев.
- changes: ОБЯЗАТЕЛЬНО: если в story герой получил вещь (в том числе ту, что выиграл раньше и теперь требует отдать) (выиграл, нашёл, купил у персонажа, ему подарили), добавь её в add этого героя, иначе вещи не будет в инвентаре. Золото-награда делится игрой поровну на всех, укажи общую сумму у любого героя. НИКОГДА не заменяй вещь деньгами: просят шлем — выдай шлем ("helmet"), а gold оставь 0; gold больше нуля только если в story кто-то прямо платит монетами и в story названа та же сумма (за выполненное поручение, продажу, выигрыш). За разговоры, расспросы, торг и знакомства золота НЕ давай — gold 0. Состояния: "cond": "poisoned" (отравлен), "blinded", "frightened", "prone", "stunned" — если с героем такое случилось; "cure": "poisoned" — если вылечили. Алхимические ингредиенты для add: "herb" (травы — собрал в лесу/поле, успех Природы или Выживания), "venom_sac" (ядовитая железа), "ember_dust" (огненная пыль). Не выдавай повторно то, что игра уже выдала (строки «Добыча», «забирает», «получает» в недавних событиях). Только реальные изменения вне боя: урон от ловушек и падений (hp отрицательный, 1-10), лечение (hp положительный), награды золотом, найденные или отданные вещи, опыт xp: за удачные проверки игра уже дала опыт сама, не дублируй; давай xp только за выполненное поручение или решённую загадку (50-200) и тогда КАЖДОМУ герою, который участвовал, одинаково. add — id из каталога, можно с улучшением {"id": "longsword", "plus": 1, "name": "Меч «Рассвет»"}, или сюжетная вещь ПО-РУССКИ с описанием: {"name": "Карта затонувшего рифа", "note": "что это, откуда и зачем может пригодиться, 1 фраза"}, никогда не латинский id. Сюжетные вещи в сумках героев важны: если герой их показывает, отдаёт, использует или выбрасывает — это меняет сюжет, отрази это в story и в remove. Пустой список, если ничего.
- options: по три коротких варианта (до 8 слов) для каждого героя: осторожный, смелый, неожиданный. Если герой с кем-то разговаривает или торгуется, сделай варианты репликами с проверкой: {"t": "Соврать, что мы из стражи", "check": {"name": "Обман", "ability": "ХАР", "dc": 13}} (игрок увидит проверку до выбора); для обычных действий — просто строка.
- place: {"name": "название", "type": "тип"} только если герои пришли в новое место или вернулись в известное, иначе null. Типы: village, city, tavern, forest, road, cave, dungeon, castle, ruins, swamp, mountain, lake, camp, temple, tower, field, sea, port.
- quests: ОБЯЗАТЕЛЬНО добавляй сюда каждое поручение, просьбу или работу, которую кто-то даёт героям (капитан просит починить лодку, трактирщик — найти вора), даже мелкую и побочную, а также цели, которые герои сами себе поставили вслух. Дополнительные задания и поручения. Новое: {"title": "Найти пропавшую козу", "note": "кто дал и где искать", "status": "new", "steps": ["Расспросить пастуха", "Найти следы", "Вернуть козу"], "place": {"name": "Волчий овраг", "type": "forest", "dist": 2}} (steps — 2-4 пункта; place — только если известно, где это, dist — событий в пути 1-6); выполнен пункт: {"title": то же, "status": "new", "done_steps": ["Найти следы"]}; выполнено: {"title": то же название, "status": "done"}; провалено: "failed". Пусто, если ничего не изменилось. Названия активных заданий бери из списка выше точно.
- npcs: важные персонажи, которых герои встретили впервые, узнали о них новое или чьё отношение к героям изменилось: [{"name": "Мельник Тарас", "note": "кто он, 1 фраза", "attitude": 1}]. attitude — изменение отношения от -2 до 1. Плюс 1 — только за настоящую услугу, ценный подарок или спасение, НЕ за обычный разговор, расспросы, вежливость или покупку; обычно 0; нагрубили, обманули (и раскрылось), угрожали, обокрали — минус; 0 если не изменилось. Отношение (см. «Знакомые персонажи») влияет на поведение: друзья помогают и дают скидки, враги отказывают, доносят, мстят. Пусто, если никого.
- rep: репутация у города, деревни, гильдии или фракции, если герои совершили заметный поступок: [{"name": "Деревня Верба", "change": -1, "why": "ограбили лавку"}]. change от -2 до 2. При репутации -3 и ниже стража враждебна, торговцы отказывают; при 3 и выше — почёт, помощь, скидки.
- consequences: решения, которые должны аукнуться позже (пощадили врага, обманули влиятельного человека, украли реликвию): ["Пощадили гоблина Шныря — может вернуться с подмогой или с благодарностью"]. resolved: начала тех отложенных последствий, которые ты сейчас вернул в сюжет.
- companions: если к отряду присоединился наёмник или зверь (нанят, приручён, спасён): [{"name": "Серый", "kind": "волк", "monster": "wolf", "owner": "имя героя"}]; monster — id из списка монстров по силе; ушёл: {"name": "Серый", "leave": true}. Не больше двух спутников. Добавь "about": характер и цель спутника, 1 фраза.
- approval: как спутники (не звери) отнеслись к поступкам героев сейчас: [{"who": "имя спутника", "d": 1, "why": "коротко"}], d от -2 до 2, только если поступок задел их характер или ценности; обычно пусто. Одобрение 5+ — спутник верный, -5 — уходит.
- secret: если герой действовал ТАЙНО от напарника — результат этого действия: {"Имя героя": "что он втайне узнал, взял или сделал, 1-3 предложения"}. В story тайное действие НЕ раскрывай: напарник его не видит, в story такой герой может лишь ненадолго отлучиться. Найденные втайне вещи всё равно добавь в changes. Иначе {}.
- goal: ближайшая цель группы, когда герои решили, куда идут или что делают дальше: {"t": "Доплыть до маяка на Скалистом мысу", "steps": ["Найти лодку", "Пережить бурю", "Подняться на маяк"], "place": {"name": "Маяк на Скалистом мысу", "type": "tower", "dist": 3}}. steps — 2-4 понятных пункта, что нужно сделать; place — только если героям известно, где это место (им показали на карте, объяснили дорогу, видно вдали), dist — сколько событий в пути до него (1-6, по расстоянию: соседняя деревня 1-2, через лес или горы 3-4, другой край земли 5-6); если место неизвестно — без place. Когда пункт выполнен: {"t": та же цель, "done_steps": ["Найти лодку"]}. "done" — цель достигнута; "" если ничего не изменилось. Цель — крупная задача; не подменяй её её же пунктом и не дублируй цель и её пункты в quests. Сделанное сразу отмечай в done_steps. Пока цель не достигнута, каждый ход приближай героев к ней.
- vote: если перед группой важная развилка, где герои могут не сойтись (кого спасти, чью сторону принять, куда идти), предложи голосование {"q": "Вопрос?", "opts": ["вариант 1", "вариант 2"]}; иначе null. Не чаще раза в 4-5 ходов.
- chest: короткое название, если герои открыли сундук, тайник или нашли клад (содержимое выдаст игра), иначе "".
- shop: имя торговца, если герои пришли торговать к лавке/рынку/кузнецу, иначе "". Знакомого торговца называй тем же именем.
- combat: если начинается бой, в story опиши только появление врагов, без ударов и исхода (бой отыграет игра). Если начинается бой, список врагов [{"id": "goblin", "count": 2, "name": "Гоблин-разбойник"}], id из списка монстров; можно своего: {"name": "...", "hp": 20, "ac": 13, "atk": 4, "dmg": "1d8+2", "xp": 100}. Бой — редкость: не чаще раза в 5 ходов и только когда оправдано сюжетом, большая часть игры — разговоры, путь и тайны. Сила врагов по уровню героев: на 1-2 уровне 1-4 слабых врага (25-50 опыта каждый), дальше сильнее.
- env: только вместе с combat — 1-3 предмета окружения на поле боя, которые герои могут использовать, из списка: barrel (бочка с маслом), chandelier (люстра), brazier (жаровня), rocks (шаткие камни), oil (бочонок масла), web (паутина), water (бочка или лужи воды), cliff (обрыв), high (возвышенность). Опиши их мимоходом в story. Иначе [].
- inspire: имя героя, если игрок только что ярко и в характере отыграл героя (смешно, смело, трогательно, по его предыстории), иначе "". Редко, не чаще раза в несколько ходов.
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
Сложность dc — насколько трудна сама задача (как в BG3): 5 пустяк, 10 обычное дело, 12-13 непросто, 15 трудно, 18 очень трудно, 20 и выше — подвиг для опытных героев. Большинство проверок 10-15. Не завышай: высокая сложность только для по-настоящему трудного (стражник-ветеран, древний замок, прыжок через пропасть). Насторожённый, умный или сильный противник — +2-3, ничего не подозревающий — -2-3.
Способ добиться своего определяет проверку (поле ability — характеристика, на которой кидают навык, если она не обычная):
- угроза, запугивание силой, выбивание, шантаж кулаками: Запугивание, ability "СИЛ";
- шантаж компроматом, холодная угроза словами: Запугивание (ХАР);
- обман, ложь, выдать себя за другого: Обман (ХАР); хитрая афера, подделка, ловушка в словах: Обман, ability "ИНТ";
- убеждение, просьба, торг, подкуп: Убеждение (ХАР);
- лесть, представление, развлечь толпу: Выступление;
- кража, срезать кошелёк, подменить вещь: Ловкость рук; незаметно пробраться: Скрытность;
- разбой, отнять силой, вырвать из рук: Атлетика (СИЛ); если жертва сопротивляется, dc выше;
- выиграть в карты/кости: Проницательность (МДР) или Обман, ability "ИНТ" для расчёта; спор на силу, армрестлинг: Атлетика;
- понять, врёт ли собеседник: Проницательность.
Разные способы — разные проверки, не подставляй всегда Убеждение.
Замки: взлом — Ловкость рук, добавь "tools": true (без воровских инструментов будет помеха, при сильном провале отмычки ломаются). Ловушки: заметить — Восприятие или Анализ; если герой попадает в ловушку, это спасбросок (kind "save", ЛОВ или ТЕЛ) и добавь "trap_dmg": "2d6" и при яде "cond": "poisoned" — урон игра нанесёт сама при провале.
Если герой помогает другому (в действии «помогает»), ему проверка не нужна — у напарника будет преимущество. Сложность зависит от того, насколько человек силён, умён и насторожен.
adv: 1 преимущество (герою помогают, у него отличные условия), -1 помеха (темнота, ранен, спешка), иначе 0.
Ответь строго JSON: {"checks": [{"who": "имя героя", "kind": "skill", "name": "Запугивание", "ability": "СИЛ", "dc": 13, "adv": 0, "why": "2-4 слова"}]} (ability можно опустить) или {"checks": []}.""" + _names_rule()
	var user := "%s\nГерои:\n%s\n\nНедавние события:\n%s\n\nДействия сейчас:\n%s" % [
		_campaign_text(), _heroes_text(), _recent_log(6), _acts_text(acts)]
	return [{"role": "system", "content": sys}, {"role": "user", "content": user}]


func _narrate_prompt(acts_text: String, rolls: Array, combat_result: String) -> Array:
	var sys := GM_RULES + "\n"
	if combat_result != "":
		sys += "Только что закончился бой. Опиши, чем он завершился и что герои видят после. Добычу и опыт уже выдала игра: changes оставь пустым, бой не начинай снова.\n"
	else:
		sys += "Расскажи, что произошло после действий героев. Результаты бросков уже посчитаны игрой, строго следуй им: успех — получилось, провал — не вышло или вышло с неприятностью, критический успех — блестяще с бонусом, критический провал — смешная или опасная неудача.\n Если герой добывал вещь или деньги (угрозой, шантажом, обманом, кражей, разбоем, уговорами, выигрышем) и проверка успешна — он ЭТО получает: добавь в changes.add или gold этого героя, у жертвы этого больше нет. При провале — последствия по способу: угрозы и разбой злят и зовут стражу, раскрытый обман портит отношения, пойманный вор платит или бежит.\n"
	if combat_result == "":
		var since := int(state.turn) - int(state.campaign.get("last_combat", -99))
		if since < COMBAT_GAP:
			sys += "СЕЙЧАС БОЙ НЕ НАЧИНАЙ: последний был %d ход(а) назад. combat оставь пустым, враги не появляются; двигай сюжет, разговоры, исследование.\n" % since
		else:
			sys += "Бой допустим, только если герои сами нарвались или его требует сюжет к цели; иначе — без боя.\n"
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
