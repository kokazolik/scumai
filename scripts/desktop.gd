extends Control
## Экран оператора для телефона (вертикальный, 720x1280).
## Главное меню, звонок (шапка с балансом и планом, карточка клиента,
## переписка, поле ввода с микрофоном, кнопки), платёжный терминал,
## итоги смены с «прикольными моментами». Весь интерфейс собирается кодом.

const VERSION := "0.18"
const SAVE_PATH := "user://save.cfg"
const SHIFT_CALLS := 8       # звонков в смене
const FIRST_QUOTA := 15000   # план первой смены, ₽
const QUOTA_GROWTH := 1.08    # на сколько растёт план каждую выполненную смену
const INPUT_MIN_H := 96
const INPUT_MAX_H := 300

# Яркая палитра
const C_BG := Color("fff4d6")
const C_CARD := Color("ffffff")
const C_INK := Color("1f2340")
const C_MUTED := Color("6b6f8a")
const C_ACCENT := Color("ff5a36")
const C_BLUE := Color("2f6bff")
const C_GREEN := Color("18b45b")
const C_YELLOW := Color("ffc21a")
const C_RED := Color("e8364f")
const C_PURPLE := Color("7b4dff")
const C_CALLER_BUBBLE := Color("eef2ff")
const C_ME_BUBBLE := Color("ffe2d6")
const C_LINE := Color("ece6d3")
const AVATAR_COLORS := ["ff8a5b", "4f8bff", "2fbf71", "b46bff", "ff5c8a", "f2a516", "20b3c9"]

# Прогресс (сохраняется)
var balance := 0
var deals := 0
var shift := 1
var quota := FIRST_QUOTA
var shift_earned := 0
var shift_calls := 0
var total_calls := 0
var best_shift := 0
var shift_log: Array = []      # все разговоры текущей смены
var last_moments: Array = []   # «прикольные моменты» прошлой смены
var earned_total := 0          # всё заработанное за игру, от него зависит ранг
var heat := 0                  # внимание полиции 0..100
var raids := 0
var upgrades: Dictionary = {}  # купленные улучшения {id: уровень}
var schemes: Array = ["ads"]  # купленные схемы
var pay_methods: Array = ["card", "phone"]  # купленные способы оплаты
var skills: Dictionary = {}    # навыки оператора {id: уровень}
var play_seconds := 0.0
var finale_shown := false
var dictated_gift := ""
var pinned_gift_btn: Button
var cur_scheme: Dictionary = {}
var heat_bar: ProgressBar
var heat_label: Label
var call_paid := false

var caller_order: Array = []
var next_profile: Dictionary = {}  # следующий звонящий, которого заранее придумала нейронка
var generating := false
var prefetch_gen := 0  # растёт при покупке схемы: заготовленный клиент по старым схемам выбрасывается
var used_names: Array = []
var session: CallSession
var dictated_card := ""
var call_rec: Dictionary = {}  # запись текущего звонка в shift_log

# Интерфейс звонка
var main_margin: MarginContainer
var header_box: Control
var caller_box: Control
var actions_box: Control
var chips_box: Control
var balance_label: Label
var deals_label: Label
var quota_label: Label
var quota_bar: ProgressBar
var avatar: Panel
var avatar_label: Label
var caller_name: Label
var caller_info: Label
var trust_bar: ProgressBar
var trust_fill: StyleBoxFlat
var trust_label: Label
var pinned_card_btn: Button
var chat_scroll: ScrollContainer
var chat_list: VBoxContainer
var status_label: Label
var input: TextEdit
var send_btn: Button
var mic_btn: Button
var mic_icon: Control
var hang_btn: Button
var next_btn: Button
var terminal_btn: Button
var kb_height := 0.0

# Терминал
var terminal: Control
var term_sheet: PanelContainer
var term_hint: Label
var card_input: LineEdit
var charge_btn: Button
var term_result: Label

# Наложенные экраны
var menu: Control
var menu_stats: Label
var menu_play_btn: Button
var overlay_scrolls: Array = []  # прокрутки поверх звонка, их тоже тянем пальцем

var voice_hint_shown := false
var recorder: VoiceRecorder
var transcribing := false


func _ready() -> void:
	randomize()
	theme = _make_theme()
	_load()
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	main_margin = MarginContainer.new()
	main_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "bottom"]:
		main_margin.add_theme_constant_override("margin_" + side, 18)
	main_margin.add_theme_constant_override("margin_top", 34)
	add_child(main_margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	main_margin.add_child(root)
	header_box = _build_header()
	root.add_child(header_box)
	caller_box = _build_caller_card()
	root.add_child(caller_box)
	root.add_child(_build_chat())
	root.add_child(_build_input_row())
	actions_box = _build_actions()
	root.add_child(actions_box)

	terminal = _build_terminal()
	add_child(terminal)
	terminal.hide()

	recorder = VoiceRecorder.new()
	add_child(recorder)
	get_tree().on_request_permissions_result.connect(func(perm: String, granted: bool):
		if perm.ends_with("RECORD_AUDIO") and granted:
			_add_note("Микрофон разрешён. Нажмите кнопку с микрофоном ещё раз.", C_BLUE))

	_update_balance()
	_set_controls()
	_show_menu()
	_prefetch_caller()


# ---------- сохранение ----------

func _save() -> void:
	var c := ConfigFile.new()
	for k in ["balance", "deals", "shift", "quota", "shift_earned", "shift_calls", "total_calls", "best_shift", "shift_log", "last_moments", "earned_total", "heat", "raids", "upgrades", "schemes", "pay_methods", "skills", "play_seconds", "finale_shown"]:
		c.set_value("game", k, get(k))
	c.save(SAVE_PATH)


func _load() -> void:
	var c := ConfigFile.new()
	if c.load(SAVE_PATH) != OK:
		return
	for k in ["balance", "deals", "shift", "quota", "shift_earned", "shift_calls", "total_calls", "best_shift", "shift_log", "last_moments", "earned_total", "heat", "raids", "upgrades", "schemes", "pay_methods", "skills", "play_seconds", "finale_shown"]:
		if c.has_section_key("game", k):
			set(k, c.get_value("game", k))
	if not "ads" in schemes:  # сохранения до 0.18: первой схемы «Объявления» тогда не было
		schemes.insert(0, "ads")


func _has_progress() -> bool:
	return balance > 0 or shift > 1 or shift_calls > 0


func _reset_progress() -> void:
	if session and session.active:
		_drop_session()
	session = null
	balance = 0; deals = 0; shift = 1; quota = FIRST_QUOTA
	shift_earned = 0; shift_calls = 0; total_calls = 0; best_shift = 0
	shift_log = []; last_moments = []
	earned_total = 0; heat = 0; raids = 0; upgrades = {}; schemes = ["ads"]; pay_methods = ["card", "phone"]
	skills = {}; play_seconds = 0.0; finale_shown = false
	_clear_chat()
	_save()
	_update_balance()


# ---------- тема и общие детали ----------

func _box(color: Color, radius := 22, pad := 18) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad * 0.6
	sb.content_margin_bottom = pad * 0.6
	sb.anti_aliasing = true
	return sb


func _shadow_box(color: Color, radius := 28, pad := 22) -> StyleBoxFlat:
	var sb := _box(color, radius, pad)
	sb.shadow_color = Color(0.45, 0.32, 0.1, 0.13)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 4)
	return sb


func _button_box(color: Color) -> StyleBoxFlat:
	var sb := _box(color)
	sb.border_width_bottom = 6
	sb.border_color = color.darkened(0.25)
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 30
	t.set_color("font_color", "Label", C_INK)
	t.set_stylebox("normal", "Button", _button_box(C_BLUE))
	t.set_stylebox("hover", "Button", _button_box(C_BLUE.lightened(0.1)))
	t.set_stylebox("pressed", "Button", _box(C_BLUE.darkened(0.2)))
	t.set_stylebox("disabled", "Button", _box(Color("d4d5de")))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(s, "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", Color("f4f4f8"))
	var le := _box(C_CARD, 24, 20)
	le.border_color = Color("e2dac4")
	le.set_border_width_all(3)
	var lef := le.duplicate()
	lef.border_color = C_BLUE
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, le)
		t.set_stylebox("focus", type, lef)
		t.set_stylebox("read_only", type, le)
		t.set_color("font_color", type, C_INK)
		t.set_color("font_placeholder_color", type, C_MUTED)
		t.set_color("caret_color", type, C_BLUE)
	t.set_color("font_readonly_color", "TextEdit", C_MUTED)
	t.set_stylebox("background", "ProgressBar", _box(C_LINE, 18, 0))
	t.set_constant("scrollbar_h_separation", "ScrollContainer", 0)
	var grab := _box(Color(0, 0, 0, 0.18), 6, 0)
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab)
	t.set_stylebox("grabber_pressed", "VScrollBar", grab)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
	return t


