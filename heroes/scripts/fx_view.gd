extends Control
## Full-screen effects overlay (loot, level up, hit flash).
##   var FxView = preload("res://scripts/fx_view.gd")
##   var fx = FxView.new(); add_child(fx)
##   fx.loot_burst("Сундук гоблинов", 35, [tex1, tex2])   # ~2.5 s, tap to skip
##   await fx.finished
##   fx.level_up("Торин", 3)                               # ~2.0 s, tap to skip
##   fx.hit_flash(Color("#ff5a5f"))                        # 0.35 s, never blocks input
## loot_burst / level_up calls made while one is playing are queued; `finished` is emitted
## when the queue of those effects has drained. hit_flash does not emit `finished`.
## The node ignores the mouse and hides itself when idle.

signal finished

const C_INK := Color("#f3f1ea")
const C_ACCENT := Color("#ffc145")
const C_GOLD_D := Color("#c98a17")
const C_RED := Color("#ff5a5f")
const C_GREEN := Color("#3ddc97")
const C_PURPLE := Color("#a77bff")
const C_OUTLINE := Color("#10111c")
const C_WOOD := Color("#8a5a2b")
const C_WOOD_D := Color("#5e3a19")

const LOOT_LEN := 2.5
const LEVEL_LEN := 2.0
const FLASH_LEN := 0.35

var sound_enabled := true

var _queue: Array = []
var _cur: Dictionary = {}
var _t := 0.0
var _flashes: Array = []
var _parts: Array = []
var _coins: Array = []
var _rng := RandomNumberGenerator.new()
var _glow_tex: Texture2D
var _vig_tex: Texture2D
var _hgrad_tex: Texture2D
var _last_tap_ms := -100000
var _clinks := 0.0

const MIX_RATE := 22050.0
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _voices: Array = []
static var _snd := {}


func _ready() -> void:
	_rng.randomize()
	_make_textures()
	_setup_audio()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _cur.is_empty() and _queue.is_empty() and _flashes.is_empty():
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false
		set_process(false)


# ---------------------------------------------------------------- public API

func loot_burst(title: String, gold: int, icons: Array) -> void:
	_queue.append({"type": "loot", "title": title, "gold": maxi(0, gold), "icons": icons.duplicate()})
	_wake()


func level_up(name: String, level: int) -> void:
	_queue.append({"type": "level", "name": name, "level": level})
	_wake()


func hit_flash(color: Color) -> void:
	_flashes.append({"col": color, "t": 0.0})
	_wake()


# ---------------------------------------------------------------- flow

func _wake() -> void:
	if _glow_tex == null:
		_make_textures()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = true
	move_to_front()
	set_process(true)
	if _cur.is_empty() and not _queue.is_empty():
		_start_next()
	queue_redraw()


func _start_next() -> void:
	_cur = _queue.pop_front()
	_t = 0.0
	_coins.clear()
	_parts.clear()
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _cur.type == "loot":
		var g: int = _cur.gold
		_cur["ncoins"] = 0 if g <= 0 else clampi(g / 3 + 6, 6, 40)
		_cur["spawned"] = 0
		_cur["fired"] = {}
	else:
		_cur["fired"] = {}
		_cur["spawn_acc"] = 0.0


func _end_cur() -> void:
	_cur = {}
	_coins.clear()
	_parts.clear()
	if not _queue.is_empty():
		_start_next()
		return
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	finished.emit()


func _cur_len() -> float:
	if _cur.is_empty():
		return 0.0
	return LOOT_LEN if _cur.type == "loot" else LEVEL_LEN


func _gui_input(event: InputEvent) -> void:
	if _cur.is_empty():
		return
	var tap := false
	if event is InputEventMouseButton and event.pressed:
		tap = true
	elif event is InputEventScreenTouch and event.pressed:
		tap = true
	if not tap:
		return
	accept_event()
	var now := Time.get_ticks_msec()
	if now - _last_tap_ms < 200:
		return
	_last_tap_ms = now
	var jump := 1.7 if _cur.type == "loot" else 1.2
	if _t < jump:
		_t = jump
		if _cur.type == "loot":
			while int(_cur.spawned) < int(_cur.ncoins):
				_spawn_coin()
	else:
		_end_cur()


func _process(delta: float) -> void:
	var alive := []
	for f in _flashes:
		f.t = float(f.t) + delta
		if float(f.t) < FLASH_LEN:
			alive.append(f)
	_flashes = alive
	if not _cur.is_empty():
		_t += delta
		if _cur.type == "loot":
			_update_loot(delta)
		else:
			_update_level(delta)
		if not _cur.is_empty() and _t >= _cur_len():
			_end_cur()
	_update_parts(delta)
	_pump_audio()
	if _cur.is_empty() and _flashes.is_empty():
		visible = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(false)
		_voices.clear()
		return
	queue_redraw()


# ---------------------------------------------------------------- loot

