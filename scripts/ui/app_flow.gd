class_name AppFlow
extends RefCounted
## Menu-to-match navigation and the state that survives scene changes (session, lobby, last result).

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const LOBBY_SCENE := "res://scenes/ui/lobby.tscn"
const MATCH_SCENE := "res://scenes/match/match.tscn"
const END_SCENE := "res://scenes/ui/end_screen.tscn"

static var session: NetSession
static var lobby: LobbyState
static var last_result: Dictionary = {}
static var profile: Dictionary = {}


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


static func go(tree: SceneTree, scene_path: String) -> void:
	tree.change_scene_to_file.call_deferred(scene_path)
