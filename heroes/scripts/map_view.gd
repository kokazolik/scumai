extends Control
## Карта странствий: рисованная «пергаментная» карта посещённых мест.
## Всё рисуется процедурно в _draw(), без картинок.
##
## Формат данных (только JSON-совместимые типы, уходит по сети):
##   map = {"nodes": [{"name": String, "type": String, "x": float, "y": float}],
##          "edges": [[int, int], ...], "cur": int}
## Типы: village, city, tavern, forest, road, cave, dungeon, castle, ruins, swamp,
##       mountain, lake, camp, temple, tower, field, sea, port (иное — общий значок).
##
## Использование:
##   const MapView := preload("res://scripts/map_view.gd")
##   map = MapView.add_place(map, "Тёмный лес", "forest")
##   map_view.set_map(map, ["Ария", "Борн"])

const TITLE := "Карта странствий"
const HINT := "Карта появится,\nкогда вы отправитесь в путь"

const STEP_MIN := 130.0
const STEP_MAX := 170.0
const MIN_GAP := 110.0

const ZOOM_MIN := 0.5
const ICON_SCALE := 1.4
const DEFAULT_ZOOM := 0.85
const ZOOM_MAX := 2.2

# Палитра
const PAPER := Color(0.93, 0.86, 0.71)
const PAPER_DARK := Color(0.78, 0.66, 0.47)
const PAPER_LIGHT := Color(0.98, 0.94, 0.82)
const INK := Color(0.33, 0.22, 0.12)
const SEPIA := Color(0.45, 0.30, 0.16)
const RED := Color(0.72, 0.12, 0.10)
const GREEN := Color(0.30, 0.45, 0.22)
const GREEN_D := Color(0.20, 0.34, 0.17)
const TRUNK := Color(0.42, 0.27, 0.14)
const STONE := Color(0.66, 0.63, 0.58)
const STONE_D := Color(0.45, 0.43, 0.40)
const ROOF := Color(0.66, 0.28, 0.18)
const WOOD := Color(0.62, 0.43, 0.24)
const WALL := Color(0.90, 0.82, 0.64)
const WATER := Color(0.42, 0.62, 0.74)
const WATER_D := Color(0.27, 0.45, 0.62)
const DARK := Color(0.16, 0.12, 0.09)
const GOLD := Color(0.86, 0.68, 0.30)
const MARBLE := Color(0.92, 0.90, 0.84)
const HERO_COLORS := [Color(0.20, 0.38, 0.62), Color(0.62, 0.22, 0.42), Color(0.24, 0.52, 0.34),
	Color(0.70, 0.44, 0.12), Color(0.42, 0.30, 0.62)]

var _map: Dictionary = {"nodes": [], "edges": [], "cur": -1}
var _heroes: Array = []
var _cam: Vector2 = Vector2.ZERO
var _zoom: float = DEFAULT_ZOOM
var _time: float = 0.0
var _tween: Tween

# ввод
var _touches: Dictionary = {}          # index -> Vector2
var _touch_seen := false
var _mouse_down := false
var _press_pos := Vector2.ZERO
var _moved := 0.0
var _last_tap_ms := -100000
var _last_tap_pos := Vector2.ZERO
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = MOUSE_FILTER_STOP
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(200, 200)
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_time += delta
	if not _nodes().is_empty():
		queue_redraw()


# ───────────────────────────── данные ─────────────────────────────

## Добавляет место (или переходит в уже известное) и возвращает обновлённую карту.
static func add_place(map: Dictionary, place_name: String, place_type: String) -> Dictionary:
	var m := _sanitize(map)
	var nodes: Array = m["nodes"]
	var edges: Array = m["edges"]
	var prev: int = m["cur"]
	var title := place_name.strip_edges()
	if title.is_empty():
		return m
	var key := title.to_lower()
	var ptype := place_type.strip_edges().to_lower()

	for i in nodes.size():
		if str(nodes[i]["name"]).strip_edges().to_lower() == key:
			if prev >= 0 and prev != i and not _has_edge(edges, prev, i):
				edges.append([prev, i])
			m["cur"] = i
			return m

	var pos := Vector2.ZERO
	if not nodes.is_empty():
		if prev < 0:
			prev = nodes.size() - 1
		pos = _find_spot(nodes, edges, prev, key)
	nodes.append({"name": title, "type": ptype, "x": snappedf(pos.x, 0.1), "y": snappedf(pos.y, 0.1)})
	var idx := nodes.size() - 1
	if prev >= 0 and prev != idx:
		edges.append([prev, idx])
	m["cur"] = idx
	return m


static func _sanitize(map) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	var cur := -1
	if map is Dictionary:
		var raw_nodes = map.get("nodes", [])
		if raw_nodes is Array:
			for n in raw_nodes:
				if n is Dictionary:
					nodes.append({"name": str(n.get("name", "?")), "type": str(n.get("type", "")),
						"x": _num(n.get("x", 0.0)), "y": _num(n.get("y", 0.0))})
		var raw_edges = map.get("edges", [])
		if raw_edges is Array:
			for e in raw_edges:
				if e is Array and e.size() >= 2:
					var a := int(_num(e[0]))
					var b := int(_num(e[1]))
					if a >= 0 and b >= 0 and a < nodes.size() and b < nodes.size() and a != b \
							and not _has_edge(edges, a, b):
						edges.append([a, b])
		cur = int(_num(map.get("cur", -1)))
	if cur < 0 or cur >= nodes.size():
		cur = nodes.size() - 1
	return {"nodes": nodes, "edges": edges, "cur": cur}


static func _num(v) -> float:
	if v is float or v is int:
		return float(v)
	if v is String and v.is_valid_float():
		return v.to_float()
	return 0.0


static func _has_edge(edges: Array, a: int, b: int) -> bool:
	for e in edges:
		var x := int(e[0])
		var y := int(e[1])
		if (x == a and y == b) or (x == b and y == a):
			return true
	return false