func _big_button(text: String, color: Color, cb: Callable, height := 110) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = height
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 32)
	_paint_button(b, color)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


func _paint_button(b: Button, color: Color) -> void:
	b.add_theme_stylebox_override("normal", _button_box(color))
	b.add_theme_stylebox_override("hover", _button_box(color.lightened(0.08)))
	b.add_theme_stylebox_override("pressed", _box(color.darkened(0.2)))
	var dark := color.get_luminance() > 0.6
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, C_INK if dark else Color.WHITE)


func _chip_button(text: String, color: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 68
	b.add_theme_font_size_override("font_size", 24)
	var sb := _box(color.lerp(Color.WHITE, 0.85), 34, 20)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", _box(color.lerp(Color.WHITE, 0.6), 34, 20))
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, color.darkened(0.2))
	b.pressed.connect(cb)
	return b


func _card(color := C_CARD) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _shadow_box(color))
	return p


func _label(text: String, size := 30, color := C_INK, wrap := false, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Полупрозрачный фон и карточка по центру. Возвращает [фон, содержимое карточки].
func _modal(width := 660) -> Array:
	var dim := ColorRect.new()
	dim.color = Color(0.12, 0.13, 0.25, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var card := _card()
	card.custom_minimum_size = Vector2(width, 0)
	center.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 20)
	card.add_child(v)
	_pop_in(card)
	return [dim, v]


func _pop_in(c: Control) -> void:
	c.modulate.a = 0.0
	c.scale = Vector2(0.94, 0.94)
	await get_tree().process_frame
	c.pivot_offset = c.size / 2.0
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "modulate:a", 1.0, 0.18)
	tw.tween_property(c, "scale", Vector2.ONE, 0.25)


# ---------- главное меню ----------

func _show_menu() -> void:
	if menu:
		_refresh_menu()
		menu.show()
		return
	menu = Control.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(menu)
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.add_child(bg)
	# Большая оранжевая «трубка» сверху
	var hero := Panel.new()
	var hs := _box(C_ACCENT, 0, 0)
	hs.corner_radius_bottom_left = 90
	hs.corner_radius_bottom_right = 90
	hero.add_theme_stylebox_override("panel", hs)
	hero.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hero.offset_bottom = 470
	menu.add_child(hero)
	for d in [[Vector2(560, 60), 120, 0.12], [Vector2(70, 330), 80, 0.1], [Vector2(640, 380), 46, 0.16]]:
		hero.add_child(_dot(d[0], d[1], Color(1, 1, 1, d[2])))

	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 44)
	m.add_theme_constant_override("margin_top", 90)
	m.add_theme_constant_override("margin_bottom", 40)
	menu.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	m.add_child(v)

	var phone := _label("☎", 100, Color.WHITE, false, HORIZONTAL_ALIGNMENT_CENTER)
	v.add_child(phone)
	var tw := create_tween().set_loops()
	phone.pivot_offset = Vector2(310, 80)
	tw.tween_property(phone, "rotation", 0.12, 0.08)
	tw.tween_property(phone, "rotation", -0.12, 0.08)
	tw.tween_property(phone, "rotation", 0.08, 0.08)
	tw.tween_property(phone, "rotation", 0.0, 0.08)
	tw.tween_interval(1.6)
	v.add_child(_label("КОНТОРА", 88, Color.WHITE, false, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(_label("Мы перезвоним. Вы заплатите.", 28, Color(1, 1, 1, 0.85), false, HORIZONTAL_ALIGNMENT_CENTER))
	var gap := Control.new()
	gap.custom_minimum_size.y = 24
	v.add_child(gap)

	var stats_card := _card()
	menu_stats = _label("", 26, C_MUTED, true, HORIZONTAL_ALIGNMENT_CENTER)
	stats_card.add_child(menu_stats)
	v.add_child(stats_card)

	menu_play_btn = _big_button("", C_GREEN, _on_menu_play, 130)
	menu_play_btn.add_theme_font_size_override("font_size", 38)
	v.add_child(menu_play_btn)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.add_child(_big_button("$ Магазин", C_ACCENT, _show_shop, 100))
	row.add_child(_big_button("★ Моменты", C_PURPLE, _show_last_moments, 100))
	v.add_child(row)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 14)
	row2.add_child(_big_button("? Как играть", C_BLUE, _show_help, 100))
	row2.add_child(_big_button("Ключи", C_YELLOW, func(): _show_key_screen(false), 100))
	v.add_child(row2)
	var row3 := HBoxContainer.new()
	var reset_btn := _big_button("Новая игра", Color("b9bccb"), Callable(), 80)
	reset_btn.pressed.connect(func():
		if reset_btn.text != "Точно? Нажми ещё":
			reset_btn.text = "Точно? Нажми ещё"
			return
		reset_btn.text = "Новая игра"
		_reset_progress()
		_refresh_menu())
	reset_btn.add_theme_font_size_override("font_size", 26)
	row3.add_child(reset_btn)
	v.add_child(row3)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(spacer)
	v.add_child(_label("версия " + VERSION + " · все персонажи и номера выдуманы", 20, C_MUTED, false, HORIZONTAL_ALIGNMENT_CENTER))
	_refresh_menu()


func _dot(pos: Vector2, r: float, c: Color) -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", _box(c, int(r), 0))
	p.position = pos - Vector2(r, r)
	p.size = Vector2(r, r) * 2
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _refresh_menu() -> void:
	if not menu:
		return
	var in_call := session != null and session.active
	if in_call:
		menu_play_btn.text = "▶ Вернуться к звонку"
	elif _has_progress():
		menu_play_btn.text = "▶ Продолжить смену %d" % shift
	else:
		menu_play_btn.text = "▶ Начать работу"
	if _has_progress():
		menu_stats.text = "%s · ур. %d · смена %d\nПлан %s / %s · на счету %s\nСхем: %d · жара %d%% · в игре %d ч %d мин" % [
			_rank_name(), Upgrades.operator_level(deals), shift, _rub(shift_earned), _rub(quota), _rub(balance), schemes.size(), heat, int(play_seconds / 3600.0), int(play_seconds / 60.0) % 60]
	else:
		menu_stats.text = "Ты оператор конторы. Тебе звонят люди с объявлений. Придумай услугу, назови цену и получи деньги.\nПлан первой смены: " + _rub(FIRST_QUOTA)


func _on_menu_play() -> void:
	if LLM.api_key.is_empty():
		_show_key_screen(true)
		return
	_prefetch_caller()
	menu.hide()
	if session == null or not session.active:
		if shift_calls >= _calls_max():
			_show_shift_result()
		elif session == null:
			_next_call()


func _show_help() -> void:
	var m := _modal()
	var v: VBoxContainer = m[1]
	v.add_child(_label("Как играть", 44, C_ACCENT))
	var text := """Тебе звонят люди, которые нашли контору по объявлению. Придумай им услугу, назови цену и добейся согласия.

• Шанс — вероятность, что клиент отдаст карту или переведёт деньги. Бред и грубость его снижают.
• Попроси номер карты с лицевой стороны. Скопируй его и спиши деньги в терминале.
• Или продиктуй наш номер для перевода: деньги придут сами.
• Списать можно только ту сумму, на которую клиент согласился.
• Клиент может бросить трубку в любой момент.
• Микрофон: с бесплатным ключом голоса (меню «Ключи») нажми, скажи фразу, нажми ещё раз, и она отправится. Без ключа откроется диктовка клавиатуры.
• Жара растёт с каждой сделкой. На 100% будет облава и штраф. Пустые звонки (−3%) и конец смены (−20%) её сбивают.
• Способы оплаты из магазина (подарочные карты, криптокошелёк и дальше) позволяют брать суммы крупнее: просто предложи их клиенту в разговоре.
• За сделки растёт уровень оператора и даются очки навыков (магазин, раздел «Навыки»).
• Цель игры — стать Королём скама: заработать 80 000 000 ₽.
• Деньги со счёта тратятся в магазине на новые схемы и улучшения. Схемы приводят клиентов богаче и складываются. Ранг растёт от заработка и открывает новые товары.
• В конце смены вспомним самые смешные моменты."""
	var l := _label(text, 26, C_INK, true)
	l.custom_minimum_size.x = 570
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(590, 820)
	overlay_scrolls.append(sc)
	sc.add_child(l)
	v.add_child(sc)
	v.add_child(_big_button("Понятно", C_GREEN, func(): m[0].queue_free(), 110))


## Ключ вставляется из буфера обмена одной кнопкой и хранится только на телефоне.
func _show_key_screen(then_play: bool) -> void:
	var m := _modal()
	var v: VBoxContainer = m[1]
	v.add_child(_label("Ключ ИИ (OpenRouter)", 38, C_ACCENT))
	var has := not LLM.api_key.is_empty()
	var info := _label(("Ключ уже сохранён. Чтобы заменить его, скопируй новый и нажми кнопку.\n" if has else "") +
		"1. Скопируй ключ OpenRouter (начинается с sk-or-).\n2. Нажми кнопку ниже.\nКлюч хранится только на этом телефоне и не показывается.", 27, C_INK, true)
	info.custom_minimum_size.x = 580
	v.add_child(info)
	var status := _label("", 26, C_RED, true, HORIZONTAL_ALIGNMENT_CENTER)
	v.add_child(_big_button("Вставить ключ ИИ из буфера", C_GREEN, func():
		var k := DisplayServer.clipboard_get().strip_edges()
		if k.begins_with("sk-or-") and k.length() > 20:
			LLM.save_key(k)
			DisplayServer.clipboard_set("")  # не оставляем ключ в буфере
			m[0].queue_free()
			if then_play:
				_on_menu_play()
		else:
			status.text = "В буфере нет ключа. Скопируй ключ sk-or-... и нажми ещё раз.", 130))
	v.add_child(status)
	v.add_child(_label("Ключ голоса (бесплатно)", 34, C_PURPLE))
	var vinfo := _label(("Ключ голоса сохранён: микрофон в игре слушает сам.\n" if not LLM.voice_key.is_empty() else "") +
		"Зарегистрируйся на console.groq.com, открой API Keys, создай ключ (начинается с gsk_), скопируй и нажми кнопку.", 25, C_INK, true)
	vinfo.custom_minimum_size.x = 580
	v.add_child(vinfo)
	v.add_child(_chip_button("Открыть console.groq.com/keys", C_PURPLE, func(): OS.shell_open("https://console.groq.com/keys")))
	var vstatus := _label("", 26, C_RED, true, HORIZONTAL_ALIGNMENT_CENTER)
	v.add_child(_big_button("Вставить ключ голоса", C_PURPLE, func():
		var k := DisplayServer.clipboard_get().strip_edges()
		if k.begins_with("gsk_") and k.length() > 20:
			LLM.save_voice_key(k)
			DisplayServer.clipboard_set("")
			vstatus.text = "✔ Ключ голоса сохранён."
			vstatus.add_theme_color_override("font_color", C_GREEN)
		else:
			vstatus.text = "В буфере нет ключа gsk_... Скопируй его и нажми ещё раз.", 110))
	v.add_child(vstatus)
	v.add_child(_big_button("Назад", C_MUTED, func(): m[0].queue_free(), 96))


func _show_last_moments() -> void:
	var m := _modal()
	var v: VBoxContainer = m[1]
	v.add_child(_label("★ Моменты прошлой смены", 40, C_PURPLE))
	if last_moments.is_empty():
		var l := _label("Пока пусто. Отработай смену, и здесь появятся самые смешные моменты разговоров.", 27, C_MUTED, true)
		l.custom_minimum_size.x = 580
		v.add_child(l)
	else:
		v.add_child(_moments_scroll(last_moments, 760))
	v.add_child(_big_button("Закрыть", C_GREEN, func(): m[0].queue_free(), 100))


func _moments_scroll(moments: Array, h: int) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(600, h)
	overlay_scrolls.append(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 14)
	sc.add_child(list)
	for mo in moments:
		list.add_child(_moment_card(mo))
	return sc


func _moment_card(mo: Dictionary) -> Control:
	var p := PanelContainer.new()
	var sb := _box(Color("f4efff"), 24, 22)
	sb.border_width_left = 8
	sb.border_color = C_PURPLE
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	v.add_child(_label(mo["title"], 29, C_PURPLE.darkened(0.2), true))
	if mo["quote"] != "":
		v.add_child(_label("«" + mo["quote"].trim_prefix("«").trim_suffix("»") + "»", 25, C_INK, true))
	if mo["comment"] != "":
		v.add_child(_label(mo["comment"], 24, C_MUTED, true))
	return p


# ---------- экран звонка ----------

func _build_header() -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _shadow_box(C_ACCENT, 30, 22))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	p.add_child(outer)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	outer.add_child(h)
	var menu_btn := Button.new()
	menu_btn.text = "≡"
	menu_btn.custom_minimum_size = Vector2(76, 76)
	menu_btn.add_theme_font_size_override("font_size", 44)
	var ms := _box(Color(1, 1, 1, 0.22), 22, 0)
	menu_btn.add_theme_stylebox_override("normal", ms)
	menu_btn.add_theme_stylebox_override("hover", ms)
	menu_btn.add_theme_stylebox_override("pressed", _box(Color(1, 1, 1, 0.4), 22, 0))
	menu_btn.pressed.connect(func():
		input.release_focus()
		_show_menu())
	h.add_child(menu_btn)
	var t := _label("КОНТОРА", 40, Color.WHITE)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	balance_label = _label("", 42, Color.WHITE, false, HORIZONTAL_ALIGNMENT_RIGHT)
	h.add_child(balance_label)
	var row := HBoxContainer.new()
	deals_label = _label("", 22, Color(1, 1, 1, 0.9))
	deals_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deals_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(deals_label)
	quota_label = _label("", 22, Color.WHITE, false, HORIZONTAL_ALIGNMENT_RIGHT)
	row.add_child(quota_label)
	outer.add_child(row)
	quota_bar = ProgressBar.new()
	quota_bar.show_percentage = false
	quota_bar.custom_minimum_size.y = 16
	quota_bar.add_theme_stylebox_override("fill", _box(C_YELLOW, 8, 0))
	quota_bar.add_theme_stylebox_override("background", _box(Color(1, 1, 1, 0.28), 8, 0))
	outer.add_child(quota_bar)
	var hr := HBoxContainer.new()
	hr.add_theme_constant_override("separation", 10)
	heat_label = _label("", 20, Color(1, 1, 1, 0.9))
	heat_label.custom_minimum_size.x = 120
	hr.add_child(heat_label)
	heat_bar = ProgressBar.new()
	heat_bar.show_percentage = false
	heat_bar.max_value = 100
	heat_bar.custom_minimum_size.y = 10
	heat_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heat_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heat_bar.add_theme_stylebox_override("fill", _box(Color("ffe08a"), 5, 0))
	heat_bar.add_theme_stylebox_override("background", _box(Color(1, 1, 1, 0.22), 5, 0))
	hr.add_child(heat_bar)
	outer.add_child(hr)
	return p


