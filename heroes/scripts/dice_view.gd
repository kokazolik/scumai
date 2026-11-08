extends Control
## Full-screen d20 roll overlay.
##   var DiceView = preload("res://scripts/dice_view.gd")
##   var dv = DiceView.new(); add_child(dv)
##   dv.play([{"label": "Торин · Атлетика", "d20": 14, "mod": 3, "total": 17, "dc": 12, "outcome": "успех"}])
##   await dv.finished
## Each roll: {label, d20, d20b (opt, -1 = none), adv (1/-1/0), mod, total, dc (0 = none), outcome,
##   kind (opt: "check", "save", "attack", "spell", "heal", "death", "enemy"),
##   dmg (opt int, damage dealt / hp healed, -1 or missing = none), dmg_text (opt, e.g. "2к6+3")}.
## d20 <= 0 means "no d20" (e.g. a plain heal): only the damage/heal burst is shown.
## Exactly 2 rolls are shown side by side, otherwise one after another.
## One roll (or a pair) lasts ~3.2 s; with 3+ rolls each lasts ~2.4 s. Tap skips to the end.

signal finished

const C_BACKDROP := Color(0.05, 0.03, 0.02, 0.84)
const C_CARD := Color("#2a1d14")
const UISkin = preload("res://scripts/skin.gd")
const C_INK := Color("#f3f1ea")
const C_ACCENT := Color("#ffc145")
const C_RED := Color("#ff5a5f")
const C_GREEN := Color("#3ddc97")
const C_PURPLE := Color("#a77bff")
const C_DIE := Color("#6a1d1b")
const C_OUTLINE := Color("#140a06")
const C_BANNER := Color("#4a1c16")

# timeline of one roll in seconds (full length; multiplied by _ts)
const T_THROW := 0.42     # die is thrown in from below
const T_IMP1 := 0.92      # first impact
const T_IMP2 := 1.22      # second bounce
const T_IMP3 := 1.40      # third bounce
const T_REST := 1.52      # settled, final number
const T_LINE := 1.72      # formula
const T_OUT := 1.98       # outcome stamp
const T_DMG := 2.34       # damage / heal burst
const T_LEN := 3.2        # one roll (or pair)
const T_LEN_FAST := 2.4   # per roll when there are 3+ rolls
const SLASH_KINDS := ["attack", "enemy"]

var sound_enabled := true

var _rolls: Array = []
var _groups: Array = []
var _gi := 0
var _t := 0.0          # roll timeline time
var _gt := 0.0         # real time since the group started
var _ts := 1.0         # timeline scale
var _fade := 0.0
var _playing := false
var _slots: Array = []
var _rng := RandomNumberGenerator.new()
var _last_tap_ms := -100000
var _parts: Array = []
var _shake_amp := 0.0
var _shake := Vector2.ZERO
var _red_at := -100.0
var _gold_at := -100.0
var _fired := {}
var _glow_tex: Texture2D
var _vig_tex: Texture2D

# --- procedural sound (pre-rendered buffers mixed into an AudioStreamGenerator) ---
const MIX_RATE := 22050.0
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _voices: Array = []   # each: {b: PackedFloat32Array, p: int, g: float}
static var _snd := {}


func _ready() -> void:
	_rng.randomize()
	_glow_tex = _make_glow_tex()
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
	_ts = T_LEN_FAST / T_LEN if _rolls.size() > 2 else 1.0
	if _glow_tex == null:
		_glow_tex = _make_glow_tex()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_gi = 0
	_fade = 0.0
	_parts.clear()
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
	_parts.clear()
	finished.emit()


func _skip() -> void:
	var last := _groups.size() - 1
	if _gi == last and _t >= _tb(T_OUT):
		_finish()
		return
	if _gi != last:
		_gi = last
		_start_group()
	_t = maxf(_t, _tb(T_OUT))
	_gt = maxf(_gt, 1.0)
	_fade = 1.0
	_fired["throw"] = true
	for s in _slots:
		for d in s.dice:
			d.shown = d.final
			d.flip = false
			d.landed = true
			d.ev = 4
	_play_snd("thud", 0.8)
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


func _tb(x: float) -> float:
	return x * _ts


func _start_group() -> void:
	_t = 0.0
	_gt = 0.0
	_slots = []
	_fired = {}
	_red_at = -100.0
	_gold_at = -100.0
	var gsize: int = _groups[_gi].size()
	var all_nodie := true
	for si in gsize:
		var idx: int = _groups[_gi][si]
		var r: Dictionary = _rolls[idx]
		var raw := int(r.get("d20", 1))
		var nodie := raw <= 0
		var d1 := clampi(raw, 1, 20)
		var d2 := int(r.get("d20b", -1))
		var adv := int(r.get("adv", 0))
		var vals := []
		if not nodie:
			all_nodie = false
			vals.append(d1)
			if d2 >= 1 and d2 <= 20:
				vals.append(d2)
		var kept := 0
		if vals.size() == 2:
			if adv < 0:
				kept = 0 if vals[0] <= vals[1] else 1
			elif adv > 0:
				kept = 0 if vals[0] >= vals[1] else 1
		var dice := []
		for j in vals.size():
			var dir := 1.0 if _rng.randf() < 0.5 else -1.0
			var side := dir
			if vals.size() == 2:
				side = -1.0 if j == 0 else 1.0
			elif gsize == 2:
				side = -1.0 if si == 0 else 1.0
			dice.append({
				"final": vals[j], "shown": _rng.randi_range(1, 20), "j": j,
				"spin": dir * _rng.randf_range(5.5, 8.0) * PI, "dir": dir, "side": side,
				"delay": (si * 2 + j) * 0.05 * _ts, "ev": 0, "landed": false,
				"next_flip": 0.0, "flip": false, "cracks": _make_cracks(),
				"R": 100.0, "rest": Vector2.ZERO,
			})
		var kind := str(r.get("kind", "")).to_lower()
		var dmg := int(r.get("dmg", -1))
		var slashes := []
		for i in 3:
			var base_ang: float = [0.62, PI - 0.55, 0.22][i]
			var ang := base_ang + _rng.randf_range(-0.12, 0.12)
			slashes.append({"dir": Vector2(cos(ang), sin(ang)),
				"off": Vector2(_rng.randf_range(-0.25, 0.25), _rng.randf_range(-0.35, 0.35))})
		_slots.append({
			"roll": r, "dice": dice, "kept": kept, "adv": adv, "kind": kind, "dmg": dmg,
			"show_dmg": dmg >= 0 and not _is_fail(r), "nodie": nodie,
			"nat": int(vals[kept]) if not nodie else 0, "seed": _rng.randf() * 100.0,
			"srot": _rng.randf_range(-0.09, 0.09), "slashes": slashes,
			"rect": Rect2(), "R": 100.0, "ncols": gsize,
		})
	_layout()
	if all_nodie:
		_t = _tb(T_REST)
		_fired["throw"] = true


func _is_fail(r: Dictionary) -> bool:
	var o := str(r.get("outcome", "")).to_lower()
	if o.contains("провал") or o.contains("промах") or o.contains("неудач") or o.contains("мимо"):
		return true
	if o.contains("успех") or o.contains("попад") or o.contains("удач") or o.contains("крит"):
		return false
	var dc := int(r.get("dc", 0))
	if dc > 0:
		return int(r.get("total", 0)) < dc
	return false


