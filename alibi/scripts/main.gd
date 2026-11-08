extends Control
## Весь интерфейс «Алиби». Экран перестраивается при смене фазы, внутри фазы обновляются только
## нужные виджеты (чтобы не сбивать набранный текст).

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

const NAMES := ["Шнырь", "Барсук", "Кучер", "Пломбир", "Тапок", "Сухарь", "Шпрота", "Кнопка", "Пельмень", "Бублик"]

var font_bold: Font
var font_black: Font
var root_margin: MarginContainer
var content: VBoxContainer
var toast: Label
var screen := ""
var refs := {}
var local_screen := "menu"   # menu / search, пока не в комнате
var error_text := ""
var _dots_t := 0.0


func _ready() -> void:
	get_tree().set_quit_on_go_back(false)
	_load_fonts()
	theme = _make_theme()
	add_child(_make_bg())
	root_margin = MarginContainer.new()
	root_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "bottom"]:
		root_margin.add_theme_constant_override("margin_" + side, 22)
	root_margin.add_theme_constant_override("margin_top", 44)
	add_child(root_margin)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	root_margin.add_child(content)
	toast = _label("", 24, C_INK)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	toast.position = Vector2(40, 1120)
	toast.size = Vector2(640, 60)
	toast.modulate.a = 0.0
	add_child(toast)

	Net.my_name = _load_name()
	Game.state_changed.connect(_refresh)
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
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and not Net.is_online() and local_screen == "search":
		Net.stop_search()
		local_screen = "menu"
		_refresh()


# ---------- навигация ----------

func _screen_key() -> String:
	if not Net.is_online():
		return local_screen
	if not Net.is_host() and not Net.players.has(Net.my_id()):
		return "connecting"
	var p := Game.phase
	if p in ["question", "judging", "verdict"]:
		return "%s%d" % [p, int(Game.state.round)]
	return p


func _refresh() -> void:
	var k := _screen_key()
	if k != screen:
		screen = k
		_build()
	_update()


func _build() -> void:
	for c in content.get_children():
		c.queue_free()
	refs = {}
	var k := screen.rstrip("0123456789")
	match k:
		"menu": _build_menu()
		"search": _build_search()
		"connecting": _build_connecting()
		"lobby": _build_lobby()
		"loading": _build_wait("Следователь заводит дело")
		"plot": _build_plot()
		"question": _build_question()
		"judging": _build_judging()
		"verdict": _build_verdict()
		"final": _build_wait("Следователь выносит решение")
		"end": _build_end()


func _leave() -> void:
	Net.stop()
	Net.stop_search()
	Game.reset_local()
	local_screen = "menu"
	_refresh()


# ---------- экраны ----------

func _build_menu() -> void:
	content.add_child(_spacer(40))
	var t := _label("АЛИБИ", 96, C_ACCENT)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(t)
	var st := _label("Кооперативный допрос с нейронкой", 28, C_MUTED)
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(st)
	content.add_child(_spacer(20))

	var card := _card()
	card.add_child(_label("Твоя кличка", 24, C_MUTED))
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

	var help := _label("Как играть: нейронка придумывает нелепое преступление и становится следователем. "
		+ "Вы банда подозреваемых. Сначала две минуты на сговор в общем чате, потом допрос: "
		+ "все тайно отвечают на один и тот же вопрос, а следователь ищет нестыковки. "
		+ "Подозрение дошло до 100 — попались. Продержались 6 вопросов — свободны.\n\n"
		+ "Все телефоны должны быть в одной Wi-Fi сети (или подключены к точке доступа хоста). "
		+ "Ключ ИИ нужен только тому, кто создаёт комнату.", 22, C_MUTED)
	content.add_child(help)