static func _find_spot(nodes: Array, edges: Array, prev: int, key: String) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key + "|" + str(nodes.size()))
	var origin := Vector2(nodes[prev]["x"], nodes[prev]["y"])
	var centroid := Vector2.ZERO
	for n in nodes:
		centroid += Vector2(n["x"], n["y"])
	centroid /= float(nodes.size())
	var out_dir := origin - centroid
	if out_dir.length() < 1.0:
		out_dir = Vector2.from_angle(rng.randf() * TAU)
	out_dir = out_dir.normalized()

	var best := origin + out_dir * STEP_MAX
	var best_score := -INF
	for attempt in 96:
		var widen := float(attempt / 32) * 40.0
		var r := rng.randf_range(STEP_MIN, STEP_MAX) + widen
		var dir := Vector2.from_angle(rng.randf() * TAU)
		var p := origin + dir * r
		var md := INF
		for n in nodes:
			md = minf(md, p.distance_to(Vector2(n["x"], n["y"])))
		var score := minf(md, MIN_GAP) * 4.0 + clampf(dir.dot(out_dir), -1.0, 0.0) * 40.0 + rng.randf() * 14.0 - widen
		if md >= MIN_GAP:
			score += 1000.0
		for e in edges:
			var a := int(e[0])
			var b := int(e[1])
			if a == prev or b == prev:
				continue
			var hit = Geometry2D.segment_intersects_segment(origin, p,
				Vector2(nodes[a]["x"], nodes[a]["y"]), Vector2(nodes[b]["x"], nodes[b]["y"]))
			if hit != null:
				score -= 300.0
		if score > best_score:
			best_score = score
			best = p
		if attempt >= 31 and best_score > 1100.0:
			break
	return best


## Показывает карту; heroes_here — имена героев, стоящих в текущем месте.
func set_map(map: Dictionary, heroes_here: Array) -> void:
	var was_empty := _nodes().is_empty()
	_map = _sanitize(map)
	_heroes = []
	for h in heroes_here:
		var s := str(h).strip_edges()
		if not s.is_empty():
			_heroes.append(s)
	var target := _view_target(DEFAULT_ZOOM if was_empty else _zoom)
	if was_empty or not is_inside_tree():
		_cam = target
	else:
		_recenter(target, _zoom)
	queue_redraw()


func _nodes() -> Array:
	return _map.get("nodes", [])


func _cur() -> int:
	return int(_map.get("cur", -1))


func _cur_pos() -> Vector2:
	var nodes := _nodes()
	var c := _cur()
	if c >= 0 and c < nodes.size():
		return Vector2(nodes[c]["x"], nodes[c]["y"])
	return Vector2.ZERO


## Точка обзора: текущее место, слегка смещённое к остальной карте (чтобы видно было больше),
## но так, чтобы текущее место оставалось ближе к центру экрана.
func _view_target(zoom_to: float) -> Vector2:
	var nodes := _nodes()
	var cp := _cur_pos()
	if nodes.size() < 2:
		return cp
	var r := Rect2(Vector2(nodes[0]["x"], nodes[0]["y"]), Vector2.ZERO)
	for n in nodes:
		r = r.expand(Vector2(n["x"], n["y"]))
	var view := (size if size.x > 1.0 else Vector2(680, 900)) / maxf(zoom_to, 0.01)
	var lim := view * 0.18
	return cp + (r.get_center() - cp).clamp(-lim, lim)


func _recenter(target: Vector2, zoom_to: float) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	var from_cam := _cam
	var from_zoom := _zoom
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(func(t: float) -> void:
		_cam = from_cam.lerp(target, t)
		_zoom = lerpf(from_zoom, zoom_to, t)
		queue_redraw(), 0.0, 1.0, 0.5)


func _stop_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()


# ───────────────────────────── ввод ─────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch_seen = true
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() == 1:
				_begin_press(event.position)
			elif _touches.size() == 2:
				_start_pinch()
		else:
			_touches.erase(event.index)
			if _touches.is_empty():
				_end_press(event.position)
			else:
				_moved = 999.0  # мультитач — не тап
				_pinch_dist = 0.0
		accept_event()
	elif event is InputEventScreenDrag:
		_touch_seen = true
		if _touches.size() >= 2 and _touches.has(event.index):
			_touches[event.index] = event.position
			_update_pinch()
		else:
			_touches[event.index] = event.position
			_pan(event.relative)
		accept_event()
	elif event is InputEventMouseButton:
		if _touch_seen and event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_mouse_down = event.pressed
			if event.pressed:
				_begin_press(event.position)
			else:
				_end_press(event.position)
			accept_event()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_zoom_at(event.position, 1.1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.1)
			accept_event()
	elif event is InputEventMouseMotion:
		if _touch_seen and event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		if _mouse_down:
			_pan(event.relative)
			accept_event()


func _begin_press(pos: Vector2) -> void:
	_stop_tween()
	_press_pos = pos
	_moved = 0.0


func _end_press(pos: Vector2) -> void:
	if _moved > 14.0:
		return
	var now := Time.get_ticks_msec()
	if now - _last_tap_ms < 380 and pos.distance_to(_last_tap_pos) < 60.0:
		_last_tap_ms = -100000
		_recenter(_view_target(DEFAULT_ZOOM), DEFAULT_ZOOM)
	else:
		_last_tap_ms = now
		_last_tap_pos = pos


func _pan(rel: Vector2) -> void:
	_moved += rel.length()
	_cam -= rel / _zoom
	_clamp_cam()
	queue_redraw()


func _two_touches() -> Array:
	var keys := _touches.keys()
	return [_touches[keys[0]], _touches[keys[1]]]


func _start_pinch() -> void:
	var t := _two_touches()
	_pinch_dist = maxf(1.0, (t[0] as Vector2).distance_to(t[1]))
	_pinch_mid = ((t[0] as Vector2) + (t[1] as Vector2)) * 0.5
	_moved = 999.0


func _update_pinch() -> void:
	var t := _two_touches()
	var d := maxf(1.0, (t[0] as Vector2).distance_to(t[1]))
	var mid: Vector2 = ((t[0] as Vector2) + (t[1] as Vector2)) * 0.5
	if _pinch_dist <= 0.0:
		_pinch_dist = d
		_pinch_mid = mid
		return
	_pan(mid - _pinch_mid)
	_zoom_at(mid, d / _pinch_dist)
	_pinch_dist = d
	_pinch_mid = mid


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_stop_tween()
	var world := _to_world(screen_pos)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_cam = world - (screen_pos - size * 0.5) / _zoom
	_clamp_cam()
	queue_redraw()


func _clamp_cam() -> void:
	var nodes := _nodes()
	if nodes.is_empty():
		_cam = Vector2.ZERO
		return
	var r := Rect2(Vector2(nodes[0]["x"], nodes[0]["y"]), Vector2.ZERO)
	for n in nodes:
		r = r.expand(Vector2(n["x"], n["y"]))
	r = r.grow(160.0)
	_cam = _cam.clamp(r.position, r.end)


func _to_screen(w: Vector2) -> Vector2:
	return size * 0.5 + (w - _cam) * _zoom


func _to_world(s: Vector2) -> Vector2:
	return _cam + (s - size * 0.5) / _zoom


# ───────────────────────────── рисование ─────────────────────────────