func _make_cracks() -> Array:
	var out := []
	var base := _rng.randf() * TAU
	for i in 3:
		var pts := PackedVector2Array()
		var ang := base + TAU * i / 3.0 + _rng.randf_range(-0.4, 0.4)
		var p := Vector2(cos(ang), sin(ang)) * 0.3
		pts.append(p)
		for k in 6:
			ang += _rng.randf_range(-0.55, 0.55)
			p += Vector2(cos(ang), sin(ang)) * _rng.randf_range(0.14, 0.2)
			if p.length() > 0.9:
				p = p.normalized() * 0.9
				pts.append(p)
				break
			pts.append(p)
		out.append(pts)
	return out


func _layout() -> void:
	var n := _slots.size()
	if n == 0:
		return
	var margin := 24.0
	var gap := 16.0
	var w := (size.x - margin * 2.0 - gap * (n - 1)) / n
	var h := 700.0 if n == 1 else 640.0
	var top := size.y * 0.5 - h * 0.5
	for i in n:
		var s: Dictionary = _slots[i]
		var rect := Rect2(margin + i * (w + gap), top, w, h)
		s.rect = rect
		var dice: Array = s.dice
		var two := dice.size() == 2
		var R := 118.0
		if n == 1 and two:
			R = 88.0
		elif n == 2 and not two:
			R = 92.0
		elif n == 2 and two:
			R = 62.0
		s.R = R
		var cx := rect.position.x + rect.size.x * 0.5
		var dy := rect.position.y + rect.size.y * 0.45
		var spread := 0.0
		if two:
			spread = minf(R * 0.866 + maxf(10.0, R * 0.22), rect.size.x * 0.5 - R * 0.866 - 8.0)
		for j in dice.size():
			var d: Dictionary = dice[j]
			d.R = R
			d.rest = Vector2(cx + (0.0 if not two else (-spread if j == 0 else spread)), dy)


func _burst_center(s: Dictionary) -> Vector2:
	var dice: Array = s.dice
	if dice.is_empty():
		var rect: Rect2 = s.rect
		return Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.45)
	if dice.size() == 2:
		var a: Vector2 = dice[0].rest
		var b: Vector2 = dice[1].rest
		return (a + b) * 0.5
	return dice[0].rest


# Pose of a die at its local time u: {vis, pos, ang, sx, sy, p}
func _die_pose(d: Dictionary, u: float) -> Dictionary:
	var R: float = d.R
	var rest: Vector2 = d.rest
	var side: float = d.side
	var t0 := _tb(T_THROW)
	var t1 := _tb(T_IMP1)
	var t2 := _tb(T_IMP2)
	var t3 := _tb(T_IMP3)
	var t4 := _tb(T_REST)
	if u < t0:
		return {"vis": false}
	var sx := 1.0
	var sy := 1.0
	var pos := Vector2.ZERO
	var I := rest + Vector2(side * R * 0.75, 0.0)
	if u < t1:
		var k := (u - t0) / (t1 - t0)
		var S := Vector2(rest.x + side * R * 1.9, size.y + R * 1.3)
		var dist := S.y - I.y
		var H := dist * 0.42 + R * 0.2
		pos = Vector2(lerpf(S.x, I.x, k), S.y + (I.y - S.y) * k - H * 4.0 * k * (1.0 - k))
		if k > 0.72:
			var q := (k - 0.72) / 0.28
			sy = 1.0 + 0.16 * q
			sx = 1.0 - 0.09 * q
	else:
		var q := clampf((u - t1) / (t4 - t1), 0.0, 1.0)
		var x := lerpf(I.x, rest.x, _ease_out(q))
		var hh := 0.0
		if u < t2:
			var b := (u - t1) / (t2 - t1)
			hh = R * 0.85 * 4.0 * b * (1.0 - b)
		elif u < t3:
			var b := (u - t2) / (t3 - t2)
			hh = R * 0.34 * 4.0 * b * (1.0 - b)
		elif u < t4:
			var b := (u - t3) / (t4 - t3)
			hh = R * 0.1 * 4.0 * b * (1.0 - b)
		pos = Vector2(x, rest.y - hh)
		var imps := [[t1, 1.0], [t2, 0.6], [t3, 0.32], [t4, 0.15]]
		for im in imps:
			var dt: float = u - float(im[0])
			if dt >= 0.0 and dt < 0.12:
				var w: float = sin(PI * dt / 0.12) * float(im[1])
				sy *= 1.0 - 0.3 * w
				sx *= 1.0 + 0.22 * w
		pos.y += R * (1.0 - sy) * 0.9
	var p := clampf((u - t0) / (t4 - t0), 0.0, 1.0)
	var spin: float = d.spin
	var ang := spin * (1.0 - pow(1.0 - p, 2.2)) - spin
	if u > t4:
		var lt := u - t4
		ang = 0.09 * float(d.dir) * sin(lt * 24.0) * exp(-lt * 8.0)
	return {"vis": true, "pos": pos, "ang": ang, "sx": sx, "sy": sy, "p": p}


func _process(delta: float) -> void:
	if not _playing:
		return
	_t += delta
	_gt += delta
	_fade = minf(1.0, _fade + delta * 5.0)
	_layout()
	if not _fired.has("throw") and _t >= _tb(T_THROW) - 0.05:
		_fired["throw"] = true
		_play_snd("whoosh", 1.0)
	for s in _slots:
		for d in s.dice:
			var u: float = _t - float(d.delay)
			if not d.landed and u >= _tb(T_THROW) and u >= float(d.next_flip):
				var n: int = _rng.randi_range(1, 19)
				if n >= int(d.shown):
					n += 1
				d.shown = n
				d.flip = not d.flip
				var p := clampf((u - _tb(T_THROW)) / _tb(T_REST - T_THROW), 0.0, 1.0)
				d.next_flip = u + lerpf(0.03, 0.2, p * p)
			var times := [_tb(T_IMP1), _tb(T_IMP2), _tb(T_IMP3), _tb(T_REST)]
			while int(d.ev) < 4 and u >= float(times[int(d.ev)]):
				_die_event(s, d, int(d.ev))
				d.ev = int(d.ev) + 1
		_slot_events(s)
	_update_parts(delta)
	_shake_amp *= exp(-delta * 9.0)
	if _shake_amp < 0.3:
		_shake_amp = 0.0
	_shake = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * _shake_amp
	_pump_audio()
	var last := _groups.size() - 1
	var dur := _tb(T_LEN)
	if _gi < last and _t >= dur:
		_gi += 1
		_start_group()
	elif _gi == last and _t >= dur:
		_finish()
		return
	queue_redraw()


