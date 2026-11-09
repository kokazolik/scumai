extends SceneTree
## Бот осмысленно играет серию боёв по правилам игры и пишет журнал и статистику.
## Запуск: ALIBI_MOCK=1 godot --headless --path . -s tools/combat_sim.gd  (SIM_OUT=папка для журналов)

const R = preload("res://scripts/rules.gd")

var G
var N
var fights := [
	{"name": "Гоблины у бочек", "party": [["Воин", 3], ["Маг", 3]], "foes": [{"id": "goblin", "count": 3}, {"id": "goblin_shaman", "count": 1}], "env": ["oil", "brazier"]},
	{"name": "Бандиты на обрыве", "party": [["Плут", 3], ["Жрец", 3]], "foes": [{"id": "bandit", "count": 2}, {"id": "cultist", "count": 2}, {"id": "kobold", "count": 2}], "env": ["cliff", "high"]},
	{"name": "Волки в лесу", "party": [["Следопыт", 2], ["Бард", 2]], "foes": [{"id": "wolf", "count": 3}], "env": ["web", "rocks"]},
	{"name": "Орки у пруда", "party": [["Воин", 3], ["Маг", 3]], "foes": [{"id": "orc", "count": 3}], "env": ["water", "barrel"]},
	{"name": "Склеп скелетов", "party": [["Жрец", 3], ["Плут", 3]], "foes": [{"id": "skeleton", "count": 4}], "env": ["brazier", "chandelier"]},
	{"name": "Огр-вожак", "party": [["Воин", 3], ["Бард", 3]], "foes": [{"id": "ogre", "count": 1}, {"id": "goblin", "count": 2}], "env": ["cliff", "oil"]},
	{"name": "Пауки в пещере", "party": [["Маг", 3], ["Следопыт", 3]], "foes": [{"id": "giant_spider", "count": 2}], "env": ["web", "water"]},
	{"name": "Главарь бандитов", "party": [["Плут", 4], ["Жрец", 4]], "foes": [{"id": "bandit_captain", "count": 1}, {"id": "bandit", "count": 2}], "env": ["barrel", "high"]},
	{"name": "Гули на кладбище", "party": [["Воин", 4], ["Жрец", 4]], "foes": [{"id": "ghoul", "count": 3}], "env": ["brazier", "rocks"]},
	{"name": "Тролль у моста", "party": [["Маг", 5], ["Воин", 5]], "foes": [{"id": "troll", "count": 1}], "env": ["oil", "water", "cliff"]},
]
var fi := -1
var acted_turn := ""
var stats := {}
var out_dir := ""
var frames := 0
var fight_frames := 0
var fight_t0 := 0


func _initialize() -> void:
	G = root.get_node("Game")
	N = root.get_node("Net")
	out_dir = OS.get_environment("SIM_OUT")


var started := false


func _hero(cls: String, lvl: int, nm: String) -> Dictionary:
	var race: String = {"Воин": "Дварф", "Маг": "Эльф", "Плут": "Полурослик", "Жрец": "Человек", "Следопыт": "Эльф", "Бард": "Человек"}[cls]
	var h: Dictionary = R.new_hero(nm, race, cls, "")
	while int(h.level) < lvl:
		R.level_up(h)
	h.erase("choices")
	h.items.append({"id": "potion_heal"})
	return h


func _next_fight() -> void:
	if fi >= 0:
		_dump()
	fi += 1
	if fi >= fights.size():
		_summary()
		quit()
		return
	var f: Dictionary = fights[fi]
	G.state = G._fresh_state()
	G.state.campaign = {"setting": "тест", "insp": 1}
	G.state.heroes = {}
	var names := ["Аня", "Боря"]
	for k in 2:
		G.state.heroes[names[k]] = _hero(f.party[k][0], f.party[k][1], "%s-%s" % [names[k], f.party[k][0]])
	N.players = {1: names[0], 2: names[1]}
	G.state.log = []
	G._busy = false
	G.phase = "play"
	stats = {"acts": {}, "rounds": 0}
	fight_frames = 0
	fight_t0 = Time.get_ticks_msec()
	G._start_combat(f.foes, f.env)