func _build_caller_card() -> Control:
	var card := _card()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	card.add_child(v)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 18)
	v.add_child(top)
	avatar = Panel.new()
	avatar.custom_minimum_size = Vector2(96, 96)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	top.add_child(avatar)
	avatar_label = _label("", 38, Color.WHITE, false, HORIZONTAL_ALIGNMENT_CENTER)
	avatar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	avatar.add_child(avatar_label)
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", 2)
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(nv)
	caller_name = _label("Ждём звонка", 32, C_INK, true)
	nv.add_child(caller_name)
	caller_info = _label("", 23, C_MUTED, true)
	nv.add_child(caller_info)

	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 14)
	v.add_child(th)
	trust_label = _label("", 27)
	trust_label.custom_minimum_size.x = 170
	th.add_child(trust_label)
	trust_bar = ProgressBar.new()
	trust_bar.max_value = CallSession.MAX_TRUST
	trust_bar.show_percentage = false
	trust_bar.custom_minimum_size.y = 34
	trust_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trust_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	trust_fill = _box(C_YELLOW, 17, 0)
	trust_bar.add_theme_stylebox_override("fill", trust_fill)
	th.add_child(trust_bar)

	# Быстрые кнопки: наш номер для перевода и присланная карта.
	var chips := HFlowContainer.new()
	chips_box = chips
	chips.add_theme_constant_override("h_separation", 10)
	chips.add_theme_constant_override("v_separation", 10)
	chips.add_child(_chip_button("⧉ Наш номер " + CallSession.CORP_PHONE, C_ACCENT, func():
		DisplayServer.clipboard_set(CallSession.CORP_PHONE)
		_add_note("Номер для перевода скопирован. Продиктуйте его клиенту.", C_BLUE)))
	pinned_card_btn = _chip_button("", C_GREEN, func():
		DisplayServer.clipboard_set(dictated_card.replace(" ", ""))
		_add_note("Номер карты скопирован. Вставьте его в терминале.", C_BLUE))
	pinned_card_btn.hide()
	chips.add_child(pinned_card_btn)
	pinned_gift_btn = _chip_button("", C_PURPLE, func():
		DisplayServer.clipboard_set(dictated_gift)
		_add_note("Код подарочной карты скопирован. Вставьте его в терминале.", C_BLUE))
	pinned_gift_btn.hide()
	chips.add_child(pinned_gift_btn)
	v.add_child(chips)
	return card


