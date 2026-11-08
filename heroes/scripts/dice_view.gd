extends Control
## Full-screen d20 roll overlay.
##   var DiceView = preload("res://scripts/dice_view.gd")
##   var dv = DiceView.new(); add_child(dv)
##   dv.play([{"label": "Торин · Атлетика", "d20": 14, "mod": 3, "total": 17, "dc": 12, "outcome": "успех"}])
##   await dv.finished
## Each roll: {label, d20, d20b (opt, -1 = none), adv (1/-1/0), mod, total, dc (0 = none), outcome}.
## Exactly 2 rolls are shown side by side, otherwise one after another. Tap skips to the end.

signal finished

const C_BACKDROP := Color(0.05, 0.055, 0.09, 0.82)
const C_CARD := Color("#23263a")
const C_INK := Color("#f3f1ea")
const C_ACCENT := Color("#ffc145")
const C_RED := Color("#ff5a5f")
const C_GREEN := Color("#3ddc97")
const C_DIE := Color("#4b5190")
const C_OUTLINE := Color("#10111c")

const T_TUMBLE := 0.9      # spinning with random numbers
const T_PUNCH := 0.28      # landing bounce
const T_LINE := 1.0        # "к20 = ..." line appears
const T_OUT := 1.2         # outcome word pops
const T_NEXT := 2.0        # next roll starts (non-last)
const T_END := 2.3         # last roll: finished (outcome visible ~1.1 s)

var sound_enabled := true

var _rolls: Array = []
var _groups: Array = []
var _gi := 0
var _t := 0.0
var _fade := 0.0
var _playing := false
var _slots: Array = []
var _rng := RandomNumberGenerator.new()
var _last_tap_ms := -100000

# --- procedural sound ---
const MIX_RATE := 22050.0
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _voices: Array = []   # each: {f, ph, t, dur, amp, noise, drop}


func _ready() -> void:
	_rng.randomize()
	_setup_audio()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not _playing:   # play() may have been called before the node entered the tree
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false
		set_process(false)


func play(rolls: Array) -> void:
	_rolls = []
	for r in rolls:
		if r is Dictionary:
			_rolls.append(r)
	if _rolls.is_empty():
		_playing = false
		visible = false
		finished.emit.call_deferred()
		return
	_groups = []
	if _rolls.size() == 2:
		_groups.append([0, 1])
	else:
		for i in _rolls.size():
			_groups.append([i])
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_gi = 0
	_fade = 0.0
	_playing = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	move_to_front()
	_start_group()
	set_process(true)
	queue_redraw()


func _finish() -> void:
	if not _playing:
		return
	_playing = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_voices.clear()
	finished.emit()


func _skip() -> void:
	var last := _groups.size() - 1
	if _gi == last and _t >= T_OUT:
		_finish()
		return
	if _gi != last:
		_gi = last
		_start_group()
	_t = max(_t, T_OUT)
	_fade = 1.0
	for s in _slots:
		for d in s.dice:
			d.shown = d.final
			d.landed = true
	_snd_land(false)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not _playing:
		return
	var tap := false
	if event is InputEventMouseButton and event.pressed:
		tap = true
	elif event is InputEventScreenTouch and event.pressed:
		tap = true
	if tap:
		accept_event()
		var now := Time.get_ticks_msec()
		if now - _last_tap_ms < 200:   # touch + emulated mouse = one tap
			return
		_last_tap_ms = now
		_skip()


func _start_group() -> void:
	_t = 0.0
	_slots = []
	for idx in _groups[_gi]:
		var r: Dictionary = _rolls[idx]
		var d1 := clampi(int(r.get("d20", 1)), 1, 20)
		var d2 := int(r.get("d20b", -1))
		var adv := int(r.get("adv", 0))
		var vals := [d1]
		if d2 >= 1 and d2 <= 20:
			vals.append(d2)
		var kept := 0
		if vals.size() == 2:
			if adv < 0:
				kept = 0 if vals[0] <= vals[1] else 1
			elif adv > 0:
				kept = 0 if vals[0] >= vals[1] else 1
		var dice := []
		for v in vals:
			var steps := _rng.randi_range(13, 19)
			var dir := 1.0 if _rng.randf() < 0.5 else -1.0
			dice.append({
				"final": v, "shown": _rng.randi_range(1, 20), "spin": dir * steps * PI / 3.0,
				"done": 0, "landed": false, "hop": _rng.randf_range(0.8, 1.2),
			})
		_slots.append({
			"roll": r, "dice": dice, "kept": kept, "adv": adv,
			"nat": int(vals[kept]), "seed": _rng.randf() * 100.0,
		})