func _draw() -> void:
	_draw_parchment()
	var nodes := _nodes()
	var font := get_theme_default_font()
	if nodes.is_empty():
		_draw_hint(font)
	else:
		_draw_roads()
		_draw_places(font)
		_draw_heroes(font)
	_draw_vignette()
	_draw_compass(Vector2(size.x - 62.0, size.y - 66.0), 44.0, font)
	_draw_title(font)
	_draw_frame()


func _draw_parchment() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7741
	var area := maxf(size.x * size.y, 1.0)
	var count := int(clampf(area / 9000.0, 30.0, 120.0))
	for i in count:
		var p := Vector2(rng.randf() * size.x, rng.randf() * size.y)
		var r := rng.randf_range(18.0, 110.0)
		var col := PAPER_DARK if rng.randf() < 0.55 else PAPER_LIGHT
		col.a = rng.randf_range(0.012, 0.025)
		# мягкое неровное пятно: концентрические круги + спутники
		var off := Vector2.from_angle(rng.randf() * TAU) * r * 0.45
		for k in 4:
			var f := 1.0 - k * 0.22
			draw_circle(p, r * f, col)
			draw_circle(p + off * f, r * 0.6 * f, col)
	# крапинки
	for i in count * 3:
		var p := Vector2(rng.randf() * size.x, rng.randf() * size.y)
		var col := SEPIA
		col.a = rng.randf_range(0.06, 0.16)
		draw_circle(p, rng.randf_range(0.6, 1.8), col)
	# пара тонких «волокон»
	for i in count / 4:
		var a := Vector2(rng.randf() * size.x, rng.randf() * size.y)
		var b := a + Vector2.from_angle(rng.randf_range(-0.4, 0.4)) * rng.randf_range(30.0, 90.0)
		var col := PAPER_DARK
		col.a = 0.12
		draw_line(a, b, col, 1.0, true)


func _draw_vignette() -> void:
	var w := minf(90.0, minf(size.x, size.y) * 0.18)
	var edge := Color(0.36, 0.22, 0.08, 0.42)
	var clear := Color(0.36, 0.22, 0.08, 0.0)
	var s := size
	var bands := [
		[Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x - w, w), Vector2(w, w)],
		[Vector2(s.x, 0), Vector2(s.x, s.y), Vector2(s.x - w, s.y - w), Vector2(s.x - w, w)],
		[Vector2(s.x, s.y), Vector2(0, s.y), Vector2(w, s.y - w), Vector2(s.x - w, s.y - w)],
		[Vector2(0, s.y), Vector2(0, 0), Vector2(w, w), Vector2(w, s.y - w)],
	]
	for b in bands:
		draw_polygon(PackedVector2Array(b), PackedColorArray([edge, edge, clear, clear]))
	# тонкая тёмная кайма
	var w2 := w * 0.35
	var edge2 := Color(0.30, 0.17, 0.06, 0.35)
	var clear2 := Color(0.30, 0.17, 0.06, 0.0)
	var bands2 := [
		[Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x - w2, w2), Vector2(w2, w2)],
		[Vector2(s.x, 0), Vector2(s.x, s.y), Vector2(s.x - w2, s.y - w2), Vector2(s.x - w2, w2)],
		[Vector2(s.x, s.y), Vector2(0, s.y), Vector2(w2, s.y - w2), Vector2(s.x - w2, s.y - w2)],
		[Vector2(0, s.y), Vector2(0, 0), Vector2(w2, w2), Vector2(w2, s.y - w2)],
	]
	for b in bands2:
		draw_polygon(PackedVector2Array(b), PackedColorArray([edge2, edge2, clear2, clear2]))


func _draw_frame() -> void:
	var col := INK
	col.a = 0.55
	draw_rect(Rect2(Vector2(7, 7), size - Vector2(14, 14)), col, false, 2.0)
	col.a = 0.35
	draw_rect(Rect2(Vector2(12, 12), size - Vector2(24, 24)), col, false, 1.0)


func _draw_title(font: Font) -> void:
	var fs := 30
	var y := 50.0
	var tw := font.get_string_size(TITLE, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var band := PAPER_LIGHT
	band.a = 0.78
	var bw := tw + 120.0
	var rect := Rect2(Vector2((size.x - bw) * 0.5, y - 32.0), Vector2(bw, 46.0))
	draw_rect(rect, band)
	var ink := INK
	ink.a = 0.6
	draw_line(rect.position + Vector2(10, 4), Vector2(rect.end.x - 10, rect.position.y + 4), ink, 1.0, true)
	draw_line(Vector2(rect.position.x + 10, rect.end.y - 4), rect.end - Vector2(10, 4), ink, 1.0, true)
	var x0 := (size.x - tw) * 0.5
	draw_string_outline(font, Vector2(x0, y), TITLE, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, PAPER_LIGHT)
	draw_string(font, Vector2(x0, y), TITLE, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, INK)
	# завитушки
	for side in [-1.0, 1.0]:
		var cx: float = size.x * 0.5 + side * (tw * 0.5 + 30.0)
		var cy := y - 10.0
		draw_line(Vector2(cx - 18, cy), Vector2(cx + 18, cy), ink, 1.5, true)
		_diamond(Vector2(cx + side * 22.0, cy), 4.0, RED)
		_diamond(Vector2(cx - side * 22.0, cy), 2.5, INK)


func _diamond(c: Vector2, r: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)]), col)


func _draw_hint(font: Font) -> void:
	var fs := 24
	var lines := HINT.split("\n")
	var lh := font.get_height(fs) * 1.15
	var y0 := size.y * 0.5 - lh * (lines.size() - 1) * 0.5
	var col := SEPIA
	for i in lines.size():
		var pos := Vector2(20.0, y0 + i * lh)
		draw_string(font, pos, lines[i], HORIZONTAL_ALIGNMENT_CENTER, size.x - 40.0, fs, col)
	# маленький пунктир-«путь» под надписью
	var y := y0 + lh * lines.size() - 6.0
	var a := Vector2(size.x * 0.5 - 90.0, y)
	var b := Vector2(size.x * 0.5 + 70.0, y)
	_dashed_curve(a, b, Vector2(size.x * 0.5, y + 26.0), SEPIA, 2.5, 9.0, 7.0, 0.0)
	_cross(b + Vector2(14, 0), 7.0, RED, 3.0)


func _cross(c: Vector2, r: float, col: Color, w: float) -> void:
	draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, w, true)
	draw_line(c + Vector2(-r, r), c + Vector2(r, -r), col, w, true)


