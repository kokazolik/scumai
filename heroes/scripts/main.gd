extends Control
## Интерфейс «Хроник двоих». Экраны строятся кодом; во время игры три вкладки: История, Герой, Карта.
## Части экрана перестраиваются только когда меняется их «ключ», чтобы не сбивать набранный текст.

const R = preload("res://scripts/rules.gd")
const MapView = preload("res://scripts/map_view.gd")
const DiceView = preload("res://scripts/dice_view.gd")
const FxView = preload("res://scripts/fx_view.gd")
const Icons = preload("res://scripts/icons.gd")
const UISkin = preload("res://scripts/skin.gd")

const C_BG1 := Color("161827")
const C_BG2 := Color("2a1f3d")
const C_CARD := Color("2a1d14")
const C_CARD2 := Color("3a281a")
const C_INK := Color("f3e9d2")
const C_MUTED := Color("bfae8f")
const C_ACCENT := Color("ffc145")
const C_RED := Color("ff5a5f")
const C_GREEN := Color("3ddc97")
const C_BLUE := Color("5b8cff")
const C_PURPLE := Color("a77bff")

const NAMES := ["Странник", "Искра", "Ворон", "Лис", "Сова", "Кремень", "Ясень", "Волчок", "Пламя", "Тень"]

var font_bold: Font
var font_black: Font
var font_title: Font
var sheet_tab := "gear"
var _panel_open := true
var tts_on := true
var _tts_voice := ""
var item_pop: Control
var root_margin: MarginContainer
var content: VBoxContainer
var overlay: Control
var dice: Control
var fx: Control
var _fx_hero := ""
var _fx_hp := -1
var _fx_level := -1
var _fx_gold := -1
var _fx_had_loot := false
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
	add_child(UISkin.make_bg_rect())
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

	fx = FxView.new()
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(fx)

	toast = _label("", 24, C_INK)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.position = Vector2(40, 1100)
	toast.size = Vector2(640, 60)
	toast.modulate.a = 0.0
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)

	Net.my_name = _load_name()
	Game.state_changed.connect(_refresh)
	Game.rolls_shown.connect(func(rolls):
		if OS.get_environment("ALIBI_NODICE") == "":
			dice.play(rolls)
		_roll_sfx(rolls))
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
	if p in ["play", "thinking", "combat", "roll"]:
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
	_check_fx()
	_update_music()


var _was_combat := false


func _update_music() -> void:
	var au := _audio()
	if au == null:
		return
	if screen != "game":
		if screen in ["menu", "search", "connecting", "lobby", "create", "create_done", "world", "roll"]:
			au.play_music("menu")
		return
	var in_combat: bool = Game.phase == "combat" or not Game.state.combat.is_empty()
	if in_combat:
		au.play_music("combat")
		_was_combat = true
		return
	if _was_combat:
		_was_combat = false
		for e in Game.state.log.slice(-6):
			if str(e.k) == "cbt" and str(e.t).begins_with("Победа"):
				au.play_sting("victory")
				break
	var m: Dictionary = Game.state.get("map", {})
	var nodes: Array = m.get("nodes", [])
	var cur := int(m.get("cur", -1))
	if cur >= 0 and cur < nodes.size():
		au.play_music(au.mood_for_place(str(nodes[cur].get("type", "")), str(nodes[cur].get("name", ""))))
	else:
		au.play_music("wild")


## Звук удара под штамп результата на кубике (~2 с после броска).
func _roll_sfx(rolls: Array) -> void:
	if rolls.is_empty() or not (rolls[0] is Dictionary):
		return
	var r: Dictionary = rolls[0]
	var kind := str(r.get("kind", ""))
	var out := str(r.get("outcome", ""))
	var snd := ""
	if kind == "attack":
		snd = "crit" if out.begins_with("крит") else ("sword_hit" if out.begins_with("попад") else "miss_whoosh")
	elif kind == "spell":
		snd = "spell_cast"
	elif kind == "enemy" and not out.begins_with("попад") and not out.begins_with("крит"):
		snd = "miss_whoosh"
	if snd != "":
		get_tree().create_timer(1.9 if rolls.size() < 3 else 1.45).timeout.connect(func(): _sfx(snd))


func _sfx(name: String, db := 0.0) -> void:
	var au := _audio()
	if au:
		au.sfx(name, db)


func _check_fx() -> void:
	if screen != "game" or not Net.is_online():
		_fx_hero = ""
		return
	var h := Game.my_hero()
	if h.is_empty():
		return
	var hp := int(h.get("hp", 0))
	var lv := int(h.get("level", 1))
	var gold := int(h.get("gold", 0))
	var loot: Dictionary = Game.state.get("loot", {})
	var has_loot := not loot.is_empty()
	if _fx_hero != str(h.name):
		_fx_hero = str(h.name)
	else:
		if hp < _fx_hp:
			fx.hit_flash(Color(0.9, 0.1, 0.1))
			_sfx("death_knell" if hp <= 0 else "enemy_hit")
		elif hp > _fx_hp and Game.phase != "combat":
			_sfx("heal", -4.0)
		if lv > _fx_level:
			fx.level_up(str(h.name), lv)
			_sfx("level_up")
		if has_loot and not _fx_had_loot:
			var icons: Array = []
			for it in loot.get("items", []):
				if it is Dictionary and icons.size() < 10:
					icons.append(Icons.for_item(it))
			_loot_fx(str(loot.get("title", "Добыча")), maxi(0, gold - _fx_gold), icons)
	_fx_hp = hp
	_fx_level = lv
	_fx_gold = gold
	_fx_had_loot = has_loot


func _loot_fx(title: String, gold: int, icons: Array) -> void:
	# сундук показываем после кубика, чтобы не прятался под ним
	if dice.visible:
		await dice.finished
	fx.loot_burst(title, gold, icons)
	_sfx("chest_open")
	if gold > 0:
		get_tree().create_timer(0.7).timeout.connect(func(): _sfx("coin"))


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
	content.add_child(_spacer(10))
	var emb := CenterContainer.new()
	emb.add_child(UISkin.make_portrait(Icons.tex("ui_dice"), 150))
	content.add_child(emb)
	var t := _label("Хроники\nдвоих", 76, C_ACCENT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UISkin.style_title(t, 76, true)
	content.add_child(t)
	content.add_child(UISkin.make_divider(30))
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
		top.add_child(UISkin.make_portrait(Icons.for_class(str(mh.cls)), 84))
	top.add_theme_constant_override("separation", 12)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var hl := _label("", 26, C_INK)
	refs.hero_line = hl
	info.add_child(hl)
	var bar := ProgressBar.new()
	UISkin.style_bar(bar, "hp")
	bar.custom_minimum_size = Vector2(0, 30)
	refs.hp_bar = bar
	info.add_child(bar)
	top.add_child(info)
	content.add_child(top)
	# вкладки
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	for t in [["story", "История", "ui_story"], ["sheet", "Герой", "ui_hero"], ["journal", "Дневник", "it_book"], ["map", "Карта", "ui_map"]]:
		var b := _with_icon(_button(t[1], C_ACCENT if tab == t[0] else C_CARD2, func():
			tab = t[0]
			screen = ""
			_refresh()), Icons.tex(t[2]), 30)
		UISkin.style_tab(b, tab == t[0], 20)
		b.add_theme_constant_override("icon_max_width", 26)
		b.add_theme_constant_override("h_separation", 4)
		b.custom_minimum_size = Vector2(0, 66)
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
		"journal":
			var scroll := _scroll()
			refs.journal = scroll.get_child(0)
			refs.journal_key = ""
			content.add_child(scroll)


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
	# Лента сама держит в кадре новое: перестаёт, только когда игрок сам листает вверх.
	_follow = true
	_follow_node = null
	scroll.scroll_started.connect(func():
		_follow = false
		_follow_node = null)
	scroll.scroll_ended.connect(func():
		var bar := scroll.get_v_scroll_bar()
		if scroll.scroll_vertical >= bar.max_value - bar.page - 40:
			_follow = true
			_follow_node = null
			if refs.has("new_btn") and is_instance_valid(refs.new_btn):
				refs.new_btn.visible = false)
	scroll.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_follow = false
			_follow_node = null)
	# полоска между текстом и действиями: «новое» и свернуть/развернуть
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	var nb := _tiny_button("▼ Новое", C_ACCENT, func():
		refs.new_btn.visible = false
		_scroll_down(refs.log_scroll))
	nb.visible = false
	nb.custom_minimum_size = Vector2(190, 48)
	refs.new_btn = nb
	bar.add_child(nb)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sp)
	var chb := _with_icon(_tiny_button("Чат", C_CARD, func(): _open_chat()), Icons.tex("ui_chat"), 28)
	chb.custom_minimum_size = Vector2(158, 48)
	refs.chat_btn = chb
	bar.add_child(chb)
	var vb := _tiny_button("🔊" if tts_on else "🔇", C_CARD, Callable())
	vb.pressed.connect(func():
		tts_on = not tts_on
		if not tts_on and DisplayServer.has_method("tts_stop"):
			DisplayServer.tts_stop()
		vb.text = "🔊" if tts_on else "🔇"
		_save_name()
		_toast("Голос ведущего " + ("включён" if tts_on else "выключен")))
	vb.custom_minimum_size = Vector2(64, 48)
	bar.add_child(vb)
	var au := _audio()
	var mb := _tiny_button("♪", C_CARD, Callable())
	mb.modulate.a = 1.0 if (au == null or au.music_enabled) else 0.45
	mb.pressed.connect(func():
		var a2 := _audio()
		if a2 == null:
			return
		a2.set_music_enabled(not a2.music_enabled)
		mb.modulate.a = 1.0 if a2.music_enabled else 0.45
		_toast("Музыка " + ("включена" if a2.music_enabled else "выключена")))
	mb.custom_minimum_size = Vector2(64, 48)
	bar.add_child(mb)
	var tg := _tiny_button("", C_CARD, func():
		_panel_open = not _panel_open
		_apply_panel())
	tg.custom_minimum_size = Vector2(200, 48)
	refs.panel_btn = tg
	bar.add_child(tg)
	content.add_child(bar)
	var bottom := VBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	content.add_child(bottom)
	refs.bottom = bottom
	_apply_panel()