func _chest_c() -> Vector2:
	return Vector2(size.x * 0.5, size.y * 0.6)


func _mouth() -> Vector2:
	return _chest_c() + Vector2(0, -6)


func _spawn_coin() -> void:
	_cur.spawned = int(_cur.spawned) + 1
	var m := _mouth()
	var vx := _rng.randf_range(-1.0, 1.0)
	vx = signf(vx) * pow(absf(vx), 0.7) * 420.0
	_coins.append({
		"p": m + Vector2(_rng.randf_range(-90, 90), _rng.randf_range(-10, 10)),
		"v": Vector2(vx, -_rng.randf_range(950.0, 1650.0)),
		"r": _rng.randf_range(15.0, 21.0), "spin": _rng.randf() * TAU, "sv": _rng.randf_range(9.0, 18.0) * (1 if _rng.randf() < 0.5 else -1),
		"floor": size.y * 0.9 + _rng.randf_range(-36.0, 30.0), "rest": false, "glint": _rng.randf_range(0.2, 0.9),
	})


func _update_loot(delta: float) -> void:
	var fired: Dictionary = _cur.fired
	if not fired.has("land") and _t >= 0.3:
		fired["land"] = true
		_play_snd("thud", 0.9)
		_dust(_chest_c() + Vector2(0, 175), 14, 170.0)
	if not fired.has("open") and _t >= 0.62:
		fired["open"] = true
		_play_snd("pop", 1.0)
		_play_snd("sparkle", 0.8)
		_stars(_mouth(), 14, C_ACCENT, 160.0)
		_sparks(_mouth(), 22, C_ACCENT)
	# coins pour out between 0.66 and 1.25 s
	var n: int = _cur.ncoins
	if _t >= 0.66 and int(_cur.spawned) < n:
		var want := int(ceil(n * clampf((_t - 0.66) / 0.55, 0.0, 1.0)))
		while int(_cur.spawned) < want:
			_spawn_coin()
	var icons: Array = _cur.icons
	for i in icons.size():
		var key := "ic%d" % i
		if not fired.has(key) and _t >= _icon_t(i, icons.size()) + 0.3:
			fired[key] = true
			_play_snd("ding", 0.7)
			_stars(_icon_pos(i, icons.size()), 6, Color(1, 0.95, 0.7), 50.0)
	_clinks = maxf(0.0, _clinks - delta)
	for c in _coins:
		if c.rest:
			c.sv = float(c.sv) * maxf(0.0, 1.0 - delta * 5.0)
			c.spin = float(c.spin) + float(c.sv) * delta
			continue
		var v: Vector2 = c.v
		v.y += 2600.0 * delta
		var p: Vector2 = (c.p as Vector2) + v * delta
		c.spin = float(c.spin) + float(c.sv) * delta
		if p.y >= float(c.floor) and v.y > 0.0:
			p.y = float(c.floor)
			if v.y < 260.0:
				v = Vector2.ZERO
				c.rest = true
			else:
				v.y = -v.y * 0.42
				v.x *= 0.65
				if _clinks <= 0.0:
					_clinks = 0.035
					_play_snd("clink", _rng.randf_range(0.4, 0.8))
				if _rng.randf() < 0.5:
					_stars(p, 1, Color(1, 0.95, 0.7), 8.0)
		if p.x < 20.0 or p.x > size.x - 20.0:
			v.x = -v.x * 0.6
			p.x = clampf(p.x, 20.0, size.x - 20.0)
		c.p = p
		c.v = v


func _icon_t(i: int, n: int) -> float:
	return 0.85 + i * minf(0.24, 0.8 / maxf(1.0, n))


func _icon_pos(i: int, n: int) -> Vector2:
	var per := mini(n, 5)
	var row := i / 5
	var col := i % 5
	var in_row := mini(per, n - row * 5)
	var sp := 124.0 if n <= 5 else 112.0
	var x := size.x * 0.5 + (col - (in_row - 1) * 0.5) * sp
	var y := _chest_c().y - 250.0 - (float((n - 1) / 5) - row) * 124.0
	return Vector2(x, y)


