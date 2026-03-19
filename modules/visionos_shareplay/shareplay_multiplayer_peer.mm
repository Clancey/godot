/**************************************************************************/
/*  shareplay_multiplayer_peer.mm                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#ifdef VISIONOS_ENABLED

#include "shareplay_multiplayer_peer.h"

#include "platform/visionos/shareplay/shareplay_bridge.h"

// ============================================================================
// Static C callback trampolines
// ============================================================================

static void _message_callback(const uint8_t *data, int length, const char *sender_id, void *userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(userdata);
	peer->_on_message_received(data, length, String::utf8(sender_id));
}

static void _participant_joined_callback(const char *participant_id, void *userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(userdata);
	peer->_on_participant_joined(String::utf8(participant_id));
}

static void _participant_left_callback(const char *participant_id, void *userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(userdata);
	peer->_on_participant_left(String::utf8(participant_id));
}

static void _session_started_callback(void *userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(userdata);
	peer->_on_session_started();
}

static void _session_ended_callback(void *userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(userdata);
	peer->_on_session_ended();
}

// ============================================================================
// Bind methods
// ============================================================================

void SharePlayMultiplayerPeer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start_activity"), &SharePlayMultiplayerPeer::start_activity);
	ClassDB::bind_method(D_METHOD("end_activity"), &SharePlayMultiplayerPeer::end_activity);

	ClassDB::bind_method(D_METHOD("set_activity_title", "title"), &SharePlayMultiplayerPeer::set_activity_title);
	ClassDB::bind_method(D_METHOD("get_activity_title"), &SharePlayMultiplayerPeer::get_activity_title);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "activity_title"), "set_activity_title", "get_activity_title");
}

SharePlayMultiplayerPeer::SharePlayMultiplayerPeer() {
}

SharePlayMultiplayerPeer::~SharePlayMultiplayerPeer() {
	close();
}

// ============================================================================
// SharePlay-specific API
// ============================================================================

Error SharePlayMultiplayerPeer::start_activity() {
	if (connection_status != CONNECTION_DISCONNECTED) {
		return ERR_ALREADY_IN_USE;
	}

	connection_status = CONNECTION_CONNECTING;
	is_host = true;
	unique_id = 1; // Host is always peer 1 (server).

	setup_session_callbacks();

	godot_shareplay_set_activity_title(activity_title.utf8().get_data());
	godot_shareplay_start_activity();

	return OK;
}

void SharePlayMultiplayerPeer::end_activity() {
	if (connection_status == CONNECTION_DISCONNECTED) {
		return;
	}

	godot_shareplay_end_activity();
	close();
}

void SharePlayMultiplayerPeer::set_activity_title(const String &p_title) {
	activity_title = p_title;
}

String SharePlayMultiplayerPeer::get_activity_title() const {
	return activity_title;
}

// ============================================================================
// MultiplayerPeer interface
// ============================================================================

void SharePlayMultiplayerPeer::set_target_peer(int p_peer_id) {
	target_peer = p_peer_id;
}

int SharePlayMultiplayerPeer::get_packet_peer() const {
	MutexLock lock(packet_mutex);
	if (current_packet_index >= 0 && current_packet_index < (int)incoming_packets.size()) {
		return incoming_packets[current_packet_index].from_peer;
	}
	return 0;
}

MultiplayerPeer::TransferMode SharePlayMultiplayerPeer::get_packet_mode() const {
	return TRANSFER_MODE_RELIABLE;
}

int SharePlayMultiplayerPeer::get_packet_channel() const {
	return 0;
}

void SharePlayMultiplayerPeer::disconnect_peer(int p_peer, bool p_force) {
	String *participant = peer_to_participant.getptr(p_peer);
	if (participant != nullptr) {
		remove_peer_id(*participant);
	}
}

bool SharePlayMultiplayerPeer::is_server() const {
	return is_host;
}

void SharePlayMultiplayerPeer::poll() {
	// Packet queue is filled from callbacks - nothing to poll actively.
}

void SharePlayMultiplayerPeer::close() {
	clear_session_callbacks();

	{
		MutexLock lock(packet_mutex);
		incoming_packets.clear();
		current_packet_index = -1;
		current_packet_data.clear();
	}

	participant_to_peer.clear();
	peer_to_participant.clear();
	connection_status = CONNECTION_DISCONNECTED;
	unique_id = 0;
	is_host = false;
	target_peer = TARGET_PEER_BROADCAST;
}

int SharePlayMultiplayerPeer::get_unique_id() const {
	return unique_id;
}

MultiplayerPeer::ConnectionStatus SharePlayMultiplayerPeer::get_connection_status() const {
	return connection_status;
}

// ============================================================================
// PacketPeer interface
// ============================================================================

int SharePlayMultiplayerPeer::get_available_packet_count() const {
	MutexLock lock(packet_mutex);
	return incoming_packets.size();
}

Error SharePlayMultiplayerPeer::get_packet(const uint8_t **r_buffer, int &r_buffer_size) {
	MutexLock lock(packet_mutex);

	if (incoming_packets.size() == 0) {
		r_buffer_size = 0;
		return ERR_UNAVAILABLE;
	}

	current_packet_data = incoming_packets[0].data;
	current_packet_index = 0;

	*r_buffer = current_packet_data.ptr();
	r_buffer_size = current_packet_data.size();

	incoming_packets.remove_at(0);

	return OK;
}

Error SharePlayMultiplayerPeer::put_packet(const uint8_t *p_buffer, int p_buffer_size) {
	if (connection_status != CONNECTION_CONNECTED) {
		return ERR_UNCONFIGURED;
	}

	if (target_peer == TARGET_PEER_BROADCAST) {
		godot_shareplay_send_message(p_buffer, p_buffer_size, nullptr);
	} else if (target_peer == TARGET_PEER_SERVER) {
		String participant = get_participant_for_peer(1);
		if (!participant.is_empty()) {
			godot_shareplay_send_message(p_buffer, p_buffer_size, participant.utf8().get_data());
		}
	} else if (target_peer > 0) {
		String participant = get_participant_for_peer(target_peer);
		if (!participant.is_empty()) {
			godot_shareplay_send_message(p_buffer, p_buffer_size, participant.utf8().get_data());
		}
	} else if (target_peer < 0) {
		int exclude_peer = -target_peer;
		for (const KeyValue<int, String> &kv : peer_to_participant) {
			if (kv.key != exclude_peer) {
				godot_shareplay_send_message(p_buffer, p_buffer_size, kv.value.utf8().get_data());
			}
		}
	}

	return OK;
}

int SharePlayMultiplayerPeer::get_max_packet_size() const {
	return 1 << 20; // 1 MB
}

// ============================================================================
// Peer ID management
// ============================================================================

int SharePlayMultiplayerPeer::allocate_peer_id(const String &p_participant_id) {
	int *existing = participant_to_peer.getptr(p_participant_id);
	if (existing != nullptr) {
		return *existing;
	}

	int new_id = generate_unique_id();
	while (new_id == 0 || new_id == 1 || peer_to_participant.has(new_id)) {
		new_id = generate_unique_id();
	}

	participant_to_peer[p_participant_id] = new_id;
	peer_to_participant[new_id] = p_participant_id;
	return new_id;
}

void SharePlayMultiplayerPeer::remove_peer_id(const String &p_participant_id) {
	int *peer_id = participant_to_peer.getptr(p_participant_id);
	if (peer_id != nullptr) {
		peer_to_participant.erase(*peer_id);
	}
	participant_to_peer.erase(p_participant_id);
}

String SharePlayMultiplayerPeer::get_participant_for_peer(int p_peer_id) const {
	const String *participant = peer_to_participant.getptr(p_peer_id);
	return participant != nullptr ? *participant : String();
}

// ============================================================================
// Callbacks from SharePlay (called from GCD queue via C bridge)
// ============================================================================

void SharePlayMultiplayerPeer::_on_message_received(const uint8_t *p_data, int p_size, const String &p_sender_id) {
	int *peer_id = participant_to_peer.getptr(p_sender_id);
	if (peer_id == nullptr) {
		allocate_peer_id(p_sender_id);
		peer_id = participant_to_peer.getptr(p_sender_id);
	}

	IncomingPacket pkt;
	pkt.from_peer = *peer_id;
	pkt.data.resize(p_size);
	memcpy(pkt.data.ptrw(), p_data, p_size);
	pkt.mode = TRANSFER_MODE_RELIABLE;
	pkt.channel = 0;

	MutexLock lock(packet_mutex);
	incoming_packets.push_back(pkt);
}

void SharePlayMultiplayerPeer::_on_participant_joined(const String &p_participant_id) {
	int peer_id = allocate_peer_id(p_participant_id);
	emit_signal(SNAME("peer_connected"), peer_id);
}

void SharePlayMultiplayerPeer::_on_participant_left(const String &p_participant_id) {
	int *peer_id = participant_to_peer.getptr(p_participant_id);
	if (peer_id != nullptr) {
		int id = *peer_id;
		remove_peer_id(p_participant_id);
		emit_signal(SNAME("peer_disconnected"), id);
	}
}

void SharePlayMultiplayerPeer::_on_session_started() {
	connection_status = CONNECTION_CONNECTED;

	const char *local_id = godot_shareplay_get_local_participant_id();
	String local_id_str = local_id != nullptr ? String::utf8(local_id) : "";

	if (is_host) {
		participant_to_peer[local_id_str] = 1;
		peer_to_participant[1] = local_id_str;
	} else {
		unique_id = allocate_peer_id(local_id_str);
	}
}

void SharePlayMultiplayerPeer::_on_session_ended() {
	connection_status = CONNECTION_DISCONNECTED;
}

// ============================================================================
// Callback setup/teardown
// ============================================================================

void SharePlayMultiplayerPeer::setup_session_callbacks() {
	godot_shareplay_set_message_callback(_message_callback, this);
	godot_shareplay_set_participant_joined_callback(_participant_joined_callback, this);
	godot_shareplay_set_participant_left_callback(_participant_left_callback, this);
	godot_shareplay_set_session_started_callback(_session_started_callback, this);
	godot_shareplay_set_session_ended_callback(_session_ended_callback, this);
}

void SharePlayMultiplayerPeer::clear_session_callbacks() {
	godot_shareplay_set_message_callback(nullptr, nullptr);
	godot_shareplay_set_participant_joined_callback(nullptr, nullptr);
	godot_shareplay_set_participant_left_callback(nullptr, nullptr);
	godot_shareplay_set_session_started_callback(nullptr, nullptr);
	godot_shareplay_set_session_ended_callback(nullptr, nullptr);
}

#endif // VISIONOS_ENABLED