func _draw_roads() -> void:
	var nodes := _nodes()
	var col := SEPIA
	col.a = 0.85
	var edges: Array = _map.get("edges", [])
	for e in edges:
		var ia := int(e[0])
		var ib := int(e[1])
		if ia < 0 or ib < 0 or ia >= nodes.size() or ib >= nodes.size():
			continue
		var a := _to_screen(Vector2(nodes[ia]["x"], nodes[ia]["y"]))
		var b := _to_screen(Vector2(nodes[ib]["x"], nodes[ib]["y"]))
		var d := b - a
		var dist := d.length()
		if dist < 1.0:
			continue
		var bend := float(((mini(ia, ib) * 7 + maxi(ia, ib) * 13) % 5) - 2) * 0.09
		if absf(bend) < 0.01:
			bend = 0.06
		var ctrl := (a + b) * 0.5 + d.orthogonal().normalized() * dist * bend
		_dashed_curve(a, b, ctrl, col, 3.0 * clampf(_zoom, 0.7, 1.4), 10.0 * _zoom, 7.0 * _zoom, 40.0 * _zoom)


func _dashed_curve(a: Vector2, b: Vector2, ctrl: Vector2, col: Color, width: float, dash: float, gap: float, trim: float) -> void:
	var steps := 40
	var pts := PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / steps
		pts.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
	var drawing := true
	var left := dash
	var cur_seg := PackedVector2Array()
	for i in steps:
		var p0 := pts[i]
		var p1 := pts[i + 1]
		var seg := p0.distance_to(p1)
		var pos := 0.0
		while pos < seg - 0.001:
			var take := minf(left, seg - pos)
			var q0 := p0.lerp(p1, pos / seg)
			var q1 := p0.lerp(p1, (pos + take) / seg)
			if drawing and q0.distance_to(a) > trim and q1.distance_to(b) > trim \
					and q1.distance_to(a) > trim and q0.distance_to(b) > trim:
				draw_line(q0, q1, col, width, true)
			pos += take
			left -= take
			if left <= 0.001:
				drawing = not drawing
				left = dash if drawing else gap


func _draw_places(font: Font) -> void:
	var nodes := _nodes()
	var cur := _cur()
	var z := _zoom
	var margin := 120.0 * z
	var vis := Rect2(Vector2(-margin, -margin), size + Vector2(margin, margin) * 2.0)
	for i in nodes.size():
		var n: Dictionary = nodes[i]
		var p := _to_screen(Vector2(n["x"], n["y"]))
		if not vis.has_point(p):
			continue
		var is_cur := i == cur
		var pulse := 0.5 + 0.5 * sin(_time * 3.2)
		if is_cur:
			var glow := RED
			glow.a = 0.10 + 0.08 * pulse
			draw_circle(p, (44.0 + 4.0 * pulse) * z, glow)
		# тень под значком
		var iz := z * ICON_SCALE
		draw_set_transform(p, 0.0, Vector2(iz, iz))
		var sh := Color(0.30, 0.18, 0.08, 0.16)
		draw_colored_polygon(_ell(Vector2(0, 16), 22, 5.5), sh)
		_draw_icon(str(n["type"]).to_lower(), i)
		draw_set_transform_matrix(Transform2D.IDENTITY)
		if is_cur:
			var rc := RED
			rc.a = 0.9
			draw_arc(p, (40.0 + 3.0 * pulse) * z, 0.0, TAU, 48, rc, 3.0 * clampf(z, 0.7, 1.4), true)
			rc.a = 0.35 * (1.0 - pulse)
			draw_arc(p, (46.0 + 10.0 * pulse) * z, 0.0, TAU, 48, rc, 2.0, true)
		_draw_label(font, str(n["name"]), p + Vector2(0, 30.0 * z), is_cur)


func _draw_label(font: Font, text: String, top_center: Vector2, is_cur: bool) -> void:
	var fs := int(clampf(round(20.0 * _zoom), 11.0, 40.0))
	var max_w := 170.0 * _zoom
	var lines := _wrap(font, text, fs, max_w, 2)
	var lh := font.get_height(fs) * 0.95
	var y := top_center.y + font.get_ascent(fs)
	var col := RED.darkened(0.25) if is_cur else INK
	var outline := PAPER_LIGHT
	outline.a = 0.85
	for line in lines:
		var w := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := Vector2(top_center.x - w * 0.5, y)
		draw_string_outline(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(3, int(5 * _zoom)), outline)
		draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		y += lh


func _wrap(font: Font, text: String, fs: int, max_w: float, max_lines: int) -> Array:
	var words := text.strip_edges().split(" ", false)
	var lines: Array = []
	var line := ""
	var i := 0
	while i < words.size():
		var w: String = words[i]
		var cand := w if line.is_empty() else line + " " + w
		if font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w or line.is_empty():
			line = cand
			i += 1
		else:
			lines.append(line)
			line = ""
			if lines.size() == max_lines - 1:
				# всё оставшееся — в последнюю строку
				line = " ".join(words.slice(i))
				i = words.size()
	if not line.is_empty():
		lines.append(line)
	if lines.size() > max_lines:
		lines = lines.slice(0, max_lines)
	for k in lines.size():
		lines[k] = _truncate(font, lines[k], fs, max_w)
	return lines


func _truncate(font: Font, s: String, fs: int, max_w: float) -> String:
	if font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		return s
	var t := s
	while t.length() > 1 and font.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		t = t.substr(0, t.length() - 1)
	return t.strip_edges() + "…"


func _draw_heroes(font: Font) -> void:
	if _heroes.is_empty():
		return
	var p := _to_screen(_cur_pos())
	var fs := int(clampf(round(16.0 * _zoom), 14.0, 26.0))
	var h := font.get_height(fs) + 6.0
	var n := mini(_heroes.size(), 5)
	# сторона, где меньше соседей
	var side := 1.0
	var cp := _cur_pos()
	var lean := 0.0
	for nd in _nodes():
		var d: Vector2 = Vector2(nd["x"], nd["y"]) - cp
		if d.length() > 1.0 and d.length() < 260.0 and absf(d.y) < 120.0:
			lean += signf(d.x)
	if lean > 0.0:
		side = -1.0
	var y := p.y - (n * (h + 4.0)) * 0.5
	for i in n:
		var name_s := str(_heroes[i])
		if name_s.length() > 10:
			name_s = name_s.substr(0, 9) + "…"
		var tw := font.get_string_size(name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var col: Color = HERO_COLORS[i % HERO_COLORS.size()]
		var r := h * 0.5
		var w := tw + h + 8.0
		var x := p.x + 48.0 * _zoom if side > 0.0 else p.x - 48.0 * _zoom - w
		# пилюля: прямоугольник + полукруги
		var pill := PackedVector2Array()
		for k in 13:
			pill.append(Vector2(x + r, y + r) + Vector2.from_angle(PI * 0.5 + PI * k / 12.0) * r)
		for k in 13:
			pill.append(Vector2(x + w - r, y + r) + Vector2.from_angle(-PI * 0.5 + PI * k / 12.0) * r)
		var fill := PAPER_LIGHT
		draw_colored_polygon(pill, fill)
		var closed := pill.duplicate()
		closed.append(pill[0])
		draw_polyline(closed, INK, 1.5, true)
		# кружок-фишка
		draw_circle(Vector2(x + r, y + r), r - 3.0, col)
		draw_arc(Vector2(x + r, y + r), r - 3.0, 0, TAU, 20, INK, 1.2, true)
		var initial := name_s.substr(0, 1).to_upper()
		var ifs := maxi(9, fs - 3)
		var iw := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, ifs).x
		draw_string(font, Vector2(x + r - iw * 0.5, y + r + font.get_ascent(ifs) * 0.36), initial,
			HORIZONTAL_ALIGNMENT_LEFT, -1, ifs, Color.WHITE)
		draw_string(font, Vector2(x + h + 2.0, y + (h - font.get_height(fs)) * 0.5 + font.get_ascent(fs)),
			name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, INK)
		y += h + 4.0