func _draw_loot() -> void:
	var t := _t
	var fade := clampf(t / 0.2, 0.0, 1.0) * clampf((LOOT_LEN - t) / 0.3, 0.0, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.03, 0.02, 0.72 * fade))
	var c := _chest_c()
	var open_k := clampf((t - 0.6) / 0.22, 0.0, 1.0)
	# light from the chest
	if open_k > 0.0:
		var gk := _ease_out(open_k)
		var pul := 0.85 + 0.15 * sin(t * 8.0)
		_glow(c + Vector2(0, -60), 330.0 * gk * pul, Color(C_ACCENT, 0.55 * fade))
		_rays(c + Vector2(0, -10), 520.0 * gk, t * 0.35, Color(1.0, 0.85, 0.4, 0.3 * fade), true)
	# drop-in + anticipation shake
	var drop := 0.0
	var sq := 1.0
	if t < 0.3:
		var k := t / 0.3
		drop = -(1.0 - k * k) * size.y * 0.6
	elif t < 0.45:
		var k := (t - 0.3) / 0.15
		sq = 1.0 - 0.14 * sin(k * PI)
	var shake := 0.0
	if t > 0.42 and t < 0.62:
		shake = sin(t * 80.0) * 5.0 * ((t - 0.42) / 0.2)
	var cc := c + Vector2(shake, drop)
	_draw_chest(cc, open_k, sq, fade, t)
	# coins
	for co in _coins:
		_draw_coin(co, fade)
	_draw_parts()
	# icons
	var icons: Array = _cur.icons
	for i in icons.size():
		var it := t - _icon_t(i, icons.size())
		if it < 0.0:
			continue
		var k := clampf(it / 0.35, 0.0, 1.0)
		var target := _icon_pos(i, icons.size())
		var p := _mouth().lerp(target, _ease_out(k)) + Vector2(0, sin(t * 3.0 + i) * 6.0 * k)
		var sc := _ease_out_back(k)
		var sz := 96.0 if icons.size() <= 5 else 84.0
		_glow(p, sz * 1.15 * (0.9 + 0.1 * sin(t * 5.0 + i)), Color(C_ACCENT, 0.5 * fade))
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(Color("#23263a"), 0.95 * fade)
		sb.set_corner_radius_all(22)
		sb.border_color = Color(C_ACCENT, fade)
		sb.set_border_width_all(3)
		sb.shadow_color = Color(0, 0, 0, 0.4 * fade)
		sb.shadow_size = 10
		var half := sz * 0.5 * sc
		draw_style_box(sb, Rect2(p - Vector2(half, half), Vector2(half, half) * 2.0))
		var tex = icons[i]
		if tex is Texture2D:
			var isz := sz * 0.72 * sc
			draw_texture_rect(tex, Rect2(p - Vector2(isz, isz) * 0.5, Vector2(isz, isz)), false, Color(1.0, 0.94, 0.75, fade))
		else:
			_gem(p, sz * 0.3 * sc, fade)
		# shine sweep
		var sk := (it - 0.3) / 0.45
		if sk > 0.0 and sk < 1.0:
			var sp := p + Vector2(-half, -half).lerp(Vector2(half, half), sk)
			_star(sp, 22.0 * sin(sk * PI), Color(1, 1, 1, fade), sk * 2.0)
			_glow(p, half * 1.6, Color(1, 1, 1, 0.25 * sin(sk * PI) * fade))
	# title + counter
	var tk := clampf((t - 0.1) / 0.35, 0.0, 1.0)
	var title: String = _cur.title
	if title != "" and tk > 0.0:
		var fs := _fit(title, 54, size.x - 60.0)
		var ty := size.y * 0.17 - (1.0 - _ease_out(tk)) * 40.0
		_text(Vector2(size.x * 0.5, ty), title, fs, Color(C_ACCENT, tk * fade), 12, Color(C_OUTLINE, tk * fade))
	var gold: int = _cur.gold
	if gold > 0 and t >= 0.65:
		var ck := clampf((t - 0.75) / 1.0, 0.0, 1.0)
		var val := int(round(gold * _ease_out(ck)))
		var pop := 1.0
		if ck >= 1.0:
			pop = 1.0 + 0.18 * maxf(0.0, 1.0 - (t - 1.75) / 0.25) * sin(clampf((t - 1.75) / 0.25, 0.0, 1.0) * PI)
		var txt := "+%d золота" % val
		var y := size.y * 0.24
		var a := clampf((t - 0.65) / 0.15, 0.0, 1.0) * fade
		var font := get_theme_default_font()
		var fs := 46
		var tw := 200.0
		if font != null:
			tw = font.get_string_size("+%d золота" % gold, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_set_transform(Vector2(size.x * 0.5, y), 0.0, Vector2(pop, pop))
		_draw_coin({"p": Vector2(-tw * 0.5 - 30.0, 0), "r": 20.0, "spin": t * 4.0}, a)
		_text(Vector2(18.0, 0), txt, fs, Color(C_INK, a), 10, Color(C_OUTLINE, a))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_chest(c: Vector2, open_k: float, sq: float, a: float, t: float) -> void:
	var W := 300.0
	var Hb := 170.0
	var Hl := 92.0
	# squash anchored at the bottom
	var bottom := c.y + Hb
	var sx := 2.0 - sq
	draw_set_transform(Vector2(c.x, bottom), 0.0, Vector2(sx, sq))
	var top := -Hb   # local y of the body top (mouth)
	# shadow
	draw_texture_rect(_glow_tex, Rect2(Vector2(-W * 0.75, -22.0), Vector2(W * 1.5, 44.0)), false, Color(0, 0, 0, 0.7 * a))
	# lid (behind when open)
	if open_k > 0.5:
		var k2 := (open_k - 0.5) / 0.5
		var lh := Hl * 1.25 * _ease_out_back(k2)
		var y0 := top - 14.0
		var inside := PackedVector2Array([Vector2(-W * 0.5, y0), Vector2(W * 0.5, y0), Vector2(W * 0.56, y0 - lh), Vector2(-W * 0.56, y0 - lh)])
		draw_colored_polygon(inside, Color(Color("#3b2410"), a))
		draw_polyline(PackedVector2Array([inside[0], inside[3], inside[2], inside[1]]), Color(C_ACCENT, a), 6.0, true)
		_glow(Vector2(0, y0 - lh * 0.4), W * 0.55, Color(C_ACCENT, 0.35 * a))
	# interior (mouth)
	if open_k > 0.0:
		draw_colored_polygon(PackedVector2Array([Vector2(-W * 0.5 + 8, top), Vector2(W * 0.5 - 8, top), Vector2(W * 0.46, top - 16.0), Vector2(-W * 0.46, top - 16.0)]), Color(Color("#2a170a"), a))
		# heap of gold inside
		for i in 7:
			var x := (i - 3) * 38.0
			draw_circle(Vector2(x, top - 8.0 - absf(sin(i * 1.7)) * 8.0), 22.0, Color(C_ACCENT.darkened(0.1 * (i % 2)), a))
		_glow(Vector2(0, top - 10.0), W * 0.45, Color(1, 0.9, 0.5, 0.7 * a * open_k))
	# body
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_WOOD, a)
	sb.corner_radius_bottom_left = 14
	sb.corner_radius_bottom_right = 14
	sb.border_color = Color(C_WOOD_D.darkened(0.3), a)
	sb.set_border_width_all(4)
	draw_style_box(sb, Rect2(-W * 0.5, top, W, Hb))
	for i in 3:
		var py := top + Hb * (0.3 + 0.27 * i)
		draw_line(Vector2(-W * 0.5 + 6, py), Vector2(W * 0.5 - 6, py), Color(C_WOOD_D, 0.8 * a), 3.0)
	_band(Rect2(-W * 0.5 + 20, top, 28, Hb), a)
	_band(Rect2(W * 0.5 - 48, top, 28, Hb), a)
	_band(Rect2(-W * 0.5, top, W, 16), a)
	# lock plate
	var lp := Rect2(-30, top + 6, 60, 66)
	var sl := StyleBoxFlat.new()
	sl.bg_color = Color(C_ACCENT, a)
	sl.set_corner_radius_all(10)
	sl.border_color = Color(C_GOLD_D, a)
	sl.set_border_width_all(3)
	draw_style_box(sl, lp)
	draw_circle(Vector2(0, top + 32), 8.0, Color(Color("#2a170a"), a))
	draw_colored_polygon(PackedVector2Array([Vector2(-5, top + 34), Vector2(5, top + 34), Vector2(3, top + 52), Vector2(-3, top + 52)]), Color(Color("#2a170a"), a))
	# lid front (closing → flipping up)
	if open_k < 0.5:
		var k1 := open_k / 0.5
		var lh := Hl * cos(k1 * PI * 0.5)
		var lift := 14.0 * k1
		if lh > 2.0:
			var sbl := StyleBoxFlat.new()
			sbl.bg_color = Color(C_WOOD.lightened(0.08 * (1.0 - k1)), a)
			sbl.corner_radius_top_left = int(minf(48.0, lh * 0.6))
			sbl.corner_radius_top_right = int(minf(48.0, lh * 0.6))
			sbl.border_color = Color(C_WOOD_D.darkened(0.3), a)
			sbl.set_border_width_all(4)
			var lr := Rect2(-W * 0.5 - 6, top - lh - lift, W + 12, lh + 4)
			draw_style_box(sbl, lr)
			_band(Rect2(-W * 0.5 + 20, lr.position.y + 4, 28, lh), a)
			_band(Rect2(W * 0.5 - 48, lr.position.y + 4, 28, lh), a)
			_band(Rect2(-W * 0.5 - 6, lr.end.y - 14, W + 12, 14), a)
		# light leaking from the seam
		var seam := clampf((t - 0.4) / 0.2, 0.0, 1.0)
		if seam > 0.0:
			draw_texture_rect(_glow_tex, Rect2(Vector2(-W * 0.6, top - 30.0 - lift), Vector2(W * 1.2, 50.0)), false, Color(1, 0.85, 0.4, 0.9 * seam * a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _band(r: Rect2, a: float) -> void:
	draw_rect(r, Color(C_ACCENT, a))
	draw_rect(Rect2(r.position, Vector2(r.size.x, 3)), Color(1, 0.92, 0.65, a))
	draw_rect(r, Color(C_GOLD_D, a), false, 2.0)
	# rivets
	if r.size.y > 40.0 and r.size.x < 40.0:
		for i in 3:
			draw_circle(Vector2(r.position.x + r.size.x * 0.5, r.position.y + r.size.y * (0.2 + 0.3 * i)), 3.5, Color(C_GOLD_D, a))


func _draw_coin(co: Dictionary, a: float) -> void:
	var p: Vector2 = co.p
	var r: float = co.r
	var sp: float = co.spin
	var cs := cos(sp)
	var w := maxf(0.14, absf(cs))
	var edge := Color(Color("#a8740c"), a)
	# thickness: slightly offset darker ellipse
	_ellipse(p + Vector2(signf(cs) * r * 0.12 * (1.0 - w), 0), Vector2(r * w + r * 0.1, r), edge)
	var face := Color(C_ACCENT.lerp(Color(1, 0.9, 0.55), 0.3 * w), a)
	_ellipse(p, Vector2(r * w, r), face)
	_ellipse(p, Vector2(r * w * 0.68, r * 0.68), Color(Color("#ffd970"), a))
	if w > 0.45:
		_ellipse(p + Vector2(-r * w * 0.25, -r * 0.3), Vector2(r * w * 0.22, r * 0.14), Color(1, 1, 1, 0.65 * a))
	var g: float = co.get("glint", -1.0)
	if g > 0.0 and absf(fmod(_t + g * 3.0, 0.9) - 0.45) < 0.06 and w > 0.6:
		_star(p + Vector2(r * 0.3, -r * 0.4), r * 0.9, Color(1, 1, 1, a), 0.3)


func _gem(p: Vector2, r: float, a: float) -> void:
	var pts := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r * 0.85, -r * 0.25), p + Vector2(0, r * 1.05), p + Vector2(-r * 0.85, -r * 0.25)])
	draw_colored_polygon(pts, Color(Color("#ffe08a"), a))
	draw_colored_polygon(PackedVector2Array([p + Vector2(0, -r), p + Vector2(r * 0.85, -r * 0.25), p]), Color(1, 1, 1, 0.8 * a))
	draw_colored_polygon(PackedVector2Array([p + Vector2(-r * 0.85, -r * 0.25), p, p + Vector2(0, r * 1.05)]), Color(C_GOLD_D, a))


