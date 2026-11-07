extends Control
## Экран оператора для телефона (вертикальный, 720x1280).
## Сверху баланс, ниже карточка клиента и шкала доверия, переписка,
## быстрые фразы, поле ввода и крупные кнопки действий.
## Платёжный терминал выезжает отдельным экраном поверх звонка.
## Весь интерфейс собирается кодом.

const CHARGE := 200

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
const C_CALLER_BUBBLE := Color("eef2ff")
const C_ME_BUBBLE := Color("ffe2d6")

const QUICK_PHRASES := [
	"Здравствуйте! Чем могу помочь?",
	"Не волнуйтесь, мы всё решим.",
	"Расскажите подробнее, пожалуйста.",
	"У нас как раз сегодня акция!",
]

var balance := 0
var deals := 0
var caller_index := 0
var session: CallSession
var dictated_card := ""

var balance_label: Label
var deals_label: Label
var caller_name: Label
var caller_info: Label
var trust_bar: ProgressBar
var trust_fill: StyleBoxFlat
var trust_label: Label
var chat_scroll: ScrollContainer
var chat_list: VBoxContainer
var status_label: Label
var input: LineEdit
var send_btn: Button
var quick_box: HBoxContainer
var card_btn: Button
var hang_btn: Button
var next_btn: Button
var terminal_btn: Button

var terminal: Control
var term_hint: Label
var card_input: LineEdit
var term_result: Label


func _ready() -> void:
	randomize()
	theme = _make_theme()
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	margin.add_theme_constant_override("margin_top", 40)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	root.add_child(_build_header())
	root.add_child(_build_caller_card())
	root.add_child(_build_chat())
	root.add_child(_build_quick_phrases())
	root.add_child(_build_input_row())
	root.add_child(_build_actions())

	terminal = _build_terminal()
	add_child(terminal)
	terminal.hide()

	if LLM.api_key.is_empty():
		_add_bubble("Система", "Нет ключа OpenRouter. Сборка сделана без ключа.", false)
	_next_call()


# ---------- тема ----------

func _box(color: Color, radius := 22, pad := 18) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad * 0.6
	sb.content_margin_bottom = pad * 0.6
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 30
	t.set_color("font_color", "Label", C_INK)
	# Кнопки
	t.set_stylebox("normal", "Button", _box(C_BLUE))
	t.set_stylebox("hover", "Button", _box(C_BLUE.lightened(0.1)))
	t.set_stylebox("pressed", "Button", _box(C_BLUE.darkened(0.2)))
	t.set_stylebox("disabled", "Button", _box(Color("c9cbd6")))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(s, "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", Color("f4f4f8"))
	# Поле ввода
	var le := _box(C_CARD, 22, 20)
	le.border_color = Color("d8d2c0")
	le.set_border_width_all(3)
	t.set_stylebox("normal", "LineEdit", le)
	var lef := le.duplicate()
	lef.border_color = C_BLUE
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_stylebox("read_only", "LineEdit", le)
	t.set_color("font_color", "LineEdit", C_INK)
	t.set_color("font_placeholder_color", "LineEdit", C_MUTED)
	t.set_color("caret_color", "LineEdit", C_BLUE)
	# Полоса доверия
	t.set_stylebox("background", "ProgressBar", _box(Color("ece6d3"), 18, 0))
	# Полосы прокрутки потоньше
	t.set_constant("scrollbar_h_separation", "ScrollContainer", 0)
	return t


func _big_button(text: String, color: Color, cb: Callable, height := 110) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = height
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 32)
	b.add_theme_stylebox_override("normal", _box(color))
	b.add_theme_stylebox_override("hover", _box(color.lightened(0.1)))
	b.add_theme_stylebox_override("pressed", _box(color.darkened(0.2)))
	b.pressed.connect(cb)
	return b


func _card() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(C_CARD, 28, 22))
	return p


# ---------- экран звонка ----------

func _build_header() -> Control:
	var h := HBoxContainer.new()
	var title := Label.new()
	title.text = "☎ КОНТОРА"
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", C_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(title)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	balance_label = Label.new()
	balance_label.add_theme_font_size_override("font_size", 44)
	balance_label.add_theme_color_override("font_color", C_GREEN)
	balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(balance_label)
	deals_label = Label.new()
	deals_label.add_theme_font_size_override("font_size", 22)
	deals_label.add_theme_color_override("font_color", C_MUTED)
	deals_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(deals_label)
	h.add_child(v)
	_update_balance()
	return h