func _process(_d: float) -> bool:
	frames += 1
	if not started:
		started = true
		var peer := ENetMultiplayerPeer.new()
		peer.create_server(27999, 4)
		G.multiplayer.multiplayer_peer = peer
		print("SIM host=", N.is_host())
		_next_fight()
		return false
	fight_frames += 1
	if fi >= fights.size():
		return true
	G._rolls_until = 0
	if fight_frames > 6000 and Time.get_ticks_msec() - fight_t0 > 90000:
		print("SIM stuck in fight ", fi, " phase=", G.phase, " actor=", G.combat_actor(), " busy=", G._busy)
		_next_fight()
		return false
	if G.phase != "combat" and not G.state.get("combat", {}).is_empty() == false and G.phase != "combat":
		if G.phase in ["play", "thinking"] and G.state.get("combat", {}).is_empty() and fight_frames > 5:
			if not G._busy or G.phase == "play":
				_next_fight()
		return false
	for a in G.state.get("ask", []):
		if not a.done:
			G._do_roll(str(a.who))
			return false
	if G._busy:
		return false
	var actor: String = G.combat_actor()
	if actor == "":
		return false
	var c: Dictionary = G.state.combat
	stats.rounds = int(c.round)
	N.players = {1: actor, 2: _other(actor)}
	var key := "%d_%d_%s" % [int(c.round), int(c.turn), JSON.stringify(c.get("used", {}).get(actor, {}))]
	if key == acted_turn:
		_do({"t": "end"}, actor)   # действие не прошло — заканчиваем ход
		return false
	acted_turn = key
	_do(_decide(actor), actor)
	return false


func _other(p: String) -> String:
	for n in G.state.heroes:
		if n != p:
			return n
	return ""


func _do(a: Dictionary, actor: String) -> void:
	var t := str(a.t)
	if t == "spell":
		t = "spell:" + str(a.spell)
	elif t == "env":
		t = "env:" + str(G.state.combat.env[int(a.idx)].id)
	elif t == "item":
		t = "item:" + str(G.state.heroes[actor].items[int(a.idx)].id)
	elif t == "throw":
		t = "throw:" + str(G.state.heroes[actor].items[int(a.idx)].id)
	var k := "%s %s" % [G.state.heroes[actor].cls, t]
	stats.acts[k] = int(stats.acts.get(k, 0)) + 1
	var before := []
	for e in G.state.combat.enemies:
		before.append("%s:%d%s" % [e.name, int(e.hp), "†" if e.dead else ""])
	G._cact(a)
	if OS.get_environment("SIM_DEBUG") != "":
		print("DBG ", k, " ", before)


func _idx(h: Dictionary, id: String) -> int:
	for i in h.items.size():
		if str(h.items[i].get("id", "")) == id:
			return i
	return -1


func _env(id: String) -> int:
	return G._env_find(id)