func _die_event(s: Dictionary, d: Dictionary, ev: int) -> void:
	var R: float = d.R
	var k := R / 118.0
	var times := [_tb(T_IMP1), _tb(T_IMP2), _tb(T_IMP3), _tb(T_REST)]
	var pose := _die_pose(d, float(times[ev]) + 0.0001)
	var gp := Vector2((pose.pos as Vector2).x, (d.rest as Vector2).y + R * 0.92)
	match ev:
		0:
			_play_snd("thud", 0.8)
			_play_snd("clack", 1.0)
			_shake_amp += 13.0 * k
			_dust(gp, 12, R * 0.9, Color(0.75, 0.75, 0.9))
			_sparks(gp, 12, C_ACCENT, 250.0, 650.0, k)
		1:
			_play_snd("clack", 0.75)
			_shake_amp += 5.0 * k
			_dust(gp, 6, R * 0.6, Color(0.75, 0.75, 0.9))
			_sparks(gp, 5, C_ACCENT, 180.0, 420.0, k)
		2:
			_play_snd("clack", 0.45)
			_dust(gp, 3, R * 0.4, Color(0.75, 0.75, 0.9))
		3:
			d.landed = true
			d.shown = d.final
			d.flip = false
			var two: bool = (s.dice as Array).size() == 2
			if two and int(d.j) != int(s.kept):
				return
			var c: Vector2 = d.rest
			if int(d.final) == 20:
				_gold_at = _t
				_play_snd("chime", 1.0)
				_shake_amp += 9.0 * k
				_confetti(c, int(70 * clampf(k, 0.6, 1.0)))
				_sparks(c, 30, C_ACCENT, 350.0, 900.0, k)
				_stars(c, 14, C_ACCENT, R * 1.6)
				_ring(c, R * 0.8, R * 3.2, C_ACCENT, 0.6, 10.0 * k)
				_ring(c, R * 0.6, R * 2.2, Color(1, 1, 1), 0.45, 6.0 * k)
			elif int(d.final) == 1:
				_red_at = _t
				_play_snd("buzz", 1.0)
				_play_snd("thud", 0.9)
				_shake_amp += 18.0 * k
				_debris(c, 16, Color("#6e2b35"), R)
				_ring(c, R * 0.8, R * 2.4, C_RED, 0.5, 8.0 * k)


func _slot_events(s: Dictionary) -> void:
	var key := str(s.seed)
	var rect: Rect2 = s.rect
	var R: float = s.R
	var k := R / 118.0
	if _t >= _tb(T_OUT) + 0.15 and not _fired.has(key + "out"):
		_fired[key + "out"] = true
		if str(s.roll.get("outcome", "")) != "":
			_play_snd("stamp", 0.8)
			_shake_amp += 4.0
			var sp := Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y * 0.88)
			_dust(sp, 10, rect.size.x * 0.32, Color(0.8, 0.8, 0.9))
	if not s.show_dmg:
		return
	var c := _burst_center(s)
	var kind: String = s.kind
	if kind == "heal":
		if _t >= _tb(T_DMG) and not _fired.has(key + "dmg"):
			_fired[key + "dmg"] = true
			_play_snd("heal", 1.0)
			_pluses(c, 18, R)
			_stars(c, 12, C_GREEN, R * 1.4)
			_ring(c, R * 0.4, R * 2.0, C_GREEN, 0.7, 8.0 * k)
	elif kind == "spell":
		if _t >= _tb(T_DMG) and not _fired.has(key + "dmg"):
			_fired[key + "dmg"] = true
			_play_snd("magic", 1.0)
			_shake_amp += 6.0 * k
			_sparks(c, 26, C_PURPLE, 300.0, 800.0, k)
			_stars(c, 16, Color("#d9c6ff"), R * 1.8)
			_debris(c, 10, C_PURPLE.darkened(0.3), R)
	else:
		for i in 3:
			if _t >= _tb(T_DMG) + i * 0.08 and not _fired.has(key + "sl%d" % i):
				_fired[key + "sl%d" % i] = true
				_play_snd("slash", 1.0 - i * 0.15)
				var sl: Dictionary = s.slashes[i]
				var dir: Vector2 = sl.dir
				var col := C_RED if kind == "enemy" else C_ACCENT
				_sparks_dir(c + _slash_off(s, i), dir, 12, col, k)
				if i == 0:
					_play_snd("thud", 0.7)
					_shake_amp += 10.0 * k
					_debris(c, 12, Color("#c9cbe0"), R)
					if kind == "enemy":
						_red_at = _t


func _slash_off(s: Dictionary, i: int) -> Vector2:
	var sl: Dictionary = s.slashes[i]
	var o: Vector2 = sl.off
	var rect: Rect2 = s.rect
	return Vector2(o.x * rect.size.x * 0.5, o.y * float(s.R))


# ---------------------------------------------------------------- particles
# kinds: 0 spark, 1 dust, 2 confetti, 3 debris, 4 star, 5 ring, 6 plus

func _add(k: int, p: Vector2, v: Vector2, life: float, col: Color, sz: float, g: float, drag: float) -> Dictionary:
	var d := {"k": k, "p": p, "v": v, "t": 0.0, "life": life, "col": col, "s": sz, "g": g, "drag": drag,
		"rot": _rng.randf() * TAU, "rv": _rng.randf_range(-10.0, 10.0), "r1": 0.0, "ph": _rng.randf() * TAU}
	_parts.append(d)
	return d


func _sparks(p: Vector2, n: int, col: Color, vmin: float, vmax: float, k: float) -> void:
	for i in n:
		var a := _rng.randf_range(PI * 1.05, PI * 1.95)
		var v := Vector2(cos(a), sin(a)) * _rng.randf_range(vmin, vmax) * maxf(k, 0.6)
		var c := col.lerp(Color(1, 1, 1), _rng.randf() * 0.6)
		_add(0, p + Vector2(_rng.randf_range(-10, 10), 0), v, _rng.randf_range(0.35, 0.7), c, _rng.randf_range(0.8, 1.4), 1400.0, 1.5)


func _sparks_dir(p: Vector2, dir: Vector2, n: int, col: Color, k: float) -> void:
	for i in n:
		var a := dir.angle() + _rng.randf_range(-0.5, 0.5)
		var v := Vector2(cos(a), sin(a)) * _rng.randf_range(300.0, 900.0) * maxf(k, 0.6)
		var c := col.lerp(Color(1, 1, 1), _rng.randf() * 0.7)
		_add(0, p + dir * _rng.randf_range(-60.0, 60.0), v, _rng.randf_range(0.25, 0.5), c, _rng.randf_range(0.9, 1.5), 900.0, 2.0)


func _dust(p: Vector2, n: int, spread: float, col: Color) -> void:
	for i in n:
		var x := _rng.randf_range(-1.0, 1.0)
		var v := Vector2(x * _rng.randf_range(80.0, 220.0), -_rng.randf_range(10.0, 70.0))
		_add(1, p + Vector2(x * spread * 0.4, _rng.randf_range(-6, 6)), v, _rng.randf_range(0.45, 0.8), col, _rng.randf_range(10.0, 20.0), -30.0, 3.0)


func _confetti(p: Vector2, n: int) -> void:
	var cols := [C_ACCENT, C_RED, C_GREEN, C_PURPLE, Color("#5ec8ff"), C_INK, C_ACCENT]
	for i in n:
		var a := _rng.randf_range(PI * 1.1, PI * 1.9)
		var v := Vector2(cos(a), sin(a)) * _rng.randf_range(400.0, 1100.0)
		_add(2, p, v, _rng.randf_range(1.0, 1.6), cols[i % cols.size()], _rng.randf_range(7.0, 12.0), 900.0, 2.2)


