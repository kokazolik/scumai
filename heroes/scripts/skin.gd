extends RefCounted
## Фэнтези-скин «тёмный фолиант»: кожа, пергамент, кованое золото.
## Все текстуры в res://art/ui/ сгенерированы процедурно (см. art/ATTRIBUTION.md),
## шрифты — OFL (fonts/OFL-*.txt).
##
## Использование:  const UISkin = preload("res://scripts/skin.gd")
## (имя `Skin` занято встроенным классом Godot — «shadows a native class», поэтому UISkin)
##   panel.add_theme_stylebox_override("panel", UISkin.panel("parchment"))
##   UISkin.style_button(btn, "gold")    # или overrides из UISkin.button_styles("gold")
##   UISkin.style_bar(progress_bar, "hp")
##   label.add_theme_font_override("font", UISkin.title_font())
##
## Ресурсы кэшируются в статических словарях; каждый вызов panel()/button_styles()
## возвращает новый StyleBox (его можно менять), текстуры и шрифты общие.

const UI := "res://art/ui/"

# ---------- цвета ----------
const INK := Color("f3e9d2")             ## основной светлый текст на тёмной коже
const INK_DIM := Color("bfae8f")         ## второстепенный текст на тёмном
const INK_MUTED := Color("8a7a64")       ## подсказки / плейсхолдеры
const INK_PARCHMENT := Color("3a2210")   ## тёмно-коричневые «чернила» на пергаменте
const INK_PARCHMENT_DIM := Color("6e4a28")
const INK_PARCHMENT_RED := Color("8e1b12")  ## выделение/имена на пергаменте (рубрика)
const GOLD := Color("ffc145")            ## акцент, заголовки на тёмном
const GOLD_LIGHT := Color("ffe39a")
const GOLD_DARK := Color("a8741e")
const TEXT_ON_GOLD := Color("2a1606")    ## текст на золотой кнопке
const OUTLINE := Color("120a06")         ## обводка текста
const HP_RED := Color("e0453a")
const HEAL_GREEN := Color("7fd36a")
const MANA_BLUE := Color("6fb2ff")
const BG_DARK := Color("120c09")         ## цвет под фоном (clear color)
const RARITY := {
	"common": Color("d8cdb8"), "magic": Color("5aa0ff"),
	"rare": Color("c07bff"), "legend": Color("ffab3d"),
}

# ---------- 9-patch ----------
## kind: [файл, отступ L, T, R, B (texture margins), толщина рамки (базовый content margin), тайлить центр]
const PATCH := {
	"dark":        ["panel_dark.png", 44, 44, 44, 44, 14, true],     # главная панель с золотыми уголками
	"dark_plain":  ["panel_dark_plain.png", 28, 28, 28, 28, 12, true],  # панель с двойной рамкой без уголков
	"inset":       ["panel_inset.png", 22, 22, 22, 22, 5, true],     # тонкая карточка (лог, строки списков)
	"parchment":   ["panel_parchment.png", 48, 48, 48, 48, 18, true],  # пергамент для текста Мастера
	"slot":        ["slot.png", 28, 28, 28, 28, 7, false],
	"slot_magic":  ["slot_magic.png", 28, 28, 28, 28, 7, false],
	"slot_rare":   ["slot_rare.png", 28, 28, 28, 28, 7, false],
	"slot_legend": ["slot_legend.png", 28, 28, 28, 28, 7, false],
	"tab_on":      ["tab_on.png", 28, 24, 28, 12, 6, false],
	"tab_off":     ["tab_off.png", 28, 24, 28, 12, 6, false],
	"ribbon":      ["header_ribbon.png", 110, 0, 110, 0, 0, false],
	"bar_bg":      ["bar_bg.png", 16, 15, 16, 15, 4, false],
	"bar_hp":      ["bar_fill_hp.png", 16, 15, 16, 15, 0, false],
	"bar_xp":      ["bar_fill_xp.png", 16, 15, 16, 15, 0, false],
	"bar_mana":    ["bar_fill_mana.png", 16, 15, 16, 15, 0, false],
}
## Кнопки: 128x88, texture margins 22/16/22/16 (центр тянется по вертикали, тайлится по горизонтали) -> мин. высота 32, рекомендуемая 52–88.
const BUTTON_MARGIN := [22, 16, 22, 16]
const BUTTON_KINDS := ["gold", "dark", "red", "green", "blue", "purple"]

static var _tex := {}
static var _fonts := {}


static func tex(file: String) -> Texture2D:
	if not _tex.has(file):
		_tex[file] = load(UI + file) as Texture2D
	return _tex[file]


static func _sbt(file: String, m: Array, tile := false, tile_h := false) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = tex(file)
	sb.texture_margin_left = m[0]
	sb.texture_margin_top = m[1]
	sb.texture_margin_right = m[2]
	sb.texture_margin_bottom = m[3]
	if tile:
		sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
		sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	elif tile_h:
		sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	return sb


