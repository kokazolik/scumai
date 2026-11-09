extends MultiplayerPeerExtension
## Сетевая игра через интернет без своего сервера.
## Телефоны общаются через публичный MQTT-брокер (WebSocket, TLS): каждый подписан на свой «почтовый ящик»
## chronicles2/<хэш кода комнаты>/<id>. Всё, что уходит через брокер, зашифровано AES-256 ключом из кода комнаты,
## поэтому посторонний без кода видит только шум. Большие пакеты (состояние игры) сжимаются и режутся на куски.
## Для движка это обычный MultiplayerPeer: rpc() и rpc_id() работают как с ENet.

signal relinked        # связь с брокером восстановилась после обрыва (свернули приложение и т.п.)
signal host_seen       # клиент снова получил ответ хоста (после переподключения)
signal host_lost       # хост замолчал: показываем «переподключаюсь»

const BROKERS := [
	"wss://broker.emqx.io:8084/mqtt",
	"wss://broker.hivemq.com:8884/mqtt",
	"wss://test.mosquitto.org:8081/mqtt",
]
const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CHUNK := 60000
const HOST_SILENCE_MS := 180000      # клиент считает хоста пропавшим
const CLIENT_SILENCE_MS := 600000    # хост забывает клиента (телефон могли свернуть надолго)

enum T { DATA = 1, HELLO = 2, WELCOME = 3, PING = 4, BYE = 5 }

var code := ""
var broker := 0
var _base := ""
var _key := PackedByteArray()
var _server := false
var _id := 0
var _status := MultiplayerPeer.CONNECTION_DISCONNECTED
var _target := 0
var _channel := 0
var _mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refuse := false

var _ws: WebSocketPeer
var _ws_ready := false     # получен CONNACK, подписки отправлены
var _buf := PackedByteArray()
var _pid := 1
var _ws_t := 0              # когда последний раз пытались подключиться к брокеру
var _ws_tries := 0
var _ping_t := 0
var _hello_t := 0
var _mqtt_ping_t := 0

var _peers := {}           # хост: id клиента -> когда последний раз слышали
var _host_seen := 0
var _welcomed := false
var _queue: Array = []     # входящие пакеты: {"from", "ch", "mode", "data"}
var _cur: Dictionary = {}
var _parts := {}           # сборка кусков: msgid -> {"n", "got": {idx: bytes}, "t"}
var _outbox: Array = []    # что не ушло, пока не было связи с брокером


# ───────────── запуск ─────────────

static func new_code(broker_idx: int) -> String:
	var s := ""
	for i in 5:
		s += ALPHABET[randi() % ALPHABET.length()]
	return s + str(broker_idx + 1)


static func normalize(c: String) -> String:
	return c.strip_edges().to_upper().replace(" ", "").replace("-", "").replace("O", "0").replace("I", "1")


static func _broker_url(i: int) -> String:
	var o := OS.get_environment("ALIBI_BROKER")
	return o if o != "" else BROKERS[clampi(i, 0, BROKERS.size() - 1)]


## Хост: подключиться к первому живому брокеру и открыть комнату. Пусто — успех, иначе текст ошибки.
func start_host(fixed_code := "") -> String:
	_server = true
	_id = 1
	for i in BROKERS.size():
		broker = i
		code = fixed_code if fixed_code != "" else new_code(i)
		_setup_keys()
		if await _connect_broker(8.0):
			_status = MultiplayerPeer.CONNECTION_CONNECTED
			return ""
		if OS.get_environment("ALIBI_BROKER") != "":
			break
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	return "Не удалось связаться с сервером-посредником. Проверь интернет."


## Клиент: войти по коду. Подключение идёт в фоне, как у ENet (статус CONNECTING → CONNECTED).
func start_client(room: String, keep_id := 0) -> String:
	code = normalize(room)
	if code.length() != 6 or not code[5].is_valid_int() or int(code[5]) < 1 or int(code[5]) > BROKERS.size():
		return "Код комнаты — 6 знаков, например K7QM42"
	broker = int(code[5]) - 1
	_server = false
	_id = keep_id if keep_id > 1 else randi_range(2, 0x3FFFFFFF)
	_setup_keys()
	_status = MultiplayerPeer.CONNECTION_CONNECTING
	_host_seen = Time.get_ticks_msec()
	_open_ws()
	return ""