## Решение «вдумчивого игрока».
func _decide(me: String) -> Dictionary:
	var h: Dictionary = G.state.heroes[me]
	var c: Dictionary = G.state.combat
	var used: Dictionary = c.get("used", {}).get(me, {"a": false, "b": false})
	var p := _other(me)
	var ph: Dictionary = G.state.heroes[p]
	var fe: Array = G._front_enemies()
	var alive: Array = G._alive_enemies()
	var surf := str(c.get("surf", {}).get("t", ""))
	var front: bool = G.hero_pos(me) == "front"
	var hpf := float(h.hp) / float(h.max_hp)
	var boss := false
	var tgt: int = alive[0] if alive.size() > 0 else -1
	for i in alive:
		if c.enemies[i].get("boss", false) or int(c.enemies[i].max_hp) >= 50:
			boss = true
		if int(c.enemies[i].hp) < int(c.enemies[tgt].hp) and str(c.enemies[i].get("pos", "front")) == "front":
			tgt = i
	if alive.is_empty():
		return {"t": "end"}
	# ---------- бонусное действие ----------
	if not used.get("b", false):
		if hpf < 0.35 and _idx(h, "potion_heal") >= 0:
			return {"t": "item", "idx": _idx(h, "potion_heal"), "target": me}
		if h.get("second_wind", false) and hpf < 0.55:
			return {"t": "second_wind"}
		if "healing_word" in R.known_spells(h) and R.slot_for(h, "healing_word") >= 0 and (int(ph.hp) <= 0 or float(ph.hp) / float(ph.max_hp) < 0.3) and not ph.get("dead", false):
			return {"t": "spell", "spell": "healing_word", "target": p}
		if front and fe.size() > 0 and _env("cliff") >= 0:
			return {"t": "shove", "target": fe[0]}
		if front and fe.size() > 0 and surf == "fire" and not used.get("a", false):
			return {"t": "shove", "target": fe[0]}
		if G.can_dip(me) and not (h.cls in ["Маг"]) and (_env("brazier") >= 0 or surf == "fire" or boss):
			return {"t": "dip"}
		if int(h.get("inspire", 0)) > 0 and int(ph.hp) > 0 and not ph.get("inspired", false):
			return {"t": "inspire", "target": p}
		if "spiritual_weapon" in R.known_spells(h) and R.slot_for(h, "spiritual_weapon") >= 0 and not used.get("a", false) and not h.has("sw_used"):
			h.sw_used = true
			return {"t": "spell", "spell": "spiritual_weapon", "target": tgt}
		if h.cls == "Плут" and not c.get("hidden", {}).get(me, false) and not used.get("a", false):
			return {"t": "hide"}
	if used.get("a", false):
		return {"t": "end"}
	# ---------- основное действие ----------
	if int(ph.hp) <= 0 and not ph.get("dead", false):
		return {"t": "stabilize", "target": p}
	if G.insp_pool() > 0 and boss and not c.get("help", {}).get(me, false) and not (h.cls in ["Маг"]):
		G._cact({"t": "insp"})
		stats.acts["%s insp" % h.cls] = int(stats.acts.get("%s insp" % h.cls, 0)) + 1
	var known: Array = R.known_spells(h)
	var can := func(sp): return sp in known and R.slot_for(h, sp) >= 0
	# окружение
	if fe.size() >= 2 and _env("oil") >= 0 and ("fire_bolt" in known or _env("brazier") >= 0 or _env("barrel") >= 0 or _idx(h, "torch") >= 0 or _idx(ph, "torch") >= 0):
		return {"t": "env", "idx": _env("oil")}
	if fe.size() >= 2 and _env("barrel") >= 0:
		return {"t": "env", "idx": _env("barrel")}
	if surf == "oil" and _env("brazier") >= 0:
		return {"t": "env", "idx": _env("brazier"), "target": fe[0] if fe.size() > 0 else -1}
	if fe.size() >= 1 and _env("water") >= 0 and ("shocking_grasp" in known or "ray_of_frost" in known):
		return {"t": "env", "idx": _env("water")}
	if fe.size() >= 2 and _env("web") >= 0:
		return {"t": "env", "idx": _env("web")}
	if surf in ["oil", "web"] and not ("fire_bolt" in known) and _idx(h, "torch") >= 0 and fe.size() > 0:
		return {"t": "throw", "idx": _idx(h, "torch"), "target": fe[0]}
	if fe.size() > 0 and _env("chandelier") >= 0 and int(c.enemies[fe[0]].hp) > 8:
		return {"t": "env", "idx": _env("chandelier"), "target": fe[0]}
	# заклинатели
	match h.cls:
		"Маг":
			if alive.size() >= 3 and can.call("fireball"):
				return {"t": "spell", "spell": "fireball", "target": -1}
			if fe.size() >= 2 and can.call("burning_hands") and surf != "water":
				return {"t": "spell", "spell": "burning_hands", "target": -1}
			if alive.size() >= 3 and int(h.level) <= 2 and can.call("sleep"):
				return {"t": "spell", "spell": "sleep", "target": -1}
			if surf in ["oil", "web"] and fe.size() > 0:
				return {"t": "spell", "spell": "fire_bolt", "target": fe[0]}
			if surf == "water" and fe.size() > 0:
				return {"t": "spell", "spell": "shocking_grasp" if randf() < 0.5 else "ray_of_frost", "target": fe[0]}
			if boss and can.call("scorching_ray"):
				return {"t": "spell", "spell": "scorching_ray", "target": tgt}
			if can.call("magic_missile") and int(c.enemies[tgt].hp) <= 10:
				return {"t": "spell", "spell": "magic_missile", "target": tgt}
			var cant := "fire_bolt"
			for i in alive:
				if "огонь" in c.enemies[i].get("vuln", []):
					tgt = i
			return {"t": "spell", "spell": cant, "target": tgt}
		"Жрец":
			if int(c.round) == 1 and can.call("bless") and h.get("conc", {}).is_empty():
				return {"t": "spell", "spell": "bless", "target": -1}
			if float(ph.hp) / float(ph.max_hp) < 0.4 and can.call("cure_wounds"):
				return {"t": "spell", "spell": "cure_wounds", "target": p}
			if boss and can.call("hold_person") and h.get("conc", {}).is_empty():
				for i in alive:
					if not c.enemies[i].get("undead", false) and not (str(c.enemies[i].get("mid", "")) in G.BEASTS):
						return {"t": "spell", "spell": "hold_person", "target": i}
			if can.call("guiding_bolt") and int(c.enemies[tgt].hp) > 12:
				return {"t": "spell", "spell": "guiding_bolt", "target": tgt}
			for i in alive:
				if c.enemies[i].get("undead", false):
					return {"t": "spell", "spell": "sacred_flame", "target": i}
		"Бард":
			if boss and can.call("hold_person") and h.get("conc", {}).is_empty():
				for i in alive:
					if not c.enemies[i].get("undead", false) and not (str(c.enemies[i].get("mid", "")) in G.BEASTS):
						return {"t": "spell", "spell": "hold_person", "target": i}
			if fe.size() >= 2 and can.call("thunderwave"):
				return {"t": "spell", "spell": "thunderwave", "target": -1}
			if alive.size() >= 3 and can.call("sleep") and int(h.level) <= 2:
				return {"t": "spell", "spell": "sleep", "target": -1}
	# ослаб впереди, а сам не танк — отступить
	if front and hpf < 0.3 and h.cls in ["Маг", "Бард", "Следопыт", "Плут"] and fe.size() > 0:
		return {"t": "disengage"}
	return {"t": "attack", "target": tgt}


func _dump() -> void:
	var f: Dictionary = fights[fi]
	var lines := []
	for e in G.state.log:
		if str(e.k) in ["cbt", "sys", "roll"]:
			lines.append(str(e.t))
	var res := "?"
	for e in G.state.log:
		var t := str(e.t)
		if t.begins_with("Победа"):
			res = "победа"
		elif t.begins_with("Поражение"):
			res = "поражение"
		elif t.begins_with("Герои сбежали"):
			res = "бегство"
	var hp := []
	for n in G.state.heroes:
		hp.append("%s %d/%d" % [G.state.heroes[n].name, int(G.state.heroes[n].hp), int(G.state.heroes[n].max_hp)])
	var head := "=== Бой %d: %s · %s · раундов %d · %s" % [fi + 1, f.name, res, int(stats.rounds), ", ".join(hp)]
	print(head)
	print("ACTS ", JSON.stringify(stats.acts))
	if out_dir != "":
		var fa := FileAccess.open("%s/fight_%02d.txt" % [out_dir, fi + 1], FileAccess.WRITE)
		fa.store_string(head + "\n" + "ACTS " + JSON.stringify(stats.acts) + "\n\n" + "\n".join(lines))


func _summary() -> void:
	print("SIM DONE")
