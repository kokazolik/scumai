extends Node
class_name VoiceRecorder
## Запись с микрофона. Звук идёт в отдельную заглушённую шину "Record",
## где AudioEffectRecord собирает его. После остановки отдаём WAV
## (моно, 16 кГц, 16 бит), чтобы запрос к модели был небольшим.

const BUS := "Record"
const TARGET_RATE := 16000
const MAX_SECONDS := 30.0

var _player: AudioStreamPlayer
var _effect: AudioEffectRecord
var recording := false
var started_at := 0.0


func _ready() -> void:
	var idx := AudioServer.get_bus_index(BUS)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS)
		AudioServer.set_bus_mute(idx, true)  # чтобы не слышать себя в динамике
		AudioServer.add_bus_effect(idx, AudioEffectRecord.new())
	_effect = AudioServer.get_bus_effect(idx, 0) as AudioEffectRecord
	_player = AudioStreamPlayer.new()
	_player.bus = BUS
	add_child(_player)


## На Android микрофон нужно разрешить. Возвращает true, если можно писать.
static func has_permission() -> bool:
	if OS.get_name() != "Android":
		return true
	return "android.permission.RECORD_AUDIO" in OS.get_granted_permissions()


static func ask_permission() -> void:
	if OS.get_name() == "Android":
		OS.request_permission("android.permission.RECORD_AUDIO")


func start() -> void:
	if recording:
		return
	_player.stream = AudioStreamMicrophone.new()
	_player.play()
	_effect.set_recording_active(true)
	recording = true
	started_at = Time.get_ticks_msec() / 1000.0


func elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - started_at if recording else 0.0


## Останавливает запись и возвращает WAV-байты (пусто, если ничего не записалось).
func stop() -> PackedByteArray:
	if not recording:
		return PackedByteArray()
	recording = false
	_effect.set_recording_active(false)
	_player.stop()
	var rec := _effect.get_recording()
	if rec == null or rec.data.is_empty():
		return PackedByteArray()
	return to_wav(rec)


## Переводит запись Godot (16 бит, обычно стерео 44.1/48 кГц) в моно 16 кГц.
static func to_wav(rec: AudioStreamWAV) -> PackedByteArray:
	var src := rec.data
	var channels := 2 if rec.stereo else 1
	var frames := src.size() / (2 * channels)
	var step := float(rec.mix_rate) / TARGET_RATE
	var pcm := PackedByteArray()
	var n := int(frames / step)
	pcm.resize(n * 2)
	for i in n:
		var f := int(i * step)
		var acc := 0
		for c in channels:
			acc += src.decode_s16((f * channels + c) * 2)
		pcm.encode_s16(i * 2, clampi(acc / channels, -32768, 32767))
	var h := PackedByteArray()
	h.resize(44)
	h.encode_u32(0, 0x46464952)        # "RIFF"
	h.encode_u32(4, 36 + pcm.size())
	h.encode_u32(8, 0x45564157)        # "WAVE"
	h.encode_u32(12, 0x20746d66)       # "fmt "
	h.encode_u32(16, 16)
	h.encode_u16(20, 1)                # PCM
	h.encode_u16(22, 1)                # моно
	h.encode_u32(24, TARGET_RATE)
	h.encode_u32(28, TARGET_RATE * 2)
	h.encode_u16(32, 2)
	h.encode_u16(34, 16)
	h.encode_u32(36, 0x61746164)       # "data"
	h.encode_u32(40, pcm.size())
	h.append_array(pcm)
	return h


## Громкость записи 0..1, чтобы понять, есть ли там вообще голос.
static func peak(wav: PackedByteArray) -> float:
	var m := 0
	var i := 44
	while i + 1 < wav.size():
		m = maxi(m, absi(wav.decode_s16(i)))
		i += 64
	return m / 32768.0
