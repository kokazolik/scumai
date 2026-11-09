extends Node
## Сеть: один телефон хост (ENet-сервер), остальные подключаются по Wi-Fi.
## Хост раз в секунду кричит в сеть UDP-пакетом «тут комната», клиенты слушают
## и показывают список. Если роутер режет широковещание, можно ввести IP хоста вручную.

signal players_changed
signal rooms_changed
signal joined          # клиент подключился и зарегистрирован
signal left(reason: String)  # нас отключили / не смогли подключиться
signal reconnecting(on: bool)  # связь с хостом пропала, пробуем вернуться

## Сколько ENet ждёт молчащего собеседника: телефон хоста могут свернуть на несколько минут.
const PEER_TIMEOUT_MIN := 120000
const PEER_TIMEOUT_MAX := 600000
const RECONNECT_FOR := 180.0

const MqttPeer = preload("res://scripts/mqtt_peer.gd")

var last_ip := ""
var online := false      # комната через интернет (код), а не по Wi-Fi
var room_code := ""
var _reconnect_left := 0.0
var _reconnect_t := 0.0

const PORT := 7777
const DISCOVERY_PORT := 7778
const MAX_PLAYERS := 4
const MAGIC := "chronicles-room-1"

var players := {}  # peer_id -> имя
var my_name := "Игрок"
var rooms := {}    # ip -> {"name": String, "count": int, "seen": msec}

var _beacon: PacketPeerUDP
var _listener: PacketPeerUDP
var _beacon_t := 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func():
		if _reconnect_left > 0.0:
			return  # ещё пробуем
		_drop("Не удалось подключиться"))
	multiplayer.server_disconnected.connect(_on_server_lost)


func is_reconnecting() -> bool:
	return _reconnect_left > 0.0


## Хост пропал посреди игры (свернул приложение, моргнул Wi-Fi): не выкидываем в меню, а переподключаемся.
func _on_server_lost() -> void:
	if online:
		_drop("Хост не вернулся")   # интернет-связь сама переподключается; сюда попадаем, только если хост пропал надолго
		return
	if Game.phase == "lobby" or last_ip == "":
		_drop("Хост закрыл комнату")
		return
	_reconnect_left = RECONNECT_FOR
	_reconnect_t = 0.5
	reconnecting.emit(true)


func _relax_timeout(id: int) -> void:
	var mp = multiplayer.multiplayer_peer
	if mp is ENetMultiplayerPeer:
		var pp = mp.get_peer(id)
		if pp:
			pp.set_timeout(32, PEER_TIMEOUT_MIN, PEER_TIMEOUT_MAX)


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)


func is_host() -> bool:
	return is_online() and multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id() if is_online() else 0


## Комната через интернет: хост получает код, который диктует напарнику.
func host_online() -> String:
	stop()
	var p := MqttPeer.new()
	var e: String = await p.start_host(OS.get_environment("ALIBI_ROOMCODE"))
	if e != "":
		p.close()
		return e
	multiplayer.multiplayer_peer = p
	online = true
	room_code = p.code
	p.relinked.connect(func():
		if is_host():
			Game._broadcast())   # пока не было связи, клиенты могли что-то пропустить
	players = {1: my_name}
	players_changed.emit()
	return ""


func join_online(code: String) -> String:
	stop_search()
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	var p := MqttPeer.new()
	var e: String = p.start_client(code)
	if e != "":
		return e
	p.host_seen.connect(func():
		reconnecting.emit(false)
		_register.rpc_id(1, my_name))   # хост мог нас забыть, пока телефон спал — представляемся снова
	p.host_lost.connect(func(): reconnecting.emit(true))
	multiplayer.multiplayer_peer = p
	online = true
	room_code = p.code
	last_ip = ""
	players = {}
	return ""


func host_room() -> String:
	stop()
	var p := ENetMultiplayerPeer.new()
	var e := p.create_server(PORT, MAX_PLAYERS - 1)
	if e != OK:
		return "Не удалось открыть комнату (порт %d занят?)" % PORT
	multiplayer.multiplayer_peer = p
	players = {1: my_name}
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon_t = 0.0
	players_changed.emit()
	return ""


func join_room(ip: String) -> String:
	stop_search()
	online = false
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	var p := ENetMultiplayerPeer.new()
	var e := p.create_client(ip.strip_edges(), PORT)
	if e != OK:
		return "Не удалось подключиться к %s" % ip
	multiplayer.multiplayer_peer = p
	last_ip = ip.strip_edges()
	if _reconnect_left <= 0.0:
		players = {}
	return ""


func stop() -> void:
	_reconnect_left = 0.0
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer or multiplayer.multiplayer_peer is MqttPeer:
		multiplayer.multiplayer_peer.close()
	online = false
	room_code = ""
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if _beacon:
		_beacon.close()
		_beacon = null
	players = {}


func start_search() -> void:
	stop_search()
	rooms = {}
	_listener = PacketPeerUDP.new()
	var e := _listener.bind(DISCOVERY_PORT)
	if e != OK:
		push_warning("discovery bind failed: %d" % e)


