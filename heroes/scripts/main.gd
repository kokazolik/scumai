extends Control
## Интерфейс «Хроник двоих». Экраны строятся кодом; во время игры три вкладки: История, Герой, Карта.
## Части экрана перестраиваются только когда меняется их «ключ», чтобы не сбивать набранный текст.

const R = preload("res://scripts/rules.gd")
const MapView = preload("res://scripts/map_view.gd")
const DiceView = preload("res://scripts/dice_view.gd")
const Icons = preload("res://scripts/icons.gd")

const C_BG1 := Color("161827")
const C_BG2 := Color("2a1f3d")
const C_CARD := Color("23263a")
const C_CARD2 := Color("2e3250")
const C_INK := Color("f3f1ea")
const C_MUTED := Color("a3a6c0")
const C_ACCENT := Color("ffc145")
const C_RED := Color("ff5a5f")
const C_GREEN := Color("3ddc97")
const C_BLUE := Color("5b8cff")
const C_PURPLE := Color("a77bff")

const NAMES := ["Странник", "Искра", "Ворон", "Лис", "Сова", "Кремень", "Ясень", "Волчок", "Пламя", "Тень"]

var font_bold: Font
var font_black: Font
var root_margin: MarginContainer
var content: VBoxContainer
var overlay: Control
var dice: Control
var toast: Label
var screen := ""
var refs := {}
var local_screen := "menu"
var error_text := ""
var _dots_t := 0.0

# игровой экран
var tab := "story"
var _bottom_key := ""
var _overlay_key := ""
var _log_n := -1
var _target := -1
var _combat_menu := ""     # "" / spell / item / inspire
var _draft := ""
# создание героя
var _race := "Человек"
var _cls := "Воин"
# лобби
var _setting := 0
var _confirm_new := false


func _ready() -> void:
	get_tree().set_quit_on_go_back(false)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_load_fonts()
	theme = _make_theme()
	add_child(_make_bg())
	root_margin = MarginContainer.new()
	root_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "bottom"]:
		root_margin.add_theme_constant_override("margin_" + side, 18)
	root_margin.add_theme_constant_override("margin_top", 40)
	add_child(root_margin)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	root_margin.add_child(content)

	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	dice = DiceView.new()
	dice.set_anchors_preset(Control.PRESET_FULL_RECT)
	dice.visible = false
	add_child(dice)

	toast = _label("", 24, C_INK)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.position = Vector2(40, 1100)
	toast.size = Vector2(640, 60)
	toast.modulate.a = 0.0
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)

	Net.my_name = _load_name()
	Game.state_changed.connect(_refresh)
	Game.rolls_shown.connect(func(rolls): dice.play(rolls))
	Net.players_changed.connect(_refresh)
	Net.rooms_changed.connect(_refresh)
	Net.joined.connect(_refresh)
	Net.left.connect(func(reason):
		error_text = reason
		local_screen = "menu"
		_refresh())
	_refresh()
	_autotest_setup()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if not Net.is_online() and local_screen == "search":
			Net.stop_search()
			local_screen = "menu"
			_refresh()
		elif screen == "game" and tab != "story":
			tab = "story"
			screen = ""
			_refresh()


# ---------- навигация ----------

func _screen_key() -> String:
	if not Net.is_online():
		return local_screen
	if not Net.is_host() and not Net.players.has(Net.my_id()):
		return "connecting"
	var p := Game.phase
	if p in ["play", "thinking", "combat"]:
		return "game"
	if p == "create":
		return "create_done" if not Game.my_hero().is_empty() else "create"
	return p


func _refresh() -> void:
	var k := _screen_key()
	if k != screen:
		screen = k
		_build()
	_update()


func _clear() -> void:
	for c in content.get_children():
		c.queue_free()
	refs = {}
	_bottom_key = ""
	_log_n = -1


func _build() -> void:
	_clear()
	match screen:
		"menu": _build_menu()
		"search": _build_search()
		"connecting": _build_wait("Подключаемся")
		"lobby": _build_lobby()
		"create": _build_create()
		"create_done": _build_create_done()
		"world": _build_wait("Ведущий создаёт мир")
		"game": _build_game()


func _leave() -> void:
	Net.stop()
	Net.stop_search()
	Game.reset_local()
	local_screen = "menu"
	_refresh()


# ---------- меню и поиск ----------