func _debris(p: Vector2, n: int, col: Color, R: float) -> void:
	for i in n:
		var a := _rng.randf_range(PI * 1.0, PI * 2.0)
		var v := Vector2(cos(a), sin(a)) * _rng.randf_range(200.0, 650.0)
		_add(3, p + Vector2(_rng.randf_range(-R, R) * 0.4, _rng.randf_range(-R, R) * 0.3), v, _rng.randf_range(0.6, 1.0),
			col.lerp(Color(1, 1, 1), _rng.randf() * 0.25), _rng.randf_range(5.0, 11.0) * R / 118.0 + 3.0, 1600.0, 0.6)


func _stars(p: Vector2, n: int, col: Color, spread: float) -> void:
	for i in n:
		var off := Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * spread
		var d := _add(4, p + off, Vector2(0, -_rng.randf_range(20.0, 80.0)), _rng.randf_range(0.5, 1.0), col, _rng.randf_range(8.0, 16.0), 0.0, 1.0)
		d.t = -_rng.randf_range(0.0, 0.3)


func _ring(p: Vector2, r0: float, r1: float, col: Color, life: float, w: float) -> void:
	var d := _add(5, p, Vector2.ZERO, life, col, r0, 0.0, 0.0)
	d.r1 = r1
	d.rv = w


func _pluses(p: Vector2, n: int, R: float) -> void:
	for i in n:
		var off := Vector2(_rng.randf_range(-1.2, 1.2) * R, _rng.randf_range(-0.6, 0.9) * R)
		var d := _add(6, p + off, Vector2(_rng.randf_range(-20, 20), -_rng.randf_range(90.0, 200.0)), _rng.randf_range(0.8, 1.3),
			C_GREEN.lerp(Color(1, 1, 1), _rng.randf() * 0.4), _rng.randf_range(9.0, 16.0) * R / 118.0 + 2.0, -60.0, 0.5)
		d.t = -_rng.randf_range(0.0, 0.35)


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
		if int(d.k) != 5:
			d.rot = float(d.rot) + float(d.rv) * delta
	_parts = alive


func _draw_parts() -> void:
	for d in _parts:
		var t: float = d.t
		if t < 0.0:
			continue
		var q: float = t / float(d.life)
		var p: Vector2 = (d.p as Vector2) + _shake
		var col: Color = d.col
		var sz: float = d.s
		match int(d.k):
			0:
				var v: Vector2 = d.v
				var ln := clampf(v.length() * 0.035, 3.0, 30.0) * sz
				var dir := v.normalized()
				draw_line(p - dir * ln, p, Color(col, 1.0 - q), maxf(1.0, 3.5 * sz * (1.0 - q * 0.6)), true)
			1:
				_glow(p, sz * (1.0 + 2.2 * q), Color(col, 0.4 * (1.0 - q)))
			2:
				var fl := absf(cos(float(d.rot) * 0.7 + float(d.ph)))
				draw_set_transform(p, float(d.rot) * 0.4, Vector2(1.0, 0.25 + 0.75 * fl))
				var a := 1.0 if q < 0.75 else (1.0 - q) / 0.25
				draw_rect(Rect2(-sz * 0.7, -sz * 0.4, sz * 1.4, sz * 0.8), Color(col.darkened(0.25 * (1.0 - fl)), a))
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			3:
				draw_set_transform(p, float(d.rot), Vector2.ONE)
				var a := 1.0 if q < 0.7 else (1.0 - q) / 0.3
				draw_colored_polygon(PackedVector2Array([Vector2(0, -sz), Vector2(sz * 0.8, sz * 0.6), Vector2(-sz * 0.6, sz * 0.4)]), Color(col, a))
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			4:
				var k := sin(clampf(q, 0.0, 1.0) * PI)
				_star(p, sz * k, Color(col, k), float(d.rot) * 0.1)
			5:
				var r := lerpf(sz, float(d.r1), _ease_out(q))
				draw_arc(p, r, 0.0, TAU, 72, Color(col, (1.0 - q) * 0.9), maxf(1.0, float(d.rv) * (1.0 - q)), true)
			6:
				var a := 1.0 if q < 0.6 else (1.0 - q) / 0.4
				var w := sz * 0.32
				draw_rect(Rect2(p.x - sz * 0.5, p.y - w * 0.5, sz, w), Color(col, a))
				draw_rect(Rect2(p.x - w * 0.5, p.y - sz * 0.5, w, sz), Color(col, a))


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


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if not _playing:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(C_BACKDROP, C_BACKDROP.a * _fade))
	_glow(size * 0.5, size.x * 0.95, Color(0.32, 0.36, 0.75, 0.16 * _fade))
	var n := _slots.size()
	if n == 0:
		return
	var intro := _ease_out(clampf(_gt / 0.22, 0.0, 1.0))
	for i in n:
		_draw_slot(_slots[i], intro * _fade, (1.0 - intro) * 60.0)
	_draw_parts()
	# full-screen flashes
	var rq := (_t - _red_at) / 0.5
	if rq >= 0.0 and rq < 1.0:
		var a := (1.0 - rq)
		draw_rect(Rect2(Vector2.ZERO, size), Color(C_RED, 0.1 * a * a))
		_vignette(Color(C_RED, 0.6 * a), size.x * 0.28)
	var gq := (_t - _gold_at) / 0.55
	if gq >= 0.0 and gq < 1.0:
		var a := (1.0 - gq)
		draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.93, 0.7, 0.16 * a * a))
		_vignette(Color(C_ACCENT, 0.6 * a), size.x * 0.22)


