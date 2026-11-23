class_name WebRtcFactory
extends RefCounted
## W2: makes the WebRTC objects NetSession uses, so tests can substitute fakes. A headless desktop build has a working
## WebRTCMultiplayerPeer but no WebRTC library behind WebRTCPeerConnection (no webrtc-native extension; we add none),
## so a test factory overrides new_peer_connection / attach / detach and keeps the real multiplayer peer.


func new_multiplayer_peer() -> WebRTCMultiplayerPeer:
	return WebRTCMultiplayerPeer.new()


## A WebRTCPeerConnection (or a fake with the same methods and signals: initialize, create_offer,
## set_local_description, set_remote_description, add_ice_candidate, close; session_description_created,
## ice_candidate_created).
func new_peer_connection() -> Object:
	return WebRTCPeerConnection.new()


## rtc.add_peer(pc, peer_id). Must run after pc.initialize and before create_offer / set_remote_description.
func attach(rtc: WebRTCMultiplayerPeer, pc: Object, peer_id: int) -> int:
	return rtc.add_peer(pc as WebRTCPeerConnection, peer_id)


## Removes peer_id from rtc at once (WebRTCMultiplayerPeer emits peer_disconnected if it was connected), so a guest
## that left is dropped without waiting for the browser's ICE timeout.
func detach(rtc: WebRTCMultiplayerPeer, peer_id: int) -> void:
	if rtc.has_peer(peer_id):
		rtc.remove_peer(peer_id)