func _build_menu() -> void:
	content.add_child(_spacer(30))
	var t := _label("ХРОНИКИ\nДВОИХ", 84, C_ACCENT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(t)
	var st := _label("Ролевая игра на двоих. Ведущий — нейронка", 26, C_MUTED)
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(st)
	content.add_child(_spacer(14))
	var card := _card()
	card.add_child(_label("Твоя кличка (по ней игра узнаёт твоего героя)", 22, C_MUTED))
	var name_edit := LineEdit.new()
	name_edit.text = Net.my_name
	name_edit.max_length = 16
	name_edit.text_changed.connect(func(s):
		Net.my_name = s.strip_edges() if s.strip_edges() != "" else "Игрок"
		_save_name())
	card.add_child(name_edit)
	content.add_child(card.get_parent())
	content.add_child(_button("Создать комнату", C_ACCENT, _on_host))
	content.add_child(_button("Найти комнату", C_BLUE, func():
		error_text = ""
		local_screen = "search"
		Net.start_search()
		_refresh()))
	var key_btn := _button("", C_CARD2, _paste_key)
	refs.key_btn = key_btn
	content.add_child(key_btn)
	var err := _label("", 24, C_RED)
	refs.err = err
	content.add_child(err)
	content.add_child(_label("Один из вас создаёт комнату, второй находит её. Телефоны должны быть в одной Wi-Fi сети "
		+ "(или второй подключён к точке доступа первого). Ключ ИИ нужен только тому, кто создаёт комнату: "
		+ "на его телефоне хранится и вся кампания.", 22, C_MUTED))


func _build_search() -> void:
	content.add_child(_title("Комнаты рядом"))
	var card := _card()
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	card.add_child(list)
	refs.rooms = list
	refs.rooms_sig = "-"
	content.add_child(card.get_parent())
	var c2 := _card()
	c2.add_child(_label("Не видно комнаты? Проверь, что телефоны в одной сети, или введи IP, который показан у хоста:", 22, C_MUTED))
	var row := HBoxContainer.new()
	var ip := LineEdit.new()
	ip.placeholder_text = "192.168.0.10"
	ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	row.add_child(ip)
	row.add_child(_small_button("Войти", C_BLUE, func(): _join(ip.text)))
	c2.add_child(row)
	content.add_child(c2.get_parent())
	var err := _label("", 24, C_RED)
	refs.err = err
	content.add_child(err)
	content.add_child(_expander())
	content.add_child(_button("Назад", C_CARD2, func():
		Net.stop_search()
		local_screen = "menu"
		_refresh()))


func _build_wait(text: String) -> void:
	content.add_child(_expander())
	var l := _label(text, 40, C_INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refs.dots = l
	refs.dots_text = text
	content.add_child(l)
	content.add_child(_expander())
	content.add_child(_button("Выйти", C_CARD2, _leave))


# ---------- лобби ----------

func _build_lobby() -> void:
	content.add_child(_title("Комната"))
	if Net.is_host():
		var ips := Net.local_ips()
		content.add_child(_label("IP для ручного входа: " + (", ".join(ips) if ips.size() > 0 else "не найден (нет Wi-Fi?)"), 22, C_MUTED))
	var card := _card()
	card.add_child(_label("Отряд", 22, C_MUTED))
	var pl := _label("", 30, C_INK)
	refs.players = pl
	card.add_child(pl)
	content.add_child(card.get_parent())
	var err := _label("", 24, C_RED)
	refs.err = err
	content.add_child(err)
	if not Net.is_host():
		content.add_child(_expander())
		var w := _label("Хост выбирает мир. Сейчас начнём!", 28, C_MUTED)
		w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		content.add_child(w)
		content.add_child(_expander())
		content.add_child(_button("Выйти", C_CARD2, _leave))
		return
	var scroll := _scroll()
	var inner: VBoxContainer = scroll.get_child(0)
	var info := str(Game.state.get("save_info", ""))
	if info != "":
		var cc := _card(C_CARD2)
		cc.add_child(_label("Сохранённая кампания", 22, C_MUTED))
		cc.add_child(_label(info, 26, C_INK))
		cc.add_child(_button("Продолжить", C_GREEN, Game.continue_campaign))
		inner.add_child(cc.get_parent())
	var nc := _card()
	nc.add_child(_label("Новая кампания: выбери мир", 24, C_MUTED))
	for i in Game.SETTINGS.size():
		var b := _wrap_button(Game.SETTINGS[i], C_PURPLE if i == _setting else C_CARD2, func():
			_setting = i
			screen = ""
			_refresh(), 23, 80)
		nc.add_child(b)
	nc.add_child(_label("Пожелания ведущему (необязательно)", 22, C_MUTED))
	var wish := LineEdit.new()
	wish.placeholder_text = "побольше юмора, загадки, дракон…"
	wish.text = str(refs.get("wish_text", ""))
	nc.add_child(wish)
	var start := _button("", C_ACCENT, func():
		if not LLM.has_key():
			_paste_key()
			return
		if info != "" and not _confirm_new:
			_confirm_new = true
			_toast("Новая кампания сотрёт сохранение. Нажми ещё раз")
			return
		_confirm_new = false
		Game.new_campaign(Game.SETTINGS[_setting], wish.text))
	refs.start = start
	nc.add_child(start)
	inner.add_child(nc.get_parent())
	content.add_child(scroll)
	content.add_child(_button("Выйти", C_CARD2, _leave))


# ---------- создание героя ----------

func _build_create() -> void:
	content.add_child(_title("Твой герой"))
	var scroll := _scroll()
	var inner: VBoxContainer = scroll.get_child(0)
	var err := _label("", 24, C_RED)
	refs.err = err
	inner.add_child(err)
	var c1 := _card()
	c1.add_child(_label("Имя героя", 22, C_MUTED))
	var hn := LineEdit.new()
	hn.max_length = 20
	hn.placeholder_text = "Например, Мирослава"
	hn.text = str(refs.get("hn", ""))
	c1.add_child(hn)
	inner.add_child(c1.get_parent())

	var c2 := _card()
	c2.add_child(_label("Раса", 22, C_MUTED))
	var g := GridContainer.new()
	g.columns = 2
	for r in R.RACES:
		var b := _with_icon(_button(r, C_PURPLE if r == _race else C_CARD2, func():
			_race = r
			_rebuild_keep({"hn": hn.text, "about": refs.about.text})), Icons.for_race(r))
		b.custom_minimum_size = Vector2(0, 70)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(b)
	c2.add_child(g)
	c2.add_child(_label(str(R.RACES[_race].desc), 22, C_INK))
	inner.add_child(c2.get_parent())

	var c3 := _card()
	c3.add_child(_label("Класс", 22, C_MUTED))
	var g2 := GridContainer.new()
	g2.columns = 2
	for c in R.CLASSES:
		var b := _with_icon(_button(c, C_ACCENT if c == _cls else C_CARD2, func():
			_cls = c
			_rebuild_keep({"hn": hn.text, "about": refs.about.text})), Icons.for_class(c))
		b.custom_minimum_size = Vector2(0, 70)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g2.add_child(b)
	c3.add_child(g2)
	var cd: Dictionary = R.CLASSES[_cls]
	c3.add_child(_label("%s. %s." % [cd.desc, cd.features], 22, C_INK))
	inner.add_child(c3.get_parent())

	var preview := R.new_hero("", _race, _cls, "")
	var c4 := _card(C_CARD2)
	c4.add_child(_label("Характеристики", 22, C_MUTED))
	var sc := []
	for a in R.AB:
		var v := R.score(preview, a)
		sc.append("%s %d (%+d)" % [a, v, R.mod(v)])
	c4.add_child(_label("   ".join(sc), 24, C_INK))
	var gear := []
	for s in preview.equip:
		gear.append(R.item_name(preview.equip[s]))
	for it in preview.items:
		gear.append(R.item_name(it))
	c4.add_child(_label("Хиты %d, КД %d. Навыки: %s.\nСнаряжение: %s." % [preview.max_hp, R.ac(preview), ", ".join(preview.skills), ", ".join(gear)], 22, C_INK))
	inner.add_child(c4.get_parent())

	var c5 := _card()
	c5.add_child(_label("Пара слов о герое (характер, прошлое)", 22, C_MUTED))
	var about := LineEdit.new()
	about.max_length = 120
	about.placeholder_text = "Сбежала из храма, обожает яблоки"
	about.text = str(refs.get("about_text", ""))
	c5.add_child(about)
	refs.about = about
	inner.add_child(c5.get_parent())
	content.add_child(scroll)
	content.add_child(_button("Готов", C_GREEN, func():
		Game.submit_hero(hn.text if hn.text.strip_edges() != "" else Net.my_name, _race, _cls, about.text)))


func _rebuild_keep(vals: Dictionary) -> void:
	_clear()
	refs.hn = vals.get("hn", "")
	refs.about_text = vals.get("about", "")
	_build_create()
	_update()


func _build_create_done() -> void:
	content.add_child(_title("Герой готов"))
	content.add_child(_hero_card(Game.my_hero()))
	content.add_child(_expander())
	var l := _label("Ждём напарника", 30, C_MUTED)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refs.dots = l
	refs.dots_text = "Ждём напарника"
	content.add_child(l)
	var err := _label("", 24, C_RED)
	refs.err = err
	content.add_child(err)
	if Net.is_host():
		var rb := _small_wide_button("Повторить", C_ACCENT, Game.retry_world)
		refs.retry = rb
		content.add_child(rb)
	content.add_child(_expander())
	content.add_child(_button("Выйти", C_CARD2, _leave))


func _hero_card(h: Dictionary) -> Control:
	var c := _card(C_CARD2)
	if h.is_empty():
		return c.get_parent()
	c.add_child(_label(str(h.name), 36, C_ACCENT))
	c.add_child(_label("%s %s, %d уровень" % [h.race, h.cls, int(h.level)], 24, C_INK))
	c.add_child(_label("Хиты %d/%d · КД %d · Золото %d" % [h.hp, h.max_hp, R.ac(h), h.gold], 24, C_INK))
	return c.get_parent()


# ---------- игровой экран ----------

func _build_game() -> void:
	# верхняя полоса героя
	var top := HBoxContainer.new()
	var mh := Game.my_hero()
	if not mh.is_empty():
		top.add_child(_icon_rect(Icons.for_class(str(mh.cls)), 52))
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hl := _label("", 26, C_INK)
	refs.hero_line = hl
	info.add_child(hl)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 18)
	bar.add_theme_stylebox_override("background", _box(C_CARD, 9, 0))
	bar.add_theme_stylebox_override("fill", _box(C_GREEN, 9, 0))
	refs.hp_bar = bar
	info.add_child(bar)
	top.add_child(info)
	content.add_child(top)
	# вкладки
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	for t in [["story", "История", "ui_story"], ["sheet", "Герой", "ui_hero"], ["map", "Карта", "ui_map"]]:
		var b := _with_icon(_button(t[1], C_ACCENT if tab == t[0] else C_CARD2, func():
			tab = t[0]
			screen = ""
			_refresh()), Icons.tex(t[2]), 30)
		b.custom_minimum_size = Vector2(0, 64)
		b.add_theme_font_size_override("font_size", 24)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tabs.add_child(b)
	content.add_child(tabs)
	match tab:
		"story": _build_story_tab()
		"sheet":
			var scroll := _scroll()
			refs.sheet = scroll.get_child(0)
			refs.sheet_key = ""
			content.add_child(scroll)
		"map":
			var mv := MapView.new()
			mv.size_flags_vertical = Control.SIZE_EXPAND_FILL
			mv.clip_contents = true
			refs.map = mv
			content.add_child(mv)
			var q := _label("", 22, C_MUTED)
			refs.quest = q
			content.add_child(q)


func _build_story_tab() -> void:
	var cb := VBoxContainer.new()
	refs.combat_box = cb
	refs.combat_key = ""
	content.add_child(cb)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var logv := VBoxContainer.new()
	logv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	logv.add_theme_constant_override("separation", 10)
	scroll.add_child(logv)
	content.add_child(scroll)
	refs.log = logv
	refs.log_scroll = scroll
	var bottom := VBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	content.add_child(bottom)
	refs.bottom = bottom


func _update() -> void:
	if refs.has("key_btn"):
		refs.key_btn.text = "Ключ ИИ: есть ✔" if LLM.has_key() else "Ключ ИИ: вставить из буфера"
	if refs.has("err"):
		var e := error_text
		if Net.is_online() and str(Game.state.get("error", "")) != "":
			e = str(Game.state.error)
		refs.err.text = e
		refs.err.visible = e != ""
	if refs.has("rooms"):
		_update_rooms()
	if refs.has("players"):
		var names := []
		for id in Net.players:
			var pn := str(Net.players[id])
			names.append(("⭐ " if id == 1 else "• ") + pn + ("  (ты)" if id == Net.my_id() else ""))
		refs.players.text = "\n".join(names)
	if refs.has("retry"):
		refs.retry.visible = str(Game.state.get("error", "")) != ""
	if refs.has("start"):
		refs.start.text = ("Начать (%d в отряде)" % Net.players.size()) if LLM.has_key() else "Нужен ключ ИИ: вставить"
	if screen == "game":
		_update_game()
	_update_overlay()


func _update_game() -> void:
	var h := Game.my_hero()
	if refs.has("hero_line"):
		if h.is_empty():
			refs.hero_line.text = "Ты зритель"
		else:
			refs.hero_line.text = "%s · %s %d · КД %d · %d зол. · Хиты %d/%d" % [h.name, h.cls, int(h.level), R.ac(h), int(h.gold), int(h.hp), int(h.max_hp)]
			refs.hp_bar.max_value = int(h.max_hp)
			refs.hp_bar.value = int(h.hp)
			var frac := float(h.hp) / maxf(1.0, float(h.max_hp))
			refs.hp_bar.add_theme_stylebox_override("fill", _box(C_GREEN if frac > 0.5 else (C_ACCENT if frac > 0.25 else C_RED), 9, 0))
	if refs.has("log"):
		_update_log()
		_update_combat_box()
		_update_bottom()
	if refs.has("sheet"):
		var key := JSON.stringify(h) + Game.phase + str(Game.state.shop.is_empty()) + JSON.stringify(Game.state.combat.get("turn", -1))
		if key != refs.sheet_key:
			refs.sheet_key = key
			_build_sheet(refs.sheet)
	if refs.has("map"):
		var here := []
		for n in Game.state.heroes:
			here.append(str(Game.state.heroes[n].name))
		refs.map.set_map(Game.state.map, here)
		var c: Dictionary = Game.state.campaign
		refs.quest.text = "Цель: %s" % c.get("quest", "")


func _update_log() -> void:
	var lg: Array = Game.state.log
	if lg.size() == _log_n:
		return
	var logv: VBoxContainer = refs.log
	if _log_n < 0 or lg.size() < _log_n:
		for c in logv.get_children():
			c.queue_free()
		_log_n = maxi(0, lg.size() - 60)
		var c0: Dictionary = Game.state.campaign
		if str(c0.get("title", "")) != "":
			var head := _label("«%s»" % c0.title, 34, C_ACCENT)
			head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			logv.add_child(head)
	for i in range(_log_n, lg.size()):
		logv.add_child(_log_entry(lg[i]))
	_log_n = lg.size()
	_scroll_down(refs.log_scroll)


func _scroll_down(sc: ScrollContainer) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(sc):
		sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)