func stop_search() -> void:
	if _listener:
		_listener.close()
		_listener = null


## Адреса этого устройства в локальной сети (для показа и ручного ввода).
func local_ips() -> Array:
	var out := []
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or _is_172(a):
			out.append(a)
	return out


func _is_172(a: String) -> bool:
	if not a.begins_with("172."):
		return false
	var p := a.split(".")
	return p.size() == 4 and int(p[1]) >= 16 and int(p[1]) <= 31


func _process(delta: float) -> void:
	if _reconnect_left > 0.0:
		_reconnect_left -= delta
		_reconnect_t -= delta
		if _reconnect_left <= 0.0:
			reconnecting.emit(false)
			_drop("Хост не вернулся")
			return
		if _reconnect_t <= 0.0:
			_reconnect_t = 4.0
			var st := -1
			if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
				st = multiplayer.multiplayer_peer.get_connection_status()
			if st != MultiplayerPeer.CONNECTION_CONNECTING:
				join_room(last_ip)
	if _beacon and is_host():
		_beacon_t -= delta
		if _beacon_t <= 0.0:
			_beacon_t = 1.0
			_send_beacon()
	if _listener:
		var changed := false
		while _listener.get_available_packet_count() > 0:
			var pkt := _listener.get_packet().get_string_from_utf8()
			var ip := _listener.get_packet_ip()
			var d = JSON.parse_string(pkt)
			if d is Dictionary and d.get("magic") == MAGIC and ip != "":
				rooms[ip] = {"name": str(d.get("name", "?")), "count": int(d.get("count", 1)),
					"open": bool(d.get("open", true)), "seen": Time.get_ticks_msec()}
				changed = true
		for ip in rooms.keys():
			if Time.get_ticks_msec() - int(rooms[ip].seen) > 4000:
				rooms.erase(ip)
				changed = true
		if changed:
			rooms_changed.emit()


func _send_beacon() -> void:
	var msg := JSON.stringify({"magic": MAGIC, "name": my_name, "count": players.size(),
		"open": Game.phase == "lobby" or Game.has_free_hero()}).to_utf8_buffer()
	var targets := ["255.255.255.255"]
	for a in local_ips():
		var p: PackedStringArray = a.split(".")
		targets.append("%s.%s.%s.255" % [p[0], p[1], p[2]])
	for t in targets:
		_beacon.set_dest_address(t, DISCOVERY_PORT)
		_beacon.put_packet(msg)


func _on_peer_connected(id: int) -> void:
	_relax_timeout(id)  # ждём, пока клиент назовёт себя в _register


func _on_peer_disconnected(id: int) -> void:
	if is_host() and players.has(id):
		players.erase(id)
		_sync_players.rpc(players)
		Game.on_player_left(id)


func _on_connected() -> void:
	_relax_timeout(1)
	_register.rpc_id(1, my_name)


@rpc("any_peer", "reliable")
func _register(pname: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	pname = pname.strip_edges().left(16)
	if players.has(id):
		# тот же телефон после обрыва связи: просто шлём свежее состояние
		_sync_players.rpc(players)
		_welcome.rpc_id(id)
		Game.send_state_to(id)
		return
	var rejoin := Game.phase != "lobby" and Game.can_rejoin(pname)
	if (Game.phase != "lobby" and not rejoin) or players.size() >= MAX_PLAYERS:
		_rejected.rpc_id(id, "Игра уже идёт: войти можно только под кличкой своего героя" if Game.phase != "lobby" else "Комната заполнена")
		get_tree().create_timer(0.5).timeout.connect(func():
			if is_host():
				multiplayer.multiplayer_peer.disconnect_peer(id))
		return
	if pname == "":
		pname = "Игрок"
	var taken := players.values()
	var base := pname
	var n := 2
	while pname in taken and not rejoin:
		pname = "%s %d" % [base, n]
		n += 1
	players[id] = pname
	_sync_players.rpc(players)
	_welcome.rpc_id(id)
	Game.send_state_to(id)


@rpc("authority", "reliable")
func _welcome() -> void:
	if _reconnect_left > 0.0:
		_reconnect_left = 0.0
		reconnecting.emit(false)
	joined.emit()


## Вернулись из свёрнутого состояния: попросить у хоста свежее состояние игры.
func request_resync() -> void:
	if is_online() and not is_host():
		_resync.rpc_id(1)


@rpc("any_peer", "reliable")
func _resync() -> void:
	if is_host():
		Game.send_state_to(multiplayer.get_remote_sender_id())


@rpc("authority", "reliable")
func _rejected(reason: String) -> void:
	_drop(reason)


@rpc("authority", "call_local", "reliable")
func _sync_players(p: Dictionary) -> void:
	players = p
	players_changed.emit()


func _drop(reason: String) -> void:
	if not is_online():
		return
	stop()
	Game.reset_local()
	left.emit(reason)