func _process(delta: float) -> void:
	if not _playing:
		return
	_t += delta
	_fade = minf(1.0, _fade + delta * 5.0)
	var p := clampf(_t / T_TUMBLE, 0.0, 1.0)
	var e := _ease_out(p)
	var clicked := false
	var landed_now := false
	for s in _slots:
		for d in s.dice:
			if d.landed:
				continue
			if p >= 1.0:
				d.shown = d.final
				d.landed = true
				landed_now = true
				continue
			var steps := int(absf(d.spin * e) / (PI / 6.0))
			if steps > d.done:
				d.done = steps
				var n: int = _rng.randi_range(1, 19)
				if n >= d.shown:
					n += 1
				d.shown = n
				clicked = true
	if landed_now:
		var nat20 := false
		for s in _slots:
			if s.nat == 20:
				nat20 = true
		_snd_land(nat20)
	elif clicked:
		_snd_click()
	_pump_audio()
	var last := _groups.size() - 1
	if _gi < last and _t >= T_NEXT:
		_gi += 1
		_start_group()
	elif _gi == last and _t >= T_END:
		_finish()
		return
	queue_redraw()


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if not _playing:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(C_BACKDROP, C_BACKDROP.a * _fade))
	var n := _slots.size()
	if n == 0:
		return
	var margin := 28.0
	var gap := 18.0
	var w := (size.x - margin * 2.0 - gap * (n - 1)) / n
	var h := 640.0 if n == 1 else 580.0
	var top := size.y * 0.5 - h * 0.5
	var intro := _ease_out(clampf(_t / 0.18, 0.0, 1.0))
	for i in n:
		var rect := Rect2(margin + i * (w + gap), top + (1.0 - intro) * 60.0, w, h)
		_draw_slot(_slots[i], rect, n, intro * _fade)