## Панель-StyleBox. kinds: dark, dark_plain, inset, parchment, slot, slot_magic, slot_rare,
## slot_legend, tab_on, tab_off, ribbon, bar_bg, bar_hp, bar_xp, bar_mana.
## pad — внутренний отступ ПОСЛЕ рамки (content margin = рамка + pad; по вертикали pad*0.75).
static func panel(kind := "dark", pad := 18) -> StyleBoxTexture:
	var p: Array = PATCH.get(kind, PATCH["dark"])
	var sb := _sbt(p[0], [p[1], p[2], p[3], p[4]], p[6])
	var border: int = p[5]
	sb.content_margin_left = border + pad
	sb.content_margin_right = border + pad
	sb.content_margin_top = border + int(pad * 0.75)
	sb.content_margin_bottom = border + int(pad * 0.75)
	return sb


## Стили кнопки {normal, hover, pressed, disabled, focus}.
## kinds: gold (главное действие), dark (обычное), red (атака/опасно), green (лечение/подтвердить),
## blue (магия/инфо), purple (заклинания/редкое).
static func button_styles(kind := "dark", pad_h := 18) -> Dictionary:
	if not kind in BUTTON_KINDS:
		kind = "dark"
	var normal := _sbt("button_%s.png" % kind, BUTTON_MARGIN, false, true)
	var hover := _sbt("button_%s.png" % kind, BUTTON_MARGIN, false, true)
	hover.modulate_color = Color(1.14, 1.10, 1.04)
	var pressed := _sbt("button_%s_pressed.png" % kind, BUTTON_MARGIN, false, true)
	var disabled := _sbt("button_%s.png" % kind, BUTTON_MARGIN, false, true)
	disabled.modulate_color = Color(0.45, 0.42, 0.40, 0.9)
	for sb in [normal, hover, pressed, disabled]:
		sb.content_margin_left = pad_h
		sb.content_margin_right = pad_h
		sb.content_margin_top = 6
		sb.content_margin_bottom = 9
	pressed.content_margin_top = 9   # текст «проседает» при нажатии
	pressed.content_margin_bottom = 6
	return {"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled,
		"focus": StyleBoxEmpty.new()}


## Цвет текста для кнопки данного вида.
static func button_font_color(kind: String) -> Color:
	return TEXT_ON_GOLD if kind == "gold" else INK


## Полностью оформить кнопку: стили, шрифт (заголовочный, капитель), цвета, обводку.
static func style_button(b: Button, kind := "dark", font_size := 28, pad_h := 18) -> Button:
	var st := button_styles(kind, pad_h)
	for k in st:
		b.add_theme_stylebox_override(k, st[k])
	b.add_theme_font_override("font", title_font())
	b.add_theme_font_size_override("font_size", font_size)
	var fc := button_font_color(kind)
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
			"font_hover_pressed_color", "icon_normal_color", "icon_hover_color",
			"icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
		b.add_theme_color_override(s, fc)
	b.add_theme_color_override("font_disabled_color", Color(fc, 0.5))
	b.add_theme_color_override("icon_disabled_color", Color(fc, 0.5))
	if kind == "gold":
		b.add_theme_color_override("font_outline_color", Color(1, 0.93, 0.7, 0.35))
		b.add_theme_constant_override("outline_size", 2)
	else:
		b.add_theme_color_override("font_outline_color", Color(OUTLINE, 0.85))
		b.add_theme_constant_override("outline_size", 4)
	return b


## Стили вкладки для Button-вкладки (on = выбрана) или TabBar.
static func tab_styles(on: bool, pad := 14) -> Dictionary:
	var sb := panel("tab_on" if on else "tab_off", pad)
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	var hv := panel("tab_on" if on else "tab_off", pad)
	hv.content_margin_top = 8
	hv.content_margin_bottom = 8
	hv.modulate_color = Color(1.15, 1.1, 1.05)
	return {"normal": sb, "hover": hv, "pressed": sb, "disabled": sb, "focus": StyleBoxEmpty.new()}


static func style_tab(b: Button, on: bool, font_size := 24) -> Button:
	var st := tab_styles(on)
	for k in st:
		b.add_theme_stylebox_override(k, st[k])
	b.add_theme_font_override("font", title_font())
	b.add_theme_font_size_override("font_size", font_size)
	var fc := GOLD_LIGHT if on else INK_DIM
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
			"font_hover_pressed_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color",
			"icon_focus_color", "icon_hover_pressed_color"]:
		b.add_theme_color_override(s, fc)
	b.add_theme_color_override("font_outline_color", OUTLINE)
	b.add_theme_constant_override("outline_size", 4)
	return b