# ---------------------------------------------------------------- level up

func _update_level(delta: float) -> void:
	var fired: Dictionary = _cur.fired
	if not fired.has("go"):
		fired["go"] = true
		_play_snd("fanfare", 1.0)
	if not fired.has("num") and _t >= 0.45:
		fired["num"] = true
		_play_snd("thud", 0.7)
		_sparks(Vector2(size.x * 0.5, size.y * 0.5), 30, C_ACCENT)
		_ring(Vector2(size.x * 0.5, size.y * 0.5), 60.0, 360.0, C_ACCENT, 0.6, 10.0)
	if _t < 1.6:
		_cur.spawn_acc = float(_cur.spawn_acc) + delta * 60.0
		while float(_cur.spawn_acc) >= 1.0:
			_cur.spawn_acc = float(_cur.spawn_acc) - 1.0
			var x := size.x * 0.5 + _rng.randf_range(-1.0, 1.0) * 120.0
			var y := size.y * 0.8 - _rng.randf_range(0.0, 200.0)
			var d := _add(4, Vector2(x, y), Vector2(_rng.randf_range(-20, 20), -_rng.randf_range(300.0, 700.0)), _rng.randf_range(0.6, 1.2),
				C_ACCENT.lerp(Color(1, 1, 1), _rng.randf() * 0.6), _rng.randf_range(5.0, 12.0), -100.0, 0.0)
			d.rv = _rng.randf_range(-3, 3)