func _draw_compass(c: Vector2, R: float, font: Font) -> void:
	var ink := INK
	ink.a = 0.8
	var faint := PAPER_LIGHT
	faint.a = 0.6
	draw_circle(c, R * 0.78, faint)
	draw_arc(c, R * 0.78, 0, TAU, 48, ink, 1.5, true)
	draw_arc(c, R * 0.70, 0, TAU, 48, ink, 1.0, true)
	for k in 32:
		var a := TAU * k / 32.0
		var l := 0.06 if k % 2 == 0 else 0.03
		draw_line(c + Vector2.from_angle(a) * R * 0.70, c + Vector2.from_angle(a) * R * (0.70 + l), ink, 1.0, true)
	# малые лучи
	for k in 4:
		var a := PI * 0.25 + PI * 0.5 * k
		_compass_ray(c, a, R * 0.55, R * 0.12, SEPIA, PAPER_LIGHT)
	# главные лучи
	for k in 4:
		var a := -PI * 0.5 + PI * 0.5 * k
		var dark := RED if k == 0 else INK
		_compass_ray(c, a, R, R * 0.17, dark, PAPER_LIGHT)
	draw_circle(c, R * 0.07, INK)
	var fs := 16
	var letters := ["С", "В", "Ю", "З"]
	for k in 4:
		var a := -PI * 0.5 + PI * 0.5 * k
		if k != 0:
			continue
		var lp: Vector2 = c + Vector2.from_angle(a) * (R + 10.0)
		var t: String = letters[k]
		var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(lp.x - tw * 0.5, lp.y + 2.0), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, RED.darkened(0.2))


func _compass_ray(c: Vector2, a: float, length: float, half: float, dark: Color, light: Color) -> void:
	var tip := c + Vector2.from_angle(a) * length
	var l := c + Vector2.from_angle(a - PI * 0.5) * half
	var r := c + Vector2.from_angle(a + PI * 0.5) * half
	draw_colored_polygon(PackedVector2Array([c, tip, l]), dark)
	draw_colored_polygon(PackedVector2Array([c, r, tip]), light)
	draw_polyline(PackedVector2Array([l, tip, r, c, l]), INK, 1.0, true)


# ───────────────────────────── значки ─────────────────────────────
# Рисуются в локальных координатах (~ -24..24), масштаб задаёт draw_set_transform.

func _ell(c: Vector2, rx: float, ry: float, n: int = 20, wob: float = 0.0, sd: int = 0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		var k := 1.0
		if wob > 0.0:
			k += wob * sin(a * 3.0 + sd) * 0.6 + wob * sin(a * 5.0 + sd * 1.7) * 0.4
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry) * k)
	return pts


func _shape(pts: PackedVector2Array, fill: Color, w: float = 1.6) -> void:
	draw_colored_polygon(pts, fill)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, INK, w, true)


func _box(x: float, y: float, w: float, h: float, fill: Color, lw: float = 1.4) -> void:
	_shape(PackedVector2Array([Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)]), fill, lw)


func _arch_door(cx: float, bottom: float, hw: float, h: float, fill: Color, outline: bool = true) -> void:
	# прямоугольник с полукруглым верхом
	var pts := PackedVector2Array()
	pts.append(Vector2(cx - hw, bottom))
	var top := bottom - h + hw
	for k in 11:
		var a := PI + PI * k / 10.0
		pts.append(Vector2(cx + cos(a) * hw, top + sin(a) * hw))
	pts.append(Vector2(cx + hw, bottom))
	if outline:
		_shape(pts, fill, 1.2)
	else:
		draw_colored_polygon(pts, fill)


func _waves(c: Vector2, w: float, col: Color, lw: float = 1.4) -> void:
	var pts := PackedVector2Array()
	for k in 9:
		var t := float(k) / 8.0
		pts.append(c + Vector2((t - 0.5) * w, sin(t * TAU * 1.5) * 1.8))
	draw_polyline(pts, col, lw, true)


func _draw_icon(t: String, sd: int) -> void:
	match t:
		"forest", "wood", "woods", "grove":
			_icon_forest()
		"mountain", "mountains", "peak", "hills":
			_icon_mountain()
		"village", "hamlet":
			_icon_village()
		"city", "town":
			_icon_city()
		"tavern", "inn":
			_icon_tavern()
		"road", "crossroads", "path":
			_icon_road()
		"cave":
			_icon_cave()
		"dungeon", "crypt":
			_icon_dungeon()
		"castle", "fortress", "fort":
			_icon_castle()
		"ruins", "ruin":
			_icon_ruins()
		"swamp", "marsh", "bog":
			_icon_swamp()
		"lake", "river", "pond":
			_icon_lake(sd)
		"sea", "ocean", "coast":
			_icon_sea(sd)
		"camp":
			_icon_camp()
		"temple", "shrine", "church", "monastery":
			_icon_temple()
		"tower":
			_icon_tower()
		"field", "fields", "meadow", "farm", "plains":
			_icon_field()
		"port", "harbor", "harbour", "docks":
			_icon_port()
		_:
			_icon_generic()


func _tree(b: Vector2, s: float, col: Color) -> void:
	_box(b.x - 2.2 * s, b.y + 4.0 * s, 4.4 * s, 8.0 * s, TRUNK, 1.2)
	_shape(PackedVector2Array([b + Vector2(0, -10) * s, b + Vector2(11, 6) * s, b + Vector2(-11, 6) * s]), col)
	_shape(PackedVector2Array([b + Vector2(0, -19) * s, b + Vector2(8, -3) * s, b + Vector2(-8, -3) * s]), col.lightened(0.12))