func _apply_panel() -> void:
	if not refs.has("bottom"):
		return
	refs.bottom.visible = _panel_open
	var hint := ""
	var m := _bottom_key
	if m.begins_with("myturn") or m.begins_with("ask") or m.begins_with("input"):
		hint = " · твой ход"
	refs.panel_btn.text = ("Свернуть ▾" if _panel_open else "Действия ▴" + hint)


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
			refs.hero_line.text = "%s · %s %d · КД %d · %d зол. · Хиты %d/%d%s" % [h.name, h.cls, int(h.level), R.ac(h), int(h.gold), int(h.hp), int(h.max_hp), _cond_tags(h)]
			refs.hp_bar.max_value = int(h.max_hp)
			refs.hp_bar.value = int(h.hp)

	if refs.has("log"):
		_update_log()
		_update_combat_box()
		_update_bottom()
	_check_notices()
	_update_chat()
	if refs.has("journal"):
		var jk := JSON.stringify([Game.state.campaign.get("quests", []), Game.state.campaign.get("npcs", []), Game.state.campaign.get("chronicle", ""), Game.state.campaign.get("quest", ""),
			Game.state.campaign.get("rep", {}), Game.state.campaign.get("threads", []), Game.state.get("companions", [])])
		if jk != refs.journal_key:
			refs.journal_key = jk
			_build_journal(refs.journal)
	_check_choice()
	if refs.has("sheet"):
		var key := JSON.stringify(h) + Game.phase + str(Game.my_shop().is_empty()) + JSON.stringify(Game.state.combat.get("turn", -1))
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
	var rebuilt := false
	if _log_n < 0 or lg.size() < _log_n:
		rebuilt = true
		for c in logv.get_children():
			c.queue_free()
		_log_n = maxi(0, lg.size() - 60)
		var c0: Dictionary = Game.state.campaign
		if str(c0.get("title", "")) != "":
			logv.add_child(UISkin.make_ribbon_title(str(c0.title), 30, 80))
	var mine := false
	var fresh := not rebuilt
	var first_gm: Control = null
	for i in range(_log_n, lg.size()):
		var en: Control = _log_entry(lg[i])
		_pass_mouse(en)
		logv.add_child(en)
		if fresh and str(lg[i].k) == "gm" and en.get_child_count() > 0 and en.get_child(0) is RichTextLabel:
			_typewrite.call_deferred(en.get_child(0))
			_speak(str(lg[i].t))
			_sfx("page", -6.0)
		if fresh and str(lg[i].k) == "gm" and first_gm == null:
			first_gm = en
		if str(lg[i].k) == "act" and str(lg[i].get("w", "")) == str(Game.my_hero().get("name", "?")):
			mine = true
	_log_n = lg.size()
	if rebuilt or mine:
		_follow = true
		_follow_node = null
	if first_gm != null:
		# новый текст ведущего всегда показываем с его начала
		_follow = true
		_follow_node = first_gm
	if _follow:
		if refs.has("new_btn") and is_instance_valid(refs.new_btn):
			refs.new_btn.visible = false
	elif refs.has("new_btn"):
		refs.new_btn.visible = true


var _follow := true
var _follow_node: Control = null


## Каждый кадр держим ленту на новом: на начале свежего текста ведущего (если он длиннее экрана) или в самом низу.
func _apply_follow() -> void:
	if not _follow or not refs.has("log_scroll"):
		return
	var sc = refs.log_scroll
	if not is_instance_valid(sc) or not sc.is_visible_in_tree():
		return
	var bar: VScrollBar = sc.get_v_scroll_bar()
	var maxs := int(maxf(0.0, bar.max_value - bar.page))
	var target := maxs
	if _follow_node != null:
		if is_instance_valid(_follow_node):
			target = mini(maxs, int(_follow_node.position.y) - 12)
		else:
			_follow_node = null
	target = maxi(0, target)
	if sc.scroll_vertical != target:
		sc.scroll_vertical = target


func _tts_init() -> void:
	if _tts_voice != "" or OS.get_environment("ALIBI_AUTOTEST") != "":
		return
	if not ProjectSettings.get_setting("audio/general/text_to_speech", false):
		return
	var voices := DisplayServer.tts_get_voices_for_language("ru")
	if voices.size() > 0:
		_tts_voice = voices[0]


func _speak(text: String) -> void:
	_tts_init()
	if not tts_on or _tts_voice == "":
		return
	DisplayServer.tts_speak(text.replace("«", "").replace("»", ""), _tts_voice, 85, 1.0, 1.05, 0, false)


func _audio() -> Node:
	return get_node_or_null("/root/Audio")


## Текст ведущего появляется постепенно; касание показывает сразу весь.
func _typewrite(r: RichTextLabel) -> void:
	var n := r.get_total_character_count()
	if n <= 0:
		return
	r.visible_ratio = 0.0
	var tw := r.create_tween()
	tw.tween_property(r, "visible_ratio", 1.0, clampf(n / 55.0, 0.6, 9.0))
	r.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and r.visible_ratio < 1.0:
			tw.kill()
			r.visible_ratio = 1.0)


## Чтобы текст листался пальцем: карточки и RichTextLabel не должны «съедать» касание.
func _pass_mouse(c: Control) -> void:
	if c.mouse_filter == Control.MOUSE_FILTER_STOP and not (c is BaseButton) and not (c is LineEdit) and not (c is TextEdit):
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	for ch in c.get_children():
		if ch is Control:
			_pass_mouse(ch)


var _scroll_pending := false


func _scroll_down(sc: ScrollContainer) -> void:
	if sc == refs.get("log_scroll"):
		_follow = true
		_follow_node = null
		if refs.has("new_btn") and is_instance_valid(refs.new_btn):
			refs.new_btn.visible = false
		return
	_scroll_pending = true
	await get_tree().process_frame
	await get_tree().process_frame
	_scroll_pending = false
	if is_instance_valid(sc):
		sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)
		if refs.has("new_btn") and is_instance_valid(refs.new_btn) and sc == refs.get("log_scroll"):
			refs.new_btn.visible = false


func _log_entry(e: Dictionary) -> Control:
	match str(e.k):
		"gm":
			var p := PanelContainer.new()
			p.add_theme_stylebox_override("panel", UISkin.panel("parchment", 8))
			var r := _rich(_esc(e.t), 26)
			UISkin.style_parchment_text(r, 26)
			p.add_child(r)
			return p
		"act":
			var p := PanelContainer.new()
			p.add_theme_stylebox_override("panel", UISkin.panel("inset", 10))
			var l := _rich("[color=#%s]%s:[/color] [i]%s[/i]" % [C_ACCENT.to_html(false), _esc(e.w), _esc(e.t)], 23)
			l.add_theme_font_override("italics_font", UISkin.text_font())
			p.add_child(l)
			return p
		"roll":
			return _label("🎲 " + str(e.t), 21, C_BLUE.lightened(0.3))
		"cbt":
			return _label("⚔ " + str(e.t), 21, Color("e7c9b0"))
		"loot":
			return _label("💰 " + str(e.t), 21, C_ACCENT)
		"lvl":
			return _label("⭐ " + str(e.t), 24, C_ACCENT)
		"quest", "rep", "rel", "vote":
			var icon: String = {"quest": "it_scroll", "rep": "ui_rep", "rel": "ui_story", "vote": "ui_vote"}[str(e.k)]
			if str(e.k) == "rel" and (str(e.t).contains("испорт")):
				icon = "ui_heart_broken"
			elif str(e.k) == "rel":
				icon = "ui_heart"
			var p := PanelContainer.new()
			p.add_theme_stylebox_override("panel", UISkin.panel("inset", 10))
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			row.add_child(_icon_rect(Icons.tex(icon), 36, C_ACCENT))
			var ql := _label(str(e.t), 22, C_ACCENT)
			ql.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(ql)
			p.add_child(row)
			return p
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
	var card := _card(C_CARD)
	var order := []
	for i in c.order.size():
		var o: Dictionary = c.order[i]
		var nm := ""
		var dead := false
		if o.k == "h":
			var hh: Dictionary = Game.state.heroes.get(str(o.id), {})
			nm = str(hh.get("name", "?")) + (" (тыл)" if Game.hero_pos(str(o.id)) == "back" else " (впереди)") + _cond_tags(hh)
			dead = int(hh.get("hp", 0)) <= 0
		elif o.k == "c":
			var cps: Array = Game.state.get("companions", [])
			if int(o.id) >= cps.size():
				continue
			nm = "%s 🐾 %d/%d" % [cps[int(o.id)].name, int(cps[int(o.id)].hp), int(cps[int(o.id)].max_hp)]
			dead = int(cps[int(o.id)].hp) <= 0
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
	card.add_child(_rich("Раунд %d: %s" % [int(c.round), " · ".join(order)], 19))
	var alive := []
	for i in c.enemies.size():
		if not c.enemies[i].dead:
			alive.append(i)
	if _target not in alive and alive.size() > 0:
		_target = alive[0]
	var my_turn := Game.combat_actor() == Game.my_pname()
	var strip := ScrollContainer.new()
	strip.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	strip.custom_minimum_size = Vector2(0, 124)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	strip.add_child(row)
	for i in alive:
		var en: Dictionary = c.enemies[i]
		var sel: bool = i == _target and my_turn
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(200, 118)
		var est := UISkin.button_styles("red" if sel else "dark", 8)
		for k in est:
			b.add_theme_stylebox_override(k, est[k])
		var v := VBoxContainer.new()
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.offset_left = 12
		v.offset_right = -12
		v.offset_top = 8
		v.offset_bottom = -10
		v.add_theme_constant_override("separation", 2)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var top := HBoxContainer.new()
		top.mouse_filter = Control.MOUSE_FILTER_IGNORE
		top.add_child(_icon_rect(Icons.for_monster(str(en.get("base_name", en.name))), 40, Color("ffd2c8")))
		var nm := _label("%s%s" % [en.name, " 💤" if en.asleep else ""], 18, C_INK)
		nm.autowrap_mode = TextServer.AUTOWRAP_OFF
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.clip_text = true
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(nm)
		v.add_child(top)
		var ac := _label(("🎯 · " if sel else "") + ("🏹 тыл · " if str(en.get("pos", "front")) == "back" else "") + "КД %d · %d/%d" % [int(en.ac), int(en.hp), int(en.max_hp)], 16, C_ACCENT if sel else C_MUTED)
		ac.autowrap_mode = TextServer.AUTOWRAP_OFF
		v.add_child(ac)
		var ec: Dictionary = en.get("conds", {})
		if not ec.is_empty():
			v.add_child(_cond_row(ec, 22))
		var pb := ProgressBar.new()
		pb.max_value = int(en.max_hp)
		pb.value = int(en.hp)
		UISkin.style_bar(pb, "hp")
		pb.custom_minimum_size = Vector2(0, 22)
		pb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(pb)
		b.add_child(v)
		b.pressed.connect(func():
			_target = i
			refs.combat_key = ""
			_update_combat_box())
		row.add_child(b)
	card.add_child(strip)
	box.add_child(card.get_parent())


func _cond_tags(h: Dictionary) -> String:
	var t := ""
	for k in h.get("conds", {}):
		t += " [" + str(R.CONDS[k].name).to_lower() + "]"
	return t


func _cond_row(cs: Dictionary, size := 26) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 4)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in cs:
		var ic := _icon_rect(Icons.tex(str(R.CONDS[k].icon)), size, Color("c8ff8a") if k == "poisoned" else Color("ffb0a0"))
		ic.tooltip_text = str(R.CONDS[k].name)
		r.add_child(ic)
	return r


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
				return "myturn%d_%d_%s_%d_%d_%s_%s_%d" % [int(Game.state.combat.round), int(Game.state.combat.turn), _combat_menu, (h.slots as Array).hash(), h.items.size(), Game.hero_pos(me), str(Game.state.combat.get("moved", {}).get(me, false)), int(h.hp)]
			return "cwait" + Game.combat_actor()
		"play":
			if h.is_empty():
				return "spectator"
			if me in Game.state.pending:
				return "waiting"
			if not Game.state.get("vote", {}).is_empty():
				return "vote" + JSON.stringify(Game.state.vote)
			return "input" + JSON.stringify(Game.state.options.get(me, [])) + str(Game.merchants_here()) + str(Game.state.pending) + str(_help_on)
	return "other"