func _setup_keys() -> void:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(("chronicles-room|" + code).to_utf8_buffer())
	_key = h.finish()
	var h2 := HashingContext.new()
	h2.start(HashingContext.HASH_SHA256)
	h2.update(("chronicles-topic|" + code).to_utf8_buffer())
	_base = "chronicles2/" + h2.finish().hex_encode().left(20)


func _connect_broker(timeout: float) -> bool:
	_open_ws()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout * 1000.0):
		_pump()
		if _ws_ready:
			return true
		if _ws == null:
			return false
		await Engine.get_main_loop().process_frame
	return false


func _open_ws() -> void:
	if _ws:
		_ws.close()
	_ws = WebSocketPeer.new()
	_ws.supported_protocols = PackedStringArray(["mqtt"])
	_ws.inbound_buffer_size = 1 << 22
	_ws.outbound_buffer_size = 1 << 22
	_ws.max_queued_packets = 4096
	_ws_ready = false
	_connect_sent = false
	_buf = PackedByteArray()
	_ws_t = Time.get_ticks_msec()
	_ws_tries += 1
	var e := _ws.connect_to_url(_broker_url(broker))
	if e != OK:
		_ws = null


# ───────────── MultiplayerPeer ─────────────

func _get_available_packet_count() -> int:
	return _queue.size()


func _get_max_packet_size() -> int:
	return 1 << 24


func _get_packet_script() -> PackedByteArray:
	if _queue.is_empty():
		return PackedByteArray()
	_cur = _queue.pop_front()
	return _cur.data


func _put_packet_script(p_buffer: PackedByteArray) -> Error:
	if _status != MultiplayerPeer.CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	if _server:
		if _target == 0:
			_send(0, T.DATA, p_buffer)
		elif _target < 0:
			for id in _peers:
				if id != -_target:
					_send(id, T.DATA, p_buffer)
		elif _peers.has(_target):
			_send(_target, T.DATA, p_buffer)
	else:
		_send(1, T.DATA, p_buffer)   # без ретрансляции: клиент говорит только с хостом
	return OK


