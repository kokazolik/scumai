extends Node
## Музыка и звуки. Автозагрузка «Audio» (project.godot → [autoload] Audio="*res://scripts/audio.gd").
##
##   Audio.play_music("town")                    # плавная смена петли (1.5 с), тот же mood — ничего
##   Audio.play_music(Audio.mood_for_place(t, name))
##   Audio.play_sting("victory")                 # короткий джингл, музыка приглушается
##   Audio.sfx("sword_hit")                       # пул из 6 плееров, высота ±4 %
##   Audio.set_music_enabled(false) / set_sfx_enabled(false) / set_music_volume_db(-6.0)
##
## Настройки хранятся в user://settings.cfg, секция "audio".
## Нет файлов или аудиодрайвер dummy (headless) — всё молча работает вхолостую.

signal settings_changed

const MUSIC_DIR := "res://audio/music/"
const SFX_DIR := "res://audio/sfx/"
const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "audio"

const MOODS := ["town", "wild", "dungeon", "combat", "sea", "mystery", "menu"]
const DEFAULT_MOOD := "wild"
const SFX_NAMES := ["sword_hit", "miss_whoosh", "crit", "enemy_hit", "spell_cast", "heal", "coin", "chest_open",
	"level_up", "page", "death_knell", "flee", "enemy_die", "fire_whoosh", "ice_crack", "zap"]

const CROSSFADE := 1.5
const POOL_SIZE := 6
const PITCH_VAR := 0.04
const DUCK_DB := -14.0
const MUSIC_BUS := "Music"
const SFX_BUS := "SFX"

## Тип места (rules.gd PLACE_TYPES + пара запасных) → настроение.
const TYPE_MOOD := {
	"village": "town", "town": "town", "city": "town", "tavern": "town", "inn": "town", "camp": "town",
	"market": "town",
	"forest": "wild", "road": "wild", "field": "wild", "mountain": "wild", "lake": "wild", "river": "wild",
	"plains": "wild", "hills": "wild",
	"cave": "dungeon", "dungeon": "dungeon", "crypt": "dungeon", "ruins": "dungeon", "castle": "dungeon",
	"temple": "dungeon", "mine": "dungeon", "sewer": "dungeon",
	"sea": "sea", "coast": "sea", "port": "sea", "ship": "sea", "harbor": "sea", "island": "sea", "beach": "sea",
	"swamp": "mystery", "graveyard": "mystery", "cemetery": "mystery", "tower": "mystery", "marsh": "mystery",
	"haunted": "mystery",
}

## Начала слов в названии (по-русски и пара английских). «Сильные» перебивают тип места,
## «слабые» используются, только если тип неизвестен. Совпадение — по началу слова.
const STRONG_NAME_MOOD := [
	["портал", "mystery"],
	["кладбищ", "mystery"], ["погост", "mystery"], ["болот", "mystery"], ["топь", "mystery"], ["трясин", "mystery"],
	["призрач", "mystery"], ["проклят", "mystery"], ["ведьм", "mystery"], ["graveyard", "mystery"],
	["swamp", "mystery"],
	["порт", "sea"], ["гаван", "sea"], ["причал", "sea"], ["пристан", "sea"], ["корабл", "sea"], ["море", "sea"],
	["морск", "sea"], ["бухт", "sea"], ["побереж", "sea"],
	["таверн", "town"], ["трактир", "town"], ["корчм", "town"], ["постоял", "town"],
]
const WEAK_NAME_MOOD := [
	["пещер", "dungeon"], ["склеп", "dungeon"], ["подземел", "dungeon"], ["катакомб", "dungeon"], ["руин", "dungeon"],
	["гробниц", "dungeon"], ["шахт", "dungeon"], ["логов", "dungeon"], ["замок", "dungeon"], ["замк", "dungeon"],
	["крепост", "dungeon"], ["форт", "dungeon"], ["цитадел", "dungeon"], ["храм", "dungeon"], ["подвал", "dungeon"], ["курган", "dungeon"],
	["башн", "mystery"], ["туман", "mystery"],
	["деревн", "town"], ["село", "town"], ["селе", "town"], ["посёл", "town"], ["посел", "town"], ["город", "town"], ["посад", "town"], ["рынок", "town"], ["лагер", "town"],
	["лес", "wild"], ["рощ", "wild"], ["чащ", "wild"], ["дорог", "wild"], ["тракт", "wild"], ["поле", "wild"],
	["полян", "wild"], ["луг", "wild"],
	["гор", "wild"], ["перевал", "wild"], ["озер", "wild"], ["озёр", "wild"], ["река", "wild"], ["реки", "wild"], ["речн", "wild"], ["холм", "wild"], ["степ", "wild"],
	["остров", "sea"], ["берег", "sea"], ["залив", "sea"],
]