func _update_bottom() -> void:
	if not refs.has("bottom") or not is_instance_valid(refs.bottom):
		return
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
	if mode.begins_with("myturn") or mode.begins_with("ask"):
		_panel_open = true
	_apply_panel.call_deferred()
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
		var co: Dictionary = Game.state.combat.get("order", [])[int(Game.state.combat.get("turn", 0))] if not Game.state.combat.is_empty() else {}
		if str(co.get("k", "")) == "c" and int(co.id) < Game.state.get("companions", []).size():
			nm = str(Game.state.companions[int(co.id)].name)
		var l := _label("Ход: %s" % nm, 26, C_MUTED)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_child(l)
		return
	if mode == "spectator":
		b.add_child(_label("У тебя пока нет героя", 24, C_MUTED))
		return
	if mode.begins_with("vote"):
		_build_vote(b)
		return
	if mode == "waiting":
		var l := _label(_wait_text(), 26, C_GREEN)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		refs.wait_label = l
		b.add_child(l)
		b.add_child(_small_wide_button("Изменить действие", C_CARD2, Game.cancel_action))
		return
	# ввод действия
	var me := Game.my_pname()
	var opts: Array = Game.state.options.get(me, [])
	var others := []
	for n in Game.state.pending:
		if str(n) != me and Game.state.heroes.has(n):
			others.append(str(Game.state.heroes[n].name))
	if others.size() > 0:
		var wb := _card(C_CARD2)
		b.add_child(wb.get_parent())
		var wl := _label("✋ %s %s действие — все ждут тебя" % [", ".join(others), "уже выбрали" if others.size() > 1 else "уже выбрал(а)"], 21, C_GREEN)
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wb.add_child(wl)
	var input := TextEdit.new()
	input.placeholder_text = "Что делает %s?" % Game.my_hero().get("name", "твой герой")
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input.custom_minimum_size = Vector2(0, 100)
	input.text = _draft
	refs.action_input = input
	for oi in opts.size():
		var o = opts[oi]
		var ot := str(o.get("t", "")) if o is Dictionary else str(o)
		var chk: Dictionary = o.get("chk", {}) if o is Dictionary else {}
		var idx: int = oi
		if chk.is_empty():
			var ob := _wrap_button("› " + ot, C_CARD, func():
				input.text = ot
				_opt_pick = -1, 21, 60, C_ACCENT)
			b.add_child(ob)
		else:
			var ob := _wrap_button("› %s\n🎲 %s %+d · сложность %d (%s)" % [ot, chk.label, int(chk.bonus), int(chk.dc), _dc_word(int(chk.dc))], C_CARD, func():
				input.text = ot
				_opt_pick = idx, 19, 76, C_ACCENT)
			b.add_child(ob)
	var mers: Array = Game.merchants_here()
	for mn in mers:
		var mb := _with_icon(_button("Торговать: " + str(mn), C_ACCENT, func(): Game.inv("shop_open", {"merchant": str(mn)})), Icons.tex("ui_shop"), 34)
		mb.custom_minimum_size = Vector2(0, 58)
		mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mb.add_theme_font_size_override("font_size", 21)
		b.add_child(mb)
	b.add_child(input)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 8)
	var partner := _partner()
	if partner != "":
		var hb := _with_icon(_button(("✓ Помогаю: " if _help_on else "Помочь: ") + str(Game.state.heroes[partner].name), C_GREEN.darkened(0.3) if _help_on else C_CARD2, func():
			_help_on = not _help_on
			_bottom_key = ""
			_update_bottom()), Icons.tex("ui_help"), 30)
		hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.custom_minimum_size.y = 56
		hb.add_theme_font_size_override("font_size", 18)
		tools.add_child(hb)
	var rs := _with_icon(_button("Привал", C_CARD2, func(): Game.vote("start", {"kind": "rest_short"})), Icons.tex("ui_campfire"), 30)
	rs.custom_minimum_size = Vector2(150, 56)
	rs.add_theme_font_size_override("font_size", 18)
	tools.add_child(rs)
	var rl := _with_icon(_button("Ночлег", C_CARD2, func(): Game.vote("start", {"kind": "rest_long"})), Icons.tex("ui_sleep_rest"), 30)
	rl.custom_minimum_size = Vector2(150, 56)
	rl.add_theme_font_size_override("font_size", 18)
	tools.add_child(rl)
	b.add_child(tools)
	if _help_on and partner != "":
		b.add_child(_label("Ты помогаешь: у %s будет преимущество на проверку, сам ты не кидаешь." % Game.state.heroes[partner].name, 16, C_MUTED))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var go := _button("Действовать", C_ACCENT, func():
		_draft = ""
		var opt := -1
		if _opt_pick >= 0 and _opt_pick < opts.size() and opts[_opt_pick] is Dictionary and str(opts[_opt_pick].t) == input.text.strip_edges():
			opt = _opt_pick
		Game.submit_action(input.text, partner if _help_on else "", opt)
		_help_on = false
		_opt_pick = -1
		DisplayServer.virtual_keyboard_hide())
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	go.custom_minimum_size.y = 80
	row.add_child(go)
	b.add_child(row)


var _help_on := false
var _opt_pick := -1


func _dc_word(dc: int) -> String:
	if dc <= 10:
		return "легко"
	if dc <= 13:
		return "средне"
	if dc <= 16:
		return "трудно"
	return "очень трудно"


func _build_vote(b: VBoxContainer) -> void:
	var v: Dictionary = Game.state.vote
	var me := Game.my_pname()
	var c := _card(C_CARD)
	b.add_child(c.get_parent())
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	top.add_child(_icon_rect(Icons.tex("ui_vote"), 44, C_ACCENT))
	var ql := _label(str(v.q), 22, C_ACCENT)
	ql.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(ql)
	c.add_child(top)
	c.add_child(_label("Голосуют все. Если мнения разойдутся, спор решит бросок к20 + Харизма.", 16, C_MUTED))
	for i in (v.opts as Array).size():
		var who := []
		for p in v.votes:
			if int(v.votes[p]) == i and Game.state.heroes.has(p):
				who.append(str(Game.state.heroes[p].name))
		var mine: bool = v.votes.has(me) and int(v.votes[me]) == i
		var idx: int = i
		var bt := _wrap_button(("✓ " if mine else "") + str(v.opts[i]) + ("   · " + ", ".join(who) if who.size() > 0 else ""), C_ACCENT if mine else C_CARD2, func(): Game.vote("pick", {"pick": idx}), 20, 60)
		c.add_child(bt)
	if str(v.get("by", "")) == me:
		c.add_child(_small_wide_button("Отменить предложение", C_CARD2, func(): Game.vote("cancel", {})))