func _set_avatar(name: String) -> void:
	var parts := name.split(" ", false)
	var ini := ""
	for p in parts.slice(0, 2):
		ini += p.substr(0, 1)
	avatar_label.text = ini.to_upper()
	var col := Color(AVATAR_COLORS[absi(name.hash()) % AVATAR_COLORS.size()])
	avatar.add_theme_stylebox_override("panel", _box(col, 48, 0))


func _build_chat() -> Control:
	var card := _card()
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	card.add_child(v)
	chat_scroll = ScrollContainer.new()
	chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(chat_scroll)
	chat_list = VBoxContainer.new()
	chat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_list.add_theme_constant_override("separation", 12)
	chat_scroll.add_child(chat_list)
	status_label = _label("", 24, C_MUTED)
	v.add_child(status_label)
	return card


func _build_input_row() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	input = TextEdit.new()
	input.placeholder_text = "Ваша реплика..."
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input.custom_minimum_size.y = INPUT_MIN_H
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.size_flags_vertical = Control.SIZE_SHRINK_END
	input.add_theme_font_size_override("font_size", 30)
	input.text_changed.connect(_on_input_changed)
	h.add_child(input)
	mic_btn = _big_button("", C_PURPLE, _on_mic, INPUT_MIN_H)
	mic_btn.size_flags_horizontal = Control.SIZE_FILL
	mic_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	mic_btn.custom_minimum_size.x = 100
	mic_icon = MicIcon.new()
	mic_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	mic_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mic_btn.add_child(mic_icon)
	h.add_child(mic_btn)
	send_btn = _big_button("➤", C_ACCENT, _on_send, INPUT_MIN_H)
	send_btn.size_flags_horizontal = Control.SIZE_FILL
	send_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	send_btn.custom_minimum_size.x = 100
	send_btn.add_theme_font_size_override("font_size", 42)
	h.add_child(send_btn)
	return h


func _build_actions() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	terminal_btn = _big_button("▤ Терминал", C_BLUE, _open_terminal, 100)
	hang_btn = _big_button("✖ Сбросить", C_RED, _on_hang_up, 100)
	next_btn = _big_button("☎ Дальше", C_YELLOW, _next_call, 100)
	for b in [terminal_btn, hang_btn, next_btn]:
		b.add_theme_font_size_override("font_size", 27)
		h.add_child(b)
	return h


# ---------- терминал ----------

func _build_terminal() -> Control:
	var dim := ColorRect.new()
	dim.color = Color(0.12, 0.13, 0.25, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP

	var sheet := PanelContainer.new()
	term_sheet = sheet
	var ss := _box(C_CARD, 40, 32)
	ss.corner_radius_bottom_left = 0
	ss.corner_radius_bottom_right = 0
	sheet.add_theme_stylebox_override("panel", ss)
	sheet.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	sheet.offset_top = -780
	dim.add_child(sheet)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 20)
	sheet.add_child(v)
	var grip := Panel.new()
	grip.custom_minimum_size = Vector2(90, 10)
	grip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grip.add_theme_stylebox_override("panel", _box(C_LINE, 5, 0))
	v.add_child(grip)

	var screen := PanelContainer.new()
	screen.add_theme_stylebox_override("panel", _box(Color("1d2a4d"), 24, 24))
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 6)
	screen.add_child(sv)
	sv.add_child(_label("▤ PayTerminal 2.0", 34, Color("7fe3a6")))
	term_hint = _label("", 25, Color("c8d3f5"), true)
	sv.add_child(term_hint)
	v.add_child(screen)

	card_input = LineEdit.new()
	card_input.placeholder_text = "0000 0000 0000 0000"
	card_input.max_length = 19
	card_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	card_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	card_input.custom_minimum_size.y = 116
	card_input.add_theme_font_size_override("font_size", 34)
	card_input.text_changed.connect(_format_card_input)
	card_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(card_input)
	var paste_btn := _big_button("Вставить", C_ACCENT, func():
		card_input.text = DisplayServer.clipboard_get()
		_format_card_input(card_input.text), 116)
	paste_btn.size_flags_horizontal = Control.SIZE_FILL
	paste_btn.custom_minimum_size.x = 190
	paste_btn.add_theme_font_size_override("font_size", 28)
	row.add_child(paste_btn)
	v.add_child(row)

	charge_btn = _big_button("Списать", C_GREEN, _on_charge, 130)
	v.add_child(charge_btn)
	term_result = _label("", 30, C_INK, true, HORIZONTAL_ALIGNMENT_CENTER)
	v.add_child(term_result)
	v.add_child(_big_button("← Назад к звонку", C_MUTED, _close_terminal, 100))
	return dim


func _open_terminal() -> void:
	term_result.text = ""
	var price: int = session.agreed_price if session else 0
	var lines := []
	lines.append(("Карта клиента: " + dictated_card) if dictated_card != "" else "Клиент ещё не прислал номер карты.")
	if dictated_gift != "":
		lines.append("Код подарочной карты: " + dictated_gift)
	lines.append(("Сумма: " + _rub(price)) if price > 0 else "Сумма не согласована: назовите клиенту цену.")
	if session and session.paid:
		lines.append("С этого клиента деньги уже получены.")
	term_hint.text = "\n".join(lines)
	charge_btn.text = ("Списать " + _rub(price)) if price > 0 else "Списать"
	card_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT if dictated_gift != "" else LineEdit.KEYBOARD_TYPE_NUMBER
	if (dictated_card != "" or dictated_gift != "") and card_input.text == "":
		card_input.placeholder_text = "Нажмите «Вставить»"
	terminal.show()
	input.release_focus()


func _close_terminal() -> void:
	card_input.release_focus()
	terminal.hide()


## Расставляет пробелы по 4 цифры, пока игрок печатает.
func _format_card_input(t: String) -> void:
	if RegEx.create_from_string("[A-Za-z]").search(t):  # код подарочной карты: XXXX-XXXX-XXXX
		var raw := ""
		for ch in t.to_upper():
			if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
				raw += ch
		raw = raw.substr(0, 12)
		var code := ""
		for i in raw.length():
			if i > 0 and i % 4 == 0:
				code += "-"
			code += raw[i]
		if code != t:
			card_input.text = code
			card_input.caret_column = code.length()
		return
	var digits := ""
	for ch in t:
		if ch >= "0" and ch <= "9":
			digits += ch
	digits = digits.substr(0, 16)
	var out := ""
	for i in digits.length():
		if i > 0 and i % 4 == 0:
			out += " "
		out += digits[i]
	if out != t:
		card_input.text = out
		card_input.caret_column = out.length()


func _on_charge() -> void:
	if card_input.text.contains("-"):
		_charge_gift()
		return
	var digits := card_input.text.replace(" ", "")
	if digits.length() != 16:
		_term_says("Нужно 16 цифр.", C_RED)
		return
	if session == null or dictated_card == "" or digits != dictated_card.replace(" ", ""):
		_term_says("✖ Операция отклонена: карта не найдена.", C_RED)
		return
	if session.paid:
		_term_says("✖ С этого клиента деньги уже получены.", C_RED)
		return
	var price: int = session.agreed_price
	if price <= 0:
		_term_says("✖ Клиент не соглашался ни на какую сумму. Договоритесь о цене.", C_RED)
		return
	if price > session.cap_for("card"):
		_term_says("✖ Недостаточно средств на карте: там около %s. Возьмите меньше или предложите другой способ." % _rub(session.cap_for("card")), C_RED)
		return
	session.paid = true
	_add_money(price, "card")
	_log_line("Терминал", "списано " + _rub(price))
	dictated_card = ""
	pinned_card_btn.hide()
	card_input.text = ""
	_term_says("✔ Операция одобрена. Списано %s." % _rub(price), C_GREEN)
	_set_controls()


func _charge_gift() -> void:
	if session == null or dictated_gift == "" or card_input.text != dictated_gift:
		_term_says("✖ Код не найден. Проверьте код подарочной карты.", C_RED)
		return
	if session.paid:
		_term_says("✖ С этого клиента деньги уже получены.", C_RED)
		return
	var price: int = session.agreed_price
	session.paid = true
	_add_money(price, "gift")
	_log_line("Терминал", "активированы подарочные карты на " + _rub(price))
	dictated_gift = ""
	pinned_gift_btn.hide()
	card_input.text = ""
	_term_says("✔ Подарочные карты активированы: +%s." % _rub(price), C_GREEN)
	_set_controls()