## Стили полоски: {background, fill}. fill: "hp" | "xp" | "mana". Высота полоски ≥ 30.
static func bar_styles(fill := "hp") -> Dictionary:
	return {"background": panel("bar_bg", 0), "fill": panel("bar_" + fill, 0)}


static func style_bar(pb: ProgressBar, fill := "hp") -> ProgressBar:
	var st := bar_styles(fill)
	pb.add_theme_stylebox_override("background", st.background)
	pb.add_theme_stylebox_override("fill", st.fill)
	pb.show_percentage = false
	if pb.custom_minimum_size.y < 30:
		pb.custom_minimum_size.y = 30
	return pb


## Стиль поля ввода (LineEdit/TextEdit) — тонкая тёмная карточка.
static func input_style() -> StyleBoxTexture:
	return panel("inset", 12)


static func slot_kind(rarity: String) -> String:
	match rarity:
		"magic", "uncommon": return "slot_magic"
		"rare", "epic": return "slot_rare"
		"legend", "legendary": return "slot_legend"
	return "slot"


# ---------- текстуры ----------
static func bg() -> Texture2D: return tex("bg.png")                 ## 720x1280, фон экрана
static func divider() -> Texture2D: return tex("divider.png")       ## 640x40, орнамент-разделитель
static func portrait_frame() -> Texture2D: return tex("portrait_frame.png")  ## 160x160, кольцо (центр прозрачный, внутр. радиус 62)
static func portrait_bg() -> Texture2D: return tex("portrait_bg.png")        ## 160x160, тёмный диск под иконку
static func ribbon() -> Texture2D: return tex("header_ribbon.png")  ## 560x104


## Фон на весь экран (заменяет градиент).
static func make_bg_rect() -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = bg()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


## Орнаментальный разделитель (высота по умолчанию 28, растягивается по ширине с сохранением пропорций).
static func make_divider(height := 28) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = divider()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(0, height)
	tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


## Портрет: тёмный диск + иконка (белая PNG, тонируется tint) + золотое кольцо сверху.
static func make_portrait(icon: Texture2D, size := 112, tint := GOLD_LIGHT) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(size, size)
	root.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var under := _full_rect(portrait_bg())
	root.add_child(under)
	if icon:
		var ic := _full_rect(icon)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.self_modulate = tint
		ic.set_anchors_preset(Control.PRESET_FULL_RECT)
		var inset := size * 0.25
		ic.offset_left = inset
		ic.offset_top = inset
		ic.offset_right = -inset
		ic.offset_bottom = -inset
		root.add_child(ic)
	root.add_child(_full_rect(portrait_frame()))
	return root


## Ячейка инвентаря size x size с иконкой (или пустая с бледным силуэтом placeholder).
static func make_slot(icon: Texture2D, rarity := "common", size := 96, empty := false) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(size, size)
	pc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := panel(slot_kind(rarity), 0)
	var m := int(size * 0.16)
	sb.content_margin_left = m
	sb.content_margin_right = m
	sb.content_margin_top = m
	sb.content_margin_bottom = m
	pc.add_theme_stylebox_override("panel", sb)
	if icon:
		var ic := TextureRect.new()
		ic.texture = icon
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ic.self_modulate = Color(1, 1, 1, 0.12) if empty else RARITY.get(rarity, RARITY.common)
		pc.add_child(ic)
	return pc


## Лента-заголовок с текстом (ширина растягивается; высота 104 текстуры — по умолчанию 84).
static func make_ribbon_title(text: String, font_size := 34, height := 84) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := panel("ribbon", 0)
	sb.content_margin_left = 96
	sb.content_margin_right = 96
	sb.content_margin_top = height * 0.12
	sb.content_margin_bottom = height * 0.18
	pc.add_theme_stylebox_override("panel", sb)
	pc.custom_minimum_size = Vector2(0, height)
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", title_font())
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", GOLD_LIGHT)
	l.add_theme_color_override("font_outline_color", Color("2a0505"))
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_y", 2)
	pc.add_child(l)
	return pc


## Заголовок экрана: золотой текст заголовочным шрифтом с тёмной обводкой и тенью.
static func style_title(l: Label, font_size := 44, display := false) -> Label:
	l.add_theme_font_override("font", display_font() if display else title_font())
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", GOLD)
	l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_constant_override("outline_size", max(4, font_size / 8))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 3)
	return l


static func _full_rect(t: Texture2D) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = t
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


# ---------- шрифты ----------
static func _fallbacks() -> Array[Font]:
	var fb: Array[Font] = []
	var emoji := load("res://fonts/NotoEmoji.ttf") as Font
	if emoji:
		fb.append(emoji)
	fb.append(ThemeDB.fallback_font)
	return fb