func _icon_forest() -> void:
	_tree(Vector2(1, -2), 1.15, GREEN_D)
	_tree(Vector2(-12, 4), 1.0, GREEN)
	_tree(Vector2(13, 5), 0.92, GREEN.darkened(0.08))


func _icon_mountain() -> void:
	var grey_l := Color(0.68, 0.66, 0.63)
	var grey := Color(0.56, 0.54, 0.52)
	_shape(PackedVector2Array([Vector2(-26, 14), Vector2(-10, -8), Vector2(4, 14)]), grey_l)
	draw_colored_polygon(PackedVector2Array([Vector2(-10, -8), Vector2(-5.6, -1.9), Vector2(-8, -3.2),
		Vector2(-10, -0.8), Vector2(-12.5, -3), Vector2(-14.4, -1.9)]), Color.WHITE)
	_shape(PackedVector2Array([Vector2(-12, 14), Vector2(6, -21), Vector2(27, 14)]), grey)
	draw_colored_polygon(PackedVector2Array([Vector2(7.5, -9), Vector2(27, 14), Vector2(14, 14)]), Color(0.3, 0.28, 0.27, 0.35))
	draw_colored_polygon(PackedVector2Array([Vector2(6, -21), Vector2(12.4, -9.8), Vector2(9.2, -12.2),
		Vector2(6.2, -8.4), Vector2(3, -11.6), Vector2(0.6, -10.5)]), Color.WHITE)
	draw_polyline(PackedVector2Array([Vector2(-12, 14), Vector2(6, -21), Vector2(27, 14)]), INK, 1.6, true)


func _house(cx: float, bottom: float, w: float, h: float, wall: Color, roof: Color) -> void:
	_box(cx - w * 0.5, bottom - h, w, h, wall)
	_shape(PackedVector2Array([Vector2(cx - w * 0.5 - 2.5, bottom - h), Vector2(cx, bottom - h - h * 0.8),
		Vector2(cx + w * 0.5 + 2.5, bottom - h)]), roof)
	draw_rect(Rect2(cx - 2.0, bottom - h * 0.55, 4.0, h * 0.55), DARK)


func _icon_village() -> void:
	_house(0, 2, 14, 10, WALL.darkened(0.05), ROOF.darkened(0.1))
	_house(-11, 14, 15, 11, WALL, ROOF)
	_house(11, 13, 16, 12, WALL, Color(0.55, 0.40, 0.22))


func _icon_city() -> void:
	# дальние здания
	_box(-22, -6, 11, 14, WALL.darkened(0.08))
	_shape(PackedVector2Array([Vector2(-24, -6), Vector2(-16.5, -14), Vector2(-9, -6)]), ROOF.darkened(0.1))
	_box(-10, -18, 9, 26, STONE)
	_shape(PackedVector2Array([Vector2(-11.5, -18), Vector2(-5.5, -30), Vector2(0.5, -18)]), Color(0.36, 0.42, 0.55))
	_box(1, -10, 11, 18, WALL)
	_shape(PackedVector2Array([Vector2(-1, -10), Vector2(6.5, -18), Vector2(14, -10)]), ROOF)
	_box(13, -3, 10, 11, WALL.darkened(0.04))
	_shape(PackedVector2Array([Vector2(11.5, -3), Vector2(18, -10), Vector2(24.5, -3)]), Color(0.55, 0.40, 0.22))
	# окна
	for p in [Vector2(-18, -1), Vector2(-14, -1), Vector2(-7, -10), Vector2(-4, -3), Vector2(4, -4), Vector2(8, -4), Vector2(17, 1)]:
		draw_rect(Rect2(p, Vector2(2, 2.6)), Color(0.95, 0.80, 0.35))
	# стена
	_box(-25, 6, 50, 10, STONE_D.lightened(0.15))
	for k in 7:
		_box(-25 + k * 8.0, 3, 4, 3, STONE_D.lightened(0.15), 1.0)
	_arch_door(0, 16, 3.5, 8, DARK)


func _icon_tavern() -> void:
	_house(-6, 14, 26, 16, WALL, Color(0.55, 0.36, 0.20))
	draw_rect(Rect2(-16, 2, 4, 4), Color(0.95, 0.78, 0.35))
	draw_rect(Rect2(1, 2, 4, 4), Color(0.95, 0.78, 0.35))
	# столб и кронштейн
	_box(12, -14, 3, 28, WOOD, 1.2)
	draw_line(Vector2(13.5, -11), Vector2(27, -11), INK, 2.0, true)
	draw_line(Vector2(16, -11), Vector2(16, -8), INK, 1.0)
	draw_line(Vector2(25, -11), Vector2(25, -8), INK, 1.0)
	# вывеска с кружкой
	_box(14.5, -8, 13, 13, Color(0.80, 0.62, 0.38), 1.3)
	_box(17.5, -5.5, 5.5, 7.5, GOLD, 1.0)
	draw_rect(Rect2(17.5, -6.5, 5.5, 1.8), Color.WHITE)
	draw_arc(Vector2(23.2, -1.8), 2.2, -PI * 0.5, PI * 0.5, 8, INK, 1.2, true)


func _icon_road() -> void:
	draw_line(Vector2(-16, 15), Vector2(16, 15), Color(0.45, 0.55, 0.25), 2.0, true)
	draw_line(Vector2(-10, 15), Vector2(-13, 10), Color(0.35, 0.48, 0.2), 1.5, true)
	draw_line(Vector2(-8, 15), Vector2(-7, 9), Color(0.35, 0.48, 0.2), 1.5, true)
	_box(-1.8, -20, 3.6, 35, WOOD, 1.2)
	_shape(PackedVector2Array([Vector2(-2, -17), Vector2(13, -17), Vector2(18, -12.5), Vector2(13, -8), Vector2(-2, -8)]), Color(0.78, 0.60, 0.36), 1.3)
	_shape(PackedVector2Array([Vector2(2, -5), Vector2(-13, -5), Vector2(-18, -0.5), Vector2(-13, 4), Vector2(2, 4)]), Color(0.72, 0.54, 0.32), 1.3)
	draw_line(Vector2(2, -12.5), Vector2(11, -12.5), INK, 1.0)
	draw_line(Vector2(-11, -0.5), Vector2(-2, -0.5), INK, 1.0)