func _log_entry(e: Dictionary) -> Control:
	match str(e.k):
		"gm":
			var c := _card(C_CARD)
			c.add_child(_label(str(e.t), 26, C_INK))
			return c.get_parent()
		"act":
			var l := _rich("[color=#%s]%s:[/color] %s" % [C_ACCENT.to_html(false), _esc(e.w), _esc(e.t)], 24)
			return l
		"roll":
			return _label("🎲 " + str(e.t), 21, C_BLUE.lightened(0.3))
		"cbt":
			return _label("⚔ " + str(e.t), 21, Color("e7c9b0"))
		"loot":
			return _label("💰 " + str(e.t), 21, C_ACCENT)
		"lvl":
			return _label("⭐ " + str(e.t), 24, C_ACCENT)
	return _label(str(e.t), 21, C_MUTED)


func _update_combat_box() -> void:
	var c: Dictionary = Game.state.combat
	var key := JSON.stringify(c)
	if key == refs.combat_key:
		return
	refs.combat_key = key
	var box: VBoxContainer = refs.combat_box
	for ch in box.get_children():
		ch.queue_free()
	if c.is_empty() or Game.phase != "combat":
		return
	var card := _card(Color("2a1f2a"))
	var order := []
	for i in c.order.size():
		var o: Dictionary = c.order[i]
		var nm := ""
		var dead := false
		if o.k == "h":
			var hh: Dictionary = Game.state.heroes.get(str(o.id), {})
			nm = str(hh.get("name", "?"))
			dead = int(hh.get("hp", 0)) <= 0
		else:
			var en: Dictionary = c.enemies[int(o.id)]
			nm = str(en.name)
			dead = en.dead
		if dead and o.k == "e":
			continue
		var s := _esc(nm)
		if i == int(c.turn):
			s = "[color=#%s]▶ %s[/color]" % [C_ACCENT.to_html(false), s]
		elif dead:
			s = "[color=#777777]%s[/color]" % s
		order.append(s)
	card.add_child(_rich("Раунд %d: %s" % [int(c.round), " · ".join(order)], 21))
	var alive := []
	for i in c.enemies.size():
		if not c.enemies[i].dead:
			alive.append(i)
	if _target not in alive and alive.size() > 0:
		_target = alive[0]
	var my_turn := Game.combat_actor() == Game.my_pname()
	for i in alive:
		var en: Dictionary = c.enemies[i]
		var row := HBoxContainer.new()
		var b := Button.new()
		b.text = ("🎯 " if i == _target and my_turn else "") + "%s%s  КД %d" % [en.name, " 💤" if en.asleep else "", int(en.ac)]
		b.icon = Icons.for_monster(str(en.get("base_name", en.name)))
		b.add_theme_constant_override("icon_max_width", 36)
		b.add_theme_color_override("icon_normal_color", Color("ffb3a8"))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 22)
		b.add_theme_stylebox_override("normal", _box(C_RED.darkened(0.55) if i == _target and my_turn else C_CARD, 12, 10))
		b.add_theme_stylebox_override("hover", _box(C_RED.darkened(0.5), 12, 10))
		b.add_theme_stylebox_override("pressed", _box(C_RED.darkened(0.4), 12, 10))
		b.pressed.connect(func():
			_target = i
			refs.combat_key = ""
			_update_combat_box())
		row.add_child(b)
		var pb := ProgressBar.new()
		pb.custom_minimum_size = Vector2(150, 16)
		pb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pb.max_value = int(en.max_hp)
		pb.value = int(en.hp)
		pb.show_percentage = false
		pb.add_theme_stylebox_override("background", _box(C_CARD2, 8, 0))
		pb.add_theme_stylebox_override("fill", _box(C_RED, 8, 0))
		row.add_child(pb)
		card.add_child(row)
	box.add_child(card.get_parent())