func _build_ask(b: VBoxContainer) -> void:
	for a in Game.state.ask:
		var c := _card(Color("2b2547"))
		c.get_parent().add_theme_stylebox_override("panel", UISkin.panel("dark", 10))
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
	if _combat_menu.begins_with("spell"):
		_build_spellbook(b, h)
		return
	if _combat_menu == "item":
		var any := false
		for i in h.items.size():
			var d := R.item_def(h.items[i])
			if d.type in ["potion", "scroll", "bomb", "coat"]:
				any = true
				var idx: int = i
				var bt := _menu_button("%s — %s" % [R.item_name(h.items[i]), R.item_desc(h.items[i])], C_RED.darkened(0.3) if d.type == "bomb" else C_GREEN.darkened(0.3), func():
					_combat_menu = ""
					Game.combat_action({"t": "item", "idx": idx, "target": _target if d.type == "bomb" or (d.type == "scroll" and R.SPELLS[str(d.spell)].kind != "heal") else me}))
				b.add_child(_with_icon(bt, Icons.for_item(h.items[i]), 34))
				var partner := _partner()
				if d.type == "potion" and partner != "":
					b.add_child(_menu_button("   › напоить %s" % Game.hero_of(partner).get("name", ""), C_GREEN.darkened(0.45), func():
						_combat_menu = ""
						Game.combat_action({"t": "item", "idx": idx, "target": partner})))
		if not any:
			b.add_child(_label("Нет зелий, свитков и бомб", 22, C_MUTED))
		b.add_child(_small_wide_button("Назад", C_CARD2, func():
			_combat_menu = ""
			_bottom_key = ""
			_update_bottom()))
		return
	var ai := R.attack_info(h)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	var l := _label("Твой ход! Цель: нажми на врага сверху.", 19, C_ACCENT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(l)
	var front := Game.hero_pos(me) == "front"
	var mv := _tiny_button("⇄ В тыл" if front else "⇄ Вперёд", C_BLUE, func(): Game.combat_action({"t": "move"}))
	mv.custom_minimum_size = Vector2(170, 50)
	mv.disabled = Game.state.combat.get("moved", {}).get(me, false)
	top.add_child(mv)
	b.add_child(top)
	b.add_child(_label(("Ты впереди: прикрываешь тех, кто в тылу. Отход — враг ударит вдогонку." if front else "Ты в тылу: ближние враги не достанут, пока впереди кто-то стоит. Стрелы бьют хуже."), 16, C_MUTED))
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
	var hp_partner := _partner()
	if hp_partner != "" and int(Game.hero_of(hp_partner).get("hp", 0)) > 0:
		acts.append(["Отвлечь врага", C_GREEN.darkened(0.45), func(): Game.combat_action({"t": "help", "target": hp_partner}), "act_help"])
	if h.get("second_wind", false):
		acts.append(["Второе дыхание", C_GREEN.darkened(0.3), func(): Game.combat_action({"t": "second_wind"}), "act_second_wind"])
	if int(h.get("inspire", 0)) > 0:
		var partner := _partner()
		if partner != "":
			acts.append(["Вдохновить (%d)" % int(h.inspire), C_ACCENT.darkened(0.3), func(): Game.combat_action({"t": "inspire", "target": partner}), "act_inspire"])
	acts.append(["Бежать", C_CARD2, func(): Game.combat_action({"t": "flee"}), "act_flee"])
	for a in acts:
		var bt := _with_icon(_button(a[0], a[1], a[2]), Icons.tex(a[3]), 34)
		bt.custom_minimum_size = Vector2(0, 62)
		bt.add_theme_font_size_override("font_size", 21)
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


const SPELL_TINT := {
	"fire_bolt": Color("ff7a3d"), "burning_hands": Color("ff7a3d"), "scorching_ray": Color("ff7a3d"), "fireball": Color("ff5a2a"),
	"ray_of_frost": Color("7fd4ff"), "sacred_flame": Color("ffd75e"), "guiding_bolt": Color("ffd75e"),
	"vicious_mockery": Color("ff8fd0"), "magic_missile": Color("b98cff"), "thunderwave": Color("8fb4ff"), "shatter": Color("8fb4ff"),
	"sleep": Color("a9a0ff"), "cure_wounds": Color("6fe3a0"), "healing_word": Color("6fe3a0"), "mass_healing_word": Color("6fe3a0"),
	"shield_of_faith": Color("ffe08a"), "spiritual_weapon": Color("ffe08a"),
}


## Что делает заклинание, в цифрах: урон, как попадает, кого бьёт, что тратит.
func _spell_facts(h: Dictionary, sid: String) -> Dictionary:
	var sp: Dictionary = R.SPELLS[sid]
	var slot := R.slot_for(h, sid)
	var dice := str(sp.get("dmg", ""))
	var p := R.parse_dice(dice) if dice != "" else {}
	if int(sp.lvl) == 0 and int(h.level) >= 5 and dice != "":
		dice = "%dd%d" % [int(p.n) * 2, int(p.sides)]
	var plus := R.talent_sum(h, "spell_dmg")
	var amount := ""
	var how := ""
	var who := "одна цель"
	match str(sp.kind):
		"attack":
			amount = R.dice_ru(dice) + (" +%d" % plus if plus > 0 else "") + " урона"
			if int(sp.get("rays", 1)) > 1:
				amount = "%d луча по %s" % [int(sp.rays), R.dice_ru(dice)]
			how = "бросок атаки %+d против КД врага" % R.spell_attack(h)
		"auto":
			amount = R.dice_ru(dice) + (" +%d" % plus if plus > 0 else "") + " урона"
			how = "попадает всегда, без броска"
		"save":
			amount = R.dice_ru(dice) + " урона"
			how = "враг кидает спасбросок %s против СЛ %d%s" % [sp.save, R.spell_dc(h), ", при успехе половина" if sp.get("aoe", false) else ", при успехе ничего"]
			if sp.get("aoe", false):
				who = "все враги"
		"heal":
			amount = "лечит %s %+d" % [R.dice_ru(dice), R.caster_mod(h) + R.talent_sum(h, "heal")]
			how = "без броска"
			who = "все союзники" if sp.get("all", false) else "самый раненый союзник"
		"buff":
			amount = "+%d к КД до конца боя" % int(sp.get("ac", 2))
			how = "без броска"
			who = "самый раненый союзник"
		"sleep":
			amount = "усыпляет врагов с суммой хитов до %s" % R.dice_ru(dice)
			how = "начиная со слабых; нежить не спит"
			who = "несколько врагов"
	var cost := ""
	var cost_short := ""
	if int(sp.lvl) == 0:
		cost = "Заговор: бесплатно, можно каждый ход"
		cost_short = "∞ заговор"
	elif slot < 0:
		cost = "Нужна ячейка %d ур. или выше, а их не осталось. Восстановятся после долгого отдыха." % int(sp.lvl)
		cost_short = "нет ячеек"
	else:
		var left := int(h.slots[slot - 1]) - 1
		cost = "Тратит ячейку %d ур. (останется %d из %d)%s" % [slot, left, int(h.slots_max[slot - 1]),
			". Ячейка выше уровня усиливает заклинание" if slot > int(sp.lvl) else ""]
		cost_short = "ячейка %d ур." % slot
	return {"amount": amount, "how": how, "who": who, "cost": cost, "cost_short": cost_short, "slot": slot}


func _slot_pips(h: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if (h.slots_max as Array).size() == 0:
		row.add_child(_label("Только заговоры: их можно читать без ограничений", 18, C_MUTED))
		return row
	var cl := _label("Ячейки:", 19, C_MUTED)
	cl.autowrap_mode = TextServer.AUTOWRAP_OFF
	row.add_child(cl)
	for i in (h.slots_max as Array).size():
		var pips := ""
		for k in int(h.slots_max[i]):
			pips += "●" if k < int(h.slots[i]) else "○"
		var pl := _label("%d ур. %s" % [i + 1, pips], 20, C_PURPLE.lightened(0.3))
		pl.autowrap_mode = TextServer.AUTOWRAP_OFF
		row.add_child(pl)
	return row


func _build_spellbook(b: VBoxContainer, h: Dictionary) -> void:
	var pick := _combat_menu.get_slice(":", 1) if _combat_menu.contains(":") else ""
	var top := HBoxContainer.new()
	var tl := _label("Книга заклинаний", 22, C_ACCENT)
	tl.autowrap_mode = TextServer.AUTOWRAP_OFF
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(tl)
	top.add_child(_slot_pips(h))
	b.add_child(top)
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 8)
	for sid in R.known_spells(h):
		var sp: Dictionary = R.SPELLS[sid]
		var f := _spell_facts(h, sid)
		var tint: Color = SPELL_TINT.get(sid, C_PURPLE)
		var card := Button.new()
		UISkin.style_button(card, "gold" if sid == pick else "dark")
		card.custom_minimum_size = Vector2(0, 150)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.clip_contents = true
		card.disabled = int(f.slot) < 0
		var v := VBoxContainer.new()
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.offset_left = 4
		v.offset_right = -4
		v.offset_top = 6
		v.offset_bottom = -4
		v.add_theme_constant_override("separation", 2)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ic := _icon_rect(Icons.tex("sp_" + sid), 58, tint if int(f.slot) >= 0 else C_MUTED.darkened(0.4))
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(ic)
		var nl := _label(str(sp.name), 15, C_INK if sid != pick else Color("2a1d14"))
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size = Vector2(0, 40)
		nl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(nl)
		var badge := _label(str(f.cost_short), 14, tint if sid != pick else Color("5a2a10"))
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(badge)
		card.add_child(v)
		card.pressed.connect(func():
			_sfx("click")
			_combat_menu = "spell:" + sid
			_bottom_key = ""
			_update_bottom())
		g.add_child(card)
	b.add_child(g)
	if pick != "" and R.SPELLS.has(pick):
		var sp: Dictionary = R.SPELLS[pick]
		var f := _spell_facts(h, pick)
		var tint: Color = SPELL_TINT.get(pick, C_PURPLE)
		var d := _card(C_CARD)
		b.add_child(d.get_parent())
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 10)
		head.add_child(_icon_rect(Icons.tex("sp_" + pick), 50, tint))
		var hl := _label("%s · %s" % [sp.name, "заговор" if int(sp.lvl) == 0 else "%d уровень" % int(sp.lvl)], 22, tint)
		hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hl.autowrap_mode = TextServer.AUTOWRAP_OFF
		hl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		head.add_child(hl)
		d.add_child(head)
		d.add_child(_label("💥 %s · 🎯 %s" % [f.amount, f.who], 19, C_INK))
		d.add_child(_label("🎲 " + str(f.how), 17, C_MUTED))
		d.add_child(_label("✦ " + str(f.cost), 17, C_ACCENT if int(f.slot) >= 0 else C_RED))
		if int(f.slot) >= 0:
			var cast := _button("Сотворить «%s»" % sp.name, C_PURPLE, func():
				var target = _target
				if sp.kind in ["heal", "buff"]:
					target = _heal_target(sp)
				_combat_menu = ""
				Game.combat_action({"t": "spell", "spell": pick, "target": target}))
			cast.custom_minimum_size.y = 64
			d.add_child(cast)
	else:
		b.add_child(_label("Нажми на заклинание, чтобы увидеть урон и что оно тратит.", 17, C_MUTED))
	b.add_child(_small_wide_button("Назад", C_CARD2, func():
		_combat_menu = ""
		_bottom_key = ""
		_update_bottom()))


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

func _build_journal(v: VBoxContainer) -> void:
	for ch in v.get_children():
		ch.queue_free()
	var c: Dictionary = Game.state.campaign
	if str(c.get("title", "")) != "":
		v.add_child(UISkin.make_ribbon_title(str(c.title), 30, 80))
	var main := _card()
	main.add_child(_section_title("Главная цель"))
	main.add_child(_label(str(c.get("quest", "пока неизвестна")), 23, C_INK))
	v.add_child(main.get_parent())
	var qs: Array = c.get("quests", [])
	var act := _card()
	act.add_child(_section_title("Задания"))
	var any := false
	for q in qs:
		if str(q.s) != "active":
			continue
		any = true
		act.add_child(_quest_row(q, "it_scroll", C_ACCENT))
	if not any:
		act.add_child(_label("Пока нет поручений. Поговорите с местными: ведущий запишет сюда всё, что вам поручат.", 19, C_MUTED))
	v.add_child(act.get_parent())
	var fin := []
	for q in qs:
		if str(q.s) != "active":
			fin.append(q)
	if fin.size() > 0:
		var dc := _card(C_CARD2)
		dc.add_child(_section_title("Завершённые"))
		for q in fin:
			dc.add_child(_quest_row(q, "ui_xp_star" if q.s == "done" else "ui_skull", C_GREEN if q.s == "done" else C_RED))
		v.add_child(dc.get_parent())
	var npcs: Array = c.get("npcs", [])
	if npcs.size() > 0:
		var nc := _card()
		nc.add_child(_section_title("Знакомые"))
		for n in npcs:
			var a := int(n.get("a", 0))
			var r := VBoxContainer.new()
			r.add_theme_constant_override("separation", 0)
			var hr := HBoxContainer.new()
			var nl := _label(str(n.n), 22, C_ACCENT)
			nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hr.add_child(nl)
			var hearts := ""
			for k in 3:
				hearts += "♥" if k < a else ("✖" if k < -a else "·")
			var al := _label("%s %s" % [hearts, Game.att_name(a)], 18, C_GREEN if a > 0 else (C_RED if a < 0 else C_MUTED))
			al.autowrap_mode = TextServer.AUTOWRAP_OFF
			hr.add_child(al)
			r.add_child(hr)
			if str(n.d) != "":
				r.add_child(_label(str(n.d), 18, C_MUTED))
			nc.add_child(r)
		v.add_child(nc.get_parent())
	var reps: Dictionary = c.get("rep", {})
	if not reps.is_empty():
		var rc := _card()
		rc.add_child(_section_title("Репутация"))
		for k in reps:
			var val := int(reps[k])
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			row.add_child(_icon_rect(Icons.tex("ui_rep"), 34, C_GREEN if val > 0 else (C_RED if val < 0 else C_MUTED)))
			var kl := _label(str(k), 21, C_INK)
			kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(kl)
			var word := "в почёте" if val >= 3 else ("уважают" if val > 0 else ("враги" if val <= -3 else ("недолюбливают" if val < 0 else "не знают")))
			var vl := _label("%+d · %s" % [val, word], 19, C_GREEN if val > 0 else (C_RED if val < 0 else C_MUTED))
			vl.autowrap_mode = TextServer.AUTOWRAP_OFF
			row.add_child(vl)
			rc.add_child(row)
		v.add_child(rc.get_parent())
	var cps: Array = Game.state.get("companions", [])
	if cps.size() > 0:
		var cc := _card()
		cc.add_child(_section_title("Спутники"))
		for cp in cps:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			row.add_child(_icon_rect(Icons.for_monster(str(R.MONSTERS.get(str(cp.mon), {}).get("name", cp.name))), 40, C_ACCENT))
			var cl := _label("%s — %s · КД %d · %d/%d хитов%s" % [cp.name, cp.kind, int(cp.ac), int(cp.hp), int(cp.max_hp), " · без сил до отдыха" if int(cp.hp) <= 0 else ""], 20, C_INK)
			cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(cl)
			cc.add_child(row)
		cc.add_child(_label("Спутники сами бьются в бою и восстанавливаются после ночлега.", 16, C_MUTED))
		v.add_child(cc.get_parent())
	var ths: Array = c.get("threads", [])
	if ths.size() > 0:
		var tc := _card(C_CARD2)
		tc.add_child(_section_title("Последствия решений"))
		for e in ths:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			row.add_child(_icon_rect(Icons.tex("ui_consequence" if e.s == "open" else "ui_xp_star"), 32, C_ACCENT if e.s == "open" else C_MUTED))
			var tl := _label(str(e.t) + ("" if e.s == "open" else " — уже аукнулось"), 19, C_INK if e.s == "open" else C_MUTED)
			tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(tl)
			tc.add_child(row)
		v.add_child(tc.get_parent())
	if str(c.get("chronicle", "")) != "":
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", UISkin.panel("parchment", 8))
		var pv := VBoxContainer.new()
		var t := _label("Что было раньше", 26, UISkin.INK_PARCHMENT_RED)
		t.add_theme_font_override("font", UISkin.title_font())
		pv.add_child(t)
		var r := _rich(_esc(c.chronicle), 22)
		UISkin.style_parchment_text(r, 22)
		pv.add_child(r)
		p.add_child(pv)
		v.add_child(p)
	_pass_mouse(v)