func _build_search() -> void:
	content.add_child(_title("Комнаты рядом"))
	var card := _card()
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 10)
	card.add_child(list)
	refs.rooms = list
	refs.rooms_sig = ""
	content.add_child(card.get_parent())

	var c2 := _card()
	c2.add_child(_label("Не видно комнаты? Проверь, что телефоны в одной сети, или введи IP, который показан у хоста:", 22, C_MUTED))
	var row := HBoxContainer.new()
	var ip := LineEdit.new()
	ip.placeholder_text = "192.168.0.10"
	ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	row.add_child(ip)
	var go := _small_button("Войти", C_BLUE, func(): _join(ip.text))
	row.add_child(go)
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


func _build_connecting() -> void:
	content.add_child(_expander())
	var l := _label("Подключаемся", 40, C_INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refs.dots = l
	refs.dots_text = "Подключаемся"
	content.add_child(l)
	content.add_child(_expander())
	content.add_child(_button("Отмена", C_CARD2, _leave))


func _build_lobby() -> void:
	content.add_child(_title("Комната"))
	if Net.is_host():
		var ips := Net.local_ips()
		var ip_text := "Твой IP для ручного входа: " + (", ".join(ips) if ips.size() > 0 else "не найден (нет Wi-Fi?)")
		content.add_child(_label(ip_text, 22, C_MUTED))
	var card := _card()
	card.add_child(_label("Банда", 24, C_MUTED))
	var pl := _label("", 30, C_INK)
	refs.players = pl
	card.add_child(pl)
	content.add_child(card.get_parent())
	var err := _label("", 24, C_RED)
	refs.err = err
	content.add_child(err)
	_add_chat("Можно поболтать, пока ждёте")
	if Net.is_host():
		var b := _button("", C_ACCENT, func():
			if not LLM.has_key():
				_paste_key()
				_update()
			else:
				Game.start_game())
		refs.start = b
		content.add_child(b)
	else:
		var w := _label("Ждём, пока хост начнёт дело", 26, C_MUTED)
		w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		content.add_child(w)
	content.add_child(_button("Выйти", C_CARD2, _leave))


func _build_wait(text: String) -> void:
	content.add_child(_expander())
	var l := _label(text, 40, C_INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refs.dots = l
	refs.dots_text = text
	content.add_child(l)
	content.add_child(_expander())
	content.add_child(_button("Выйти", C_CARD2, _leave))


func _case_card() -> void:
	var c: Dictionary = Game.state.case
	var card := _card(C_CARD2)
	card.add_child(_label(str(c.get("title", "")), 38, C_ACCENT))
	card.add_child(_label(str(c.get("crime", "")), 26, C_INK))
	card.add_child(_label("Ведёт дело: " + str(c.get("detective", "")), 22, C_MUTED))
	content.add_child(card.get_parent())


func _build_plot() -> void:
	var top := HBoxContainer.new()
	top.add_child(_label("Сговор", 40, C_INK))
	top.add_child(_expander_h())
	var tl := _label("", 36, C_ACCENT)
	refs.timer = tl
	top.add_child(tl)
	content.add_child(top)
	_case_card()
	var hint := str(Game.state.case.get("hint", ""))
	content.add_child(_label("Договоритесь об общей легенде. Во время допроса шептаться будет нельзя! " + hint, 22, C_MUTED))
	_add_chat("Где мы были? Что ели? Кто платил?")
	var b := _button("", C_GREEN, func():
		Game.press_ready()
		refs.ready_btn.disabled = true)
	refs.ready_btn = b
	refs.ready_label = "Мы готовы"
	content.add_child(b)


func _round_header() -> void:
	var top := HBoxContainer.new()
	top.add_child(_label("Вопрос %d из %d" % [int(Game.state.round), int(Game.state.rounds)], 34, C_INK))
	top.add_child(_expander_h())
	var tl := _label("", 36, C_ACCENT)
	refs.timer = tl
	top.add_child(tl)
	content.add_child(top)
	content.add_child(_suspicion_bar())


func _suspicion_bar() -> Control:
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	row.add_child(_label("Подозрение", 22, C_MUTED))
	row.add_child(_expander_h())
	var v := _label("%d / 100" % int(Game.state.suspicion), 22, C_INK)
	row.add_child(v)
	box.add_child(row)
	var bar := ProgressBar.new()
	bar.max_value = 100
	bar.value = int(Game.state.suspicion)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 26)
	var bg := _box(C_CARD, 13)
	var fg := _box(C_RED.lerp(C_ACCENT, 1.0 - bar.value / 100.0), 13)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)
	box.add_child(bar)
	return box