func _draw_level() -> void:
	var t := _t
	var fade := clampf(t / 0.18, 0.0, 1.0) * clampf((LEVEL_LEN - t) / 0.35, 0.0, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.03, 0.02, 0.7 * fade))
	var cx := size.x * 0.5
	var floor_y := size.y * 0.8
	var wk := _ease_out_back(clampf(t / 0.3, 0.0, 1.0))
	var pul := 1.0 + 0.06 * sin(t * 14.0)
	var w := 150.0 * wk * pul
	# pillar of light
	draw_texture_rect(_hgrad_tex, Rect2(cx - w * 2.2, 0, w * 4.4, floor_y), false, Color(C_ACCENT, 0.3 * fade))
	draw_texture_rect(_hgrad_tex, Rect2(cx - w, 0, w * 2.0, floor_y), false, Color(1.0, 0.86, 0.45, 0.65 * fade))
	draw_texture_rect(_hgrad_tex, Rect2(cx - w * 0.32, 0, w * 0.64, floor_y), false, Color(1, 1, 0.92, 0.9 * fade))
	_glow(Vector2(cx, floor_y), w * 2.6, Color(C_ACCENT, 0.7 * fade))
	draw_texture_rect(_glow_tex, Rect2(Vector2(cx - w * 2.2, floor_y - 30), Vector2(w * 4.4, 60)), false, Color(1, 1, 0.9, 0.9 * fade))
	for i in 3:
		var rk := fmod(t * 1.2 + i / 3.0, 1.0)
		_ellipse_arc(Vector2(cx, floor_y), Vector2(w * (0.6 + 2.2 * rk), 22.0 * (0.6 + 2.2 * rk)), Color(C_ACCENT, (1.0 - rk) * 0.8 * fade), 4.0)
	_draw_parts()
	# text
	var c := Vector2(cx, size.y * 0.5)
	var nk := clampf((t - 0.3) / 0.15, 0.0, 1.0)
	if nk > 0.0:
		_rays(c, 360.0 * _ease_out(nk), t * 0.6, Color(1.0, 0.85, 0.4, 0.35 * fade), false)
		_glow(c, 260.0, Color(C_ACCENT, 0.5 * fade))
	var name: String = _cur.name
	var hk := clampf((t - 0.12) / 0.3, 0.0, 1.0)
	if name != "" and hk > 0.0:
		_text(Vector2(cx, size.y * 0.29 - (1.0 - _ease_out(hk)) * 30.0), name, _fit(name, 40, size.x - 60.0), Color(C_INK, hk * fade), 10, Color(C_OUTLINE, hk * fade))
	if hk > 0.0:
		var sc := 1.0 + 0.8 * (1.0 - _ease_out_back(hk))
		draw_set_transform(Vector2(cx, size.y * 0.36), 0.0, Vector2(sc, sc))
		_text(Vector2.ZERO, "Новый уровень!", _fit("Новый уровень!", 62, size.x - 60.0), Color(C_ACCENT, hk * fade), 14, Color(C_OUTLINE, hk * fade))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if nk > 0.0:
		var k := clampf((t - 0.3) / 0.3, 0.0, 1.0)
		var sc := 1.0 + 1.6 * (1.0 - _ease_out_back(k))
		draw_set_transform(c, 0.0, Vector2(sc, sc))
		_text(Vector2(0, 0), str(_cur.level), 220, Color(Color("#fff6dc"), nk * fade), 22, Color(Color("#5a3a00"), nk * fade))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if not _cur.is_empty():
		if _cur.type == "loot":
			_draw_loot()
		else:
			_draw_level()
	for f in _flashes:
		var q: float = float(f.t) / FLASH_LEN
		var col: Color = f.col
		var a := pow(1.0 - q, 1.5)
		if q < 0.15:
			a = q / 0.15
		draw_rect(Rect2(Vector2.ZERO, size), Color(col, 0.08 * a))
		_vignette(Color(col, 0.85 * a), size.x * 0.3)