func _quest_row(q: Dictionary, icon: String, col: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_icon_rect(Icons.tex(icon), 40, col))
	var qv := VBoxContainer.new()
	qv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qv.add_theme_constant_override("separation", 0)
	qv.add_child(_label(str(q.t), 22, C_INK if q.s == "active" else C_MUTED))
	if str(q.get("d", "")) != "" and q.s == "active":
		qv.add_child(_label(str(q.d), 18, C_MUTED))
	row.add_child(qv)
	return row


var choice_pop: Control
var _choice_key := ""


## Новый уровень: окно выбора таланта или +2 к характеристике.
func _check_choice() -> void:
	var h := Game.my_hero()
	var chs: Array = h.get("choices", []) if not h.is_empty() else []
	var busy: bool = Game.phase == "combat" or not Game.state.get("ask", []).is_empty()
	var key := "" if (chs.is_empty() or busy) else JSON.stringify(chs[0])
	if key == _choice_key:
		return
	_choice_key = key
	if choice_pop and is_instance_valid(choice_pop):
		choice_pop.queue_free()
	choice_pop = null
	if key == "":
		return
	var ch: Dictionary = chs[0]
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.03, 0.02, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 24)
	m.add_theme_constant_override("margin_top", 120)
	m.add_theme_constant_override("margin_bottom", 120)
	layer.add_child(m)
	var col := VBoxContainer.new()
	m.add_child(col)
	col.add_child(_expander())
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UISkin.panel("dark", 18))
	col.add_child(panel)
	col.add_child(_expander())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	var pc := CenterContainer.new()
	pc.add_child(UISkin.make_portrait(Icons.tex("ui_level_up"), 110))
	v.add_child(pc)
	var t := _ftitle("%d уровень!" % int(ch.level), 40)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := _label("Выбери +2 к одной характеристике" if ch.kind == "asi" else "Выбери новый талант", 22, C_MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	for opt in ch.options:
		var o: String = opt
		var title := ""
		var desc := ""
		if ch.kind == "asi":
			title = "%s +2" % R.AB_NAME.get(o, o)
			desc = "сейчас %d (мод %+d), станет %d (мод %+d)" % [int(h.scores[o]), R.mod(int(h.scores[o])), mini(20, int(h.scores[o]) + 2), R.mod(mini(20, int(h.scores[o]) + 2))]
		else:
			title = str(R.TALENTS[o].name)
			desc = str(R.TALENTS[o].desc)
		var b := _wrap_button("", C_CARD, func():
			Game.inv("choose", {"pick": o})
			_choice_key = "picked" + o, 21, 110)
		var lbl: Label = b.get_child(b.get_child_count() - 1)
		lbl.text = ""
		var bv := VBoxContainer.new()
		bv.set_anchors_preset(Control.PRESET_FULL_RECT)
		bv.offset_left = 22
		bv.offset_right = -18
		bv.offset_top = 10
		bv.offset_bottom = -12
		bv.alignment = BoxContainer.ALIGNMENT_CENTER
		bv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tl := _label(title, 25, C_ACCENT)
		tl.add_theme_font_override("font", UISkin.title_font())
		bv.add_child(tl)
		bv.add_child(_label(desc, 18, C_INK))
		b.add_child(bv)
		v.add_child(b)
	add_child(layer)
	choice_pop = layer


func _build_sheet(v: VBoxContainer) -> void:
	for c in v.get_children():
		c.queue_free()
	var h := Game.my_hero()
	if h.is_empty():
		v.add_child(_label("Нет героя", 26, C_MUTED))
		return
	var in_combat := Game.phase == "combat"
	var msh := Game.my_shop()
	if not msh.is_empty():
		var sb := _with_icon(_button("В лавке: %s. Нажми вещь в сумке → «Продать». Вернуться к прилавку" % msh.title, C_ACCENT, func():
			tab = "story"
			screen = ""
			overlay.visible = true
			_refresh()), Icons.tex("ui_shop"), 34)
		sb.custom_minimum_size.y = 64
		sb.add_theme_font_size_override("font_size", 17)
		sb.clip_text = true
		v.add_child(sb)
	if not h.get("conds", {}).is_empty():
		var cc := _card(C_CARD)
		for k in h.conds:
			var cr := HBoxContainer.new()
			cr.add_theme_constant_override("separation", 10)
			cr.add_child(_icon_rect(Icons.tex(str(R.CONDS[k].icon)), 40, Color("c8ff8a") if k == "poisoned" else Color("ffb0a0")))
			var cl := _label("%s: %s" % [R.CONDS[k].name, R.CONDS[k].desc], 19, C_INK)
			cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cr.add_child(cl)
			cc.add_child(cr)
		v.add_child(cc.get_parent())

	# --- шапка героя: портрет, имя, опыт, хиты/КД/золото ---
	var head := _card(C_CARD2)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 16)
	hrow.add_child(_portrait(str(h.cls), 120))
	var hv := VBoxContainer.new()
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hv.add_theme_constant_override("separation", 4)
	hv.add_child(_ftitle(str(h.name), 38))
	hv.add_child(_label("%s · %s · %d уровень" % [h.race, h.cls, int(h.level)], 22, C_MUTED))
	var xpb := _bar(int(h.xp), maxi(1, R.xp_next(h)), C_PURPLE, 14)
	hv.add_child(xpb)
	hv.add_child(_label("опыт %d / %d" % [int(h.xp), R.xp_next(h)], 17, C_MUTED))
	hrow.add_child(hv)
	head.add_child(hrow)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 8)
	chips.add_child(_chip("ui_heart", "%d/%d" % [int(h.hp), int(h.max_hp)], C_RED.lightened(0.2)))
	chips.add_child(_chip("ui_shield_ac", "КД %d" % R.ac(h), C_BLUE.lightened(0.3)))
	chips.add_child(_chip("ui_coin", str(int(h.gold)), C_ACCENT))
	chips.add_child(_chip("ui_xp_star", "+%d" % R.prof(int(h.level)), C_PURPLE.lightened(0.3)))
	head.add_child(chips)
	v.add_child(head.get_parent())

	# --- переключатель разделов ---
	var seg := HBoxContainer.new()
	seg.add_theme_constant_override("separation", 6)
	for t in [["gear", "Вещи"], ["stats", "Параметры"], ["magic", "Умения"], ["alchemy", "Алхимия"]]:
		var key: String = t[0]
		var b := _button(t[1], C_ACCENT if sheet_tab == key else C_CARD, func():
			sheet_tab = key
			refs.sheet_key = ""
			_update())
		b.custom_minimum_size = Vector2(0, 58)
		b.add_theme_font_size_override("font_size", 19)
		if sheet_tab == key:
			b.add_theme_color_override("font_color", Color("2a1d08"))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seg.add_child(b)
	v.add_child(seg)

	match sheet_tab:
		"gear": _sheet_gear(v, h, in_combat)
		"stats": _sheet_stats(v, h)
		"alchemy": _sheet_alchemy(v, h, in_combat)
		_: _sheet_magic(v, h, in_combat)


func _count_id(h: Dictionary, id: String) -> int:
	var n := 0
	for it in h.items:
		if str(it.get("id", "")) == id:
			n += 1
	return n


func _sheet_alchemy(v: VBoxContainer, h: Dictionary, in_combat: bool) -> void:
	var intro := _card(C_CARD2)
	var ir := HBoxContainer.new()
	ir.add_theme_constant_override("separation", 12)
	ir.add_child(_icon_rect(Icons.tex("ui_craft"), 56, C_ACCENT))
	var il := _label("Травы, яды и огненная пыль добываются в походе: соберите травы в лесу (Природа, Выживание), снимите железы с пауков, купите у торговца. Варить можно вне боя.", 18, C_MUTED)
	il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ir.add_child(il)
	intro.add_child(ir)
	v.add_child(intro.get_parent())
	for rid in R.RECIPES:
		var rc: Dictionary = R.RECIPES[rid]
		var c := _card(C_CARD)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		row.add_child(_slot_cell({"id": rid}, 84, "", Callable()))
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(_label(str(R.ITEMS[rid].name), 22, C_ACCENT))
		col.add_child(_label(R.item_desc({"id": rid}), 17, C_MUTED))
		var need := []
		var ok := true
		for k in rc.need:
			var have := _count_id(h, k)
			if have < int(rc.need[k]):
				ok = false
			need.append("%s %d/%d" % [R.ITEMS[k].name, have, int(rc.need[k])])
		col.add_child(_label("Нужно: " + ", ".join(need), 17, C_GREEN if ok else C_INK))
		row.add_child(col)
		c.add_child(row)
		var rr: String = rid
		var bt := _small_wide_button("Сварить", C_GREEN.darkened(0.3), func(): Game.inv("craft", {"r": rr}))
		bt.disabled = not ok or in_combat
		c.add_child(bt)
		v.add_child(c.get_parent())