func _detective_says(text: String, color := C_CARD2) -> void:
	var card := _card(color)
	card.add_child(_label(str(Game.state.case.get("detective", "Следователь")), 22, C_ACCENT))
	card.add_child(_label(text, 32, C_INK))
	content.add_child(card.get_parent())


func _build_question() -> void:
	_round_header()
	_detective_says(str(Game.state.question))
	var answered: bool = Net.my_id() in Game.state.answered
	if not answered:
		content.add_child(_label("Отвечай тайно: остальные твой ответ не видят.", 22, C_MUTED))
		var input := TextEdit.new()
		input.placeholder_text = "Твой ответ…"
		input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		input.custom_minimum_size = Vector2(0, 170)
		content.add_child(input)
		var send := func():
			Game.send_answer(input.text)
			DisplayServer.virtual_keyboard_hide()
		content.add_child(_button("Ответить", C_ACCENT, send))
		refs.answer_input = input
	else:
		var l := _label("Ответ записан. Ждём остальных…", 28, C_GREEN)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		content.add_child(l)
	var w := _label("", 24, C_MUTED)
	w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refs.answered = w
	content.add_child(w)
	content.add_child(_expander())


func _build_judging() -> void:
	_round_header()
	_detective_says(str(Game.state.question), C_CARD)
	content.add_child(_expander())
	var l := _label("Следователь сверяет показания", 34, C_INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refs.dots = l
	refs.dots_text = "Следователь сверяет показания"
	content.add_child(l)
	content.add_child(_expander())


func _build_verdict() -> void:
	_round_header()
	var h: Dictionary = Game.state.history[-1] if Game.state.history.size() > 0 else {}
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 12)
	scroll.add_child(inner)

	var delta := int(h.get("delta", 0))
	var dl := _label(("+%d подозрения" % delta) if delta > 0 else ("%d подозрения" % delta), 36, C_RED if delta > 0 else C_GREEN)
	dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(dl)

	var qc := _card(C_CARD)
	qc.add_child(_label(str(h.get("q", "")), 24, C_MUTED))
	var answers: Dictionary = h.get("answers", {})
	for n in answers:
		var row := _label("", 26, C_INK)
		row.text = "%s: %s" % [n, answers[n]]
		qc.add_child(row)
	inner.add_child(qc.get_parent())

	var dc := _card(C_CARD2)
	dc.add_child(_label(str(Game.state.case.get("detective", "Следователь")), 22, C_ACCENT))
	dc.add_child(_label(str(h.get("comment", "")), 30, C_INK))
	inner.add_child(dc.get_parent())
	content.add_child(scroll)

	var b := _button("", C_BLUE, func():
		Game.press_ready()
		refs.ready_btn.disabled = true)
	refs.ready_btn = b
	refs.ready_label = "Дальше"
	content.add_child(b)


func _build_end() -> void:
	var free := str(Game.state.result) == "free"
	content.add_child(_spacer(30))
	var t := _label("ОТПУСТИЛИ!" if free else "ПОПАЛИСЬ!", 80, C_GREEN if free else C_RED)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(t)
	var sub := _label(("Банда выкрутилась, подозрение %d из 100." if free else "Подозрение дошло до %d. Следователь вас раскусил.") % int(Game.state.suspicion), 26, C_MUTED)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(sub)
	_detective_says(str(Game.state.speech))
	content.add_child(_label("Дело: " + str(Game.state.case.get("title", "")), 24, C_MUTED))
	content.add_child(_expander())
	if Net.is_host():
		content.add_child(_button("Новое дело", C_ACCENT, Game.back_to_lobby))
	else:
		var w := _label("Хост может начать новое дело", 24, C_MUTED)
		w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		content.add_child(w)
	content.add_child(_button("Выйти", C_CARD2, _leave))