static func _font(key: String, path: String, weight := 0) -> Font:
	if _fonts.has(key):
		return _fonts[key]
	var f := load(path) as FontFile
	var out: Font = f
	if f == null:
		out = ThemeDB.fallback_font
	else:
		f.fallbacks = _fallbacks()
		if weight > 0:
			var fv := FontVariation.new()
			fv.base_font = f
			fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
			out = fv
	_fonts[key] = out
	return out


## Alegreya SC Bold — капитель: заголовки экранов (40–46), заголовки панелей (28–34), кнопки (24–30), вкладки (22–26).
static func title_font() -> Font:
	return _font("title", "res://fonts/AlegreyaSC-Bold.ttf")


## Ruslan Display — только для логотипа / очень крупных надписей (56–80): «Хроники двоих», «Победа!».
static func display_font() -> Font:
	return _font("display", "res://fonts/RuslanDisplay-Regular.ttf")


## Alegreya Sans Bold — интерфейс: подписи, статы, лог, поля ввода (20–28).
static func body_font() -> Font:
	return _font("body", "res://fonts/AlegreyaSans-Bold.ttf")


## Alegreya (книжная антиква, вес 500) — повествование Мастера на пергаменте (24–28), INK_PARCHMENT.
static func text_font() -> Font:
	return _font("text", "res://fonts/Alegreya-Variable.ttf", 500)


## Жирная антиква (вес 800) для [b] в RichTextLabel на пергаменте.
static func text_bold_font() -> Font:
	return _font("text_bold", "res://fonts/Alegreya-Variable.ttf", 800)


## Настроить RichTextLabel для текста на пергаменте.
static func style_parchment_text(r: RichTextLabel, font_size := 26) -> RichTextLabel:
	r.add_theme_font_override("normal_font", text_font())
	r.add_theme_font_override("bold_font", text_bold_font())
	r.add_theme_font_size_override("normal_font_size", font_size)
	r.add_theme_font_size_override("bold_font_size", font_size)
	r.add_theme_color_override("default_color", INK_PARCHMENT)
	return r


## Базовая тема: шрифт, цвета, стили кнопок (dark), полей ввода, панелей, полос, скроллбара.
## Можно вызывать после main._make_theme(): UISkin.apply_theme(theme).
static func apply_theme(t: Theme) -> Theme:
	t.default_font = body_font()
	t.default_font_size = 26
	t.set_color("font_color", "Label", INK)
	t.set_color("default_color", "RichTextLabel", INK)
	t.set_font("normal_font", "RichTextLabel", body_font())
	t.set_font("bold_font", "RichTextLabel", title_font())
	var bs := button_styles("dark")
	for k in bs:
		t.set_stylebox(k, "Button", bs[k])
	t.set_font("font", "Button", title_font())
	t.set_color("font_color", "Button", INK)
	t.set_color("font_hover_color", "Button", GOLD_LIGHT)
	t.set_color("font_pressed_color", "Button", GOLD_LIGHT)
	t.set_color("font_outline_color", "Button", OUTLINE)
	t.set_constant("outline_size", "Button", 4)
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, input_style())
		t.set_stylebox("focus", type, StyleBoxEmpty.new())
		t.set_stylebox("read_only", type, input_style())
		t.set_color("font_color", type, INK)
		t.set_color("font_placeholder_color", type, INK_MUTED)
		t.set_color("caret_color", type, GOLD)
		t.set_color("selection_color", type, Color(GOLD, 0.35))
	t.set_stylebox("panel", "PanelContainer", panel("dark"))
	t.set_stylebox("panel", "Panel", panel("dark"))
	t.set_stylebox("background", "ProgressBar", panel("bar_bg", 0))
	t.set_stylebox("fill", "ProgressBar", panel("bar_hp", 0))
	t.set_stylebox("tab_selected", "TabBar", tab_styles(true).normal)
	t.set_stylebox("tab_unselected", "TabBar", tab_styles(false).normal)
	t.set_stylebox("tab_hovered", "TabBar", tab_styles(false).hover)
	t.set_stylebox("tab_selected", "TabContainer", tab_styles(true).normal)
	t.set_stylebox("tab_unselected", "TabContainer", tab_styles(false).normal)
	t.set_stylebox("tab_hovered", "TabContainer", tab_styles(false).hover)
	t.set_color("font_selected_color", "TabBar", GOLD_LIGHT)
	t.set_color("font_unselected_color", "TabBar", INK_DIM)
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(GOLD_DARK, 0.6)
	grab.set_corner_radius_all(4)
	grab.content_margin_left = 6
	grab.content_margin_right = 6
	t.set_stylebox("grabber", "VScrollBar", grab)
	var grab_h := grab.duplicate()
	grab_h.bg_color = Color(GOLD, 0.8)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab_h)
	t.set_stylebox("grabber_pressed", "VScrollBar", grab_h)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
	return t