func _bottom_mode() -> String:
	var me := Game.my_pname()
	var h := Game.my_hero()
	var asks: Array = Game.state.get("ask", [])
	if asks.size() > 0:
		var sig := "ask"
		for a in asks:
			sig += "%s%s" % [a.who, a.done]
		return sig
	match Game.phase:
		"thinking", "roll":
			return "thinking"
		"combat":
			if Game.state.combat.get("wait", false):
				return "thinking"
			if Game.combat_actor() == me and not h.is_empty() and int(h.hp) > 0:
				return "myturn%d_%d_%s_%d_%d" % [int(Game.state.combat.round), int(Game.state.combat.turn), _combat_menu, (h.slots as Array).hash(), h.items.size()]
			return "cwait" + Game.combat_actor()
		"play":
			if h.is_empty():
				return "spectator"
			if me in Game.state.pending:
				return "waiting"
			return "input" + JSON.stringify(Game.state.options.get(me, []))
	return "other"


func _update_bottom() -> void:
	var mode := _bottom_mode()
	var waiting_label = refs.get("wait_label")
	if mode == _bottom_key:
		if waiting_label and is_instance_valid(waiting_label):
			waiting_label.text = _wait_text()
		return
	var old_input = refs.get("action_input")
	if old_input and is_instance_valid(old_input):
		_draft = old_input.text
	_bottom_key = mode
	refs.erase("action_input")
	refs.erase("wait_label")
	var b: VBoxContainer = refs.bottom
	for c in b.get_children():
		c.queue_free()
	if mode == "thinking":
		var l := _label("Ведущий думает", 28, C_MUTED)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		refs.dots = l
		refs.dots_text = "Ведущий думает"
		b.add_child(l)
		return
	refs.erase("dots")
	if mode.begins_with("ask"):
		_build_ask(b)
		return
	if mode.begins_with("myturn"):
		_build_turn_menu(b)
		return
	if mode.begins_with("cwait"):
		var who := Game.combat_actor()
		var nm := str(Game.hero_of(who).get("name", "")) if who != "" else "враги"
		var l := _label("Ход: %s" % nm, 26, C_MUTED)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_child(l)
		return
	if mode == "spectator":
		b.add_child(_label("У тебя пока нет героя", 24, C_MUTED))
		return
	if mode == "waiting":
		var l := _label(_wait_text(), 26, C_GREEN)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		refs.wait_label = l
		b.add_child(l)
		b.add_child(_small_wide_button("Изменить действие", C_CARD2, Game.cancel_action))
		return
	# ввод действия
	var opts: Array = Game.state.options.get(Game.my_pname(), [])
	var input := TextEdit.new()
	input.placeholder_text = "Что делает %s?" % Game.my_hero().get("name", "твой герой")
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input.custom_minimum_size = Vector2(0, 100)
	input.text = _draft
	refs.action_input = input
	for o in opts:
		var ob := _wrap_button("› " + str(o), C_CARD, func(): input.text = str(o), 21, 60, C_ACCENT)
		b.add_child(ob)
	b.add_child(input)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var go := _button("Действовать", C_ACCENT, func():
		_draft = ""
		Game.submit_action(input.text)
		DisplayServer.virtual_keyboard_hide())
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.custom_minimum_size.y = 80
	row.add_child(go)
	b.add_child(row)


func _build_ask(b: VBoxContainer) -> void:
	for a in Game.state.ask:
		var c := _card(Color("2b2547"))
		var adv := ""
		if int(a.adv) > 0:
			adv = " · с преимуществом"
		elif int(a.adv) < 0:
			adv = " · с помехой"
		c.add_child(_label("Проверка: %s — %s" % [a.hero, a.label], 24, C_ACCENT))
		c.add_child(_label("Сложность %d · бонус %+d%s%s" % [int(a.dc), int(a.bonus), adv, (" · " + str(a.why)) if str(a.why) != "" else ""], 22, C_INK))
		if a.done:
			c.add_child(_label("Брошено", 22, C_GREEN))
		elif str(a.who) == Game.my_pname():
			var rb := _button("🎲 Бросить к20", C_ACCENT, func():
				Game.roll_now())
			c.add_child(rb)
		else:
			c.add_child(_label("Ждём, когда %s бросит кубик" % a.hero, 22, C_MUTED))
		b.add_child(c.get_parent())