func _draw_slot(s: Dictionary, alpha: float, yoff: float) -> void:
	var r: Dictionary = s.roll
	var base_rect: Rect2 = s.rect
	var ncols: int = s.ncols
	var R: float = s.R
	var kind: String = s.kind
	var nat: int = s.nat
	var landed := _t >= _tb(T_REST)
	# knock-back when hit by a slash
	var kick := Vector2.ZERO
	var hitflash := 0.0
	if s.show_dmg and kind != "heal":
		for i in (3 if kind != "spell" else 1):
			var dk := _t - _tb(T_DMG) - i * 0.08
			if dk >= 0.0 and dk < 0.3:
				var f := 1.0 - dk / 0.3
				var sl: Dictionary = s.slashes[i]
				var dir: Vector2 = sl.dir
				kick += Vector2(-dir.y, dir.x) * 9.0 * f * sin(dk * 55.0)
				hitflash = maxf(hitflash, f * f)
	var off := Vector2(0, yoff) + _shake + kick
	var rect := Rect2(base_rect.position + off, base_rect.size)
	var cx := rect.position.x + rect.size.x * 0.5
	var inner_w := rect.size.x - 36.0

	# nat 20 glow around the card
	var gq := (_t - _gold_at) / 1.2
	if landed and nat == 20 and gq >= 0.0:
		var ga := lerpf(0.55, 0.22, clampf(gq, 0.0, 1.0))
		_glow(rect.get_center(), rect.size.x * 1.0, Color(C_ACCENT, ga * alpha))

	# card
	var skin_sb := UISkin.panel("dark", 0)
	skin_sb.modulate_color = Color(Color(1, 1, 1).lerp(Color(1.6, 1.5, 1.4), hitflash), alpha)
	var sh := StyleBoxFlat.new()
	sh.bg_color = Color(0, 0, 0, 0)
	sh.set_corner_radius_all(24)
	sh.shadow_color = Color(0, 0, 0, 0.5 * alpha)
	sh.shadow_size = 18
	sh.shadow_offset = Vector2(0, 8)
	draw_style_box(sh, rect.grow(-6))
	draw_style_box(skin_sb, rect)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(20)
	var border := Color(C_INK, 0.0)
	if kind == "enemy":
		border = Color(C_RED, 0.35)
	if landed and nat == 20:
		border = C_ACCENT
	elif landed and nat == 1:
		border = C_RED
	sb.border_color = Color(border, border.a * alpha)
	sb.set_border_width_all(2 if ncols == 2 else 3)
	draw_style_box(sb, rect.grow(-10))

	# label
	var label := str(r.get("label", ""))
	if label != "":
		var ls := _fit(label, 34 if ncols == 1 else 26, inner_w)
		_text(Vector2(cx, rect.position.y + (50.0 if ncols == 1 else 44.0)), label, ls, Color(C_INK, 0.85 * alpha))

	# target banner
	_draw_banner(s, Vector2(cx, rect.position.y + (112.0 if ncols == 1 else 100.0)), alpha, inner_w)

	# dice
	var dice: Array = s.dice
	for d in dice:
		_draw_die(s, d, off, alpha)

	# advantage caption
	if dice.size() == 2 and _t >= _tb(T_REST):
		var adv: int = s.adv
		var cap := "преимущество" if adv > 0 else ("помеха" if adv < 0 else "")
		if cap != "":
			var ca := clampf((_t - _tb(T_REST)) / 0.2, 0.0, 1.0) * alpha
			var ccol := C_GREEN if adv > 0 else C_RED
			var dy: float = (dice[0].rest as Vector2).y + off.y
			_text(Vector2(cx, dy + R * 1.2 + 18.0), cap, 26 if ncols == 1 else 22, Color(ccol, ca), 6, Color(C_OUTLINE, 0.9 * ca))

	# formula line
	if _t >= _tb(T_LINE):
		var la := clampf((_t - _tb(T_LINE)) / 0.2, 0.0, 1.0) * alpha
		var rise := (1.0 - _ease_out(clampf((_t - _tb(T_LINE)) / 0.25, 0.0, 1.0))) * 14.0
		var lines := _formula(s)
		var line: String = lines[0] if lines[1] == "" else lines[0] + " " + lines[1]
		var ly := rect.position.y + rect.size.y * 0.745 + rise
		var fs := _fit(line, 32 if ncols == 1 else 28, inner_w)
		if fs >= 26 or lines[1] == "":
			_text(Vector2(cx, ly), line, fs, Color(C_INK, la), 6, Color(C_OUTLINE, la))
		else:
			fs = mini(_fit(lines[0], 28, inner_w), _fit(lines[1], 28, inner_w))
			_text(Vector2(cx, ly - fs * 0.62), lines[0], fs, Color(C_INK, la), 6, Color(C_OUTLINE, la))
			_text(Vector2(cx, ly + fs * 0.62), lines[1], fs, Color(C_INK, 0.75 * la), 6, Color(C_OUTLINE, la))

	# outcome stamp
	if _t >= _tb(T_OUT):
		_draw_stamp(s, Vector2(cx, rect.position.y + rect.size.y * 0.88), alpha, inner_w)

	# damage / heal burst
	if s.show_dmg and _t >= _tb(T_DMG):
		_draw_dmg(s, _burst_center(s) + off, rect, alpha, inner_w)


