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

#include "core/object/class_db.h"

#include "platform/visionos/shareplay_bridge.h"

// Static C trampolines. These are invoked on the SharePlay dispatch queue.

static void _message_callback(const uint8_t *p_data, int p_length, const char *p_sender_id, void *p_userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(p_userdata);
	peer->_on_message_received(p_data, p_length, String::utf8(p_sender_id));
}

static void _participant_joined_callback(const char *p_participant_id, void *p_userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(p_userdata);
	peer->_on_participant_joined(String::utf8(p_participant_id));
}

static void _participant_left_callback(const char *p_participant_id, void *p_userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(p_userdata);
	peer->_on_participant_left(String::utf8(p_participant_id));
}

static void _session_started_callback(void *p_userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(p_userdata);
	peer->_on_session_started();
}

static void _session_ended_callback(void *p_userdata) {
	SharePlayMultiplayerPeer *peer = static_cast<SharePlayMultiplayerPeer *>(p_userdata);
	peer->_on_session_ended();
}

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

Error SharePlayMultiplayerPeer::start_activity() {
	ERR_FAIL_COND_V_MSG(connection_status != CONNECTION_DISCONNECTED, ERR_ALREADY_IN_USE, "A SharePlay activity is already running.");

	connection_status = CONNECTION_CONNECTING;
	is_host = true;
	unique_id = HOST_PEER_ID;

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

	// Keep the Swift side in sync so an activity started later uses the new title.
	godot_shareplay_set_activity_title(activity_title.utf8().get_data());
}

String SharePlayMultiplayerPeer::get_activity_title() const {
	return activity_title;
}

void SharePlayMultiplayerPeer::set_target_peer(int p_peer_id) {
	target_peer = p_peer_id;
}

int SharePlayMultiplayerPeer::get_packet_peer() const {
	ERR_FAIL_COND_V_MSG(!has_current_packet, 0, "No packet to read. Call get_packet() first.");
	return current_packet.from_peer;
}

MultiplayerPeer::TransferMode SharePlayMultiplayerPeer::get_packet_mode() const {
	// GroupSessionMessenger delivers reliably and in order.
	return TRANSFER_MODE_RELIABLE;
}

int SharePlayMultiplayerPeer::get_packet_channel() const {
	return 0;
}

void SharePlayMultiplayerPeer::disconnect_peer(int p_peer, bool p_force) {
	String participant = get_participant_for_peer(p_peer);
	if (participant.is_empty()) {
		return;
	}

	remove_peer_id(participant);
	if (!p_force) {
		emit_signal(SNAME("peer_disconnected"), p_peer);
	}
}

bool SharePlayMultiplayerPeer::is_server() const {
	return is_host;
}

void SharePlayMultiplayerPeer::poll() {
	// Drain everything SharePlay handed us since the last frame, then process it on
	// the main thread so peer bookkeeping and signal emission stay single-threaded.
	List<Event> events;
	{
		MutexLock lock(event_mutex);
		events = pending_events;
		pending_events.clear();
	}

	for (const Event &event : events) {
		_process_event(event);
	}
}

void SharePlayMultiplayerPeer::_process_event(const Event &p_event) {
	switch (p_event.type) {
		case EventType::MESSAGE: {
			int peer_id = allocate_peer_id(p_event.participant_id);

			IncomingPacket packet;
			packet.from_peer = peer_id;
			packet.data = p_event.data;
			incoming_packets.push_back(packet);
		} break;

		case EventType::PARTICIPANT_JOINED: {
			int peer_id = allocate_peer_id(p_event.participant_id);
			emit_signal(SNAME("peer_connected"), peer_id);
		} break;

		case EventType::PARTICIPANT_LEFT: {
			const int *peer_id = participant_to_peer.getptr(p_event.participant_id);
			if (peer_id != nullptr) {
				int id = *peer_id;
				remove_peer_id(p_event.participant_id);
				emit_signal(SNAME("peer_disconnected"), id);
			}
		} break;

		case EventType::SESSION_STARTED: {
			connection_status = CONNECTION_CONNECTED;

			const char *local_id = godot_shareplay_get_local_participant_id();
			String local_id_str = local_id != nullptr ? String::utf8(local_id) : String();

			if (is_host) {
				participant_to_peer[local_id_str] = HOST_PEER_ID;
				peer_to_participant[HOST_PEER_ID] = local_id_str;
				unique_id = HOST_PEER_ID;
			} else {
				unique_id = allocate_peer_id(local_id_str);
			}
		} break;

		case EventType::SESSION_ENDED: {
			connection_status = CONNECTION_DISCONNECTED;
		} break;
	}
}