func _wait_text() -> String:
	var missing := []
	for id in Net.players:
		var pn := str(Net.players[id])
		if Game.state.heroes.has(pn) and not (pn in Game.state.pending):
			missing.append(str(Game.state.heroes[pn].name))
	return "Ждём: " + ", ".join(missing) if missing.size() > 0 else "Ведущий думает…"


func _build_turn_menu(b: VBoxContainer) -> void:
	var h := Game.my_hero()
	var me := Game.my_pname()
	if _combat_menu == "spell":
		b.add_child(_label("Заклинания · ячейки: " + _slots_text(h), 22, C_MUTED))
		for sid in R.known_spells(h):
			var sp: Dictionary = R.SPELLS[sid]
			var slot := R.slot_for(h, sid)
			var bt := _menu_button("%s%s — %s" % [sp.name, "" if int(sp.lvl) == 0 else " (%d ур.)" % int(sp.lvl), sp.desc], C_PURPLE, func():
				var target = _target
				if sp.kind in ["heal", "buff"]:
					target = _heal_target(sp)
				_combat_menu = ""
				Game.combat_action({"t": "spell", "spell": sid, "target": target}))
			bt.disabled = slot < 0
			b.add_child(bt)
		b.add_child(_small_wide_button("Назад", C_CARD2, func():
			_combat_menu = ""
			_bottom_key = ""
			_update_bottom()))
		return
	if _combat_menu == "item":
		var any := false
		for i in h.items.size():
			var d := R.item_def(h.items[i])
			if d.type in ["potion", "scroll"]:
				any = true
				var idx: int = i
				b.add_child(_menu_button("%s — %s" % [R.item_name(h.items[i]), R.item_desc(h.items[i])], C_GREEN.darkened(0.3), func():
					_combat_menu = ""
					Game.combat_action({"t": "item", "idx": idx, "target": _target if d.type == "scroll" and R.SPELLS[str(d.spell)].kind != "heal" else me})))
				var partner := _partner()
				if d.type == "potion" and partner != "":
					b.add_child(_menu_button("   › напоить %s" % Game.hero_of(partner).get("name", ""), C_GREEN.darkened(0.45), func():
						_combat_menu = ""
						Game.combat_action({"t": "item", "idx": idx, "target": partner})))
		if not any:
			b.add_child(_label("Нет зелий и свитков", 22, C_MUTED))
		b.add_child(_small_wide_button("Назад", C_CARD2, func():
			_combat_menu = ""
			_bottom_key = ""
			_update_bottom()))
		return
	var ai := R.attack_info(h)
	var l := _label("Твой ход! Цель выбирается в списке врагов.", 22, C_ACCENT)
	b.add_child(l)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 8)
	var acts := [["%s (%+d, %s%+d)" % [ai.name, ai.atk, R.dice_ru(ai.dice), ai.bonus], C_RED, func(): Game.combat_action({"t": "attack", "target": _target}), "act_ranged" if ai.ranged else "act_attack"]]
	if R.known_spells(h).size() > 0:
		acts.append(["Заклинание", C_PURPLE, func():
			_combat_menu = "spell"
			_bottom_key = ""
			_update_bottom(), "act_spell"])
	acts.append(["Предмет", C_GREEN.darkened(0.3), func():
		_combat_menu = "item"
		_bottom_key = ""
		_update_bottom(), "act_item"])
	acts.append(["Уклонение", C_BLUE, func(): Game.combat_action({"t": "dodge"}), "act_dodge"])
	if h.get("second_wind", false):
		acts.append(["Второе дыхание", C_GREEN.darkened(0.3), func(): Game.combat_action({"t": "second_wind"}), "act_second_wind"])
	if int(h.get("inspire", 0)) > 0:
		var partner := _partner()
		if partner != "":
			acts.append(["Вдохновить (%d)" % int(h.inspire), C_ACCENT.darkened(0.3), func(): Game.combat_action({"t": "inspire", "target": partner}), "act_inspire"])
	acts.append(["Бежать", C_CARD2, func(): Game.combat_action({"t": "flee"}), "act_flee"])
	for a in acts:
		var bt := _with_icon(_button(a[0], a[1], a[2]), Icons.tex(a[3]), 34)
		bt.custom_minimum_size = Vector2(0, 72)
		bt.add_theme_font_size_override("font_size", 22)
		bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(bt)
	b.add_child(g)
	var row := HBoxContainer.new()
	var free := LineEdit.new()
	free.placeholder_text = "Своё действие: опрокинуть стол…"
	free.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(free)
	row.add_child(_small_button("▶", C_ACCENT, func():
		if free.text.strip_edges() != "":
			Game.combat_action({"t": "free", "text": free.text})))
	b.add_child(row)


func _heal_target(sp: Dictionary):
	# лечим того, кому хуже
	var best := Game.my_pname()
	var worst := 2.0
	for n in Game.state.heroes:
		var hh: Dictionary = Game.state.heroes[n]
		var f := float(hh.hp) / maxf(1.0, float(hh.max_hp))
		if f < worst and not hh.get("dead", false):
			worst = f
			best = n
	return best


func _partner() -> String:
	for n in Game.state.heroes:
		if n != Game.my_pname():
			return n
	return ""


func _slots_text(h: Dictionary) -> String:
	var parts := []
	for i in (h.slots_max as Array).size():
		parts.append("%d ур. %d/%d" % [i + 1, int(h.slots[i]), int(h.slots_max[i])])
	return ", ".join(parts) if parts.size() > 0 else "нет"


# ---------- лист героя ----------