func _add_chat(placeholder: String) -> void:
	var card := _card(C_CARD)
	var panel := card.get_parent() as Control
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var log := VBoxContainer.new()
	log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log.add_theme_constant_override("separation", 6)
	scroll.add_child(log)
	card.add_child(scroll)
	var row := HBoxContainer.new()
	var input := LineEdit.new()
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.max_length = 200
	var send := func(_t = ""):
		Game.send_chat(input.text)
		input.text = ""
	input.text_submitted.connect(send)
	row.add_child(input)
	row.add_child(_small_button("➤", C_ACCENT, send))
	card.add_child(row)
	content.add_child(panel)
	refs.chat_log = log
	refs.chat_scroll = scroll
	refs.chat_n = -1


# ---------- обновление ----------

func _update() -> void:
	if refs.has("key_btn"):
		refs.key_btn.text = "Ключ ИИ: есть ✓" if LLM.has_key() else "Ключ ИИ: вставить из буфера"
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
			names.append(("★ " if id == 1 else "• ") + str(Net.players[id]) + ("  (ты)" if id == Net.my_id() else ""))
		refs.players.text = "\n".join(names)
	if refs.has("start"):
		var n := Net.players.size()
		refs.start.text = ("Начать дело (%d в банде)" % n) if LLM.has_key() else "Нужен ключ ИИ: вставить"
	if refs.has("chat_log"):
		_update_chat()
	if refs.has("ready_btn"):
		var r: Array = Game.state.ready
		refs.ready_btn.text = "%s (%d/%d)" % [refs.ready_label, r.size(), Net.players.size()]
		if Net.my_id() in r:
			refs.ready_btn.disabled = true
	if refs.has("answered"):
		refs.answered.text = "Ответили %d из %d" % [Game.state.answered.size(), Net.players.size()]


func _update_rooms() -> void:
	var sig := JSON.stringify(Net.rooms.keys()) + str(Net.rooms.size())
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
		var txt := "%s · %d в банде%s" % [r.name, r.count, "" if r.open else " · идёт игра"]
		var b := _button(txt, C_BLUE if r.open else C_CARD2, func(): _join(ip))
		b.disabled = not r.open
		list.add_child(b)


func _update_chat() -> void:
	var chat: Array = Game.state.get("chat", [])
	if chat.size() == refs.chat_n:
		return
	refs.chat_n = chat.size()
	var log: VBoxContainer = refs.chat_log
	for c in log.get_children():
		c.queue_free()
	if chat.is_empty():
		log.add_child(_label("Тут пока тихо", 22, C_MUTED))
	for m in chat:
		var l := RichTextLabel.new()
		l.bbcode_enabled = true
		l.fit_content = true
		l.scroll_active = false
		l.add_theme_font_size_override("normal_font_size", 26)
		var col := C_ACCENT if int(m.get("id", 0)) == Net.my_id() else C_BLUE
		l.text = "[color=#%s]%s:[/color] %s" % [col.to_html(false), str(m.n), str(m.t).replace("[", "(")]
		log.add_child(l)
	var sc: ScrollContainer = refs.chat_scroll
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(sc):
		sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)


func _process(delta: float) -> void:
	if refs.has("timer"):
		var t := Game.time_left()
		refs.timer.text = "%d:%02d" % [int(t) / 60, int(t) % 60] if t > 0 else ""
		refs.timer.add_theme_color_override("font_color", C_RED if t > 0 and t < 10 else C_ACCENT)
	if refs.has("dots"):
		_dots_t += delta
		refs.dots.text = refs.dots_text + ".".repeat(int(_dots_t * 2.0) % 4)
	_follow_keyboard()