func _rays(c: Vector2, r: float, rot: float, col: Color, upward: bool) -> void:
	var n := 14
	for i in n:
		var an := rot + TAU * i / n
		if upward:
			an = -PI * 0.5 + (float(i) / (n - 1) - 0.5) * PI * 0.95 + sin(rot * 3.0 + i) * 0.04
		var dir := Vector2(cos(an), sin(an))
		var perp := dir.orthogonal()
		var wr := r * 0.09
		draw_polygon(PackedVector2Array([c, c + dir * r + perp * wr, c + dir * r - perp * wr]),
			PackedColorArray([col, Color(col, 0.0), Color(col, 0.0)]))


func _ellipse(c: Vector2, rad: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var an := TAU * i / 24.0
		pts.append(c + Vector2(cos(an) * rad.x, sin(an) * rad.y))
	draw_colored_polygon(pts, col)


func _ellipse_arc(c: Vector2, rad: Vector2, col: Color, w: float) -> void:
	var pts := PackedVector2Array()
	for i in 41:
		var an := TAU * i / 40.0
		pts.append(c + Vector2(cos(an) * rad.x, sin(an) * rad.y))
	draw_polyline(pts, col, w, true)


func _glow(c: Vector2, r: float, col: Color) -> void:
	if col.a <= 0.003 or r <= 0.5 or _glow_tex == null:
		return
	draw_texture_rect(_glow_tex, Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0), false, col)


func _star(p: Vector2, r: float, col: Color, rot: float) -> void:
	if r < 0.5:
		return
	_glow(p, r * 1.6, Color(col, col.a * 0.35))
	var pts := PackedVector2Array()
	for i in 8:
		var a := rot + TAU * i / 8.0
		var rr := r if i % 2 == 0 else r * 0.22
		pts.append(p + Vector2(cos(a), sin(a)) * rr)
	draw_colored_polygon(pts, Color(col.lerp(Color(1, 1, 1), 0.5), col.a))