func _sheet_gear(v: VBoxContainer, h: Dictionary, in_combat: bool) -> void:
	# кукла: слоты вокруг портрета
	var doll := _card()
	doll.add_child(_section_title("Надето"))
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 14)
	g.add_theme_constant_override("v_separation", 14)
	var layout := ["amulet", "head", "ring", "weapon", "", "offhand", "clothes", "armor", "*"]
	for slot in layout:
		if slot == "":
			var pc := CenterContainer.new()
			pc.custom_minimum_size = Vector2(150, 150)
			pc.add_child(_portrait(str(h.cls), 140))
			g.add_child(pc)
		elif slot == "*":
			var st := VBoxContainer.new()
			st.alignment = BoxContainer.ALIGNMENT_CENTER
			st.custom_minimum_size = Vector2(150, 150)
			var ai := R.attack_info(h)
			var l1 := _label("КД %d" % R.ac(h), 28, C_BLUE.lightened(0.4))
			l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			st.add_child(l1)
			var l2 := _label("удар %+d\n%s%+d" % [int(ai.atk), R.dice_ru(ai.dice), int(ai.bonus)], 19, C_INK)
			l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			st.add_child(l2)
			g.add_child(st)
		else:
			var it = h.equip.get(slot)
			var has: bool = it is Dictionary and not it.is_empty()
			var s: String = slot
			var cell := _slot_cell(it if has else {}, 150, R.SLOT_NAMES[slot], func():
				if has:
					_show_item(it, -1, s))
			g.add_child(cell)
	var gc := CenterContainer.new()
	gc.add_child(g)
	doll.add_child(gc)
	v.add_child(doll.get_parent())

	# сумка: сетка ячеек
	var bag := _card()
	var bh := HBoxContainer.new()
	var bt := _section_title("Сумка")
	bt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(bt)
	bh.add_child(_chip("ui_coin", str(int(h.gold)), C_ACCENT))
	bag.add_child(bh)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var cells := maxi(15, int(ceil(h.items.size() / 5.0)) * 5)
	for i in cells:
		if i < h.items.size():
			var it: Dictionary = h.items[i]
			var idx: int = i
			grid.add_child(_slot_cell(it, 112, "", func(): _show_item(it, idx, "")))
		else:
			grid.add_child(_slot_cell({}, 112, "", Callable()))
	var gcc := CenterContainer.new()
	gcc.add_child(grid)
	bag.add_child(gcc)
	bag.add_child(_label("Нажми на вещь, чтобы надеть, выпить, отдать или продать.", 18, C_MUTED))
	var partner := _partner()
	if partner != "" and int(h.gold) >= 10 and not in_combat:
		bag.add_child(_small_wide_button("Дать другу 10 золота", C_ACCENT.darkened(0.4), func(): Game.inv("give_gold", {"to": partner, "amount": 10})))
	v.add_child(bag.get_parent())

	if partner != "":
		var ph: Dictionary = Game.state.heroes[partner]
		var pc := _card()
		var prow := HBoxContainer.new()
		prow.add_theme_constant_override("separation", 12)
		prow.add_child(_portrait(str(ph.cls), 72))
		var pv := VBoxContainer.new()
		pv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pv.add_child(_label("%s · %s %s, %d ур." % [ph.name, ph.race, ph.cls, int(ph.level)], 22, C_INK))
		pv.add_child(_bar(int(ph.hp), int(ph.max_hp), C_RED, 14))
		pv.add_child(_label("Хиты %d/%d · КД %d" % [ph.hp, ph.max_hp, R.ac(ph)], 18, C_MUTED))
		prow.add_child(pv)
		pc.add_child(prow)
		v.add_child(pc.get_parent())


func _sheet_stats(v: VBoxContainer, h: Dictionary) -> void:
	var ab := _card()
	ab.add_child(_section_title("Характеристики"))
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 12)
	for a in R.AB:
		var prof_save: bool = a in R.CLASSES[h.cls].saves
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", _style("medal"))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 0)
		var n := _label(str(R.AB_NAME.get(a, a)) if R.AB_NAME is Dictionary else str(a), 17, C_MUTED)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(n)
		var m := _ftitle("%+d" % R.amod(h, a), 40)
		m.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(m)
		var s := _label("%d · спас %+d%s" % [R.score(h, a), R.save_bonus(h, a), " •" if prof_save else ""], 16, C_INK if prof_save else C_MUTED)
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(s)
		cell.add_child(cv)
		g.add_child(cell)
	ab.add_child(g)
	v.add_child(ab.get_parent())

	var sk := _card()
	sk.add_child(_section_title("Навыки"))
	sk.add_child(_label("Золотые — те, которыми герой владеет.", 17, C_MUTED))
	var g2 := GridContainer.new()
	g2.columns = 2
	g2.add_theme_constant_override("h_separation", 10)
	g2.add_theme_constant_override("v_separation", 6)
	for s in R.SKILLS:
		var owned: bool = s in h.skills
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nl := _label(s, 19, C_ACCENT if owned else C_INK)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(nl)
		var bl := _label("%+d" % R.skill_bonus(h, s), 19, C_ACCENT if owned else C_MUTED)
		bl.autowrap_mode = TextServer.AUTOWRAP_OFF
		row.add_child(bl)
		g2.add_child(row)
	sk.add_child(g2)
	v.add_child(sk.get_parent())
	if str(h.about) != "":
		var ac := _card()
		ac.add_child(_section_title("О герое"))
		ac.add_child(_label(str(h.about), 21, C_INK))
		v.add_child(ac.get_parent())


func _sheet_magic(v: VBoxContainer, h: Dictionary, in_combat: bool) -> void:
	var ai := R.attack_info(h)
	var at := _card()
	at.add_child(_section_title("Атака"))
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 12)
	arow.add_child(_icon_rect(Icons.tex("act_attack"), 56, C_ACCENT))
	var av := VBoxContainer.new()
	av.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	av.add_child(_label(str(ai.name), 24, C_INK))
	av.add_child(_label("попадание %+d · урон %s%+d%s" % [int(ai.atk), R.dice_ru(ai.dice), int(ai.bonus), " · две атаки" if int(ai.attacks) > 1 else ""], 19, C_MUTED))
	arow.add_child(av)
	at.add_child(arow)
	v.add_child(at.get_parent())

	var fc := _card()
	fc.add_child(_section_title("Умения класса"))
	var feats = R.CLASSES[h.cls].features
	if not (feats is Array):
		feats = str(feats).split(";" if ";" in str(feats) else ". ", false)
	for f in feats:
		fc.add_child(_label("✦ " + str(f).strip_edges().trim_suffix("."), 20, C_INK))
	for td in R.talent_names(h):
		var tr := VBoxContainer.new()
		tr.add_theme_constant_override("separation", 0)
		tr.add_child(_label("★ " + str(td.name), 21, C_ACCENT))
		tr.add_child(_label(str(td.desc), 17, C_MUTED))
		fc.add_child(tr)
	if h.get("second_wind", false) and not in_combat:
		fc.add_child(_small_wide_button("Второе дыхание (1к10+%d)" % int(h.level), C_GREEN.darkened(0.3), func(): Game.inv("second_wind", {})))
	v.add_child(fc.get_parent())

	var spells := R.known_spells(h)
	if spells.size() > 0:
		var sc := _card()
		sc.add_child(_section_title("Заклинания"))
		sc.add_child(_label("атака %+d · сложность спасброска %d · ячейки: %s" % [R.spell_attack(h), R.spell_dc(h), _slots_text(h)], 18, C_PURPLE.lightened(0.4)))
		for sid in spells:
			var sp: Dictionary = R.SPELLS[sid]
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			row.add_child(_icon_rect(Icons.tex("act_spell"), 40, C_PURPLE.lightened(0.4)))
			var sv := VBoxContainer.new()
			sv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sv.add_child(_label("%s · %s" % [sp.name, "заговор" if int(sp.lvl) == 0 else "%d круг" % int(sp.lvl)], 21, C_INK))
			sv.add_child(_label(str(sp.desc), 17, C_MUTED))
			row.add_child(sv)
			sc.add_child(row)
			if sp.kind == "heal" and not in_combat and R.slot_for(h, sid) >= 0:
				for n in Game.state.heroes:
					var tn: String = n
					sc.add_child(_small_wide_button("Лечить: %s" % Game.state.heroes[n].name, C_PURPLE.darkened(0.3), func(): Game.inv("cast", {"spell": sid, "target": tn})))
		v.add_child(sc.get_parent())


# ---------- элементы листа героя ----------

func _rarity_color(it: Dictionary) -> Color:
	var d := R.item_def(it)
	if d.get("magic", false):
		return C_PURPLE.lightened(0.35)
	if int(d.get("price", 0)) >= 50:
		return C_BLUE.lightened(0.35)
	return C_ACCENT


func _slot_cell(it: Dictionary, size: int, placeholder: String, cb: Callable) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(size, size)
	b.focus_mode = Control.FOCUS_NONE
	var kind := "slot"
	if not it.is_empty():
		var rc := _rarity_color(it)
		kind = "slot_rare" if rc == C_PURPLE.lightened(0.35) else ("slot_magic" if rc == C_BLUE.lightened(0.35) else "slot")
	for s in ["normal", "hover", "pressed", "disabled"]:
		b.add_theme_stylebox_override(s, _style(kind))
	if not it.is_empty():
		var t := _icon_rect(Icons.for_item(it), int(size * 0.62), _rarity_color(it))
		t.set_anchors_preset(Control.PRESET_FULL_RECT)
		t.size_flags_vertical = Control.SIZE_FILL
		b.add_child(t)
	elif placeholder != "":
		var l := _label(placeholder, 17, Color(C_MUTED, 0.55))
		l.set_anchors_preset(Control.PRESET_FULL_RECT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(l)
	if cb.is_valid():
		b.pressed.connect(cb)
	else:
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


func _chip(icon: String, text: String, color: Color) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style("chip"))
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	r.add_child(_icon_rect(Icons.tex(icon), 26, color))
	var tl := _label(text, 20, C_INK)
	tl.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.add_child(tl)
	p.add_child(r)
	return p


func _bar(val: int, maxv: int, color: Color, h := 16) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, h)
	bar.max_value = maxi(1, maxv)
	bar.value = clampi(val, 0, maxi(1, maxv))
	UISkin.style_bar(bar, "xp" if _kind(color) in ["gold", "purple", "blue"] else "hp")
	bar.custom_minimum_size = Vector2(0, maxi(h, 26))
	return bar


func _portrait(cls: String, size: int) -> Control:
	return UISkin.make_portrait(Icons.for_class(cls), size)


func _section_title(text: String) -> Label:
	return _ftitle(text, 28)


func _ftitle(text: String, size := 34) -> Label:
	var l := _label(text, size, C_ACCENT)
	return UISkin.style_title(l, size)


func _style(kind: String) -> StyleBox:
	match kind:
		"slot", "slot_magic", "slot_rare", "slot_legend":
			return UISkin.panel(kind, 0)
		"chip":
			var c := UISkin.panel("inset", 4)
			c.content_margin_top = 6
			c.content_margin_bottom = 6
			return c
		"medal":
			return UISkin.panel("inset", 6)
		"popup":
			return UISkin.panel("dark", 18)
	return UISkin.panel("dark")


# ---------- карточка предмета ----------