func _icon_cave() -> void:
	var pts := PackedVector2Array()
	pts.append(Vector2(-26, 14))
	for k in 13:
		var a := PI + PI * k / 12.0
		var wob := 1.0 + 0.08 * sin(k * 2.3)
		pts.append(Vector2(cos(a) * 25.0 * wob, 14 + sin(a) * 28.0 * wob))
	pts.append(Vector2(26, 14))
	_shape(pts, Color(0.58, 0.50, 0.42))
	draw_line(Vector2(-18, -2), Vector2(-12, -6), INK, 1.0, true)
	draw_line(Vector2(14, -6), Vector2(19, 0), INK, 1.0, true)
	draw_line(Vector2(-4, -11), Vector2(3, -12), INK, 1.0, true)
	_arch_door(0, 14, 10, 20, DARK)
	draw_line(Vector2(-14, 14), Vector2(14, 14), INK, 1.6, true)


func _icon_dungeon() -> void:
	_box(-20, -14, 40, 29, STONE_D)
	for row in 4:
		var y := -14.0 + row * 7.25
		draw_line(Vector2(-20, y), Vector2(20, y), Color(0.25, 0.23, 0.22, 0.7), 1.0)
		var off := 0.0 if row % 2 == 0 else 5.0
		for k in 5:
			var x := -20.0 + off + k * 10.0
			draw_line(Vector2(x, y), Vector2(x, y + 7.25), Color(0.25, 0.23, 0.22, 0.7), 1.0)
	_arch_door(0, 15, 10, 24, DARK)
	# ступени вниз
	var stc := Color(0.62, 0.58, 0.52)
	for k in 4:
		var y := 13.0 - k * 4.0
		var hw := 9.0 - k * 1.8
		draw_rect(Rect2(-hw, y - 1.6, hw * 2.0, 1.8), stc)
	# факелы
	for sx in [-15.0, 15.0]:
		draw_line(Vector2(sx, -2), Vector2(sx, 4), WOOD, 2.0)
		draw_colored_polygon(PackedVector2Array([Vector2(sx, -8), Vector2(sx + 2.2, -3), Vector2(sx, -1.5), Vector2(sx - 2.2, -3)]), Color(1.0, 0.6, 0.15))


func _merlons(x0: float, x1: float, y: float, n: int, col: Color) -> void:
	var w := (x1 - x0) / (n * 2 - 1)
	for k in n:
		_box(x0 + k * 2 * w, y - 4.0, w, 4.0, col, 1.0)


func _icon_castle() -> void:
	var st := STONE
	_box(-10, -10, 20, 25, st.lightened(0.05))
	_merlons(-10, 10, -10, 4, st.lightened(0.05))
	# флаг
	draw_line(Vector2(0, -14), Vector2(0, -28), INK, 1.5)
	draw_colored_polygon(PackedVector2Array([Vector2(0, -28), Vector2(11, -24.5), Vector2(0, -21)]), RED)
	_box(-24, -16, 11, 31, st)
	_merlons(-24, -13, -16, 3, st)
	_box(13, -16, 11, 31, st)
	_merlons(13, 24, -16, 3, st)
	draw_rect(Rect2(-20, -8, 3, 5), DARK)
	draw_rect(Rect2(17, -8, 3, 5), DARK)
	_arch_door(0, 15, 5, 13, DARK)
	draw_line(Vector2(-5, 9), Vector2(5, 9), Color(0.5, 0.4, 0.3), 1.0)


func _column_broken(x: float, top: float, sd: int) -> void:
	var j := 2.0 + float(sd % 3)
	_shape(PackedVector2Array([Vector2(x - 4, 12), Vector2(x + 4, 12), Vector2(x + 4, top + j),
		Vector2(x + 1.5, top - 1), Vector2(x - 0.5, top + 3), Vector2(x - 4, top)]), MARBLE.darkened(0.1), 1.3)
	draw_line(Vector2(x - 1.3, 11), Vector2(x - 1.3, top + 4), Color(0.5, 0.45, 0.4, 0.6), 1.0)
	draw_line(Vector2(x + 1.5, 11), Vector2(x + 1.5, top + 5), Color(0.5, 0.45, 0.4, 0.6), 1.0)


func _icon_ruins() -> void:
	_shape(_ell(Vector2(0, 13), 25, 4.5), Color(0.62, 0.58, 0.50), 1.2)
	_box(-24, 8, 10, 4, MARBLE.darkened(0.15), 1.2)  # обломок архитрава
	_column_broken(-13, -4, 1)
	_column_broken(-1, -18, 2)
	_column_broken(11, -8, 0)
	# упавший барабан колонны
	_shape(PackedVector2Array([Vector2(16, 14), Vector2(24, 11), Vector2(25.5, 14.5), Vector2(17.5, 17.5)]), MARBLE.darkened(0.12), 1.2)
	draw_colored_polygon(PackedVector2Array([Vector2(-9, 13), Vector2(-6, 10), Vector2(-3, 13)]), STONE_D)


func _icon_temple() -> void:
	_box(-24, 11, 48, 5, MARBLE.darkened(0.1))
	_box(-21, 7, 42, 4, MARBLE.darkened(0.05))
	for x in [-16.0, -6.0, 4.0, 14.0]:
		_box(x - 0.5, -6, 4, 13, MARBLE, 1.1)
	_box(-21, -10, 42, 4, MARBLE.darkened(0.05))
	_shape(PackedVector2Array([Vector2(-23, -10), Vector2(0, -23), Vector2(23, -10)]), MARBLE.darkened(0.12))
	draw_circle(Vector2(0, -14.5), 2.2, GOLD)


func _icon_tower() -> void:
	_box(-7.5, -14, 15, 30, STONE)
	for y in [-6.0, 2.0, 10.0]:
		draw_line(Vector2(-7.5, y), Vector2(7.5, y), Color(0.35, 0.33, 0.3, 0.6), 1.0)
	_shape(PackedVector2Array([Vector2(-11, -14), Vector2(0, -32), Vector2(11, -14)]), Color(0.36, 0.42, 0.58))
	draw_line(Vector2(0, -32), Vector2(0, -37), INK, 1.2)
	draw_colored_polygon(PackedVector2Array([Vector2(0, -37), Vector2(6, -35.5), Vector2(0, -34)]), RED)
	_arch_door(0, -2, 2.4, 7, Color(0.95, 0.80, 0.35))
	_arch_door(0, 16, 3.5, 9, DARK)