func _vignette(col: Color, th: float) -> void:
	if _vig_tex == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.5, 0.75, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0.95)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.2, 0.5)
		t.width = 256
		t.height = 256
		t.use_hdr = true
		g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CUBIC
		_vig_tex = t
	var grow := th * 0.0
	draw_texture_rect(_vig_tex, Rect2(Vector2(-grow, -grow), size + Vector2(grow, grow) * 2.0), false, col)


func _make_textures() -> void:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.6, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.15), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 128
	t.height = 128
	t.use_hdr = true
	_glow_tex = t
	var g2 := Gradient.new()
	g2.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g2.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var t2 := GradientTexture2D.new()
	t2.gradient = g2
	t2.fill_from = Vector2(0, 0)
	t2.fill_to = Vector2(1, 0)
	t2.width = 128
	t2.use_hdr = true
	t2.height = 4
	_hgrad_tex = t2


func _text(center: Vector2, txt: String, fs: int, col: Color, outline := 0, ocol := Color.BLACK) -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var base := Vector2(center.x - w * 0.5, center.y + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5)
	if outline > 0 and ocol.a > 0.0:
		draw_string_outline(font, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, outline, ocol)
	draw_string(font, base, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _fit(txt: String, fs: int, maxw: float) -> int:
	var font := get_theme_default_font()
	if font == null:
		return fs
	while fs > 14 and font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > maxw:
		fs -= 2
	return fs


func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - x, 3.0)


func _ease_out_back(x: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)


# ---------------------------------------------------------------- particles
# kinds: 0 spark, 1 dust, 4 star, 5 ring

func _add(k: int, p: Vector2, v: Vector2, life: float, col: Color, sz: float, g: float, drag: float) -> Dictionary:
	var d := {"k": k, "p": p, "v": v, "t": 0.0, "life": life, "col": col, "s": sz, "g": g, "drag": drag,
		"rot": _rng.randf() * TAU, "rv": 0.0, "r1": 0.0}
	_parts.append(d)
	return d


func _sparks(p: Vector2, n: int, col: Color) -> void:
	for i in n:
		var a := _rng.randf_range(PI * 1.05, PI * 1.95)
		var v := Vector2(cos(a), sin(a)) * _rng.randf_range(300.0, 900.0)
		_add(0, p, v, _rng.randf_range(0.35, 0.7), col.lerp(Color(1, 1, 1), _rng.randf() * 0.6), _rng.randf_range(0.8, 1.4), 1300.0, 1.5)


func _dust(p: Vector2, n: int, spread: float) -> void:
	for i in n:
		var x := _rng.randf_range(-1.0, 1.0)
		_add(1, p + Vector2(x * spread, 0), Vector2(x * _rng.randf_range(60.0, 200.0), -_rng.randf_range(10.0, 60.0)),
			_rng.randf_range(0.45, 0.8), Color(1.0, 0.9, 0.7), _rng.randf_range(10.0, 18.0), -30.0, 3.0)


func _stars(p: Vector2, n: int, col: Color, spread: float) -> void:
	for i in n:
		var off := Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * spread
		var d := _add(4, p + off, Vector2(0, -_rng.randf_range(20.0, 80.0)), _rng.randf_range(0.5, 1.0), col, _rng.randf_range(8.0, 16.0), 0.0, 1.0)
		d.t = -_rng.randf_range(0.0, 0.25)


func _ring(p: Vector2, r0: float, r1: float, col: Color, life: float, w: float) -> void:
	var d := _add(5, p, Vector2.ZERO, life, col, r0, 0.0, 0.0)
	d.r1 = r1
	d.rv = w


func _update_parts(delta: float) -> void:
	var alive := []
	for d in _parts:
		d.t = float(d.t) + delta
		if float(d.t) >= float(d.life):
			continue
		alive.append(d)
		if float(d.t) < 0.0:
			continue
		var v: Vector2 = d.v
		v.y += float(d.g) * delta
		v *= maxf(0.0, 1.0 - float(d.drag) * delta)
		d.v = v
		d.p = (d.p as Vector2) + v * delta
		if int(d.k) == 4:
			d.rot = float(d.rot) + float(d.rv) * delta
	_parts = alive


func _draw_parts() -> void:
	for d in _parts:
		var t: float = d.t
		if t < 0.0:
			continue
		var q: float = t / float(d.life)
		var p: Vector2 = d.p
		var col: Color = d.col
		var sz: float = d.s
		match int(d.k):
			0:
				var v: Vector2 = d.v
				var ln := clampf(v.length() * 0.035, 3.0, 30.0) * sz
				draw_line(p - v.normalized() * ln, p, Color(col, 1.0 - q), maxf(1.0, 3.5 * sz * (1.0 - q * 0.6)), true)
			1:
				_glow(p, sz * (1.0 + 2.2 * q), Color(col, 0.4 * (1.0 - q)))
			4:
				var k := sin(clampf(q, 0.0, 1.0) * PI)
				_star(p, sz * k, Color(col, k), float(d.rot))
			5:
				var r := lerpf(sz, float(d.r1), _ease_out(q))
				draw_arc(p, r, 0.0, TAU, 72, Color(col, (1.0 - q) * 0.9), maxf(1.0, float(d.rv) * (1.0 - q)), true)