func _draw_slot(s: Dictionary, rect: Rect2, ncols: int, alpha: float) -> void:
	var r: Dictionary = s.roll
	var lt := _t - T_TUMBLE      # time since landing
	var nat: int = s.nat
	var shake := Vector2.ZERO
	if nat == 1 and lt >= 0.0 and lt < 0.5:
		var k := 1.0 - lt / 0.5
		shake = Vector2(sin(lt * 90.0 + s.seed), cos(lt * 77.0 + s.seed * 2.0)) * 16.0 * k
	rect.position += shake

	# card
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_CARD, alpha)
	sb.set_corner_radius_all(28)
	var border := Color(C_INK, 0.08)
	if lt >= 0.0 and nat == 20:
		border = C_ACCENT
	elif lt >= 0.0 and nat == 1:
		border = C_RED
	sb.border_color = Color(border, border.a * alpha)
	sb.set_border_width_all(2 if ncols == 2 else 3)
	sb.shadow_color = Color(0, 0, 0, 0.45 * alpha)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0, 8)
	draw_style_box(sb, rect)

	var cx := rect.position.x + rect.size.x * 0.5
	var inner_w := rect.size.x - 36.0

	# label
	var label := str(r.get("label", ""))
	if label != "":
		var ls := _fit(label, 34 if ncols == 1 else 28, inner_w)
		_text(Vector2(cx, rect.position.y + 52.0), label, ls, Color(C_INK, 0.85 * alpha))

	# dice
	var dice: Array = s.dice
	var two := dice.size() == 2
	var R := 128.0
	if ncols == 1 and two:
		R = 100.0
	elif ncols == 2 and not two:
		R = 104.0
	elif ncols == 2 and two:
		R = 70.0
	var dy := rect.position.y + rect.size.y * 0.40
	var spread := 0.0
	if two:
		spread = minf(R * 0.866 + maxf(10.0, R * 0.2), rect.size.x * 0.5 - R * 0.866 - 8.0)
	for j in dice.size():
		var d: Dictionary = dice[j]
		var dx := cx + (0.0 if not two else (-spread if j == 0 else spread))
		var is_kept: bool = (j == s.kept)
		_draw_one_die(d, Vector2(dx, dy), R, is_kept, two, alpha, s.seed + j * 13.0)

	# advantage caption
	if two:
		var adv: int = s.adv
		var cap := "преимущество" if adv > 0 else ("помеха" if adv < 0 else "")
		if cap != "":
			var ccol := C_GREEN if adv > 0 else C_RED
			_text(Vector2(cx, dy + R * 1.2 + 22.0), cap, 26 if ncols == 1 else 22, Color(ccol, alpha), 6, Color(C_OUTLINE, 0.9 * alpha))

	# formula line
	if _t >= T_LINE:
		var la := clampf((_t - T_LINE) / 0.2, 0.0, 1.0) * alpha
		var lines := _formula(r, nat)
		var line: String = lines[0] if lines[1] == "" else lines[0] + " " + lines[1]
		var ly := rect.position.y + rect.size.y * 0.72
		var fs := _fit(line, 32 if ncols == 1 else 28, inner_w)
		if fs >= 26 or lines[1] == "":
			_text(Vector2(cx, ly), line, fs, Color(C_INK, la), 6, Color(C_OUTLINE, la))
		else:
			fs = mini(_fit(lines[0], 28, inner_w), _fit(lines[1], 28, inner_w))
			_text(Vector2(cx, ly - fs * 0.62), lines[0], fs, Color(C_INK, la), 6, Color(C_OUTLINE, la))
			_text(Vector2(cx, ly + fs * 0.62), lines[1], fs, Color(C_INK, 0.75 * la), 6, Color(C_OUTLINE, la))

	# outcome
	if _t >= T_OUT:
		var ot := _t - T_OUT
		var oa := clampf(ot / 0.15, 0.0, 1.0) * alpha
		var sc := 1.0 + 0.8 * (1.0 - _ease_out_back(clampf(ot / 0.3, 0.0, 1.0)))
		var word := str(r.get("outcome", "")).to_upper()
		if word != "":
			var col := _outcome_color(r)
			var base := 52 if ncols == 1 else 42
			var os := _fit(word, base, inner_w)
			var pos := Vector2(cx, rect.position.y + rect.size.y * 0.87)
			draw_set_transform(pos, 0.0, Vector2(sc, sc))
			var sp := word.find(" ")
			if os < base - 8 and sp > 0:
				var w1 := word.substr(0, sp)
				var w2 := word.substr(sp + 1)
				os = mini(_fit(w1, base, inner_w), _fit(w2, base, inner_w))
				_text(Vector2(0, -os * 0.55), w1, os, Color(col, oa), 10, Color(C_OUTLINE, oa))
				_text(Vector2(0, os * 0.55), w2, os, Color(col, oa), 10, Color(C_OUTLINE, oa))
			else:
				_text(Vector2.ZERO, word, os, Color(col, oa), 10, Color(C_OUTLINE, oa))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_one_die(d: Dictionary, c: Vector2, R: float, is_kept: bool, two: bool, alpha: float, seed: float) -> void:
	var p := clampf(_t / T_TUMBLE, 0.0, 1.0)
	var e := _ease_out(p)
	var ang: float = d.spin * (e - 1.0)
	var lt := _t - T_TUMBLE
	var val: int = d.final
	# hop: decaying bounces while tumbling
	var hop := 0.0
	var squash := 1.0
	if p < 1.0:
		hop = -absf(sin(p * PI * 3.0 * d.hop)) * R * 0.45 * (1.0 - p)
		squash = 0.86 + 0.14 * absf(cos(ang * 1.5))
	var punch := 1.0
	if lt >= 0.0 and lt < T_PUNCH:
		var k := lt / T_PUNCH
		punch = 1.0 + 0.22 * sin(k * PI) * (1.0 - k * 0.5)
	var dim := two and lt >= 0.15 and not is_kept
	var a := alpha
	var scale := punch
	if dim:
		var k2 := clampf((lt - 0.15) / 0.25, 0.0, 1.0)
		a *= lerpf(1.0, 0.32, k2)
		scale *= lerpf(1.0, 0.82, k2)

	var landed_effects := lt >= 0.0 and (is_kept or not two)
	# shadow
	var sh_w := R * 0.9 * (1.0 + hop / (R * 2.0))
	_ellipse(c + Vector2(0, R * 1.02), Vector2(sh_w, R * 0.14), Color(0, 0, 0, 0.35 * a))

	# nat 20 burst / nat 1 flash (behind die)
	if landed_effects and val == 20:
		var k3 := clampf(lt / 0.6, 0.0, 1.0)
		var burst := _ease_out(k3)
		var glow_a := lerpf(1.0, 0.45, k3) * a
		for i in 6:
			var rr := R * (1.05 + 0.13 * i + 0.5 * burst)
			draw_circle(c, rr, Color(C_ACCENT, 0.09 * glow_a))
		var rot := _t * 0.6
		for i in 14:
			var aa := rot + TAU * i / 14.0
			var dir := Vector2(cos(aa), sin(aa))
			var r0 := R * 1.05
			var r1 := R * (1.25 + (0.75 if not two else 0.45) * burst) * (1.0 if i % 2 == 0 else 0.78)
			var perp := Vector2(-dir.y, dir.x) * R * 0.06
			draw_colored_polygon(PackedVector2Array([c + dir * r0 + perp, c + dir * r1, c + dir * r0 - perp]),
				Color(C_ACCENT, 0.75 * glow_a))
		if lt < 0.6:
			draw_arc(c, R * (1.0 + 1.4 * burst), 0.0, TAU, 64, Color(C_ACCENT, (1.0 - k3) * a), 6.0 * (1.0 - k3) + 1.0)
	elif landed_effects and val == 1:
		var k4 := clampf(lt / 0.5, 0.0, 1.0)
		draw_circle(c, R * 1.25, Color(C_RED, 0.18 * a * (1.0 - k4 * 0.6)))
		if lt < 0.5:
			draw_arc(c, R * (1.0 + 0.9 * _ease_out(k4)), 0.0, TAU, 64, Color(C_RED, (1.0 - k4) * a), 5.0)

	var body := C_DIE
	var num_col := C_INK
	if lt >= 0.0 and (is_kept or not two):
		if val == 20:
			body = C_ACCENT.darkened(0.05)
			num_col = Color("#2a1d00")
		elif val == 1:
			body = C_RED.darkened(0.1)
	if dim:
		body = body.lerp(Color("#3a3c52"), 0.6)

	draw_set_transform(c + Vector2(0, hop), ang, Vector2(scale, scale * squash))
	_die_shape(R, body, a)
	# number (rotates with the die)
	var txt := str(d.shown)
	var fs := int(R * (0.56 if two else 0.52))
	if fs < 30:
		fs = 30
	var ncol := Color(num_col, a)
	var ocol := Color(C_OUTLINE, 0.9 * a) if num_col == C_INK else Color(1, 0.95, 0.8, 0.0)
	_text(Vector2(0, R * 0.1), txt, fs, ncol, 10 if num_col == C_INK else 0, ocol)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _die_shape(R: float, body: Color, a: float) -> void:
	var H := PackedVector2Array()
	for k in 6:
		var an := -PI / 2.0 + k * PI / 3.0
		H.append(Vector2(cos(an), sin(an)) * R)
	var tr := R * 0.6
	var T := PackedVector2Array()
	for an in [-PI / 2.0, PI / 6.0, PI * 5.0 / 6.0]:
		T.append(Vector2(cos(an), sin(an)) * tr)
	var facets := [
		[H[0], H[1], T[0]], [H[5], H[0], T[0]], [T[0], H[1], T[1]],
		[H[1], H[2], T[1]], [H[2], H[3], T[1]], [T[1], H[3], T[2]],
		[H[3], H[4], T[2]], [H[4], H[5], T[2]], [T[2], H[5], T[0]],
	]
	var light := Vector2(-0.45, -0.9).normalized()
	for f in facets:
		var cen: Vector2 = (f[0] + f[1] + f[2]) / 3.0
		var l := cen.normalized().dot(light)
		var col := body.lightened(0.28 * l) if l > 0.0 else body.darkened(-0.38 * l)
		draw_colored_polygon(PackedVector2Array(f), Color(col, a))
	draw_colored_polygon(T, Color(body.lightened(0.14), a))
	var edge := Color(C_INK, 0.38 * a)
	for f in facets:
		draw_line(f[0], f[2], edge, 2.0, true)
		draw_line(f[1], f[2], edge, 2.0, true)
	var outline := H.duplicate()
	outline.append(H[0])
	draw_polyline(outline, Color(C_INK, 0.85 * a), 4.0, true)