func _build_sheet(v: VBoxContainer) -> void:
	for c in v.get_children():
		c.queue_free()
	var h := Game.my_hero()
	if h.is_empty():
		v.add_child(_label("Нет героя", 26, C_MUTED))
		return
	var in_combat := Game.phase == "combat"
	var my_turn := Game.combat_actor() == Game.my_pname()
	var can_manage := not in_combat or my_turn
	var head := _card(C_CARD2)
	head.add_child(_label(str(h.name), 40, C_ACCENT))
	head.add_child(_label("%s %s, %d уровень · опыт %d/%d" % [h.race, h.cls, int(h.level), int(h.xp), R.xp_next(h)], 24, C_INK))
	head.add_child(_label("Хиты %d/%d · КД %d · Мастерство +%d · Золото %d · Кости хитов %d" % [h.hp, h.max_hp, R.ac(h), R.prof(int(h.level)), h.gold, h.hd_left], 22, C_INK))
	if str(h.about) != "":
		head.add_child(_label(str(h.about), 22, C_MUTED))
	v.add_child(head.get_parent())

	var ab := _card()
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 10)
	for a in R.AB:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var prof_save: bool = a in R.CLASSES[h.cls].saves
		var s1 := _label("%s %d" % [a, R.score(h, a)], 26, C_ACCENT)
		s1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(s1)
		var s2 := _label("мод %+d · спас %+d%s" % [R.amod(h, a), R.save_bonus(h, a), "•" if prof_save else ""], 18, C_MUTED)
		s2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(s2)
		g.add_child(cell)
	ab.add_child(g)
	v.add_child(ab.get_parent())

	var ai := R.attack_info(h)
	var at := _card()
	at.add_child(_label("Атака: %s %+d, урон %s%+d%s" % [ai.name, ai.atk, R.dice_ru(ai.dice), ai.bonus, " ×2" if int(ai.attacks) > 1 else ""], 24, C_INK))
	at.add_child(_label("Умения: " + str(R.CLASSES[h.cls].features), 21, C_MUTED))
	if h.get("second_wind", false) and not in_combat:
		at.add_child(_small_wide_button("❤ Второе дыхание (1к10+%d)" % int(h.level), C_GREEN.darkened(0.3), func(): Game.inv("second_wind", {})))
	v.add_child(at.get_parent())

	var spells := R.known_spells(h)
	if spells.size() > 0:
		var sc := _card()
		sc.add_child(_label("Заклинания (атака %+d, СЛ %d) · ячейки: %s" % [R.spell_attack(h), R.spell_dc(h), _slots_text(h)], 22, C_PURPLE.lightened(0.3)))
		for sid in spells:
			var sp: Dictionary = R.SPELLS[sid]
			sc.add_child(_label("• %s%s — %s" % [sp.name, " (заговор)" if int(sp.lvl) == 0 else " (%d ур.)" % int(sp.lvl), sp.desc], 21, C_INK))
			if sp.kind == "heal" and not in_combat and R.slot_for(h, sid) >= 0:
				for n in Game.state.heroes:
					var tn: String = n
					sc.add_child(_small_wide_button("Лечить: %s" % Game.state.heroes[n].name, C_PURPLE.darkened(0.3), func(): Game.inv("cast", {"spell": sid, "target": tn})))
		v.add_child(sc.get_parent())

	var sk := _card()
	sk.add_child(_label("Навыки (• — владеешь)", 22, C_MUTED))
	var lines := []
	for s in R.SKILLS:
		lines.append("%s%s %+d" % ["• " if s in h.skills else "   ", s, R.skill_bonus(h, s)])
	var g2 := GridContainer.new()
	g2.columns = 2
	for l in lines:
		var ll := _label(l, 19, C_INK)
		ll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g2.add_child(ll)
	sk.add_child(g2)
	v.add_child(sk.get_parent())

	var eq := _card()
	eq.add_child(_label("Снаряжение", 26, C_ACCENT))
	for slot in R.SLOT_NAMES:
		var it = h.equip.get(slot)
		var has: bool = it is Dictionary and not it.is_empty()
		var row := HBoxContainer.new()
		if has and Icons.for_item(it) != null:
			row.add_child(_icon_rect(Icons.for_item(it), 36, C_ACCENT))
		var txt := _label("%s: %s" % [R.SLOT_NAMES[slot], (R.item_name(it) + " — " + R.item_desc(it)) if has else "—"], 21, C_INK if has else C_MUTED)
		txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(txt)
		if has and can_manage:
			var s: String = slot
			row.add_child(_tiny_button("Снять", C_CARD2, func(): Game.inv("unequip", {"slot": s})))
		eq.add_child(row)
	v.add_child(eq.get_parent())

	var bag := _card()
	bag.add_child(_label("Сумка", 26, C_ACCENT))
	if h.items.is_empty():
		bag.add_child(_label("пусто", 22, C_MUTED))
	var partner := _partner()
	var shop_open: bool = not Game.state.shop.is_empty()
	for i in h.items.size():
		var it: Dictionary = h.items[i]
		var idx: int = i
		var d := R.item_def(it)
		var brow := HBoxContainer.new()
		brow.add_theme_constant_override("separation", 8)
		if Icons.for_item(it) != null:
			brow.add_child(_icon_rect(Icons.for_item(it), 36, C_PURPLE.lightened(0.4) if d.get("magic", false) else C_ACCENT))
		var bl := _label("%s%s" % [R.item_name(it), (" — " + R.item_desc(it)) if R.item_desc(it) != "" else ""], 22, C_PURPLE.lightened(0.4) if d.get("magic", false) else C_INK)
		bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		brow.add_child(bl)
		bag.add_child(brow)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		if R.item_slot(it) != "" and can_manage:
			row.add_child(_tiny_button("Надеть", C_BLUE, func(): Game.inv("equip", {"idx": idx})))
		if d.type == "potion" and not in_combat:
			row.add_child(_tiny_button("Выпить", C_GREEN.darkened(0.3), func(): Game.inv("use", {"idx": idx})))
			if partner != "":
				row.add_child(_tiny_button("Напоить друга", C_GREEN.darkened(0.4), func(): Game.inv("use", {"idx": idx, "target": partner})))
		if partner != "" and not in_combat:
			row.add_child(_tiny_button("Отдать", C_CARD2, func(): Game.inv("give", {"idx": idx, "to": partner})))
		if shop_open:
			row.add_child(_tiny_button("Продать %d" % maxi(1, R.item_price(it) / 2), C_ACCENT.darkened(0.3), func(): Game.inv("sell", {"idx": idx})))
		elif not in_combat:
			row.add_child(_tiny_button("✖", C_CARD2, func(): Game.inv("drop", {"idx": idx})))
		bag.add_child(row)
	if partner != "" and int(h.gold) >= 10 and not in_combat:
		bag.add_child(_small_wide_button("Дать другу 10 золота", C_ACCENT.darkened(0.4), func(): Game.inv("give_gold", {"to": partner, "amount": 10})))
	v.add_child(bag.get_parent())

	if partner != "":
		var ph: Dictionary = Game.state.heroes[partner]
		var pc := _card()
		pc.add_child(_label("Напарник: %s, %s %s %d ур." % [ph.name, ph.race, ph.cls, int(ph.level)], 22, C_INK))
		pc.add_child(_label("Хиты %d/%d · КД %d" % [ph.hp, ph.max_hp, R.ac(ph)], 22, C_MUTED))
		v.add_child(pc.get_parent())


# ---------- сундук и лавка ----------