# ---------------------------------------------------------------- sound

func _setup_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.12
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	_player.volume_db = -6.0
	add_child(_player)
	if _snd.is_empty():
		_build_sounds()


func _ensure_playback() -> bool:
	if not sound_enabled or _player == null or not _player.is_inside_tree():
		return false
	if _playback == null or not _player.playing:
		_player.play()
		_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	return _playback != null


func _play_snd(name: String, gain := 1.0) -> void:
	if not _snd.has(name) or not _ensure_playback():
		return
	_voices.append({"b": _snd[name], "p": 0, "g": gain})


func _synth(dur: float, f0: float, f1: float, wave: int, nz: float, lp0: float, lp1: float, att: float, amp: float) -> PackedFloat32Array:
	var n := int(dur * MIX_RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	var y := 0.0
	var dt := 1.0 / MIX_RATE
	for i in n:
		var q := float(i) / n
		var env := q / att if q < att else pow(1.0 - (q - att) / (1.0 - att), 2.0)
		ph = fmod(ph + lerpf(f0, f1, q) * dt, 1.0)
		var tone := sin(ph * TAU) if wave == 0 else (4.0 * absf(ph - 0.5) - 1.0)
		var x := tone * (1.0 - nz) + (_rng.randf() * 2.0 - 1.0) * nz
		y += lerpf(lp0, lp1, q) * (x - y)
		out[i] = y * amp * env
	return out


func _mix_into(dst: PackedFloat32Array, src: PackedFloat32Array, at: float) -> PackedFloat32Array:
	var o := int(at * MIX_RATE)
	if dst.size() < o + src.size():
		dst.resize(o + src.size())
	for i in src.size():
		dst[o + i] += src[i]
	return dst


func _build_sounds() -> void:
	_snd["thud"] = _synth(0.24, 120.0, 45.0, 0, 0.15, 0.35, 0.2, 0.03, 0.8)
	_snd["pop"] = _mix_into(_synth(0.3, 0.0, 0.0, 0, 1.0, 0.05, 0.4, 0.3, 0.45), _synth(0.12, 300.0, 700.0, 0, 0.0, 1.0, 1.0, 0.05, 0.25), 0.0)
	_snd["clink"] = _mix_into(_synth(0.09, 3100.0, 3000.0, 0, 0.0, 1.0, 1.0, 0.01, 0.16), _synth(0.07, 4650.0, 4600.0, 0, 0.1, 1.0, 1.0, 0.01, 0.1), 0.0)
	_snd["ding"] = _mix_into(_synth(0.4, 1568.0, 1568.0, 0, 0.0, 1.0, 1.0, 0.01, 0.12), _synth(0.3, 2349.0, 2349.0, 0, 0.0, 1.0, 1.0, 0.01, 0.07), 0.0)
	var sp := PackedFloat32Array()
	for i in 6:
		var f := 1800.0 + i * 420.0
		sp = _mix_into(sp, _synth(0.25, f, f, 0, 0.0, 1.0, 1.0, 0.02, 0.06), i * 0.04)
	_snd["sparkle"] = sp
	var fan := PackedFloat32Array()
	var notes := [523.25, 659.25, 783.99, 1046.5]
	for i in notes.size():
		fan = _mix_into(fan, _synth(0.35 if i < 3 else 1.0, notes[i], notes[i], 1, 0.0, 0.5, 0.5, 0.02, 0.16), i * 0.1)
	fan = _mix_into(fan, _synth(1.0, 1318.5, 1318.5, 0, 0.0, 1.0, 1.0, 0.02, 0.07), 0.3)
	fan = _mix_into(fan, _synth(1.0, 1568.0, 1568.0, 0, 0.0, 1.0, 1.0, 0.02, 0.06), 0.3)
	_snd["fanfare"] = fan


func _pump_audio() -> void:
	if _voices.is_empty() or _playback == null:
		return
	var n := mini(_playback.get_frames_available(), int(MIX_RATE * 0.06))
	if n <= 0:
		return
	var mix := PackedFloat32Array()
	mix.resize(n)
	var alive := []
	for v in _voices:
		var b: PackedFloat32Array = v.b
		var p: int = v.p
		var g: float = v.g
		var bl := b.size()
		for i in range(maxi(0, -p), mini(n, bl - p)):
			mix[i] += b[p + i] * g
		v.p = p + n
		if p + n < bl:
			alive.append(v)
	_voices = alive
	var frames := PackedVector2Array()
	frames.resize(n)
	for i in n:
		var smp := clampf(mix[i], -1.0, 1.0)
		frames[i] = Vector2(smp, smp)
	_playback.push_buffer(frames)