func _ellipse(c: Vector2, rad: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var an := TAU * i / 24.0
		pts.append(c + Vector2(cos(an) * rad.x, sin(an) * rad.y))
	draw_colored_polygon(pts, col)


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


func _formula(r: Dictionary, nat: int) -> Array:
	var m := int(r.get("mod", 0))
	var total := int(r.get("total", nat + m))
	var dc := int(r.get("dc", 0))
	var s := "к20 = %d" % nat
	if m > 0:
		s += " + %d" % m
	elif m < 0:
		s += " - %d" % -m
	if m != 0 or total != nat:
		s += " = %d" % total
	return [s, ("против %d" % dc) if dc > 0 else ""]


func _outcome_color(r: Dictionary) -> Color:
	var o := str(r.get("outcome", "")).to_lower()
	if o.contains("провал") or o.contains("промах") or o.contains("неудач"):
		return C_RED
	if o.contains("успех") or o.contains("попад") or o.contains("удач"):
		return C_GREEN
	var dc := int(r.get("dc", 0))
	if dc > 0:
		return C_GREEN if int(r.get("total", 0)) >= dc else C_RED
	return C_ACCENT


func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - x, 3.0)


func _ease_out_back(x: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)


# ---------------------------------------------------------------- sound

func _setup_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.1
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	_player.volume_db = -6.0
	add_child(_player)