func _update_overlay() -> void:
	var loot: Dictionary = Game.state.get("loot", {}) if Net.is_online() else {}
	var shop: Dictionary = Game.state.get("shop", {}) if Net.is_online() else {}
	var show_any := screen == "game" and (not loot.is_empty() or not shop.is_empty())
	var h := Game.my_hero()
	var key := JSON.stringify([loot, shop, h.get("gold", 0), show_any])
	if key == _overlay_key:
		return
	_overlay_key = key
	for c in overlay.get_children():
		c.queue_free()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not show_any:
		return
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right"]:
		m.add_theme_constant_override("margin_" + s, 26)
	m.add_theme_constant_override("margin_top", 160)
	m.add_theme_constant_override("margin_bottom", 120)
	overlay.add_child(m)
	var panel := _card(C_CARD2)
	m.add_child(panel.get_parent())
	var scroll := _scroll()
	var inner: VBoxContainer = scroll.get_child(0)
	if not loot.is_empty():
		panel.add_child(_label("💰 " + str(loot.title), 36, C_ACCENT))
		for i in loot.items.size():
			var it: Dictionary = loot.items[i]
			var idx: int = i
			var d := R.item_def(it)
			var c := _card(C_CARD)
			var lrow := HBoxContainer.new()
			lrow.add_theme_constant_override("separation", 10)
			if Icons.for_item(it) != null:
				lrow.add_child(_icon_rect(Icons.for_item(it), 48, C_PURPLE.lightened(0.4) if d.get("magic", false) else C_ACCENT))
			var ll := _label(R.item_name(it), 26, C_PURPLE.lightened(0.4) if d.get("magic", false) else C_INK)
			ll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lrow.add_child(ll)
			c.add_child(lrow)
			if R.item_desc(it) != "":
				c.add_child(_label(R.item_desc(it), 20, C_MUTED))
			c.add_child(_small_wide_button("Взять себе", C_GREEN.darkened(0.2), func(): Game.inv("loot_take", {"idx": idx})))
			inner.add_child(c.get_parent())
		panel.add_child(scroll)
		panel.add_child(_small_wide_button("Оставить остальное", C_CARD, func(): Game.inv("loot_close", {})))
		return
	panel.add_child(_label("⚖ " + str(shop.title), 34, C_ACCENT))
	panel.add_child(_label("Твоё золото: %d. Продать можно из сумки на вкладке «Герой»." % int(h.get("gold", 0)), 20, C_MUTED))
	for i in shop.items.size():
		var it: Dictionary = shop.items[i]
		var idx: int = i
		var price := R.item_price(it)
		var c := _card(C_CARD)
		var srow := HBoxContainer.new()
		srow.add_theme_constant_override("separation", 10)
		if Icons.for_item(it) != null:
			srow.add_child(_icon_rect(Icons.for_item(it), 44, C_ACCENT))
		var sl := _label("%s — %d зол." % [R.item_name(it), price], 24, C_INK)
		sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		srow.add_child(sl)
		c.add_child(srow)
		if R.item_desc(it) != "":
			c.add_child(_label(R.item_desc(it), 20, C_MUTED))
		var bt := _small_wide_button("Купить", C_ACCENT.darkened(0.2), func(): Game.inv("buy", {"idx": idx}))
		bt.disabled = int(h.get("gold", 0)) < price
		c.add_child(bt)
		inner.add_child(c.get_parent())
	panel.add_child(scroll)
	var row := HBoxContainer.new()
	var sell := _small_wide_button("Продать вещи", C_BLUE, func():
		tab = "sheet"
		screen = ""
		overlay.visible = false
		_refresh())
	sell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sell)
	var close := _small_wide_button("Уйти из лавки", C_CARD, func():
		overlay.visible = true
		Game.inv("shop_close", {}))
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(close)
	panel.add_child(row)
	overlay.visible = tab != "sheet"


# ---------- поиск комнат ----------

func _update_rooms() -> void:
	var sig := JSON.stringify(Net.rooms)
	sig = sig.substr(0, 0) + str(Net.rooms.keys()) + str(Net.rooms.size())
	for ip in Net.rooms:
		sig += str(Net.rooms[ip].count) + str(Net.rooms[ip].open)
	if sig == refs.rooms_sig:
		return
	refs.rooms_sig = sig
	var list: VBoxContainer = refs.rooms
	for c in list.get_children():
		c.queue_free()
	if Net.rooms.is_empty():
		list.add_child(_label("Ищем комнаты в сети…", 26, C_MUTED))
		return
	for ip in Net.rooms:
		var r: Dictionary = Net.rooms[ip]
		var txt := "%s · %d в отряде%s" % [r.name, r.count, "" if r.open else " · идёт игра"]
		var b := _button(txt, C_BLUE if r.open else C_CARD2, func(): _join(ip))
		b.disabled = not r.open
		list.add_child(b)


func _process(delta: float) -> void:
	if refs.has("dots") and is_instance_valid(refs.dots):
		_dots_t += delta
		refs.dots.text = refs.dots_text + ".".repeat(int(_dots_t * 2.0) % 4)
	_follow_keyboard()


func _follow_keyboard() -> void:
	var px := 0.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		px = float(DisplayServer.virtual_keyboard_get_height())
	var win_h := float(DisplayServer.window_get_size().y)
	var vp_h := get_viewport_rect().size.y
	var off := px * vp_h / win_h if win_h > 0 else 0.0
	root_margin.add_theme_constant_override("margin_bottom", 18 + int(off))


# ---------- действия ----------

func _on_host() -> void:
	error_text = ""
	if not LLM.has_key():
		error_text = "Сначала вставь ключ ИИ: он нужен тому, кто создаёт комнату"
		_update()
		return
	var e := Net.host_room()
	if e != "":
		error_text = e
	_refresh()


func _join(ip: String) -> void:
	if ip.strip_edges() == "":
		return
	error_text = ""
	var e := Net.join_room(ip)
	if e != "":
		error_text = e
		local_screen = "search"
	_refresh()


func _paste_key() -> void:
	var k := DisplayServer.clipboard_get().strip_edges()
	if k.begins_with("sk-or-"):
		LLM.save_key(k)
		DisplayServer.clipboard_set("")
		_toast("Ключ сохранён на этом телефоне")
	else:
		_toast("Скопируй ключ OpenRouter (sk-or-…) и нажми ещё раз")
	_update()


func _toast(text: String) -> void:
	toast.text = text
	toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(2.2)
	tw.tween_property(toast, "modulate:a", 0.0, 0.5)


func _load_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		var n := str(cfg.get_value("player", "name", ""))
		if n != "":
			return n
	return NAMES[randi() % NAMES.size()]


func _save_name() -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("player", "name", Net.my_name)
	cfg.save("user://settings.cfg")


# ---------- оформление ----------

func _load_fonts() -> void:
	var fb: Array[Font] = [ThemeDB.fallback_font]
	var emoji := load("res://fonts/NotoEmoji.ttf") as FontFile
	if emoji:
		fb.push_front(emoji)
	for pair in [["font_bold", "res://fonts/Nunito-Bold.ttf"], ["font_black", "res://fonts/Nunito-Black.ttf"]]:
		var f := load(pair[1]) as FontFile
		if f:
			f.fallbacks = fb
			set(pair[0], f)
	if font_black == null:
		font_black = font_bold


func _make_bg() -> Control:
	var g := Gradient.new()
	g.colors = PackedColorArray([C_BG1, C_BG2])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 8
	gt.height = 256
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


