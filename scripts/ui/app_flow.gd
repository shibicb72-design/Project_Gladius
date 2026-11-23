class_name AppFlow
extends RefCounted
## Menu-to-match navigation and the state that survives scene changes (session, lobby, last result).

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const LOBBY_SCENE := "res://scenes/ui/lobby.tscn"
const MATCH_SCENE := "res://scenes/match/match.tscn"
const END_SCENE := "res://scenes/ui/end_screen.tscn"

static var session: NetSession
static var lobby: LobbyState
static var match_seed: int = 0
static var last_result: Dictionary = {}
static var profile: Dictionary = {}
## M2 H1b commit 5 (OQ-COACH): the explicit "real match from the menu / lobby route" flag. Set ONLY by the lobby screen
## when the match starts (lobby.gd _on_match_starting, on the host and every LAN client); taken (read and cleared) by
## GameHud.bind, which shows the first-play coach when it is set and the profile's coach_done is not. Tests, sims and
## capture tools start matches without it (MatchRoot.auto_start / use_map_select do not set it).
static var coach_route: bool = false
## W0 (binding fix 1): the explicit "Play solo" flag. Set ONLY by the main menu's Play solo button; cleared by
## end_session() and by Host / Join. While it is set the lobby is a local host with no network (NetSession.start_offline,
## no ENet peer, no lobby RPCs) and MatchRoot plays the match offline (networked_match false, no bridge, the tree
## pauses in the menu). An explicit flag, not a peer test: the lobby always creates a session and the default
## OfflineMultiplayerPeer reports unique id 1, so sniffing the peer would call solo networked (docs/ARCHITECTURE.md).
static var solo: bool = false


## Returns the persistent session, creating it under the tree root on first use.
static func ensure_session(tree: SceneTree) -> NetSession:
	if session == null or not is_instance_valid(session):
		session = NetSession.new()
		session.name = "NetSession"
		tree.root.add_child(session)
	return session


static func end_session() -> void:
	if session != null and is_instance_valid(session):
		session.leave()
		session.queue_free()
	session = null
	lobby = null
	match_seed = 0
	coach_route = false
	solo = false


## M2 H1b commit 5: reads the real-match flag and clears it (one match per lobby start).
static func take_coach_route() -> bool:
	var on := coach_route
	coach_route = false
	return on


static func go(tree: SceneTree, scene_path: String) -> void:
	tree.change_scene_to_file.call_deferred(scene_path)