func _show_item(it: Dictionary, idx: int, slot: String) -> void:
	_close_item()
	var h := Game.my_hero()
	var in_combat := Game.phase == "combat"
	var my_turn := Game.combat_actor() == Game.my_pname()
	var can_manage := not in_combat or my_turn
	var partner := _partner()
	var shop_open: bool = not Game.my_shop().is_empty()
	var d := R.item_def(it)
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			_close_item())
	layer.add_child(dim)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style("popup"))
	# ширина задаётся полями экрана: у PanelContainer по центру с переносом строк
	# высота пересчитывалась по кругу и карточка росла при каждом нажатии
	var pm := MarginContainer.new()
	pm.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		pm.add_theme_constant_override("margin_" + side, 34)
	pm.add_theme_constant_override("margin_top", 80)
	pm.add_theme_constant_override("margin_bottom", 80)
	pm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pcol := VBoxContainer.new()
	pcol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pcol.add_child(_expander())
	pcol.add_child(panel)
	pcol.add_child(_expander())
	pm.add_child(pcol)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	top.add_child(_slot_cell(it, 120, "", Callable()))
	var tv := VBoxContainer.new()
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := _ftitle(R.item_name(it), 32)
	nm.add_theme_color_override("font_color", _rarity_color(it))
	tv.add_child(nm)
	var kind_txt: String = str({"weapon": "Оружие", "armor": "Доспех", "shield": "Щит", "clothes": "Одежда", "head": "Головной убор",
		"ring": "Кольцо", "amulet": "Амулет", "potion": "Зелье", "scroll": "Свиток", "reagent": "Ингредиент", "coat": "Яд", "bomb": "Бомба"}.get(str(d.get("type", "")), "Вещь"))
	if d.get("magic", false):
		kind_txt += " · волшебное"
	tv.add_child(_label(kind_txt, 19, C_MUTED))
	top.add_child(tv)
	v.add_child(top)
	if R.item_desc(it) != "":
		v.add_child(_label(R.item_desc(it), 22, C_INK))
	if str(it.get("note", "")) != "":
		v.add_child(_label(str(it.note), 20, C_MUTED))
	v.add_child(_label("Цена: %d зол." % R.item_price(it), 19, C_MUTED))
	var acts := VBoxContainer.new()
	acts.add_theme_constant_override("separation", 8)
	var close_then := func(cb: Callable) -> Callable:
		return func():
			_close_item()
			cb.call()
	if slot != "":
		if can_manage:
			acts.add_child(_small_wide_button("Снять", C_CARD2, close_then.call(func(): Game.inv("unequip", {"slot": slot}))))
	else:
		if R.item_slot(it) != "" and can_manage:
			acts.add_child(_small_wide_button("Надеть", C_BLUE, close_then.call(func(): Game.inv("equip", {"idx": idx}))))
		if d.type == "coat" and not in_combat:
			acts.add_child(_small_wide_button("Нанести на оружие", C_GREEN.darkened(0.25), close_then.call(func(): Game.inv("use", {"idx": idx}))))
		if d.type == "potion" and not in_combat:
			acts.add_child(_small_wide_button("Выпить", C_GREEN.darkened(0.25), close_then.call(func(): Game.inv("use", {"idx": idx}))))
			if partner != "":
				acts.add_child(_small_wide_button("Напоить друга", C_GREEN.darkened(0.4), close_then.call(func(): Game.inv("use", {"idx": idx, "target": partner}))))
		if partner != "" and not in_combat:
			acts.add_child(_small_wide_button("Отдать другу", C_CARD2, close_then.call(func(): Game.inv("give", {"idx": idx, "to": partner}))))
		if shop_open:
			acts.add_child(_small_wide_button("Продать за %d зол." % maxi(1, R.item_price(it) / 2), C_ACCENT.darkened(0.3), close_then.call(func(): Game.inv("sell", {"idx": idx}))))
		elif not in_combat:
			acts.add_child(_small_wide_button("Выбросить", C_RED.darkened(0.45), close_then.call(func(): Game.inv("drop", {"idx": idx}))))
	if in_combat and not my_turn:
		acts.add_child(_label("В бою вещами можно пользоваться только в свой ход.", 18, C_MUTED))
	acts.add_child(_small_wide_button("Закрыть", C_CARD, func(): _close_item()))
	v.add_child(acts)
	panel.add_child(v)
	layer.add_child(pm)
	add_child(layer)
	item_pop = layer


func _close_item() -> void:
	if item_pop and is_instance_valid(item_pop):
		item_pop.queue_free()
	item_pop = null


# ---------- сундук и лавка ----------

func _update_overlay() -> void:
	var loot: Dictionary = Game.state.get("loot", {}) if Net.is_online() else {}
	var shop: Dictionary = Game.my_shop() if Net.is_online() else {}
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
	panel.get_parent().add_theme_stylebox_override("panel", UISkin.panel("dark", 14))
	m.add_child(panel.get_parent())
	var scroll := _scroll()
	var inner: VBoxContainer = scroll.get_child(0)
	if not loot.is_empty():
		panel.add_child(UISkin.make_ribbon_title(str(loot.title), 30, 80))
		for i in loot.items.size():
			var it: Dictionary = loot.items[i]
			var idx: int = i
			var d := R.item_def(it)
			var c := _card(Color("2b2547"))
			var lrow := HBoxContainer.new()
			lrow.add_theme_constant_override("separation", 10)
			lrow.add_child(_slot_cell(it, 88, "", Callable()))
			var ll := _label(R.item_name(it), 26, _rarity_color(it))
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
	panel.add_child(UISkin.make_ribbon_title(str(shop.title), 30, 80))
	panel.add_child(_label("Твоё золото: %d. Продать можно из сумки на вкладке «Герой»." % int(h.get("gold", 0)), 20, C_MUTED))
	var att := int(shop.get("att", 0))
	if att != 0:
		panel.add_child(_label("%s относится к вам: %s — цены %s на %d%%." % [shop.title, Game.att_name(att), "ниже" if att > 0 else "выше", absi(att) * 8], 19, C_GREEN if att > 0 else C_RED))
	for i in shop.items.size():
		var it: Dictionary = shop.items[i]
		var idx: int = i
		var price := Game.shop_price(it)
		var c := _card(Color("2b2547"))
		var srow := HBoxContainer.new()
		srow.add_theme_constant_override("separation", 10)
		srow.add_child(_slot_cell(it, 80, "", Callable()))
		var sl := _label("%s\n%d зол." % [R.item_name(it), price], 24, _rarity_color(it))
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
	_apply_follow()


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


# ---------- чат и уведомления ----------

var _chat_seen := -1
var _chat_pop: Control = null
var _chat_n_shown := -1
var _seen_pending := []
var _seen_vote := ""
var _notice: Control = null


func _chat_unread() -> int:
	var n := 0
	for m in Game.state.get("chat", []):
		if int(m.n) > _chat_seen and str(m.p) != Game.my_pname():
			n += 1
	return n


## Заметные уведомления на экране истории: сообщение в чате, напарник уже выбрал действие, голосование.
func _check_notices() -> void:
	if screen != "game":
		return
	var chat: Array = Game.state.get("chat", [])
	if _chat_seen < 0:
		_chat_seen = int(chat[-1].n) if chat.size() > 0 else 0
	var last_n := int(chat[-1].n) if chat.size() > 0 else 0
	if _chat_pop != null and is_instance_valid(_chat_pop):
		_chat_seen = last_n
	elif chat.size() > 0 and int(chat[-1].n) > int(refs.get("chat_notified", _chat_seen)):
		refs.chat_notified = int(chat[-1].n)
		var m: Dictionary = chat[-1]
		if str(m.p) != Game.my_pname():
			_show_notice("ui_chat", "%s пишет:" % m.w, str(m.t), func(): _open_chat())
			_sfx("page", -4.0)
	if refs.has("chat_btn") and is_instance_valid(refs.chat_btn):
		var u := _chat_unread()
		refs.chat_btn.text = "Чат" + (" (%d)" % u if u > 0 else "")
		refs.chat_btn.modulate = Color(1.3, 1.15, 0.7) if u > 0 else Color.WHITE
	var me := Game.my_pname()
	var pend: Array = Game.state.get("pending", [])
	if Game.phase == "play" and not (me in pend):
		for n in pend:
			if str(n) != me and not (n in _seen_pending) and Game.state.heroes.has(n):
				var hn := str(Game.state.heroes[n].name)
				_show_notice("ui_hero", "%s сделал(а) ход" % hn, "Действие выбрано. Ждём тебя, чтобы ведущий продолжил.", Callable())
	_seen_pending = pend.duplicate()
	var v: Dictionary = Game.state.get("vote", {})
	var vk := str(v.get("q", ""))
	if vk != "" and vk != _seen_vote and str(v.get("by", "")) != me:
		_show_notice("ui_vote", "Голосование", vk, Callable())
	_seen_vote = vk


func _show_notice(icon: String, title: String, text: String, cb: Callable) -> void:
	if _notice != null and is_instance_valid(_notice):
		_notice.queue_free()
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UISkin.panel("popup", 12))
	p.set_anchors_preset(Control.PRESET_TOP_WIDE)
	p.offset_left = 22
	p.offset_right = -22
	p.offset_top = 236
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_icon_rect(Icons.tex(icon), 52, C_ACCENT))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 2)
	col.add_child(_label(title, 22, C_ACCENT))
	var tl := _label(text.left(160), 21, C_INK)
	col.add_child(tl)
	if cb.is_valid():
		col.add_child(_label("Нажми, чтобы открыть", 15, C_MUTED))
	row.add_child(col)
	p.add_child(row)
	p.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			if is_instance_valid(p):
				p.queue_free()
			if cb.is_valid():
				cb.call())
	add_child(p)
	_notice = p
	p.modulate.a = 0.0
	var tw := p.create_tween()
	tw.tween_property(p, "modulate:a", 1.0, 0.25)
	tw.tween_interval(6.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.6)
	tw.tween_callback(func():
		if is_instance_valid(p):
			p.queue_free())


func _open_chat() -> void:
	if _chat_pop != null and is_instance_valid(_chat_pop):
		return
	if _notice != null and is_instance_valid(_notice):
		_notice.queue_free()
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", 8)
	m.add_theme_constant_override("margin_right", 8)
	m.add_theme_constant_override("margin_top", 150)
	m.add_theme_constant_override("margin_bottom", 4)
	layer.add_child(m)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style("popup"))
	m.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var top := HBoxContainer.new()
	top.add_child(_icon_rect(Icons.tex("ui_chat"), 40, C_ACCENT))
	var tl := _label("Чат игроков", 28, C_ACCENT)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl.autowrap_mode = TextServer.AUTOWRAP_OFF
	top.add_child(tl)
	top.add_child(_tiny_button("✕", C_CARD2, func(): _close_chat()))
	v.add_child(top)
	v.add_child(_label("Ведущий этого не видит: договаривайтесь между собой.", 16, C_MUTED))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	sc.add_child(list)
	v.add_child(sc)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var le := LineEdit.new()
	le.placeholder_text = "Написать напарнику…"
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size.y = 64
	le.max_length = 300
	var send := func():
		if le.text.strip_edges() != "":
			Game.send_chat(le.text)
			le.text = ""
	le.text_submitted.connect(func(_t): send.call())
	row.add_child(le)
	var sb := _button("➤", C_ACCENT, send)
	sb.custom_minimum_size = Vector2(90, 64)
	row.add_child(sb)
	v.add_child(row)
	# в корневых полях: поднимается вместе с клавиатурой
	root_margin.add_child(layer)
	_chat_pop = layer
	refs.chat_list = list
	refs.chat_scroll = sc
	_chat_n_shown = -1
	_update_chat()