func _draw_banner(s: Dictionary, c: Vector2, alpha: float, inner_w: float) -> void:
	var r: Dictionary = s.roll
	var dc := int(r.get("dc", 0))
	if dc <= 0:
		return
	var k := clampf((_gt - 0.06) / 0.34, 0.0, 1.0)
	if k <= 0.0:
		return
	var sc := _ease_out_back(k)
	var kind: String = s.kind
	var ac := kind in ["attack", "enemy", "spell"]
	var txt := ("КД %d" if ac else "Сложность %d") % dc
	var ncols: int = s.ncols
	var fs := _fit(txt, 30 if ncols == 1 else 24, inner_w - 90.0)
	var font := get_theme_default_font()
	var tw := fs * 4.0
	if font != null:
		tw = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var bw := tw + fs * 2.6
	var bh := fs * 1.65
	var bcol := C_ACCENT
	if _t >= _tb(T_OUT):
		var oc := _outcome_color(r)
		bcol = C_ACCENT.lerp(oc, clampf((_t - _tb(T_OUT)) / 0.25, 0.0, 1.0))
	var a := alpha * clampf(k * 2.0, 0.0, 1.0)
	# pulse while waiting for the throw
	if _t < _tb(T_REST):
		var pul := 0.5 + 0.5 * sin(_gt * 9.0)
		_glow(c, bw * 0.75, Color(bcol, 0.18 * pul * a))
	draw_set_transform(c, 0.0, Vector2(sc, sc))
	var hw := bw * 0.5
	var tail := Color(C_BANNER.darkened(0.35), a)
	for sgn in [-1.0, 1.0]:
		var x0: float = sgn * (hw - 10.0)
		var x1: float = sgn * (hw + bh * 0.62)
		var x2: float = sgn * (hw + bh * 0.36)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x0, -bh * 0.22), Vector2(x1, -bh * 0.22), Vector2(x2, bh * 0.24),
			Vector2(x1, bh * 0.7), Vector2(x0, bh * 0.7)]), tail)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_BANNER, a)
	sb.set_corner_radius_all(int(bh * 0.22))
	sb.border_color = Color(bcol, a)
	sb.set_border_width_all(3)
	draw_style_box(sb, Rect2(-hw, -bh * 0.5, bw, bh))
	# icon
	var ic := Vector2(-hw + fs * 1.0, 0.0)
	var ir := fs * 0.42
	if ac:
		var sh := PackedVector2Array()
		for pt in [Vector2(0, -1), Vector2(0.85, -0.68), Vector2(0.78, 0.2), Vector2(0, 1.05), Vector2(-0.78, 0.2), Vector2(-0.85, -0.68)]:
			sh.append(ic + pt * ir)
		draw_colored_polygon(sh, Color(bcol, a))
		var sh2 := PackedVector2Array()
		for pt in [Vector2(0, -0.6), Vector2(0.5, -0.4), Vector2(0.45, 0.12), Vector2(0, 0.6), Vector2(-0.45, 0.12), Vector2(-0.5, -0.4)]:
			sh2.append(ic + pt * ir)
		draw_colored_polygon(sh2, Color(C_BANNER, a))
	else:
		draw_arc(ic, ir, 0.0, TAU, 32, Color(bcol, a), 3.0, true)
		draw_arc(ic, ir * 0.55, 0.0, TAU, 24, Color(bcol, a), 3.0, true)
		draw_circle(ic, ir * 0.2, Color(bcol, a))
	_text(Vector2(fs * 0.55, 0.0), txt, fs, Color(C_INK.lerp(bcol, 0.35), a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_die(s: Dictionary, d: Dictionary, off: Vector2, alpha: float) -> void:
	var u: float = _t - float(d.delay)
	var pose := _die_pose(d, u)
	if not pose.vis:
		return
	var R: float = d.R
	var two: bool = (s.dice as Array).size() == 2
	var is_kept: bool = int(d.j) == int(s.kept)
	var lt := u - _tb(T_REST)
	var landed := lt >= 0.0
	var val: int = d.final
	var a := alpha
	var sc := 1.0
	var dim := two and lt >= 0.15 and not is_kept
	if dim:
		var k2 := clampf((lt - 0.15) / 0.25, 0.0, 1.0)
		a *= lerpf(1.0, 0.32, k2)
		sc *= lerpf(1.0, 0.82, k2)
	if s.show_dmg and _t > _tb(T_DMG):
		a *= lerpf(1.0, 0.3, clampf((_t - _tb(T_DMG)) / 0.25, 0.0, 1.0))
	if landed and lt < 0.3 and (is_kept or not two) and (val == 20 or val == 1):
		var kk := lt / 0.3
		sc *= 1.0 + 0.2 * sin(kk * PI) * (1.0 - kk * 0.4)
	var rest: Vector2 = (d.rest as Vector2) + off
	var pos: Vector2 = (pose.pos as Vector2) + off
	var hgt := maxf(0.0, rest.y - pos.y)
	var in_flight := u < _tb(T_IMP1)
	# shadow
	var sf := 1.0
	if in_flight:
		var fk := (u - _tb(T_THROW)) / _tb(T_IMP1 - T_THROW)
		sf = clampf((fk - 0.45) / 0.45, 0.0, 1.0)
	var shk := clampf(1.0 - hgt / (R * 3.0), 0.25, 1.0)
	var shc := Vector2(pos.x, rest.y + R * 0.95)
	draw_texture_rect(_glow_tex, Rect2(shc - Vector2(R * 1.15, R * 0.24) * shk, Vector2(R * 2.3, R * 0.48) * shk), false, Color(0, 0, 0, 0.75 * a * sf * shk))

	var effects := landed and (is_kept or not two)
	# nat 20 burst / nat 1 glow (behind die)
	if effects and val == 20:
		var k3 := clampf(lt / 0.7, 0.0, 1.0)
		var burst := _ease_out(k3)
		var glow_a := lerpf(1.0, 0.5, k3) * a
		_glow(rest, R * (2.2 + 1.2 * burst), Color(C_ACCENT, 0.55 * glow_a))
		var rot := _t * 0.5
		for i in 16:
			var aa := rot + TAU * i / 16.0
			var dir := Vector2(cos(aa), sin(aa))
			var r0 := R * 0.9
			var r1 := R * (1.3 + (1.3 if not two else 0.7) * burst) * (1.0 if i % 2 == 0 else 0.7)
			var perp := Vector2(-dir.y, dir.x) * R * 0.09
			draw_polygon(PackedVector2Array([rest + dir * r0 + perp, rest + dir * r1, rest + dir * r0 - perp]),
				PackedColorArray([Color(C_ACCENT, 0.8 * glow_a), Color(1, 0.95, 0.7, 0.0), Color(C_ACCENT, 0.8 * glow_a)]))
	elif effects and val == 1:
		var k4 := clampf(lt / 0.6, 0.0, 1.0)
		_glow(rest, R * 2.0, Color(C_RED, 0.45 * a * (1.0 - k4 * 0.5)))

	var body := C_DIE
	var num_col := C_INK
	if effects:
		if val == 20:
			body = C_ACCENT.darkened(0.05)
			num_col = Color("#2a1d00")
		elif val == 1:
			body = Color("#8c3440")
	if dim:
		body = body.lerp(Color("#3a2a20"), 0.6)

	var ang: float = pose.ang
	var light := Vector2(-0.45, -0.9).normalized().rotated(-ang * 1.9)
	# motion trail
	if u < _tb(T_IMP2):
		for k in range(7, 0, -1):
			var pp := _die_pose(d, u - k * 0.02)
			if not pp.vis:
				continue
			var ga := a * 0.2 * (1.0 - k / 8.0)
			_set_xf((pp.pos as Vector2) + off, float(pp.ang), float(pp.sx) * sc, float(pp.sy) * sc)
			draw_colored_polygon(_hex(R), Color(body.lightened(0.25), ga))
		draw_set_transform_matrix(Transform2D.IDENTITY)
	_set_xf(pos, ang, float(pose.sx) * sc, float(pose.sy) * sc)
	_die_shape(R, body, a, light, bool(d.flip))
	# cracks on a natural 1
	if effects and val == 1:
		var cp := clampf(lt / 0.22, 0.0, 1.0)
		for cr in d.cracks:
			var pts: PackedVector2Array = cr
			var cnt := maxi(2, int(ceil(cp * pts.size())))
			var seg := PackedVector2Array()
			for i in mini(cnt, pts.size()):
				seg.append(pts[i] * R)
			if seg.size() >= 2:
				draw_polyline(seg, Color(C_OUTLINE, 0.95 * a), maxf(3.0, R * 0.07), true)
				draw_polyline(seg, Color(1.0, 0.55, 0.5, 0.85 * a), maxf(1.0, R * 0.022), true)
	var txt := str(d.shown)
	var fs := maxi(30, int(R * (0.56 if two else 0.52)))
	var ncol := Color(num_col, a)
	var ocol := Color(C_OUTLINE, 0.9 * a) if num_col == C_INK else Color(1, 0.95, 0.8, 0.0)
	_text(Vector2(0, R * 0.1), txt, fs, ncol, 10 if num_col == C_INK else 0, ocol)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	# specular glint
	_glow(pos + Vector2(-R * 0.32, -R * 0.42), R * 0.45, Color(1, 1, 1, 0.1 * a))


func _set_xf(pos: Vector2, ang: float, sx: float, sy: float) -> void:
	var m := Transform2D(ang, Vector2.ZERO).scaled(Vector2(sx, sy))
	m.origin = pos
	draw_set_transform_matrix(m)


func _hex(R: float) -> PackedVector2Array:
	var H := PackedVector2Array()
	for k in 6:
		var an := -PI / 2.0 + k * PI / 3.0
		H.append(Vector2(cos(an), sin(an)) * R)
	return H


func _die_shape(R: float, body: Color, a: float, light: Vector2, flip: bool) -> void:
	var H0 := _hex(R)
	var o := 1 if flip else 0
	var H := PackedVector2Array()
	for k in 6:
		H.append(H0[(k + o) % 6])
	var tr := R * 0.6
	var T := PackedVector2Array([H[0].normalized() * tr, H[2].normalized() * tr, H[4].normalized() * tr])
	var facets := [
		[H[0], H[1], T[0]], [H[5], H[0], T[0]], [T[0], H[1], T[1]],
		[H[1], H[2], T[1]], [H[2], H[3], T[1]], [T[1], H[3], T[2]],
		[H[3], H[4], T[2]], [H[4], H[5], T[2]], [T[2], H[5], T[0]],
	]
	for f in facets:
		var cen: Vector2 = (f[0] + f[1] + f[2]) / 3.0
		var l := cen.normalized().dot(light)
		var col := body.lightened(0.3 * l) if l > 0.0 else body.darkened(-0.4 * l)
		draw_colored_polygon(PackedVector2Array(f), Color(col, a))
	draw_colored_polygon(T, Color(body.lightened(0.14 + 0.08 * light.dot(Vector2(0, -1))), a))
	var edge := Color(C_INK, 0.38 * a)
	for f in facets:
		draw_line(f[0], f[2], edge, 2.0, true)
		draw_line(f[1], f[2], edge, 2.0, true)
	var outline := H0.duplicate()
	outline.append(H0[0])
	draw_polyline(outline, Color(C_INK, 0.85 * a), 4.0, true)


func _draw_stamp(s: Dictionary, pos: Vector2, alpha: float, inner_w: float) -> void:
	var r: Dictionary = s.roll
	var word := str(r.get("outcome", "")).to_upper()
	if word == "":
		return
	var ot := _t - _tb(T_OUT)
	var slam := 0.15
	var sc := 1.0
	var rot: float = s.srot
	var oa := alpha
	if ot < slam:
		var k := ot / slam
		sc = lerpf(2.7, 1.0, k * k)
		rot = lerpf(-0.45, float(s.srot), k * k)
		oa *= k
	else:
		var k2 := clampf((ot - slam) / 0.22, 0.0, 1.0)
		sc = 1.0 - 0.08 * sin(PI * k2)
	var col := _outcome_color(r)
	var ncols: int = s.ncols
	var base := 50 if ncols == 1 else 38
	var maxw := inner_w - 40.0
	var os := _fit(word, base, maxw)
	var font := get_theme_default_font()
	var lines := [word]
	var sp := word.find(" ")
	if os < base - 8 and sp > 0:
		lines = [word.substr(0, sp), word.substr(sp + 1)]
		os = mini(_fit(lines[0], base, maxw), _fit(lines[1], base, maxw))
	var tw := 0.0
	for ln in lines:
		var w := os * 3.0
		if font != null:
			w = font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, os).x
		tw = maxf(tw, w)
	var th := os * (1.25 * lines.size() + 0.2)
	if ot >= slam and ot < slam + 0.35:
		var gk := (ot - slam) / 0.35
		_glow(pos, tw * 0.9, Color(col, 0.35 * (1.0 - gk) * alpha))
	draw_set_transform(pos, rot, Vector2(sc, sc))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col, 0.13 * oa)
	sb.set_corner_radius_all(14)
	sb.border_color = Color(col, 0.95 * oa)
	sb.set_border_width_all(5 if ncols == 1 else 4)
	draw_style_box(sb, Rect2(-tw * 0.5 - 22.0, -th * 0.5, tw + 44.0, th))
	if lines.size() == 2:
		_text(Vector2(0, -os * 0.6), lines[0], os, Color(col, oa), 10, Color(C_OUTLINE, oa))
		_text(Vector2(0, os * 0.6), lines[1], os, Color(col, oa), 10, Color(C_OUTLINE, oa))
	else:
		_text(Vector2.ZERO, word, os, Color(col, oa), 10, Color(C_OUTLINE, oa))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_dmg(s: Dictionary, c: Vector2, rect: Rect2, alpha: float, inner_w: float) -> void:
	var dt := _t - _tb(T_DMG)
	var kind: String = s.kind
	var R: float = s.R
	var heal := kind == "heal"
	var spell := kind == "spell"
	var ncols: int = s.ncols
	if heal:
		var k := clampf(dt / 0.5, 0.0, 1.0)
		_glow(c, R * (1.4 + 1.0 * _ease_out(k)), Color(C_GREEN, 0.5 * alpha * (1.0 - 0.5 * k)))
		for i in 2:
			var rk := (dt - i * 0.18) / 0.8
			if rk > 0.0 and rk < 1.0:
				_ellipse_arc(c + Vector2(0, R * 1.15), Vector2(R * (0.6 + 1.4 * _ease_out(rk)), R * (0.18 + 0.4 * _ease_out(rk))), Color(C_GREEN, (1.0 - rk) * alpha), 5.0)
	elif spell:
		var k := clampf(dt / 0.5, 0.0, 1.0)
		_glow(c, R * (1.5 + 1.3 * _ease_out(k)), Color(C_PURPLE, 0.6 * alpha * (1.0 - 0.5 * k)))
		for i in 3:
			var rk := (dt - i * 0.1) / 0.65
			if rk > 0.0 and rk < 1.0:
				draw_arc(c, R * (0.4 + 2.0 * _ease_out(rk)), 0.0, TAU, 72, Color(C_PURPLE.lerp(Color(1, 1, 1), 0.3 * i), (1.0 - rk) * alpha), 12.0 * (1.0 - rk) + 2.0, true)
		# orbiting runes
		var ra := clampf(dt / 0.25, 0.0, 1.0) * clampf((1.2 - dt) / 0.4, 0.0, 1.0) * alpha
		if ra > 0.0:
			var rr := R * (1.25 + 0.15 * sin(dt * 6.0))
			for i in 10:
				var an := dt * 2.2 + TAU * i / 10.0
				var p := c + Vector2(cos(an), sin(an)) * rr
				_star(p, R * 0.09, Color(Color("#e6dbff"), ra), an)
			draw_arc(c, rr, 0.0, TAU, 72, Color(C_PURPLE, 0.6 * ra), 2.0, true)
	else:
		var col := C_RED if kind == "enemy" else Color("#fff2c9")
		for i in 3:
			var si := dt - i * 0.08
			if si < 0.0:
				continue
			var sl: Dictionary = s.slashes[i]
			var dir: Vector2 = sl.dir
			var L := rect.size.x * 1.05
			var p := c + _slash_off(s, i)
			_slash(p - dir * L * 0.5, p + dir * L * 0.5, si, col, (13.0 if ncols == 1 else 9.0) * (1.0 - i * 0.15), alpha)
	# the number
	var dmg: int = s.dmg
	var txt := ("+%d" % dmg) if heal else ("−%d" % dmg)
	var ncol := C_GREEN if heal else C_RED
	var fs := _fit(txt, 128 if ncols == 1 else 84, inner_w)
	var k := clampf(dt / 0.26, 0.0, 1.0)
	var sc := 1.0 + 1.1 * (1.0 - _ease_out_back(k))
	var rise := 64.0 * _ease_out(clampf((dt - 0.12) / 0.9, 0.0, 1.0)) * (1.0 if ncols == 1 else 0.7)
	var pos := c + Vector2(0, -rise - R * 0.05)
	var na := clampf(dt / 0.06, 0.0, 1.0) * alpha
	draw_set_transform(pos, 0.0, Vector2(sc, sc))
	if not heal and not spell:
		var pts := PackedVector2Array()
		var n := 14
		var rr := fs * 0.92
		for i in n * 2:
			var an := dt * 0.5 + PI * i / n
			var jit := 1.0 + 0.12 * sin(i * 7.3 + float(s.seed))
			var rad := rr * jit if i % 2 == 0 else rr * 0.6
			pts.append(Vector2(cos(an) * rad * 1.15, sin(an) * rad * 0.85))
		draw_colored_polygon(pts, Color(Color("#5a1620"), 0.85 * na))
		var ol := pts.duplicate()
		ol.append(pts[0])
		draw_polyline(ol, Color(C_RED, 0.9 * na), 3.0, true)
	else:
		_glow(Vector2.ZERO, fs * 1.1, Color(ncol if heal else C_PURPLE, 0.45 * na))
	_text(Vector2.ZERO, txt, fs, Color(ncol.lerp(Color(1, 1, 1), 0.15), na), 16, Color(C_OUTLINE, na))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var dtext := str(s.roll.get("dmg_text", ""))
	if dtext != "" and not s.nodie:
		var ta := clampf((dt - 0.2) / 0.25, 0.0, 1.0) * alpha
		var word := ("лечение " if heal else "урон ") + dtext
		var tfs := 28 if ncols == 1 else 20
		var tp := pos + Vector2(0, fs * 0.98)
		_text(tp, word, tfs, Color(C_INK, ta), 8, Color(C_OUTLINE, ta))