func _build_caller_card() -> Control:
	var card := _card()
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	card.add_child(v)
	caller_name = Label.new()
	caller_name.add_theme_font_size_override("font_size", 36)
	v.add_child(caller_name)
	caller_info = Label.new()
	caller_info.add_theme_font_size_override("font_size", 24)
	caller_info.add_theme_color_override("font_color", C_MUTED)
	caller_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(caller_info)

	var th := HBoxContainer.new()
	v.add_child(th)
	trust_label = Label.new()
	trust_label.custom_minimum_size.x = 210
	trust_label.add_theme_font_size_override("font_size", 28)
	th.add_child(trust_label)
	trust_bar = ProgressBar.new()
	trust_bar.max_value = CallSession.MAX_TRUST
	trust_bar.show_percentage = false
	trust_bar.custom_minimum_size.y = 40
	trust_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trust_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	trust_fill = _box(C_YELLOW, 18, 0)
	trust_bar.add_theme_stylebox_override("fill", trust_fill)
	th.add_child(trust_bar)
	return card


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
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 24)
	status_label.add_theme_color_override("font_color", C_MUTED)
	v.add_child(status_label)
	return card


func _build_quick_phrases() -> Control:
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.custom_minimum_size.y = 84
	quick_box = HBoxContainer.new()
	quick_box.add_theme_constant_override("separation", 10)
	scroll.add_child(quick_box)
	for p in QUICK_PHRASES:
		var b := Button.new()
		b.text = p
		b.custom_minimum_size.y = 72
		b.add_theme_font_size_override("font_size", 24)
		var sb := _box(C_CARD, 36, 18)
		sb.border_color = C_BLUE
		sb.set_border_width_all(3)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		var sbp := sb.duplicate()
		sbp.bg_color = C_CALLER_BUBBLE
		b.add_theme_stylebox_override("pressed", sbp)
		b.add_theme_color_override("font_color", C_BLUE)
		b.add_theme_color_override("font_hover_color", C_BLUE)
		b.add_theme_color_override("font_pressed_color", C_BLUE)
		b.pressed.connect(_say.bind(p))
		quick_box.add_child(b)
	return scroll


func _build_input_row() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	input = LineEdit.new()
	input.placeholder_text = "Ваша реплика..."
	input.custom_minimum_size.y = 100
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.text_submitted.connect(func(_t): _on_send())
	h.add_child(input)
	send_btn = _big_button("➤", C_ACCENT, _on_send, 100)
	send_btn.size_flags_horizontal = Control.SIZE_FILL
	send_btn.custom_minimum_size.x = 120
	send_btn.add_theme_font_size_override("font_size", 44)
	h.add_child(send_btn)
	return h


func _build_actions() -> Control:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 12)
	card_btn = _big_button("$ Попросить карту", C_GREEN, _on_ask_card)
	terminal_btn = _big_button("▤ Терминал", C_BLUE, _open_terminal)
	hang_btn = _big_button("✖ Положить трубку", C_RED, _on_hang_up)
	next_btn = _big_button("☎ Следующий", C_YELLOW, _next_call)
	next_btn.add_theme_color_override("font_color", C_INK)
	next_btn.add_theme_color_override("font_pressed_color", C_INK)
	next_btn.add_theme_color_override("font_hover_color", C_INK)
	for b in [card_btn, terminal_btn, hang_btn, next_btn]:
		g.add_child(b)
	return g


# ---------- терминал ----------

func _build_terminal() -> Control:
	var dim := ColorRect.new()
	dim.color = Color(0.12, 0.13, 0.25, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP

	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", _box(C_CARD, 36, 32))
	sheet.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	sheet.offset_top = -760
	dim.add_child(sheet)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 20)
	sheet.add_child(v)

	var title := Label.new()
	title.text = "▤ PayTerminal 2.0"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", C_BLUE)
	v.add_child(title)

	term_hint = Label.new()
	term_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	term_hint.add_theme_font_size_override("font_size", 26)
	term_hint.add_theme_color_override("font_color", C_MUTED)
	v.add_child(term_hint)

	card_input = LineEdit.new()
	card_input.placeholder_text = "0000 0000 0000 0000"
	card_input.max_length = 19
	card_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	card_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	card_input.custom_minimum_size.y = 120
	card_input.add_theme_font_size_override("font_size", 42)
	card_input.text_changed.connect(_format_card_input)
	v.add_child(card_input)

	v.add_child(_big_button("Списать $%d" % CHARGE, C_GREEN, _on_charge, 130))

	term_result = Label.new()
	term_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	term_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	term_result.add_theme_font_size_override("font_size", 30)
	v.add_child(term_result)

	v.add_child(_big_button("← Назад к звонку", C_MUTED, _close_terminal, 100))
	return dim


func _open_terminal() -> void:
	term_result.text = ""
	if dictated_card != "":
		term_hint.text = "Клиент продиктовал: " + dictated_card
	else:
		term_hint.text = "Сначала уговорите клиента назвать номер карты."
	terminal.show()
	card_input.grab_focus()


func _close_terminal() -> void:
	card_input.release_focus()
	terminal.hide()