func _on_gift_dictated(code: String) -> void:
	dictated_gift = code
	_log_line(session.profile["name"], "(диктует коды подарочных карт)")
	pinned_gift_btn.text = "⧉ Код " + code
	pinned_gift_btn.show()
	_add_bubble(session.profile["name"], "✉ " + code, false)
	_add_note("Клиент продиктовал код подарочной карты. Активируйте его в терминале!", C_GREEN, true)
	_set_controls()


func _add_money(rub: int, method := "card") -> void:
	balance += rub
	shift_earned += rub
	deals += 1
	call_rec["money"] = int(call_rec.get("money", 0)) + rub
	call_paid = true
	var old_rank := Upgrades.rank_index(earned_total)
	earned_total += rub
	var new_rank := Upgrades.rank_index(earned_total)
	if new_rank > old_rank:
		_add_note("★ Новый ранг: %s! В магазине открылись новые улучшения, клиенты стали богаче." % Upgrades.RANKS[new_rank]["name"], C_PURPLE, true)
	# Жара растёт медленнее суммы (логарифм), иначе на крупных схемах облава была бы после каждой сделки.
	var h := (3.0 + 3.0 * log(1.0 + rub / 1000.0) / log(10.0)) * float(cur_scheme.get("heat", 1.0)) * float(Upgrades.method(method)["heat"])
	h *= (1.0 - 0.2 * Upgrades.level(upgrades, "lawyer")) * (1.0 - 0.08 * _skill("cool"))
	_add_heat(int(round(h)))
	var lvl_before := Upgrades.operator_level(deals - 1)
	if Upgrades.operator_level(deals) > lvl_before:
		_add_note("▲ Уровень оператора %d! Получено очко навыка, потратьте его в магазине." % Upgrades.operator_level(deals), C_BLUE, true)
	if new_rank == Upgrades.RANKS.size() - 1 and not finale_shown:
		finale_shown = true
		call_deferred("_show_finale")
	_update_balance()
	_bump(balance_label)
	_save()


func _bump(c: Control) -> void:
	c.pivot_offset = c.size / 2.0
	var tw := create_tween()
	tw.tween_property(c, "scale", Vector2(1.25, 1.25), 0.12)
	tw.tween_property(c, "scale", Vector2.ONE, 0.2)


func _on_transfer_done(rub: int, method: String) -> void:
	_add_money(rub, method)
	var mname: String = Upgrades.method(method)["name"]
	_log_line("Банк", "%s: %s" % [mname, _rub(rub)])
	if method == "phone":
		_add_note("✔ Поступил перевод %s по номеру %s" % [_rub(rub), CallSession.CORP_PHONE], C_GREEN, true)
	else:
		_add_note("✔ %s: поступило %s" % [mname, _rub(rub)], C_GREEN, true)
	_set_controls()


func _term_says(t: String, c: Color) -> void:
	term_result.text = t
	term_result.add_theme_color_override("font_color", c)


# ---------- игра ----------

## Отключаем старый звонок от экрана, чтобы его поздний ответ не попал в новый чат.
func _drop_session() -> void:
	if session == null:
		return
	for sig in session.get_signal_list():
		for con in session.get_signal_connection_list(sig["name"]):
			session.disconnect(sig["name"], con["callable"])
	if session.active:
		session.hang_up()
		_finish_record("оператор положил трубку")


func _clear_chat() -> void:
	for c in chat_list.get_children():
		c.queue_free()


func _next_call() -> void:
	if recorder.recording:
		recorder.stop()
	_drop_session()
	_close_terminal()
	if shift_calls >= _calls_max():
		_show_shift_result()
		return
	shift_calls += 1
	total_calls += 1
	if caller_order.is_empty():
		caller_order = Callers.LIST.duplicate()
		caller_order.shuffle()
	var p: Dictionary
	if not next_profile.is_empty():
		p = next_profile
		next_profile = {}
	else:
		p = caller_order.pop_back()
		while p["name"] in used_names and not caller_order.is_empty():
			p = caller_order.pop_back()
		p = p.duplicate()
		p["scheme"] = "ads"
	used_names.append(p["name"])
	_prefetch_caller()
	dictated_card = ""
	pinned_card_btn.hide()
	session = CallSession.new(p)
	call_paid = false
	cur_scheme = Upgrades.scheme(str(p.get("scheme", "ads")))
	_apply_upgrades(session)
	session.set_methods(pay_methods)
	dictated_gift = ""
	pinned_gift_btn.hide()
	call_rec = {"name": p["name"], "age": p["age"], "outcome": "звонок прервался", "money": 0, "lines": []}
	shift_log.append(call_rec)
	session.caller_spoke.connect(func(t):
		_log_line(p["name"], t)
		_add_bubble(p["name"], t, false))
	session.trust_changed.connect(_on_trust)
	session.thinking.connect(_on_thinking)
	session.call_ended.connect(_on_call_ended)
	session.card_dictated.connect(_on_card_dictated)
	session.transfer_done.connect(_on_transfer_done)
	session.gift_dictated.connect(_on_gift_dictated)
	session.method_locked.connect(func(n): _add_note("Способ «%s» ещё не куплен. Его можно открыть в магазине." % n, C_MUTED))
	session.price_agreed.connect(func(rub):
		_log_line(p["name"], "(соглашается заплатить %s)" % _rub(rub))
		_add_note("Клиент согласен заплатить " + _rub(rub), C_GREEN, true))
	_clear_chat()
	caller_name.text = "%s, %d" % [p["name"], p["age"]]
	caller_info.text = ("Схема «%s» · " % cur_scheme["name"] if schemes.size() > 1 else "") + "Узнал(а) о нас: " + p["source"]
	if Upgrades.level(upgrades, "base") > 0:
		caller_info.text += "\nБаза: на карте около %s, всего до %s. %s" % [_rub(session.base_budget), _rub(session.budget), p["personality"]]
	_set_avatar(p["name"])
	_add_note("☎ Входящий звонок...")
	_on_trust(session.trust, 0)
	_update_balance()
	_save()
	_set_controls()
	session.start()


func _calls_max() -> int:
	return SHIFT_CALLS + Upgrades.level(upgrades, "coffee")


func _rank_name() -> String:
	return Upgrades.RANKS[Upgrades.rank_index(earned_total)]["name"]


## Улучшения и ранг меняют звонок: стартовое доверие, шанс, штрафы, бюджет клиента.
func _apply_upgrades(s: CallSession) -> void:
	s.trust = clampi(s.trust + 5 * Upgrades.level(upgrades, "script") + 3 * _skill("charm"), 1, CallSession.MAX_TRUST)
	s.roll_bonus = 5 * Upgrades.level(upgrades, "spoof") + 3 * _skill("persuade")
	s.neg_mult = (1.0 - 0.2 * Upgrades.level(upgrades, "acting")) * (1.0 - 0.08 * _skill("patience"))
	var mult: float = Upgrades.RANKS[Upgrades.rank_index(earned_total)]["mult"]
	mult *= 1.0 + 0.15 * Upgrades.level(upgrades, "office")
	mult *= 1.0 + 0.05 * _skill("bargain")
	mult *= float(cur_scheme.get("mult", 1.0)) * (1.0 + 0.025 * (schemes.size() - 1))  # схемы складываются
	s.budget = int(round(s.budget * mult / 500.0)) * 500


func _skill(id: String) -> int:
	return int(skills.get(id, 0))


func _skill_points() -> int:
	var spent := 0
	for k in skills:
		spent += int(skills[k])
	return Upgrades.operator_level(deals) - spent


## Жара: каждая сделка привлекает внимание. На 100 — облава.
func _add_heat(n: int) -> void:
	heat = clampi(heat + n, 0, 100)
	if heat >= 80 and heat - n < 80:
		_add_note("Жара %d%%! Полиция уже интересуется конторой. Отпустите пару клиентов без денег." % heat, C_RED, true)
	if heat >= 100:
		_raid()