func _slash(a: Vector2, b: Vector2, si: float, col: Color, w: float, alpha: float) -> void:
	var head := _ease_out(clampf(si / 0.11, 0.0, 1.0))
	var tail := clampf((si - 0.06) / 0.2, 0.0, 1.0)
	tail = tail * tail
	# lingering cut
	if si > 0.08 and si < 0.4:
		var la := (1.0 - (si - 0.08) / 0.32) * alpha
		draw_line(a.lerp(b, 0.08), a.lerp(b, minf(head, 0.92)), Color(col, 0.45 * la), 2.0, true)
	if tail >= head - 0.01:
		return
	var h := a.lerp(b, head)
	var tl := a.lerp(b, tail)
	if h.distance_to(tl) < 3.0:
		return
	var mid := tl.lerp(h, 0.62)
	var glow_col := C_ACCENT if col != C_RED else C_RED
	var perp := (h - tl).normalized().orthogonal()
	draw_colored_polygon(PackedVector2Array([tl, mid + perp * w * 1.9, h, mid - perp * w * 1.9]), Color(glow_col, 0.45 * alpha))
	draw_colored_polygon(PackedVector2Array([tl, mid + perp * w, h, mid - perp * w]), Color(col.lerp(Color(1, 1, 1), 0.5), 0.95 * alpha))
	draw_colored_polygon(PackedVector2Array([tl.lerp(h, 0.2), mid + perp * w * 0.35, h, mid - perp * w * 0.35]), Color(1, 1, 1, alpha))


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