func _get_packet_channel() -> int:
	return int(_cur.get("ch", 0))


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return int(_cur.get("mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)) as MultiplayerPeer.TransferMode


func _get_packet_peer() -> int:
	return int(_cur.get("from", 1))


func _set_transfer_channel(p_channel: int) -> void:
	_channel = p_channel


func _get_transfer_channel() -> int:
	return _channel


func _set_transfer_mode(p_mode: MultiplayerPeer.TransferMode) -> void:
	_mode = p_mode


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _mode


func _set_target_peer(p_peer: int) -> void:
	_target = p_peer


func _is_server() -> bool:
	return _server


func _get_unique_id() -> int:
	return _id


func _is_server_relay_supported() -> bool:
	return false


func _set_refuse_new_connections(p_enable: bool) -> void:
	_refuse = p_enable


func _is_refusing_new_connections() -> bool:
	return _refuse


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _status


func _disconnect_peer(p_peer: int, _p_force: bool) -> void:
	if _server and _peers.has(p_peer):
		_send(p_peer, T.BYE, PackedByteArray())
		_peers.erase(p_peer)
		peer_disconnected.emit(p_peer)


func _close() -> void:
	if _status == MultiplayerPeer.CONNECTION_DISCONNECTED and _ws == null:
		return
	if _ws_ready:
		if _server:
			_send(0, T.BYE, PackedByteArray())
		else:
			_send(1, T.BYE, PackedByteArray())
		_ws.send(PackedByteArray([0xE0, 0x00]), WebSocketPeer.WRITE_MODE_BINARY)
	if _ws:
		_ws.close()
	_ws = null
	_ws_ready = false
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	_peers = {}


func _poll() -> void:
	_pump()
	var now := Time.get_ticks_msec()
	if _status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	# обрыв связи с брокером: переподключаемся сами (свернули приложение, сменилась сеть)
	if _ws == null or (_ws.get_ready_state() == WebSocketPeer.STATE_CLOSED):
		var wait := mini(2000 * _ws_tries, 10000)
		if now - _ws_t > wait:
			_open_ws()
	if _ws_ready:
		if now - _mqtt_ping_t > 20000:
			_mqtt_ping_t = now
			_ws.send(PackedByteArray([0xC0, 0x00]), WebSocketPeer.WRITE_MODE_BINARY)
		if not _server and not _welcomed and now - _hello_t > 2000:
			_hello_t = now
			_send(1, T.HELLO, PackedByteArray())
		if now - _ping_t > 5000:
			_ping_t = now
			if _server:
				if not _peers.is_empty():
					_send(0, T.PING, PackedByteArray())
			elif _welcomed:
				_send(1, T.PING, PackedByteArray())
	if _server:
		for id in _peers.keys():
			if now - int(_peers[id]) > CLIENT_SILENCE_MS:
				_peers.erase(id)
				peer_disconnected.emit(id)
	elif _status == MultiplayerPeer.CONNECTION_CONNECTING and now - _host_seen > 25000:
		_status = MultiplayerPeer.CONNECTION_DISCONNECTED   # хост так и не ответил: неверный код или нет связи
	elif now - _host_seen > HOST_SILENCE_MS:
		_status = MultiplayerPeer.CONNECTION_DISCONNECTED
		if _welcomed:
			peer_disconnected.emit(1)
	elif _welcomed and now - _host_seen > 15000:
		_welcomed = false   # хост молчит: снова стучимся, пока не ответит
		host_lost.emit()
	for k in _parts.keys():
		if now - int(_parts[k].t) > 60000:
			_parts.erase(k)


# ───────────── наш протокол ─────────────

func _send(to: int, t: int, data: PackedByteArray) -> void:
	var plain := PackedByteArray()
	plain.resize(8)
	plain.encode_u8(0, t)
	plain.encode_u32(1, _id)
	plain.encode_u8(5, _channel)
	plain.encode_u8(6, _mode)
	var packed := data
	var flags := 0
	if data.size() > 512:
		var z := data.compress(FileAccess.COMPRESSION_DEFLATE)
		if z.size() < data.size():
			packed = z
			flags = 1
			plain.resize(12)
			plain.encode_u32(8, data.size())
	plain.encode_u8(7, flags)
	plain.append_array(packed)
	var blob := _encrypt(plain)
	var msgid := randi()
	var n := ceili(float(blob.size()) / CHUNK)
	for i in n:
		var head := PackedByteArray()
		head.resize(8)
		head.encode_u32(0, msgid)
		head.encode_u16(4, i)
		head.encode_u16(6, n)
		head.append_array(blob.slice(i * CHUNK, mini((i + 1) * CHUNK, blob.size())))
		_publish("%s/%d" % [_base, to], head)


func _on_message(payload: PackedByteArray) -> void:
	if payload.size() < 8:
		return
	var msgid := payload.decode_u32(0)
	var idx := payload.decode_u16(4)
	var n := payload.decode_u16(6)
	var body := payload.slice(8)
	if n > 1:
		if not _parts.has(msgid):
			_parts[msgid] = {"n": n, "got": {}, "t": Time.get_ticks_msec()}
		var pr: Dictionary = _parts[msgid]
		pr.got[idx] = body
		if pr.got.size() < n:
			return
		body = PackedByteArray()
		for i in n:
			body.append_array(pr.got.get(i, PackedByteArray()))
		_parts.erase(msgid)
	var plain := _decrypt(body)
	if plain.size() < 8:
		return
	var t := plain.decode_u8(0)
	var from := int(plain.decode_u32(1))
	if from == _id:
		return
	var ch := plain.decode_u8(5)
	var mode := plain.decode_u8(6)
	var flags := plain.decode_u8(7)
	var data := plain.slice(8)
	if flags & 1:
		if plain.size() < 12:
			return
		data = plain.slice(12).decompress(plain.decode_u32(8), FileAccess.COMPRESSION_DEFLATE)
	var now := Time.get_ticks_msec()
	if _server:
		if t == T.HELLO:
			if not _peers.has(from):
				if _refuse:
					return
				_peers[from] = now
				peer_connected.emit(from)
			_peers[from] = now
			_send(from, T.WELCOME, PackedByteArray())
			return
		if not _peers.has(from):
			if t != T.BYE:
				_send(from, T.BYE, PackedByteArray())   # хост нас не знает: пусть клиент поздоровается заново
			return
		_peers[from] = now
		if t == T.BYE:
			_peers.erase(from)
			peer_disconnected.emit(from)
		elif t == T.DATA:
			_queue.append({"from": from, "ch": ch, "mode": mode, "data": data})
		return
	if from != 1:
		return
	_host_seen = now
	match t:
		T.WELCOME:
			var first := _status != MultiplayerPeer.CONNECTION_CONNECTED
			_welcomed = true
			if first:
				_status = MultiplayerPeer.CONNECTION_CONNECTED
				peer_connected.emit(1)
			else:
				host_seen.emit()
		T.BYE:
			_welcomed = false   # хост перезапустился или забыл нас — здороваемся снова
		T.DATA:
			if _status == MultiplayerPeer.CONNECTION_CONNECTED:
				_queue.append({"from": 1, "ch": ch, "mode": mode, "data": data})


func _encrypt(plain: PackedByteArray) -> PackedByteArray:
	var pad := 16 - plain.size() % 16
	var p := plain.duplicate()
	for i in pad:
		p.append(pad)
	var iv := Crypto.new().generate_random_bytes(16)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, _key, iv)
	var out := iv.duplicate()
	out.append_array(aes.update(p))
	aes.finish()
	return out


func _decrypt(blob: PackedByteArray) -> PackedByteArray:
	if blob.size() < 32 or blob.size() % 16 != 0:
		return PackedByteArray()
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, _key, blob.slice(0, 16))
	var p := aes.update(blob.slice(16))
	aes.finish()
	if p.is_empty():
		return p
	var pad := p[p.size() - 1]
	if pad < 1 or pad > 16 or pad > p.size():
		return PackedByteArray()   # чужой ключ или мусор
	return p.slice(0, p.size() - pad)