## Поднимаем интерфейс над экранной клавиатурой.
func _follow_keyboard() -> void:
	var px := 0.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		px = float(DisplayServer.virtual_keyboard_get_height())
	var win_h := float(DisplayServer.window_get_size().y)
	var vp_h := get_viewport_rect().size.y
	var off := px * vp_h / win_h if win_h > 0 else 0.0
	root_margin.add_theme_constant_override("margin_bottom", 22 + int(off))


# ---------- действия ----------

func _on_host() -> void:
	error_text = ""
	if not LLM.has_key():
		error_text = "Сначала вставь ключ ИИ: его использует только хост"
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
	var tw := create_tween()
	toast.modulate.a = 1.0
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
	t.default_font_size = 28
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
		t.set_font_size("font_size", type, 28)
	t.set_constant("minimum_character_width", "LineEdit", 4)
	return t


func _label(text: String, size := 28, color := C_INK) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if size >= 34 and font_black:
		l.add_theme_font_override("font", font_black)
	return l


func _title(text: String) -> Label:
	return _label(text, 48, C_INK)


func _button(text: String, color: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 92)
	b.add_theme_font_size_override("font_size", 30)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var dark := color.get_luminance() > 0.55
	b.add_theme_stylebox_override("normal", _box(color, 24))
	b.add_theme_stylebox_override("hover", _box(color.lightened(0.08), 24))
	b.add_theme_stylebox_override("pressed", _box(color.darkened(0.2), 24))
	b.add_theme_stylebox_override("disabled", _box(color.darkened(0.45), 24))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, Color("1b1b24") if dark else Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.45))
	b.pressed.connect(cb)
	return b


func _small_button(text: String, color: Color, cb: Callable) -> Button:
	var b := _button(text, color, cb)
	b.custom_minimum_size = Vector2(110, 72)
	b.size_flags_horizontal = Control.SIZE_SHRINK_END
	return b


## Возвращает VBox внутри карточки; саму карточку брать через get_parent().
func _card(color := C_CARD) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(color, 26, 22))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	return v


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _expander() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


func _expander_h() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


# ---------- автотест (ALIBI_AUTOTEST=host|client, обычно вместе с ALIBI_MOCK=1) ----------

var _auto := ""
var _auto_done := {}


func _autotest_setup() -> void:
	_auto = OS.get_environment("ALIBI_AUTOTEST")
	if _auto == "":
		return
	Net.my_name = "Хост" if _auto == "host" else "Гость"
	Game.state_changed.connect(_autotest_step)
	Net.players_changed.connect(_autotest_step)
	if _auto == "host":
		Net.host_room()
	else:
		await get_tree().create_timer(1.0).timeout
		_join(OS.get_environment("ALIBI_IP") if OS.get_environment("ALIBI_IP") != "" else "127.0.0.1")
	_refresh()


func _autotest_step() -> void:
	var key := "%s%d%d" % [Game.phase, int(Game.state.round), Net.players.size()]
	if _auto_done.has(key):
		return
	_auto_done[key] = true
	print("[%s] phase=%s round=%s susp=%s players=%s" % [_auto, Game.phase, Game.state.round, Game.state.suspicion, Net.players.values()])
	await get_tree().create_timer(0.4).timeout
	match Game.phase:
		"lobby":
			if _auto == "host" and Net.players.size() >= 2 and not _auto_done.has("started"):
				_auto_done["started"] = true
				Game.send_chat("привет, банда")
				Game.start_game()
		"plot":
			Game.send_chat("были в кино, ели попкорн")
			Game.press_ready()
		"question":
			Game.send_answer("В кино на Ленина, ели попкорн (%s)" % _auto)
		"verdict":
			var h: Dictionary = Game.state.history[-1]
			print("[%s] comment=%s delta=%s next=%s" % [_auto, h.comment, h.delta, Game.state.question])
			Game.press_ready()
		"end":
			print("[%s] END result=%s speech=%s" % [_auto, Game.state.result, Game.state.speech])
			await get_tree().create_timer(1.0).timeout
			get_tree().quit()