func _box(color: Color, radius := 22, pad := 18) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad * 0.7
	sb.content_margin_bottom = pad * 0.7
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 26
	if font_bold:
		t.default_font = font_bold
	t.set_color("font_color", "Label", C_INK)
	t.set_color("default_color", "RichTextLabel", C_INK)
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, _box(Color("1a1c2c"), 16, 16))
		t.set_stylebox("focus", type, _box(Color("1a1c2c"), 16, 16))
		t.set_color("font_color", type, C_INK)
		t.set_color("font_placeholder_color", type, Color("6f7393"))
		t.set_color("caret_color", type, C_ACCENT)
		t.set_font_size("font_size", type, 26)
	t.set_color("font_color", "Button", C_INK)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	var sb_v := StyleBoxFlat.new()
	sb_v.bg_color = Color(1, 1, 1, 0.15)
	sb_v.set_corner_radius_all(4)
	t.set_stylebox("grabber", "VScrollBar", sb_v)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
	return t


func _label(text: String, size := 26, color := C_INK) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if size >= 34 and font_black:
		l.add_theme_font_override("font", font_black)
	return l


func _rich(bb: String, size := 24) -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.add_theme_font_size_override("normal_font_size", size)
	l.text = bb
	return l


func _esc(s) -> String:
	return str(s).replace("[", "(").replace("]", ")")


func _title(text: String) -> Label:
	return _label(text, 46, C_INK)


func _button(text: String, color: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 88)
	b.add_theme_font_size_override("font_size", 28)
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var dark := color.get_luminance() > 0.55
	b.add_theme_stylebox_override("normal", _box(color, 22))
	b.add_theme_stylebox_override("hover", _box(color.lightened(0.08), 22))
	b.add_theme_stylebox_override("pressed", _box(color.darkened(0.2), 22))
	b.add_theme_stylebox_override("disabled", _box(color.darkened(0.45), 22))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
			"icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(s, Color("1b1b24") if dark else Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.45))
	b.add_theme_constant_override("icon_max_width", 40)
	b.add_theme_constant_override("h_separation", 10)
	b.pressed.connect(cb)
	return b


func _small_button(text: String, color: Color, cb: Callable) -> Button:
	var b := _button(text, color, cb)
	b.custom_minimum_size = Vector2(110, 68)
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	return b


func _small_wide_button(text: String, color: Color, cb: Callable) -> Button:
	var b := _button(text, color, cb)
	b.custom_minimum_size = Vector2(0, 62)
	b.add_theme_font_size_override("font_size", 22)
	return b


func _tiny_button(text: String, color: Color, cb: Callable) -> Button:
	var b := _button(text, color, cb)
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", 20)
	for s in ["normal", "hover", "pressed", "disabled"]:
		var sb: StyleBoxFlat = b.get_theme_stylebox(s).duplicate()
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		b.add_theme_stylebox_override(s, sb)
	return b


func _with_icon(b: Button, tex: Texture2D, w := 40) -> Button:
	b.icon = tex
	b.add_theme_constant_override("icon_max_width", w)
	return b


func _icon_rect(tex: Texture2D, size := 44, color := C_ACCENT) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.modulate = color
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


func _menu_button(text: String, color: Color, cb: Callable) -> Button:
	return _wrap_button(text, color, cb, 21, 72)


## Кнопка с переносом строк. Высота фиксированная: у Button с autowrap в Godot 4.3
## высота пересчитывается по кругу и кнопка растёт при каждом нажатии.
func _wrap_button(text: String, color: Color, cb: Callable, font := 22, h := 72, text_color := Color.WHITE) -> Button:
	var b := _button("", color, cb)
	b.custom_minimum_size = Vector2(0, h)
	b.clip_contents = true
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", text_color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.offset_left = 16
	l.offset_right = -12
	l.offset_top = 4
	l.offset_bottom = -4
	l.clip_text = true
	b.add_child(l)
	return b


func _card(color := C_CARD) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(color, 22, 18))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	return v


func _scroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	s.add_child(v)
	return s


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _expander() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


# ---------- автотест (ALIBI_AUTOTEST=host|client вместе с ALIBI_MOCK=1) ----------

var _auto := ""
var _auto_n := 0


func _autotest_setup() -> void:
	_auto = OS.get_environment("ALIBI_AUTOTEST")
	if _auto == "":
		return
	Net.my_name = "Хост" if _auto == "host" else "Гость"
	if _auto == "host":
		Net.host_room()
	else:
		await get_tree().create_timer(1.0).timeout
		_join("127.0.0.1")
	var t := Timer.new()
	t.wait_time = 0.7
	t.autostart = true
	t.timeout.connect(_autotest_tick)
	add_child(t)


func _autotest_tick() -> void:
	_auto_n += 1
	if _auto_n > 400:
		print("[%s] AUTOTEST TIMEOUT" % _auto)
		get_tree().quit(1)
		return
	var me := Game.my_pname()
	var shot := OS.get_environment("ALIBI_SHOT")
	if shot != "" and _auto_n % 2 == 0:
		get_viewport().get_texture().get_image().save_png("%s/%s_%03d_%s_%s.png" % [shot, _auto, _auto_n, Game.phase, tab])
		if _auto == "client" and screen == "game":
			var want := "story"
			if int(Game.state.turn) in [3, 4]:
				want = "sheet"
			elif int(Game.state.turn) in [6, 7]:
				want = "map"
			if want != tab:
				tab = want
				screen = ""
				_refresh()
	for a in Game.state.get("ask", []):
		if str(a.who) == me and not a.done:
			Game.roll_now()
			return
	match Game.phase:
		"lobby":
			if _auto == "host" and Net.players.size() >= 2:
				Game.new_campaign(Game.SETTINGS[0], "")
		"create":
			if Game.my_hero().is_empty():
				Game.submit_hero("Торин" if _auto == "host" else "Мира", "Дварф" if _auto == "host" else "Эльф", "Воин" if _auto == "host" else "Маг", "тест")
		"play":
			if not Game.state.loot.is_empty():
				Game.inv("loot_take", {"idx": 0})
				return
			if not Game.state.shop.is_empty():
				Game.inv("buy", {"idx": 0})
				Game.inv("shop_close", {})
				return
			if Game.my_hero().items.size() > 0 and _auto_n % 5 == 0:
				Game.inv("equip", {"idx": 0})
			if not (me in Game.state.pending):
				Game.submit_action("Осматриваюсь (%s, ход %d)" % [_auto, Game.state.turn])
			if int(Game.state.turn) >= 12:
				print("[%s] AUTOTEST DONE turn=%d heroes=%s" % [_auto, Game.state.turn, JSON.stringify(Game.state.heroes)])
				print("[%s] MAP %s" % [_auto, JSON.stringify(Game.state.map)])
				for e in Game.state.log.slice(-40):
					print("[%s] LOG %s: %s" % [_auto, e.k, e.t])
				get_tree().quit()
		"combat":
			if Game.combat_actor() == me:
				var h := Game.my_hero()
				if h.cls == "Маг" and R.slot_for(h, "magic_missile") > 0:
					Game.combat_action({"t": "spell", "spell": "magic_missile", "target": -1})
				elif _auto_n % 7 == 0:
					Game.combat_action({"t": "free", "text": "Пинаю гоблина в костёр"})
				else:
					Game.combat_action({"t": "attack", "target": -1})