func _icon_swamp() -> void:
	_shape(_ell(Vector2(0, 9), 24, 8, 22, 0.08, 3), Color(0.42, 0.50, 0.36), 1.3)
	_waves(Vector2(-6, 9), 12, Color(0.30, 0.36, 0.25), 1.2)
	_waves(Vector2(10, 12), 9, Color(0.30, 0.36, 0.25), 1.2)
	var reeds := [[-15.0, -3.0, -14.0], [-9.0, 1.0, -20.0], [-3.0, -1.5, -12.0], [6.0, 2.0, -18.0], [13.0, 3.0, -10.0], [18.0, -1.0, -6.0]]
	for r in reeds:
		var base := Vector2(r[0], 10)
		var top := Vector2(r[0] + r[1], r[2])
		draw_line(base, top, Color(0.30, 0.42, 0.18), 1.6, true)
		draw_colored_polygon(_ell(top + Vector2(0, 3.5), 1.8, 3.8, 10), Color(0.45, 0.27, 0.14))
	# листик
	draw_line(Vector2(-3, 10), Vector2(-8, 0), Color(0.36, 0.50, 0.22), 1.2, true)
	draw_line(Vector2(6, 10), Vector2(11, 2), Color(0.36, 0.50, 0.22), 1.2, true)


func _icon_lake(sd: int) -> void:
	_shape(_ell(Vector2(0, 2), 25, 14, 28, 0.08, sd), WATER, 1.5)
	draw_colored_polygon(_ell(Vector2(-3, 0), 15, 7, 20, 0.05, sd + 2), WATER.lightened(0.15))
	_waves(Vector2(-6, -2), 12, Color(1, 1, 1, 0.85), 1.4)
	_waves(Vector2(7, 5), 11, WATER_D, 1.4)
	_waves(Vector2(-9, 8), 8, WATER_D, 1.2)
	# камыш у берега
	draw_line(Vector2(20, 10), Vector2(22, 1), Color(0.30, 0.42, 0.18), 1.4, true)
	draw_line(Vector2(23, 11), Vector2(26, 4), Color(0.30, 0.42, 0.18), 1.4, true)


func _icon_sea(sd: int) -> void:
	_shape(_ell(Vector2(0, 3), 28, 15, 30, 0.06, sd), WATER_D, 1.5)
	for row in 3:
		var y := -5.0 + row * 6.5
		for k in 2:
			var x := -11.0 + k * 20.0 + (row % 2) * 5.0
			_waves(Vector2(x, y), 11, Color(0.92, 0.96, 1.0, 0.9), 1.4)
	# парус
	_shape(PackedVector2Array([Vector2(-2, -16), Vector2(-2, -4), Vector2(7, -4)]), MARBLE, 1.1)
	_shape(PackedVector2Array([Vector2(-9, -3), Vector2(9, -3), Vector2(6, 0), Vector2(-6, 0)]), WOOD, 1.1)


func _icon_camp() -> void:
	_shape(PackedVector2Array([Vector2(-23, 13), Vector2(-8, -15), Vector2(7, 13)]), Color(0.86, 0.74, 0.52))
	draw_colored_polygon(PackedVector2Array([Vector2(-8, -1), Vector2(-3, 13), Vector2(-13, 13)]), DARK)
	draw_line(Vector2(-8, -15), Vector2(-8, -19), INK, 1.5)
	draw_line(Vector2(-23, 13), Vector2(-26, 15), INK, 1.0)
	draw_line(Vector2(7, 13), Vector2(10, 15), INK, 1.0)
	# костёр
	draw_line(Vector2(10, 14), Vector2(22, 9), TRUNK, 3.0, true)
	draw_line(Vector2(10, 9), Vector2(22, 14), TRUNK.darkened(0.15), 3.0, true)
	_shape(PackedVector2Array([Vector2(16, -6), Vector2(21, 4), Vector2(19, 10), Vector2(13, 10), Vector2(11, 4)]), Color(0.93, 0.45, 0.12), 1.0)
	draw_colored_polygon(PackedVector2Array([Vector2(16, 0), Vector2(18.5, 6), Vector2(16, 10), Vector2(13.5, 6)]), Color(1.0, 0.85, 0.3))
	draw_circle(Vector2(20, -9), 1.0, Color(0.5, 0.5, 0.5, 0.6))
	draw_circle(Vector2(22, -13), 1.4, Color(0.5, 0.5, 0.5, 0.45))


func _icon_field() -> void:
	_shape(_ell(Vector2(0, 12), 25, 5.5), Color(0.72, 0.70, 0.38), 1.2)
	var stalk := Color(0.70, 0.54, 0.18)
	var grain := Color(0.86, 0.66, 0.24)
	for k in 6:
		var x := -16.0 + k * 6.4
		var lean := (k - 2.5) * 1.1
		var top := Vector2(x + lean, -12.0 + absf(k - 2.5) * 2.0)
		draw_line(Vector2(x, 13), top + Vector2(0, 4), stalk, 1.4, true)
		for g in 4:
			var gp := top + Vector2(0, g * 2.6)
			draw_colored_polygon(_ell(gp + Vector2(-1.5, 0), 1.4, 2.4, 8), grain)
			draw_colored_polygon(_ell(gp + Vector2(1.5, 0.8), 1.4, 2.4, 8), grain)
		draw_line(top + Vector2(0, -1), top + Vector2(0, -5), stalk, 0.8)


func _icon_port() -> void:
	_shape(_ell(Vector2(0, 13), 26, 6, 22), WATER, 1.2)
	_waves(Vector2(-12, 14), 10, Color(1, 1, 1, 0.85), 1.2)
	_waves(Vector2(13, 13), 9, Color(1, 1, 1, 0.85), 1.2)
	var iron := Color(0.22, 0.24, 0.28)
	draw_arc(Vector2(0, -17), 3.8, 0, TAU, 16, iron, 2.6, true)
	draw_line(Vector2(0, -13), Vector2(0, 11), iron, 3.2, true)
	draw_line(Vector2(-8, -8), Vector2(8, -8), iron, 3.0, true)
	draw_arc(Vector2(0, -1), 12.0, 0.25, PI - 0.25, 16, iron, 3.0, true)
	var lp := Vector2(cos(PI - 0.25), sin(PI - 0.25)) * 12.0 + Vector2(0, -1)
	var rp := Vector2(cos(0.25), sin(0.25)) * 12.0 + Vector2(0, -1)
	draw_colored_polygon(PackedVector2Array([lp + Vector2(-3.5, -1.5), lp + Vector2(2.5, -3.5), lp + Vector2(0.5, 1.5)]), iron)
	draw_colored_polygon(PackedVector2Array([rp + Vector2(3.5, -1.5), rp + Vector2(-0.5, 1.5), rp + Vector2(-2.5, -3.5)]), iron)


func _icon_generic() -> void:
	draw_circle(Vector2(0, 0), 10.0, Color(0.86, 0.74, 0.52))
	draw_arc(Vector2(0, 0), 10.0, 0, TAU, 24, INK, 1.6, true)
	_cross(Vector2(0, 0), 5.5, RED, 3.0)
