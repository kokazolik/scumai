extends Control
## Имитация рабочего стола оператора: окно звонка и платёжный терминал.
## Весь интерфейс собирается кодом, чтобы сцену было легко переделать в редакторе.

const CHARGE := 200

var balance := 0
var caller_index := 0
var session: CallSession
var dictated_card := ""

var log_box: RichTextLabel
var input: LineEdit
var send_btn: Button
var card_btn: Button
var hang_btn: Button
var next_btn: Button
var trust_bar: ProgressBar
var trust_label: Label
var caller_label: Label
var status_label: Label
var card_input: LineEdit
var charge_btn: Button
var terminal_log: Label
var balance_label: Label


func _ready() -> void:
	randomize()
	var bg := ColorRect.new()
	bg.color = Color("1d4e6e")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_build_taskbar()
	_build_phone_window()
	_build_terminal_window()
	if LLM.api_key.is_empty():
		_ask_key()
	else:
		_next_call()


## Окно ввода ключа OpenRouter при первом запуске (ключ не вшивается в APK).
func _ask_key() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(620, 0)
	panel.position = Vector2(330, 260)
	dim.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	var l := Label.new()
	l.text = "Вставьте ключ OpenRouter (openrouter.ai/settings/keys).\nОн сохранится только на этом устройстве."
	v.add_child(l)
	var e := LineEdit.new()
	e.placeholder_text = "sk-or-v1-..."
	e.secret = true
	v.add_child(e)
	var b := Button.new()
	b.text = "Сохранить"
	v.add_child(b)
	b.pressed.connect(func():
		if e.text.strip_edges().begins_with("sk-or-"):
			LLM.save_key(e.text)
			dim.queue_free()
			_next_call()
		else:
			l.text = "Ключ должен начинаться с sk-or-")


# ---------- интерфейс ----------

func _window(title: String, pos: Vector2, size: Vector2) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.position = pos
	panel.size = size
	add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	var bar := Label.new()
	bar.text = "  " + title
	bar.add_theme_color_override("font_color", Color.WHITE)
	var bar_bg := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("2b5797")
	bar_bg.add_theme_stylebox_override("panel", sb)
	bar_bg.add_child(bar)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bar_bg.gui_input.connect(func(e):
		if e is InputEventMouseMotion and e.button_mask & MOUSE_BUTTON_MASK_LEFT:
			panel.position += e.relative)
	v.add_child(bar_bg)
	var body := VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	return body


func _build_taskbar() -> void:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -36
	add_child(bar)
	var h := HBoxContainer.new()
	bar.add_child(h)
	var start := Label.new()
	start.text = "  ☰ Контора  "
	h.add_child(start)
	balance_label = Label.new()
	balance_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(balance_label)
	_update_balance()


func _build_phone_window() -> void:
	var w := _window("Телефон — входящий звонок", Vector2(30, 30), Vector2(700, 600))
	caller_label = Label.new()
	w.add_child(caller_label)

	var th := HBoxContainer.new()
	w.add_child(th)
	trust_label = Label.new()
	trust_label.custom_minimum_size.x = 130
	th.add_child(trust_label)
	trust_bar = ProgressBar.new()
	trust_bar.max_value = CallSession.MAX_TRUST
	trust_bar.show_percentage = false
	trust_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trust_bar.custom_minimum_size.y = 18
	th.add_child(trust_bar)

	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	w.add_child(log_box)

	status_label = Label.new()
	status_label.modulate = Color(1, 1, 1, 0.6)
	w.add_child(status_label)

	var ih := HBoxContainer.new()
	w.add_child(ih)
	input = LineEdit.new()
	input.placeholder_text = "Что вы скажете клиенту..."
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.text_submitted.connect(func(_t): _on_send())
	ih.add_child(input)
	send_btn = Button.new()
	send_btn.text = "Сказать"
	send_btn.pressed.connect(_on_send)
	ih.add_child(send_btn)

	var bh := HBoxContainer.new()
	w.add_child(bh)
	card_btn = Button.new()
	card_btn.text = "Попросить номер карты"
	card_btn.pressed.connect(_on_ask_card)
	bh.add_child(card_btn)
	hang_btn = Button.new()
	hang_btn.text = "Положить трубку"
	hang_btn.pressed.connect(_on_hang_up)
	bh.add_child(hang_btn)
	next_btn = Button.new()
	next_btn.text = "Следующий звонок"
	next_btn.pressed.connect(_next_call)
	bh.add_child(next_btn)