func _make_glow_tex() -> Texture2D:
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
	return t


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


func _formula(s: Dictionary) -> Array:
	var r: Dictionary = s.roll
	if s.nodie:
		var dt := str(r.get("dmg_text", ""))
		var dm := int(r.get("dmg", -1))
		if dt != "" and dm >= 0:
			return ["%s = %d" % [dt, dm], ""]
		return [dt, ""]
	var nat: int = s.nat
	var m := int(r.get("mod", 0))
	var total := int(r.get("total", nat + m))
	var dc := int(r.get("dc", 0))
	var t := "к20 = %d" % nat
	if m > 0:
		t += " + %d" % m
	elif m < 0:
		t += " - %d" % -m
	if m != 0 or total != nat:
		t += " = %d" % total
	return [t, ("против %d" % dc) if dc > 0 else ""]


func _outcome_color(r: Dictionary) -> Color:
	var o := str(r.get("outcome", "")).to_lower()
	var enemy := str(r.get("kind", "")).to_lower() == "enemy"   # an enemy hitting us is bad news
	if o.contains("провал") or o.contains("промах") or o.contains("неудач"):
		return C_GREEN if enemy else C_RED
	if o.contains("успех") or o.contains("попад") or o.contains("удач"):
		return C_RED if enemy else C_GREEN
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


func _play_snd(name: String, gain := 1.0, delay := 0.0) -> void:
	if not _snd.has(name) or not _ensure_playback():
		return
	_voices.append({"b": _snd[name], "p": -int(delay * MIX_RATE), "g": gain})


# One synthesized layer: wave 0 sine, 1 triangle, 2 saw; nz = noise mix; lp0/lp1 = one-pole low-pass
# coefficient sweep; att = attack fraction of dur.
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
		var tone := 0.0
		if wave == 0:
			tone = sin(ph * TAU)
		elif wave == 1:
			tone = 4.0 * absf(ph - 0.5) - 1.0
		else:
			tone = 2.0 * ph - 1.0
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
	_snd["whoosh"] = _synth(0.42, 0.0, 0.0, 0, 1.0, 0.02, 0.25, 0.62, 0.55)
	var clack := _synth(0.05, 2100.0, 1500.0, 1, 0.45, 0.7, 0.7, 0.03, 0.45)
	_snd["clack"] = _mix_into(clack, _synth(0.035, 3300.0, 2900.0, 0, 0.0, 1.0, 1.0, 0.02, 0.18), 0.0)
	_snd["thud"] = _synth(0.24, 130.0, 48.0, 0, 0.12, 0.35, 0.2, 0.03, 0.8)
	_snd["stamp"] = _mix_into(_synth(0.22, 95.0, 40.0, 0, 0.25, 0.3, 0.15, 0.02, 0.75), _synth(0.06, 0.0, 0.0, 0, 1.0, 0.5, 0.2, 0.05, 0.3), 0.0)
	var chime := PackedFloat32Array()
	var fs := [1046.5, 1318.5, 1568.0, 2093.0]
	for i in fs.size():
		chime = _mix_into(chime, _synth(0.9, fs[i], fs[i], 0, 0.0, 1.0, 1.0, 0.01, 0.12), i * 0.06)
	chime = _mix_into(chime, _synth(0.5, 0.0, 0.0, 0, 1.0, 0.9, 0.6, 0.05, 0.05), 0.0)
	_snd["chime"] = chime
	var buzz := _synth(0.6, 82.0, 56.0, 2, 0.05, 0.12, 0.08, 0.04, 0.35)
	_snd["buzz"] = _mix_into(buzz, _synth(0.6, 87.0, 60.0, 2, 0.0, 0.12, 0.08, 0.04, 0.28), 0.0)
	_snd["slash"] = _mix_into(_synth(0.2, 0.0, 0.0, 0, 1.0, 0.25, 0.9, 0.3, 0.5), _synth(0.16, 1500.0, 350.0, 0, 0.0, 1.0, 1.0, 0.2, 0.1), 0.0)
	var magic := PackedFloat32Array()
	var mf := [523.25, 659.25, 783.99, 1046.5, 1318.5]
	for i in mf.size():
		magic = _mix_into(magic, _synth(0.5, mf[i], mf[i] * 1.01, 1, 0.0, 0.6, 0.6, 0.02, 0.1), i * 0.05)
	magic = _mix_into(magic, _synth(0.7, 0.0, 0.0, 0, 1.0, 0.05, 0.5, 0.4, 0.12), 0.0)
	_snd["magic"] = magic
	var healb := PackedFloat32Array()
	var hf := [659.25, 830.6, 987.8, 1318.5]
	for i in hf.size():
		healb = _mix_into(healb, _synth(0.7, hf[i], hf[i], 0, 0.0, 1.0, 1.0, 0.05, 0.11), i * 0.08)
	_snd["heal"] = healb


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
		var i0 := maxi(0, -p)
		var i1 := mini(n, bl - p)
		for i in range(i0, i1):
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