# ───────────── MQTT 3.1.1 поверх WebSocket ─────────────

func _pump() -> void:
	if _ws == null:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _ws_ready and not _connect_sent:
			_mqtt_connect()
		while _ws.get_available_packet_count() > 0:
			_buf.append_array(_ws.get_packet())
		_parse()
	elif st == WebSocketPeer.STATE_CLOSED:
		if _ws_ready:
			push_warning("mqtt: связь с брокером оборвалась (%d)" % _ws.get_close_code())
		_ws_ready = false


var _connect_sent := false


func _mqtt_connect() -> void:
	_connect_sent = true
	var vh := PackedByteArray([0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x04, 0x02, 0x00, 60])
	vh.append_array(_mqtt_str("chr%d_%d" % [_id, randi() % 100000]))
	_mqtt_send(0x10, vh)


func _mqtt_str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray([(b.size() >> 8) & 0xFF, b.size() & 0xFF])
	out.append_array(b)
	return out


func _mqtt_send(head: int, body: PackedByteArray) -> void:
	var pkt := PackedByteArray([head])
	var n := body.size()
	while true:
		var byte := n % 128
		n = n / 128
		if n > 0:
			byte |= 0x80
		pkt.append(byte)
		if n == 0:
			break
	pkt.append_array(body)
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send(pkt, WebSocketPeer.WRITE_MODE_BINARY)


func _publish(topic: String, payload: PackedByteArray) -> void:
	var body := _mqtt_str(topic)
	body.append_array(payload)
	if not _ws_ready:
		_outbox.append(body)
		if _outbox.size() > 200:
			_outbox.pop_front()
		return
	_mqtt_send(0x30, body)


func _subscribe() -> void:
	var topics := ["%s/%d" % [_base, _id]]
	if not _server:
		topics.append("%s/0" % _base)
	var body := PackedByteArray([(_pid >> 8) & 0xFF, _pid & 0xFF])
	_pid = (_pid % 60000) + 1
	for t in topics:
		body.append_array(_mqtt_str(t))
		body.append(0)
	_mqtt_send(0x82, body)


func _parse() -> void:
	while _buf.size() >= 2:
		var mult := 1
		var len := 0
		var i := 1
		var complete := false
		while i < _buf.size() and i <= 4:
			var b := _buf[i]
			len += (b & 0x7F) * mult
			mult *= 128
			i += 1
			if b & 0x80 == 0:
				complete = true
				break
		if not complete or _buf.size() < i + len:
			return
		var head := _buf[0]
		var body := _buf.slice(i, i + len)
		_buf = _buf.slice(i + len)
		match head >> 4:
			2:   # CONNACK
				if body.size() >= 2 and body[1] == 0:
					_ws_ready = true
					_ws_tries = 0
					_subscribe()
					var was := _outbox.duplicate()
					_outbox = []
					for ob in was:
						_mqtt_send(0x30, ob)
					if _server and _status == MultiplayerPeer.CONNECTION_CONNECTED:
						relinked.emit()
					elif not _server:
						_welcomed = false
						_hello_t = 0
				else:
					push_warning("mqtt: брокер отказал в подключении")
					_ws.close()
			3:   # PUBLISH
				if body.size() < 2:
					continue
				var tl := (body[0] << 8) | body[1]
				var off := 2 + tl
				if head & 0x06:
					off += 2   # QoS>0: идентификатор пакета
				_on_message(body.slice(off))