func _ensure_playback() -> bool:
	if not sound_enabled or _player == null or not _player.is_inside_tree():
		return false
	if _playback == null or not _player.playing:
		_player.play()
		_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	return _playback != null


func _snd_click() -> void:
	if _ensure_playback():
		_voices.append({"f": _rng.randf_range(1500.0, 2300.0), "ph": 0.0, "t": 0.0, "dur": 0.025,
			"amp": 0.18, "noise": 0.6, "drop": 0.0})


func _snd_land(big: bool) -> void:
	if not _ensure_playback():
		return
	_voices.append({"f": 160.0, "ph": 0.0, "t": 0.0, "dur": 0.16, "amp": 0.5, "noise": 0.25, "drop": 0.6})
	if big:
		for f in [880.0, 1320.0, 1760.0]:
			_voices.append({"f": f, "ph": 0.0, "t": 0.0, "dur": 0.5, "amp": 0.09, "noise": 0.0, "drop": 0.0})


func _pump_audio() -> void:
	if _voices.is_empty() or _playback == null:
		return
	var n := mini(_playback.get_frames_available(), int(MIX_RATE * 0.05))
	var dt := 1.0 / MIX_RATE
	for i in n:
		var smp := 0.0
		for v in _voices:
			if v.t >= v.dur:
				continue
			var env: float = 1.0 - v.t / v.dur
			env *= env
			var f: float = v.f * (1.0 - v.drop * v.t / v.dur)
			v.ph = fmod(v.ph + f * dt, 1.0)
			var tone: float = sin(v.ph * TAU)
			var nz: float = _rng.randf() * 2.0 - 1.0
			smp += (tone * (1.0 - v.noise) + nz * v.noise) * v.amp * env
			v.t += dt
		smp = clampf(smp, -1.0, 1.0)
		_playback.push_frame(Vector2(smp, smp))
	var alive := []
	for v in _voices:
		if v.t < v.dur:
			alive.append(v)
	_voices = alive