var music_enabled := true
var sfx_enabled := true
var music_volume_db := -3.0
var sfx_volume_db := 0.0
var current_mood := ""

var _players: Array[AudioStreamPlayer] = []   # два плеера для кроссфейда
var _gain := [0.0, 0.0]                        # линейная громкость каждого
var _active := 0
var _fade: Tween
var _sting: AudioStreamPlayer
var _duck: Tween
var _duck_db := 0.0
var _pool: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _cache := {}
var _music_bus := "Master"
var _sfx_bus := "Master"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_music_bus = _ensure_bus(MUSIC_BUS)
	_sfx_bus = _ensure_bus(SFX_BUS)
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = _music_bus
		p.volume_db = -80.0
		add_child(p)
		_players.append(p)
	_sting = AudioStreamPlayer.new()
	_sting.bus = "Master"
	add_child(_sting)
	for i in POOL_SIZE:
		var s := AudioStreamPlayer.new()
		s.bus = _sfx_bus
		add_child(s)
		_pool.append(s)
	_load_settings()
	_apply_bus_volumes()


# ---------------------------------------------------------------- музыка

## Плавно переключиться на петлю `mood`. Тот же mood — ничего не делает. Неизвестный → "wild".
func play_music(mood: String) -> void:
	mood = mood.strip_edges().to_lower()
	if not _music_stream(mood):
		mood = DEFAULT_MOOD
	if mood == current_mood and (not music_enabled or _players[_active].playing):
		return
	current_mood = mood
	if music_enabled:
		_crossfade_to(_music_stream(mood))


## Затихнуть (1.5 с) и забыть текущий mood.
func stop_music() -> void:
	current_mood = ""
	_crossfade_to(null)


## Короткий джингл (например "victory") поверх приглушённой музыки.
func play_sting(sting_name: String) -> void:
	if not music_enabled:
		return
	var st := _load(MUSIC_DIR + sting_name.strip_edges().to_lower() + ".ogg", false)
	if st == null:
		return
	_sting.stream = st
	_sting.volume_db = music_volume_db
	_sting.play()
	var hold := maxf(0.5, st.get_length() - 0.8)
	if _duck and _duck.is_valid():
		_duck.kill()
	_duck = create_tween()
	_duck.tween_method(_set_duck, _duck_db, DUCK_DB, 0.25)
	_duck.tween_interval(hold)
	_duck.tween_method(_set_duck, DUCK_DB, 0.0, 1.5)


## Настроение музыки для места. type — из PLACE_TYPES (rules.gd), name — название (часто по-русски).
func mood_for_place(type: String, place_name := "") -> String:
	var t := type.strip_edges().to_lower()
	var words := _words(place_name)
	var m := _match_words(words, STRONG_NAME_MOOD)
	if m != "":
		return m
	if TYPE_MOOD.has(t):
		return TYPE_MOOD[t]
	m = _match_words(words, WEAK_NAME_MOOD)
	return m if m != "" else DEFAULT_MOOD


func _words(s: String) -> PackedStringArray:
	s = s.to_lower()
	for ch in "-—–,.:;!?«»\"'()[]/":
		s = s.replace(ch, " ")
	return s.split(" ", false)


func _match_words(words: PackedStringArray, table: Array) -> String:
	for pair in table:
		for w in words:
			if w.begins_with(pair[0]):
				return pair[1]
	return ""


func _crossfade_to(stream: AudioStream) -> void:
	if _fade and _fade.is_valid():
		_fade.kill()
	var old := _active
	_fade = create_tween().set_parallel(true)
	if stream != null:
		_active = 1 - _active
		var p := _players[_active]
		p.stream = stream
		_gain[_active] = 0.0
		p.volume_db = -80.0
		p.play()
		_fade.tween_method(_set_gain.bind(_active), 0.0, 1.0, CROSSFADE)
	for i in 2:
		if i != _active or stream == null:
			if _players[i].playing:
				_fade.tween_method(_set_gain.bind(i), float(_gain[i]), 0.0, CROSSFADE)
	_fade.chain().tween_callback(_stop_idle.bind(stream == null))