func _build_terminal_window() -> void:
	var w := _window("PayTerminal 2.0", Vector2(760, 60), Vector2(480, 260))
	var l := Label.new()
	l.text = "Номер карты (16 цифр):"
	w.add_child(l)
	card_input = LineEdit.new()
	card_input.placeholder_text = "0000 0000 0000 0000"
	card_input.max_length = 19
	w.add_child(card_input)
	charge_btn = Button.new()
	charge_btn.text = "Списать $%d" % CHARGE
	charge_btn.pressed.connect(_on_charge)
	w.add_child(charge_btn)
	terminal_log = Label.new()
	terminal_log.autowrap_mode = TextServer.AUTOWRAP_WORD
	terminal_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	w.add_child(terminal_log)


# ---------- игра ----------

func _next_call() -> void:
	if session and session.active:
		session.hang_up()
	var p: Dictionary = Callers.LIST[caller_index % Callers.LIST.size()]
	caller_index += 1
	dictated_card = ""
	session = CallSession.new(p)
	session.caller_spoke.connect(func(t): _log("[color=#ffd479]%s:[/color] %s" % [p["name"], t]))
	session.trust_changed.connect(_on_trust)
	session.thinking.connect(_on_thinking)
	session.call_ended.connect(_on_call_ended)
	session.card_dictated.connect(func(c): dictated_card = c)
	log_box.clear()
	caller_label.text = "Звонит: %s, %d лет" % [p["name"], p["age"]]
	_log("[i]Входящий звонок...[/i]")
	_on_trust(session.trust, 0)
	_set_controls()
	session.start()


func _set_controls() -> void:
	var can := session != null and session.active and not session.busy
	input.editable = can
	send_btn.disabled = not can
	card_btn.disabled = not can
	hang_btn.disabled = not (session and session.active)


func _on_thinking(on: bool) -> void:
	status_label.text = "Клиент думает..." if on else ""
	_set_controls()


func _on_hang_up() -> void:
	if session:
		session.hang_up()


func _log(t: String) -> void:
	log_box.append_text(t + "\n")


func _on_send() -> void:
	var t := input.text.strip_edges()
	if t.is_empty() or not session or session.busy:
		return
	input.clear()
	_log("[color=#8fd3ff]Вы:[/color] " + t)
	session.say(t)


func _on_ask_card() -> void:
	_log("[color=#8fd3ff]Вы:[/color] Назовите, пожалуйста, номер карты с лицевой стороны.")
	session.try_ask_card()


func _on_trust(value: int, delta: int) -> void:
	trust_bar.value = value
	trust_label.text = "Доверие: %d" % value
	if delta != 0:
		_log("[color=%s][i]доверие %+d[/i][/color]" % ["#7dff7d" if delta > 0 else "#ff7d7d", delta])


func _on_call_ended(reason: String) -> void:
	var msg := {"hung_up": "Клиент бросил трубку.", "operator": "Вы положили трубку.", "card_given": "Звонок завершён."}
	_log("[i]%s[/i]" % msg.get(reason, "Звонок завершён."))
	_set_controls()


func _on_charge() -> void:
	var digits := card_input.text.replace(" ", "").replace("-", "")
	if digits.length() != 16 or not digits.is_valid_int():
		terminal_log.text = "Ошибка: нужно 16 цифр."
		return
	if dictated_card != "" and digits == dictated_card.replace(" ", ""):
		balance += CHARGE
		terminal_log.text = "Операция одобрена. Списано $%d." % CHARGE
		dictated_card = ""
		_update_balance()
	else:
		terminal_log.text = "Операция отклонена: карта не найдена."
	card_input.clear()


func _update_balance() -> void:
	balance_label.text = "Баланс: $%d   " % balance