## Расставляет пробелы по 4 цифры, пока игрок печатает.
func _format_card_input(t: String) -> void:
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
	var digits := card_input.text.replace(" ", "")
	if digits.length() != 16:
		_term_says("Нужно 16 цифр.", C_RED)
		return
	if dictated_card != "" and digits == dictated_card.replace(" ", ""):
		balance += CHARGE
		deals += 1
		dictated_card = ""
		_update_balance()
		card_input.text = ""
		_term_says("✔ Операция одобрена. Списано $%d." % CHARGE, C_GREEN)
		_set_controls()
	else:
		_term_says("✖ Операция отклонена: карта не найдена.", C_RED)


func _term_says(t: String, c: Color) -> void:
	term_result.text = t
	term_result.add_theme_color_override("font_color", c)


# ---------- игра ----------

func _next_call() -> void:
	if session and session.active:
		session.hang_up()
	var p: Dictionary = Callers.LIST[caller_index % Callers.LIST.size()]
	caller_index += 1
	dictated_card = ""
	session = CallSession.new(p)
	session.caller_spoke.connect(func(t): _add_bubble(p["name"], t, false))
	session.trust_changed.connect(_on_trust)
	session.thinking.connect(_on_thinking)
	session.call_ended.connect(_on_call_ended)
	session.card_dictated.connect(_on_card_dictated)
	for c in chat_list.get_children():
		c.queue_free()
	caller_name.text = "%s, %d" % [p["name"], p["age"]]
	caller_info.text = "Узнал(а) о нас: " + p["source"]
	_add_note("Входящий звонок...")
	_on_trust(session.trust, 0)
	_set_controls()
	session.start()


func _set_controls() -> void:
	var talking := session != null and session.active and not session.busy
	input.editable = talking
	send_btn.disabled = not talking
	card_btn.disabled = not talking
	for b in quick_box.get_children():
		b.disabled = not talking
	hang_btn.disabled = not (session != null and session.active)
	terminal_btn.text = "▤ Терминал ●" if dictated_card != "" else "▤ Терминал"


func _scroll_down() -> void:
	await get_tree().process_frame
	chat_scroll.scroll_vertical = int(chat_scroll.get_v_scroll_bar().max_value)


func _add_bubble(who: String, text: String, mine: bool) -> void:
	var row := HBoxContainer.new()
	var bubble := PanelContainer.new()
	bubble.add_theme_stylebox_override("panel", _box(C_ME_BUBBLE if mine else C_CALLER_BUBBLE, 24, 18))
	bubble.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bubble.size_flags_stretch_ratio = 5.0
	var v := VBoxContainer.new()
	bubble.add_child(v)
	var name_l := Label.new()
	name_l.text = who
	name_l.add_theme_font_size_override("font_size", 22)
	name_l.add_theme_color_override("font_color", C_ACCENT if mine else C_BLUE)
	v.add_child(name_l)
	var text_l := Label.new()
	text_l.text = text
	text_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_l.add_theme_font_size_override("font_size", 28)
	v.add_child(text_l)
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


func _add_note(text: String, color := C_MUTED) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", color)
	chat_list.add_child(l)
	_scroll_down()


func _say(text: String) -> void:
	if session == null or not session.active or session.busy:
		return
	_add_bubble("Вы", text, true)
	session.say(text)


func _on_send() -> void:
	var t := input.text.strip_edges()
	if t.is_empty():
		return
	input.clear()
	input.release_focus()  # прячем клавиатуру, чтобы был виден ответ
	_say(t)


func _on_ask_card() -> void:
	if session == null or not session.active or session.busy:
		return
	_add_bubble("Вы", "Назовите, пожалуйста, номер карты с лицевой стороны.", true)
	session.try_ask_card()


func _on_hang_up() -> void:
	if session:
		session.hang_up()


func _on_thinking(on: bool) -> void:
	status_label.text = "Клиент думает…" if on else ""
	_set_controls()


func _on_card_dictated(card: String) -> void:
	dictated_card = card
	_add_note("Клиент продиктовал карту. Откройте терминал!", C_GREEN)
	_set_controls()


func _on_trust(value: int, delta: int) -> void:
	trust_bar.value = value
	trust_label.text = "Доверие %d" % value
	trust_fill.bg_color = C_RED if value < 30 else (C_YELLOW if value < 60 else C_GREEN)
	if delta != 0:
		_add_note("доверие %+d" % delta, C_GREEN if delta > 0 else C_RED)


func _on_call_ended(reason: String) -> void:
	var msg := {"hung_up": "Клиент бросил трубку.", "operator": "Вы положили трубку.", "card_given": "Звонок завершён."}
	_add_note(msg.get(reason, "Звонок завершён."))
	_set_controls()


func _update_balance() -> void:
	balance_label.text = "$%d" % balance
	deals_label.text = "сделок: %d" % deals