void SharePlayMultiplayerPeer::_push_event(Event &&p_event) {
	MutexLock lock(event_mutex);
	pending_events.push_back(p_event);
}

void SharePlayMultiplayerPeer::close() {
	clear_session_callbacks();

	{
		MutexLock lock(event_mutex);
		pending_events.clear();
	}

	incoming_packets.clear();
	current_packet = IncomingPacket();
	has_current_packet = false;

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

int SharePlayMultiplayerPeer::get_available_packet_count() const {
	return incoming_packets.size();
}

Error SharePlayMultiplayerPeer::get_packet(const uint8_t **r_buffer, int &r_buffer_size) {
	if (incoming_packets.is_empty()) {
		r_buffer_size = 0;
		return ERR_UNAVAILABLE;
	}

	// Hold the packet alive until the next call so get_packet_peer() keeps reporting
	// the sender of the packet the caller is currently looking at.
	current_packet = incoming_packets.front()->get();
	incoming_packets.pop_front();
	has_current_packet = true;

	*r_buffer = current_packet.data.ptr();
	r_buffer_size = current_packet.data.size();

	return OK;
}

Error SharePlayMultiplayerPeer::put_packet(const uint8_t *p_buffer, int p_buffer_size) {
	ERR_FAIL_COND_V_MSG(connection_status != CONNECTION_CONNECTED, ERR_UNCONFIGURED, "The SharePlay session is not connected.");

	if (target_peer == TARGET_PEER_BROADCAST) {
		godot_shareplay_send_message(p_buffer, p_buffer_size, nullptr);
	} else if (target_peer < 0) {
		// Broadcast, excluding one peer.
		int exclude_peer = -target_peer;
		for (const KeyValue<int, String> &kv : peer_to_participant) {
			if (kv.key != exclude_peer && kv.key != unique_id) {
				godot_shareplay_send_message(p_buffer, p_buffer_size, kv.value.utf8().get_data());
			}
		}
	} else {
		int destination = (target_peer == TARGET_PEER_SERVER) ? HOST_PEER_ID : target_peer;
		String participant = get_participant_for_peer(destination);
		if (participant.is_empty()) {
			return ERR_INVALID_PARAMETER;
		}
		godot_shareplay_send_message(p_buffer, p_buffer_size, participant.utf8().get_data());
	}

	return OK;
}

int SharePlayMultiplayerPeer::get_max_packet_size() const {
	return 1 << 20; // 1 MiB.
}

int SharePlayMultiplayerPeer::allocate_peer_id(const String &p_participant_id) {
	const int *existing = participant_to_peer.getptr(p_participant_id);
	if (existing != nullptr) {
		return *existing;
	}

	int new_id = generate_unique_id();
	while (new_id == 0 || new_id == HOST_PEER_ID || peer_to_participant.has(new_id)) {
		new_id = generate_unique_id();
	}

	participant_to_peer[p_participant_id] = new_id;
	peer_to_participant[new_id] = p_participant_id;
	return new_id;
}

void SharePlayMultiplayerPeer::remove_peer_id(const String &p_participant_id) {
	const int *peer_id = participant_to_peer.getptr(p_participant_id);
	if (peer_id != nullptr) {
		peer_to_participant.erase(*peer_id);
	}
	participant_to_peer.erase(p_participant_id);
}

String SharePlayMultiplayerPeer::get_participant_for_peer(int p_peer_id) const {
	const String *participant = peer_to_participant.getptr(p_peer_id);
	return participant != nullptr ? *participant : String();
}

// Callbacks below run on the SharePlay dispatch queue; they only enqueue work.

void SharePlayMultiplayerPeer::_on_message_received(const uint8_t *p_data, int p_size, const String &p_sender_id) {
	Event event;
	event.type = EventType::MESSAGE;
	event.participant_id = p_sender_id;
	event.data.resize(p_size);
	memcpy(event.data.ptrw(), p_data, p_size);
	_push_event(std::move(event));
}

void SharePlayMultiplayerPeer::_on_participant_joined(const String &p_participant_id) {
	Event event;
	event.type = EventType::PARTICIPANT_JOINED;
	event.participant_id = p_participant_id;
	_push_event(std::move(event));
}

void SharePlayMultiplayerPeer::_on_participant_left(const String &p_participant_id) {
	Event event;
	event.type = EventType::PARTICIPANT_LEFT;
	event.participant_id = p_participant_id;
	_push_event(std::move(event));
}

void SharePlayMultiplayerPeer::_on_session_started() {
	Event event;
	event.type = EventType::SESSION_STARTED;
	_push_event(std::move(event));
}

void SharePlayMultiplayerPeer::_on_session_ended() {
	Event event;
	event.type = EventType::SESSION_ENDED;
	_push_event(std::move(event));
}

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