func _set_gain(v: float, idx: int) -> void:
	_gain[idx] = v
	_players[idx].volume_db = linear_to_db(maxf(v, 0.0001))


func _stop_idle(all: bool) -> void:
	for i in 2:
		if all or i != _active:
			_players[i].stop()
			_gain[i] = 0.0


func _set_duck(db: float) -> void:
	_duck_db = db
	_apply_bus_volumes()


func _music_stream(mood: String) -> AudioStream:
	if mood.is_empty():
		return null
	return _load(MUSIC_DIR + mood + ".ogg", true)


# ---------------------------------------------------------------- звуки

## Короткий звук из res://audio/sfx/<name>.ogg. До 6 одновременно; самый старый вытесняется.
func sfx(sfx_name: String, volume_db := 0.0) -> void:
	if not sfx_enabled or _pool.is_empty():
		return
	var st := _load(SFX_DIR + sfx_name + ".ogg", false)
	if st == null:
		return
	var p: AudioStreamPlayer = null
	for i in POOL_SIZE:
		var c := _pool[(_next_voice + i) % POOL_SIZE]
		if not c.playing:
			p = c
			break
	if p == null:
		p = _pool[_next_voice]
	_next_voice = (_pool.find(p) + 1) % POOL_SIZE
	p.stream = st
	p.volume_db = volume_db
	p.pitch_scale = randf_range(1.0 - PITCH_VAR, 1.0 + PITCH_VAR)
	p.play()


# ---------------------------------------------------------------- настройки

func set_music_enabled(b: bool) -> void:
	if music_enabled == b:
		return
	music_enabled = b
	if b:
		if current_mood != "":
			_crossfade_to(_music_stream(current_mood))
	else:
		_crossfade_to(null)   # current_mood помним, чтобы вернуть при включении
		_sting.stop()
	_save_settings()


func set_sfx_enabled(b: bool) -> void:
	if sfx_enabled == b:
		return
	sfx_enabled = b
	if not b:
		for p in _pool:
			p.stop()
	_save_settings()


func set_music_volume_db(db: float) -> void:
	music_volume_db = clampf(db, -40.0, 6.0)
	_apply_bus_volumes()
	_save_settings()


func set_sfx_volume_db(db: float) -> void:
	sfx_volume_db = clampf(db, -40.0, 6.0)
	_apply_bus_volumes()
	_save_settings()


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	music_enabled = bool(cf.get_value(SECTION, "music_enabled", music_enabled))
	sfx_enabled = bool(cf.get_value(SECTION, "sfx_enabled", sfx_enabled))
	music_volume_db = float(cf.get_value(SECTION, "music_volume_db", music_volume_db))
	sfx_volume_db = float(cf.get_value(SECTION, "sfx_volume_db", sfx_volume_db))


func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)   # сохраняем чужие секции, если файл общий
	cf.set_value(SECTION, "music_enabled", music_enabled)
	cf.set_value(SECTION, "sfx_enabled", sfx_enabled)
	cf.set_value(SECTION, "music_volume_db", music_volume_db)
	cf.set_value(SECTION, "sfx_volume_db", sfx_volume_db)
	cf.save(SETTINGS_PATH)
	settings_changed.emit()


# ---------------------------------------------------------------- служебное

func _ensure_bus(bus_name: String) -> String:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	return bus_name if AudioServer.get_bus_index(bus_name) != -1 else "Master"


func _apply_bus_volumes() -> void:
	if _music_bus != "Master":
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(_music_bus), music_volume_db + _duck_db)
	else:
		for i in _players.size():
			_set_gain(_gain[i], i)
	if _sfx_bus != "Master":
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(_sfx_bus), sfx_volume_db)


func _load(path: String, loop: bool) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	var st: AudioStream = null
	if ResourceLoader.exists(path):
		st = load(path) as AudioStream
	if st is AudioStreamOggVorbis:
		(st as AudioStreamOggVorbis).loop = loop
	elif st is AudioStreamWAV:
		(st as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	_cache[path] = st   # null тоже кэшируем, чтобы не дёргать диск
	return st