func _close_chat() -> void:
	if _chat_pop != null and is_instance_valid(_chat_pop):
		_chat_pop.queue_free()
	_chat_pop = null
	refs.erase("chat_list")
	DisplayServer.virtual_keyboard_hide()
	_check_notices()


func _update_chat() -> void:
	if _chat_pop == null or not is_instance_valid(_chat_pop) or not refs.has("chat_list"):
		return
	var chat: Array = Game.state.get("chat", [])
	var last := int(chat[-1].n) if chat.size() > 0 else 0
	_chat_seen = last
	if last == _chat_n_shown:
		return
	_chat_n_shown = last
	var list: VBoxContainer = refs.chat_list
	for ch in list.get_children():
		ch.queue_free()
	if chat.is_empty():
		list.add_child(_label("Пока пусто. Напиши напарнику план или шутку.", 19, C_MUTED))
	for msg in chat.slice(-60):
		var mine := str(msg.p) == Game.my_pname()
		var pc := PanelContainer.new()
		pc.add_theme_stylebox_override("panel", UISkin.panel("inset" if mine else "dark", 10))
		var r := _rich("[color=#%s]%s:[/color] %s" % [(C_GREEN if mine else C_ACCENT).to_html(false), _esc(str(msg.w)), _esc(str(msg.t))], 21)
		pc.add_child(r)
		_pass_mouse(pc)
		list.add_child(pc)
	var sc: ScrollContainer = refs.chat_scroll
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(sc):
		sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)


func _toast(text: String) -> void:
	toast.text = text
	toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(2.2)
	tw.tween_property(toast, "modulate:a", 0.0, 0.5)


func _load_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		tts_on = bool(cfg.get_value("player", "tts", true))
		var n := str(cfg.get_value("player", "name", ""))
		if n != "":
			return n
	return NAMES[randi() % NAMES.size()]


func _save_name() -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("player", "name", Net.my_name)
	cfg.set_value("player", "tts", tts_on)
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
	font_bold = UISkin.body_font()
	font_black = UISkin.title_font()
	font_title = UISkin.title_font()


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
	UISkin.apply_theme(t)
	return t


func _label(text: String, size := 26, color := C_INK) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if size >= 34 and font_black:
		l.add_theme_font_override("font", font_black)
		l.add_theme_color_override("font_outline_color", UISkin.OUTLINE)
		l.add_theme_constant_override("outline_size", 5)
	return l


func _rich(bb: String, size := 24) -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_font_size_override("normal_font_size", size)
	l.text = bb
	return l


func _esc(s) -> String:
	return str(s).replace("[", "(").replace("]", ")")


func _title(text: String) -> Label:
	var l := _label(text, 46, C_ACCENT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return UISkin.style_title(l, 46)


func _kind(c: Color) -> String:
	if c.s < 0.3 or c.v < 0.3:
		return "dark"
	var hue := c.h * 360.0
	if hue < 18.0 or hue >= 330.0:
		return "red"
	if hue < 70.0:
		return "gold"
	if hue < 175.0:
		return "green"
	if hue < 250.0:
		return "blue"
	return "purple"


func _button(text: String, color: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 88)
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.focus_mode = Control.FOCUS_NONE
	UISkin.style_button(b, _kind(color), 28)
	b.add_theme_constant_override("icon_max_width", 40)
	b.add_theme_constant_override("h_separation", 10)
	if cb.is_valid():
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
		var sb: StyleBox = b.get_theme_stylebox(s).duplicate()
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 4
		sb.content_margin_bottom = 6
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
func _wrap_button(text: String, color: Color, cb: Callable, font := 22, h := 72, text_color := Color.TRANSPARENT) -> Button:
	var b := _button("", color, cb)
	if text_color == Color.TRANSPARENT:
		text_color = UISkin.button_font_color(_kind(color))
	b.custom_minimum_size = Vector2(0, h)
	b.clip_contents = true
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", text_color)
	l.add_theme_font_override("font", UISkin.body_font())
	if _kind(color) != "gold":
		l.add_theme_color_override("font_outline_color", UISkin.OUTLINE)
		l.add_theme_constant_override("outline_size", 3)
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
	var kind := "dark"
	if color == C_CARD2:
		kind = "dark_plain"
	elif color != C_CARD:
		kind = "inset"
	p.add_theme_stylebox_override("panel", UISkin.panel(kind, 10 if kind == "dark" else 14))
	p.mouse_filter = Control.MOUSE_FILTER_PASS
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
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ---------- автотест (ALIBI_AUTOTEST=host|client вместе с ALIBI_MOCK=1) ----------

var _auto := ""
var _auto_n := 0


func _autotest_setup() -> void:
	var ms := OS.get_environment("ALIBI_MENUSHOT")
	if ms != "":
		await get_tree().create_timer(1.5).timeout
		get_viewport().get_texture().get_image().save_png(ms)
		get_tree().quit()
		return
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


var _drag_done := false


func _drag_test() -> void:
	# ALIBI_DRAGTEST=1: проверка, что историю можно листать пальцем поверх карточек
	var sc: ScrollContainer = refs.log_scroll
	var before := sc.scroll_vertical
	var p0 := Vector2(360, sc.global_position.y + sc.size.y * 0.3)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = p0
	ev.global_position = p0
	Input.parse_input_event(ev)
	for k in 12:
		await get_tree().process_frame
		var mv := InputEventMouseMotion.new()
		mv.position = p0 + Vector2(0, 25 * (k + 1))
		mv.global_position = mv.position
		mv.relative = Vector2(0, 25)
		mv.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(mv)
	var up := ev.duplicate()
	up.pressed = false
	up.position = p0 + Vector2(0, 300)
	Input.parse_input_event(up)
	await get_tree().create_timer(0.5).timeout
	print("[%s] DRAGTEST before=%d after=%d max=%d touch=%s" % [_auto, before, sc.scroll_vertical, int(sc.get_v_scroll_bar().max_value), DisplayServer.is_touchscreen_available()])


func _autotest_tick() -> void:
	if _auto == "":
		return
	if OS.get_environment("ALIBI_DRAGTEST") != "" and not _drag_done and screen == "game" and tab == "story" and int(Game.state.turn) >= 9 and refs.has("log_scroll"):
		_drag_done = true
		_drag_test()
	_auto_n += 1
	if _auto_n > 1000:
		print("[%s] AUTOTEST TIMEOUT" % _auto)
		get_tree().quit(1)
		return
	var me := Game.my_pname()
	var shot := OS.get_environment("ALIBI_SHOT")
	if shot != "" and _auto_n % 2 == 0 and not (tab == "sheet" and dice.visible):
		get_viewport().get_texture().get_image().save_png("%s/%s_%03d_%s_%s.png" % [shot, _auto, _auto_n, Game.phase, tab])
		if screen == "game":
			var want := "story"
			if int(Game.state.turn) in [3, 4, 5, 6] and Game.phase != "combat":
				want = "sheet"
				var st: String = ["gear", "stats", "magic", "alchemy"][int(Game.state.turn) - 3]
				if st != sheet_tab:
					sheet_tab = st
					refs.erase("sheet_key")
					screen = ""
					_refresh()
				if st == "gear" and item_pop == null and not Game.my_hero().items.is_empty() and _auto_n % 6 == 0:
					_show_item(Game.my_hero().items[0], 0, "")
				elif st != "gear":
					_close_item()
			elif int(Game.state.turn) in [7, 8] and Game.phase != "combat":
				want = "journal"
			elif int(Game.state.turn) == 9 and Game.phase != "combat":
				want = "map"
			if want != tab:
				tab = want
				screen = ""
				_refresh()
	for a in Game.state.get("ask", []):
		if str(a.who) == me and not a.done:
			Game.roll_now()
			return
	var mh := Game.my_hero()
	if shot != "" and _auto == "host" and not mh.is_empty() and int(Game.state.turn) == 2 and not mh.has("talents") and not mh.has("choices"):
		mh.choices = [R.make_choice(mh)]
		Game._broadcast()
	if not mh.is_empty() and not (mh.get("choices", []) as Array).is_empty() and _auto_n % 7 == 0:
		print("[%s] CHOOSE %s" % [_auto, mh.choices[0].options[0]])
		Game.inv("choose", {"pick": str(mh.choices[0].options[0])})
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
			if not Game.my_shop().is_empty():
				Game.inv("buy", {"idx": 0})
				Game.inv("shop_close", {})
				return
			if not Game.state.get("vote", {}).is_empty():
				if not Game.state.vote.votes.has(me):
					Game.vote("pick", {"pick": 0 if _auto == "host" else 1})
				return
			if _auto == "client" and int(Game.state.turn) == 2 and not refs.has("auto_chat"):
				refs.auto_chat = true
				Game.send_chat("Давай я отвлеку, а ты бей!")
			if _auto == "host" and int(Game.state.turn) == 5 and not refs.has("auto_rest"):
				refs.auto_rest = true
				Game.vote("start", {"kind": "rest_long"})
				return
			if _count_id(Game.my_hero(), "herb") >= 2:
				Game.inv("craft", {"r": "potion_heal"})
			if Game.my_hero().items.size() > 0 and _auto_n % 5 == 0:
				Game.inv("equip", {"idx": 0})
			if not (me in Game.state.pending):
				var opts: Array = Game.state.options.get(me, [])
				if _auto == "host" and opts.size() > 1 and opts[1] is Dictionary:
					Game.submit_action(str(opts[1].t), "", 1)
				elif _auto == "client" and int(Game.state.turn) % 3 == 0:
					Game.submit_action("Помогаю напарнику", _partner())
				else:
					Game.submit_action("Осматриваюсь (%s, ход %d)" % [_auto, Game.state.turn])
			if int(Game.state.turn) >= 12:
				print("[%s] AUTOTEST DONE turn=%d heroes=%s" % [_auto, Game.state.turn, JSON.stringify(Game.state.heroes)])
				print("[%s] MAP %s" % [_auto, JSON.stringify(Game.state.map)])
				for e in Game.state.log.slice(-40):
					print("[%s] LOG %s: %s" % [_auto, e.k, e.t])
				_auto = ""
				if Net.is_host():
					await get_tree().create_timer(4.0).timeout
				get_tree().quit()
		"combat":
			if Game.combat_actor() == me:
				var h := Game.my_hero()
				if int(Game.state.combat.round) == 2 and not Game.state.combat.get("moved", {}).get(me, false) and _auto_n % 2 == 0:
					Game.combat_action({"t": "move"})
					return
				if h.cls == "Маг" and R.slot_for(h, "magic_missile") > 0:
					if not _combat_menu.begins_with("spell"):
						_combat_menu = "spell:magic_missile"
						_bottom_key = ""
						_update_bottom()
						return
					_combat_menu = ""
					Game.combat_action({"t": "spell", "spell": "magic_missile", "target": -1})
				elif _auto_n % 7 == 0:
					Game.combat_action({"t": "free", "text": "Пинаю гоблина в костёр"})
				else:
					Game.combat_action({"t": "attack", "target": -1})