func _raid() -> void:
	raids += 1
	var fine := int(round(balance * 0.3 / 100.0)) * 100
	balance -= fine
	heat = 35
	_save()
	_update_balance()
	var m := _modal()
	var v: VBoxContainer = m[1]
	v.add_child(_label("ОБЛАВА!", 56, C_RED, false, HORIZONTAL_ALIGNMENT_CENTER))
	var l := _label("Полиция нагрянула в контору. Пока адвокаты договаривались, пришлось отдать %s (30%% со счёта).\nЖара сбита до 35%%. В следующий раз не жадничайте." % _rub(fine), 27, C_INK, true, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size.x = 580
	v.add_child(l)
	v.add_child(_big_button("Работаем дальше", C_ACCENT, func(): m[0].queue_free(), 110))


func _show_finale() -> void:
	var m := _modal()
	var v: VBoxContainer = m[1]
	v.add_child(_label("♛ КОРОЛЬ СКАМА", 52, C_YELLOW.darkened(0.25), false, HORIZONTAL_ALIGNMENT_CENTER))
	var h := int(play_seconds / 3600.0)
	var mins := int(play_seconds / 60.0) % 60
	var l := _label("Ты прошёл путь от стажёра до короля телефонного скама.\n\nЗаработано за игру: %s\nСделок: %d · звонков: %d · облав: %d\nВремя в игре: %d ч %d мин\n\nКонтора продолжает работать: можно играть дальше и скупить всё до конца." % [_rub(earned_total), deals, total_calls, raids, h, mins], 27, C_INK, true, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size.x = 580
	v.add_child(l)
	v.add_child(_big_button("Продолжить царствовать", C_GREEN, func(): m[0].queue_free(), 110))


func _show_shop() -> void:
	var m := _modal()
	var v: VBoxContainer = m[1]
	v.add_child(_label("$ Магазин конторы", 42, C_ACCENT))
	var top := _label("", 26, C_MUTED, true)
	top.custom_minimum_size.x = 580
	v.add_child(top)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(600, 700)
	overlay_scrolls.append(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 12)
	sc.add_child(list)
	v.add_child(sc)
	var holder := []  # лямбда не видит саму себя, поэтому храним её в массиве
	var refresh := func():
		var r := Upgrades.rank_index(earned_total)
		var nxt := ""
		if r + 1 < Upgrades.RANKS.size():
			nxt = "\nДо ранга «%s»: ещё %s заработка." % [Upgrades.RANKS[r + 1]["name"], _rub(Upgrades.RANKS[r + 1]["earned"] - earned_total)]
		top.text = "На счету %s · ранг: %s%s" % [_rub(balance), Upgrades.RANKS[r]["name"], nxt]
		for c in list.get_children():
			c.queue_free()
		var pts := _skill_points()
		list.add_child(_label("Навыки", 32, C_ACCENT))
		list.add_child(_label("Уровень оператора %d. Свободных очков: %d. Очки дают за сделки." % [Upgrades.operator_level(deals), pts], 22, C_MUTED, true))
		for skd in Upgrades.SKILLS:
			var sl := _skill(skd["id"])
			var srow := HBoxContainer.new()
			srow.add_theme_constant_override("separation", 10)
			var sinfo := VBoxContainer.new()
			sinfo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sinfo.add_child(_label("%s  %d/%d" % [skd["name"], sl, Upgrades.SKILL_MAX], 27, C_INK, true))
			sinfo.add_child(_label(skd["desc"], 21, C_MUTED, true))
			srow.add_child(sinfo)
			var skid: String = skd["id"]
			var plus := _big_button("+", C_BLUE if (pts > 0 and sl < Upgrades.SKILL_MAX) else Color("b9bccb"), func():
				if _skill_points() <= 0 or _skill(skid) >= Upgrades.SKILL_MAX:
					return
				skills[skid] = _skill(skid) + 1
				_save()
				holder[0].call(), 76)
			plus.custom_minimum_size.x = 90
			plus.size_flags_horizontal = Control.SIZE_SHRINK_END
			srow.add_child(plus)
			list.add_child(srow)
		list.add_child(_label("Схемы", 32, C_ACCENT))
		list.add_child(_label("Каждая схема приводит клиентов побогаче. Купленные складываются: +2,5%% к бюджету клиентов за схему и доход в конце смены (сейчас %s)." % _rub(Upgrades.passive_income(schemes)), 22, C_MUTED, true))
		for sc_item in Upgrades.SCHEMES:
			if sc_item["price"] == 0:
				continue
			var owned: bool = sc_item["id"] in schemes
			var scard := PanelContainer.new()
			var ssb := _box(Color("fff1ec") if not owned else Color("eafaf0"), 24, 22)
			ssb.border_width_left = 8
			ssb.border_color = C_ACCENT if not owned else C_GREEN
			scard.add_theme_stylebox_override("panel", ssb)
			var sv := VBoxContainer.new()
			sv.add_theme_constant_override("separation", 6)
			scard.add_child(sv)
			sv.add_child(_label(sc_item["name"], 29, C_INK, true))
			sv.add_child(_label(sc_item["desc"], 23, C_MUTED, true))
			sv.add_child(_label("Клиенты ×%s богаче · +%s за смену · жара ×%s" % [str(sc_item["mult"]), _rub(sc_item["passive"]), str(sc_item["heat"])], 22, C_ACCENT.darkened(0.2), true))
			var sb2: Button
			if owned:
				sb2 = _big_button("✔ Работает", Color("b9bccb"), Callable(), 76)
				sb2.disabled = true
			elif r < sc_item["rank"]:
				sb2 = _big_button("Нужен ранг «%s»" % Upgrades.RANKS[sc_item["rank"]]["name"], Color("b9bccb"), Callable(), 76)
				sb2.disabled = true
			else:
				var sprice: int = sc_item["price"]
				var sid: String = sc_item["id"]
				sb2 = _big_button("Запустить за " + _rub(sprice), C_ACCENT if balance >= sprice else Color("b9bccb"), func():
					if balance < sprice:
						return
					balance -= sprice
					schemes.append(sid)
					next_profile = {}  # следующий клиент уже придёт и по новой схеме
					prefetch_gen += 1
					_save()
					_update_balance()
					holder[0].call(), 76)
			sb2.add_theme_font_size_override("font_size", 25)
			sv.add_child(sb2)
			list.add_child(scard)
		list.add_child(_label("Способы оплаты", 32, C_ACCENT))
		list.add_child(_label("Чем круче способ, тем больше денег клиент может отдать, но уговорить труднее. Карта и перевод по номеру есть сразу. Способ работает, когда ты называешь его в разговоре.", 22, C_MUTED, true))
		for mt in Upgrades.METHODS:
			if mt["price"] == 0:
				continue
			var mown: bool = mt["id"] in pay_methods
			var mcard := PanelContainer.new()
			var msb := _box(Color("f1f0ff") if not mown else Color("eafaf0"), 24, 22)
			msb.border_width_left = 8
			msb.border_color = C_PURPLE if not mown else C_GREEN
			mcard.add_theme_stylebox_override("panel", msb)
			var mv := VBoxContainer.new()
			mv.add_theme_constant_override("separation", 6)
			mcard.add_child(mv)
			mv.add_child(_label(mt["name"], 29, C_INK, true))
			mv.add_child(_label(mt["desc"], 23, C_MUTED, true))
			mv.add_child(_label("Суммы до ×%s · шанс %d%% · жара ×%s" % [str(mt["cap"]), mt["chance"], str(mt["heat"])], 22, C_PURPLE.darkened(0.2), true))
			var mb: Button
			if mown:
				mb = _big_button("✔ Доступен", Color("b9bccb"), Callable(), 76)
				mb.disabled = true
			elif r < mt["rank"]:
				mb = _big_button("Нужен ранг «%s»" % Upgrades.RANKS[mt["rank"]]["name"], Color("b9bccb"), Callable(), 76)
				mb.disabled = true
			else:
				var mprice: int = mt["price"]
				var mid: String = mt["id"]
				mb = _big_button("Открыть за " + _rub(mprice), C_PURPLE if balance >= mprice else Color("b9bccb"), func():
					if balance < mprice:
						return
					balance -= mprice
					pay_methods.append(mid)
					_save()
					_update_balance()
					holder[0].call(), 76)
			mb.add_theme_font_size_override("font_size", 25)
			mv.add_child(mb)
			list.add_child(mcard)
		list.add_child(_label("Улучшения", 32, C_ACCENT))
		for u in Upgrades.LIST:
			var lvl := Upgrades.level(upgrades, u["id"])
			var maxl: int = u["prices"].size()
			var card := PanelContainer.new()
			card.add_theme_stylebox_override("panel", _box(Color("fff8ea"), 24, 22))
			var cv := VBoxContainer.new()
			cv.add_theme_constant_override("separation", 6)
			card.add_child(cv)
			var head := _label(u["name"] + ("  ур. %d/%d" % [lvl, maxl] if maxl > 1 else ""), 29, C_INK, true)
			cv.add_child(head)
			cv.add_child(_label(u["desc"], 23, C_MUTED, true))
			var b: Button
			if lvl >= maxl:
				b = _big_button("✔ Куплено", Color("b9bccb"), Callable(), 76)
				b.disabled = true
			elif r < u["rank"]:
				b = _big_button("Нужен ранг «%s»" % Upgrades.RANKS[u["rank"]]["name"], Color("b9bccb"), Callable(), 76)
				b.disabled = true
			else:
				var price: int = u["prices"][lvl]
				var id: String = u["id"]
				b = _big_button("Купить за " + _rub(price), C_GREEN if balance >= price else Color("b9bccb"), func():
					if balance < price:
						return
					balance -= price
					upgrades[id] = lvl + 1
					_save()
					_update_balance()
					holder[0].call(), 76)
			b.add_theme_font_size_override("font_size", 25)
			cv.add_child(b)
			list.add_child(card)
	holder.append(refresh)
	refresh.call()
	v.add_child(_big_button("Закрыть", C_MUTED, func():
		m[0].queue_free()
		_refresh_menu(), 96))


## Пока идёт звонок, нейронка придумывает следующего клиента.
## Примерно каждый третий — пародия на известного персонажа.
func _prefetch_caller() -> void:
	if generating or not next_profile.is_empty() or LLM.api_key.is_empty():
		return
	generating = true
	var avoid := used_names.duplicate()
	for c in Callers.LIST:
		avoid.append(c["name"])
	var gen := prefetch_gen
	var sch := Upgrades.pick_scheme(schemes)
	var p: Dictionary = await Callers.generate(randf() < 0.35, avoid, sch["premise"])
	generating = false
	if gen != prefetch_gen:
		_prefetch_caller()
		return
	if not p.is_empty() and not (p["name"] in used_names):
		p["scheme"] = sch["id"]
		next_profile = p


func _log_line(who: String, text: String) -> void:
	if call_rec.has("lines"):
		call_rec["lines"].append([who, text])


func _finish_record(outcome: String) -> void:
	if call_rec.is_empty():
		return
	var money: int = call_rec.get("money", 0)
	call_rec["outcome"] = ("получено %s; " % _rub(money) if money > 0 else "") + outcome
	_save()


func _set_controls() -> void:
	var live := session != null and session.active
	var talking := live and not session.busy and not transcribing
	input.editable = talking
	send_btn.disabled = not talking
	mic_btn.disabled = not (talking or recorder.recording)
	hang_btn.disabled = not live
	terminal_btn.text = "▤ Терминал ●" if (dictated_card != "" or dictated_gift != "") else "▤ Терминал"
	var last := shift_calls >= _calls_max()
	next_btn.text = ("★ Итоги" if last else "☎ Дальше") if not live else ("★ Итоги" if last else "☎ Дальше")
	_paint_button(next_btn, C_GREEN if (not live and session != null) else C_YELLOW)
	if mic_icon:
		mic_icon.modulate.a = 0.6 if mic_btn.disabled else 1.0
		mic_icon.set("recording", recorder.recording)
		mic_icon.queue_redraw()


func _scroll_down() -> void:
	await get_tree().process_frame
	await get_tree().process_frame  # ждём, пока переписка пересчитает размеры
	chat_scroll.scroll_vertical = int(chat_scroll.get_v_scroll_bar().max_value)


func _add_bubble(who: String, text: String, mine: bool) -> void:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bubble := PanelContainer.new()
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _box(C_ME_BUBBLE if mine else C_CALLER_BUBBLE, 26, 20)
	if mine:
		sb.corner_radius_bottom_right = 6
	else:
		sb.corner_radius_bottom_left = 6
	bubble.add_theme_stylebox_override("panel", sb)
	bubble.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bubble.size_flags_stretch_ratio = 5.0
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	bubble.add_child(v)
	var who_l := _label(who, 21, C_ACCENT if mine else C_BLUE)
	who_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(who_l)
	v.add_child(_label(text, 28, C_INK, true))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if mine:
		row.add_child(spacer)
		row.add_child(bubble)
	else:
		row.add_child(bubble)
		row.add_child(spacer)
	chat_list.add_child(row)
	_scroll_down()


## Служебная заметка по центру переписки. strong — яркая плашка для важного.
func _add_note(text: String, color := C_MUTED, strong := false) -> void:
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", _box(color.lerp(Color.WHITE, 0.6 if strong else 0.88), 20, 18))
	var l := _label(text, 23, color.darkened(0.25) if strong else color, true, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size.x = mini(560, 40 + text.length() * 13)
	p.add_child(l)
	c.add_child(p)
	chat_list.add_child(c)
	_scroll_down()


func _say(text: String) -> void:
	if session == null or not session.active or session.busy:
		return
	_log_line("Вы", text)
	_add_bubble("Вы", text, true)
	session.say(text)


func _on_send() -> void:
	var t := input.text.replace("\n", " ").strip_edges()
	if t.is_empty():
		return
	input.text = ""
	_on_input_changed()
	input.release_focus()  # прячем клавиатуру, чтобы был виден ответ
	_say(t)


func _on_hang_up() -> void:
	if session:
		session.hang_up()


func _on_thinking(on: bool) -> void:
	status_label.text = "Клиент думает…" if on else ""
	_set_controls()


func _on_card_dictated(card: String) -> void:
	dictated_card = card
	_log_line(session.profile["name"], "(присылает номер своей карты)")
	pinned_card_btn.text = "⧉ Карта " + card
	pinned_card_btn.show()
	_add_bubble(session.profile["name"], "✉ " + card, false)
	var copy_btn := _big_button("⧉ Скопировать номер", C_BLUE, func():
		DisplayServer.clipboard_set(card.replace(" ", ""))
		_add_note("Номер скопирован. Вставьте его в терминале.", C_BLUE), 86)
	copy_btn.add_theme_font_size_override("font_size", 27)
	chat_list.add_child(copy_btn)
	_add_note("Клиент прислал номер карты. Откройте терминал!", C_GREEN, true)
	_set_controls()


func _on_trust(value: int, delta: int) -> void:
	trust_label.text = "Шанс %d%%" % value
	var col := C_RED if value < 30 else (C_YELLOW if value < 60 else C_GREEN)
	trust_fill.bg_color = col
	if delta == 0:
		trust_bar.value = value
	else:
		create_tween().tween_property(trust_bar, "value", float(value), 0.35).set_trans(Tween.TRANS_CUBIC)
		_add_note("доверие %+d" % delta, C_GREEN if delta > 0 else C_RED)


func _on_call_ended(reason: String) -> void:
	var msg := {"hung_up": "Клиент бросил трубку.", "operator": "Вы положили трубку.", "card_given": "Звонок завершён."}
	var log_msg := {"hung_up": "клиент бросил трубку", "operator": "оператор положил трубку"}
	_finish_record(log_msg.get(reason, "звонок завершён"))
	if not call_paid:
		heat = maxi(0, heat - 3)  # пустой звонок: полиция понемногу забывает о нас
		_update_balance()
	if recorder.recording:
		recorder.stop()
	input.release_focus()
	_add_note(msg.get(reason, "Звонок завершён.") + ("  Жмите «Итоги»." if shift_calls >= _calls_max() else "  Жмите «Дальше»."), C_INK, true)
	_set_controls()


func _update_balance() -> void:
	balance_label.text = _rub(balance)
	deals_label.text = _rank_name() + " · смена %d · звонок %d из %d" % [shift, shift_calls, _calls_max()]
	quota_label.text = "план %s / %s" % [_rub(shift_earned), _rub(quota)]
	quota_bar.max_value = quota
	quota_bar.value = mini(shift_earned, quota)
	heat_bar.value = heat
	heat_label.text = "Жара %d%%" % heat
	var hcol := Color("ffe08a") if heat < 50 else (Color("ffb04a") if heat < 80 else Color("2b0d0d"))
	(heat_bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = hcol


## 12500 -> «12 500 ₽»
static func _rub(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += " "
		out += s[i]
	return ("-" if n < 0 else "") + out + " ₽"


## Итог смены и «прикольные моменты». План выполнен — следующая смена
## с планом побольше, не выполнен — смена начинается заново с тем же планом.
func _show_shift_result() -> void:
	_drop_session()
	session = null
	var ok := shift_earned >= quota
	best_shift = maxi(best_shift, shift_earned)
	# План растёт на 8%, но не меньше 60% от заработанного в этой смене, чтобы не отставать от игрока.
	var next_quota := int(round(maxf(quota * QUOTA_GROWTH, shift_earned * 0.6) / 500.0)) * 500 if ok else quota
	# Старые схемы приносят доход, только если смена вообще работала: весь при выполненном плане, половину иначе.
	var passive := 0 if shift_earned <= 0 else (Upgrades.passive_income(schemes) if ok else Upgrades.passive_income(schemes) / 2)
	if passive > 0:
		balance += passive
		earned_total += passive
	var m := _modal()
	var dim: Control = m[0]
	var v: VBoxContainer = m[1]
	v.add_child(_label("ПЛАН ВЫПОЛНЕН!" if ok else "ПЛАН ПРОВАЛЕН", 50, C_GREEN if ok else C_RED, false, HORIZONTAL_ALIGNMENT_CENTER))
	var info := _label("Смена %d: заработано %s из %s.\n%s" % [shift, _rub(shift_earned), _rub(quota),
		("Следующий план: " + _rub(next_quota)) if ok else "Начальник недоволен. Смена начинается заново."] +
		("\nСтарые схемы принесли ещё %s на счёт." % _rub(passive) if passive > 0 else ""), 27, C_INK, true, HORIZONTAL_ALIGNMENT_CENTER)
	info.custom_minimum_size.x = 580
	v.add_child(info)
	v.add_child(_label("★ Лучшие моменты смены", 34, C_PURPLE))
	var holder := VBoxContainer.new()
	v.add_child(holder)
	var wait := _label("Вспоминаем смену…", 26, C_MUTED, true)
	holder.add_child(wait)
	var dots := create_tween().set_loops()
	dots.tween_property(wait, "modulate:a", 0.35, 0.5)
	dots.tween_property(wait, "modulate:a", 1.0, 0.5)

	var log_copy := shift_log.duplicate(true)
	heat = maxi(0, heat - 20)
	# Сразу закрываем смену в сохранении, чтобы итог не потерялся при выходе.
	if ok:
		shift += 1
		quota = next_quota
	var done_shift := shift
	shift_earned = 0
	shift_calls = 0
	shift_log = []
	_save()
	_update_balance()
	v.add_child(_big_button("Начать смену %d" % done_shift, C_GREEN if ok else C_ACCENT, func():
		dim.queue_free()
		_clear_chat()
		_next_call(), 120))
	v.add_child(_big_button("$ Магазин", C_ACCENT, _show_shop, 90))
	v.add_child(_big_button("В меню", C_MUTED, func():
		dim.queue_free()
		_clear_chat()
		_show_menu(), 90))

	var moments: Array = await ShiftRecap.find_moments(log_copy)
	if not is_instance_valid(holder):
		if not moments.is_empty():
			last_moments = moments
			_save()
		return
	dots.kill()
	wait.modulate.a = 1.0
	if moments.is_empty():
		wait.text = "В этой смене ничего смешного не нашлось. Попробуйте говорить с клиентами побольше." if log_copy.size() > 0 else "Смена была пустой."
		return
	last_moments = moments
	_save()
	wait.queue_free()
	var h := mini(600, 190 * moments.size())
	var sc := _moments_scroll(moments, h)
	holder.add_child(sc)
	for card in sc.get_child(0).get_children():
		_pop_in(card)


# ---------- голос ----------

## Голос. С ключом Groq: нажал — пишем, нажал ещё раз — распознаём бесплатным
## Whisper и сразу отправляем. Без ключа открываем клавиатуру с её диктовкой.
func _on_mic() -> void:
	if recorder.recording:
		var wav := recorder.stop()
		_set_controls()
		if wav.size() < 44 + 16000:  # меньше полсекунды
			_add_note("Слишком коротко. Нажмите микрофон, скажите фразу и нажмите ещё раз.", C_MUTED)
			return
		if VoiceRecorder.peak(wav) < 0.01:
			_add_note("Ничего не слышно. Проверьте, что игре разрешён микрофон.", C_RED)
			return
		transcribing = true
		status_label.text = "Распознаю голос…"
		_set_controls()
		var res: Dictionary = await LLM.transcribe(wav)
		transcribing = false
		status_label.text = ""
		_set_controls()
		if not res["ok"]:
			_add_note("Голос не распознан: " + str(res["error"]), C_RED)
			return
		var t: String = res["text"].replace("\n", " ").strip_edges()
		if t.is_empty():
			_add_note("Речь не разобрать. Попробуйте ещё раз.", C_MUTED)
			return
		_say(t)
		return
	if session == null or not session.active or session.busy:
		return
	if LLM.voice_key.is_empty():
		_keyboard_dictation()
		return
	if not VoiceRecorder.has_permission():
		VoiceRecorder.ask_permission()
		_add_note("Разрешите игре доступ к микрофону.", C_BLUE)
		return
	input.release_focus()
	recorder.start()
	_set_controls()


func _keyboard_dictation() -> void:
	input.grab_focus()
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_show(input.text, Rect2(), DisplayServer.KEYBOARD_TYPE_MULTILINE)
	if not voice_hint_shown:
		voice_hint_shown = true
		_add_note("Нажмите значок микрофона на клавиатуре и говорите, потом ➤. Чтобы игра слушала сама, добавьте бесплатный ключ голоса в меню «Ключи».", C_PURPLE, true)
	status_label.text = "Диктуйте через микрофон на клавиатуре"


# ---------- ввод и клавиатура ----------

## Поле ввода растёт по мере набора (до INPUT_MAX_H), чтобы текст был виден целиком.
func _on_input_changed() -> void:
	var lines := 0
	for i in input.get_line_count():
		lines += input.get_line_wrap_count(i) + 1
	var h := lines * input.get_line_height() + 36
	input.custom_minimum_size.y = clampf(h, INPUT_MIN_H, INPUT_MAX_H)
	input.adjust_viewport_to_caret()  # строка с курсором всегда видна


func _process(_delta: float) -> void:
	if menu and not menu.visible:
		play_seconds += _delta
	if recorder and recorder.recording:
		var sec := int(recorder.elapsed())
		status_label.text = "● Запись %d:%02d · нажмите микрофон, чтобы отправить" % [sec / 60, sec % 60]
		status_label.add_theme_color_override("font_color", C_RED)
		mic_icon.queue_redraw()
		if recorder.elapsed() > VoiceRecorder.MAX_SECONDS:
			_on_mic()
	elif status_label.get_theme_color("font_color") != C_MUTED:
		status_label.add_theme_color_override("font_color", C_MUTED)
		if status_label.text.begins_with("●"):
			status_label.text = ""
	_follow_keyboard()


## Экранная клавиатура телефона: поднимаем весь экран и терминал над ней.
func _follow_keyboard() -> void:
	var px := 0.0
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		px = float(DisplayServer.virtual_keyboard_get_height())
	if OS.get_environment("KB_TEST") == "1":  # для проверки без телефона
		px = 600.0 if (input.has_focus() or card_input.has_focus()) else 0.0
	var win_h := float(DisplayServer.window_get_size().y)
	var h := 0.0
	if px > 0.0 and win_h > 0.0:
		h = px * get_viewport_rect().size.y / win_h
	if absf(h - kb_height) < 1.0:
		return
	kb_height = h
	var up := h > 0.0
	main_margin.add_theme_constant_override("margin_bottom", 18 + int(h))
	main_margin.add_theme_constant_override("margin_top", 16 if up else 34)
	term_sheet.offset_bottom = -h
	term_sheet.offset_top = -780 - h
	caller_info.visible = not up  # освобождаем место под переписку
	chips_box.visible = not up
	actions_box.visible = not up
	header_box.visible = not up
	_scroll_down()


## Прокрутка пальцем. Свои обработчики, потому что на телефоне стандартная
## прокрутка в переписке и в поле ввода срабатывала ненадёжно.
func _input(event: InputEvent) -> void:
	if not (event is InputEventScreenDrag):
		return
	for sc in overlay_scrolls.duplicate():
		if not is_instance_valid(sc):
			overlay_scrolls.erase(sc)
		elif sc.is_visible_in_tree() and sc.get_global_rect().has_point(event.position):
			sc.scroll_vertical -= int(event.relative.y)
			get_viewport().set_input_as_handled()
			return
	if terminal.visible or (menu and menu.visible):
		return
	if chat_scroll.get_global_rect().has_point(event.position):
		chat_scroll.scroll_vertical -= int(event.relative.y)
		get_viewport().set_input_as_handled()
	elif input.get_global_rect().has_point(event.position):
		input.scroll_vertical -= event.relative.y / float(input.get_line_height())
		get_viewport().set_input_as_handled()


## Значок микрофона, нарисованный вручную (эмодзи на телефонах показываются квадратиками).
class MicIcon extends Control:
	var recording := false

	func _draw() -> void:
		var c := size / 2.0
		var col := Color.WHITE
		if recording:
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 160.0)
			draw_circle(c, 34 + 4 * pulse, Color(1, 1, 1, 0.25))
			draw_rect(Rect2(c - Vector2(14, 14), Vector2(28, 28)), col)
			return
		var w := 22.0
		var hh := 34.0
		var top := c + Vector2(0, -24)
		draw_circle(top + Vector2(0, w / 2), w / 2, col)
		draw_rect(Rect2(top.x - w / 2, top.y + w / 2, w, hh - w), col)
		draw_circle(top + Vector2(0, hh - w / 2), w / 2, col)
		draw_arc(c + Vector2(0, -2), 20, 0.15, PI - 0.15, 24, col, 4.0, true)
		draw_line(c + Vector2(0, 18), c + Vector2(0, 28), col, 4.0)
		draw_line(c + Vector2(-12, 28), c + Vector2(12, 28), col, 4.0)
