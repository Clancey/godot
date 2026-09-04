/**************************************************************************/
/*  shareplay_multiplayer_peer.h                                          */
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

#pragma once

#ifdef VISIONOS_ENABLED

#include "core/os/mutex.h"
#include "core/templates/hash_map.h"
#include "core/templates/list.h"
#include "scene/main/multiplayer_peer.h"

class SharePlayMultiplayerPeer : public MultiplayerPeer {
	GDCLASS(SharePlayMultiplayerPeer, MultiplayerPeer);

public:
	SharePlayMultiplayerPeer();
	~SharePlayMultiplayerPeer();

	// SharePlay-specific API.
	Error start_activity();
	void end_activity();

	void set_activity_title(const String &p_title);
	String get_activity_title() const;

	// MultiplayerPeer interface.
	virtual void set_target_peer(int p_peer_id) override;
	virtual int get_packet_peer() const override;
	virtual TransferMode get_packet_mode() const override;
	virtual int get_packet_channel() const override;
	virtual void disconnect_peer(int p_peer, bool p_force = false) override;
	virtual bool is_server() const override;
	virtual void poll() override;
	virtual void close() override;
	virtual int get_unique_id() const override;
	virtual ConnectionStatus get_connection_status() const override;

	// PacketPeer interface.
	virtual Error get_packet(const uint8_t **r_buffer, int &r_buffer_size) override;
	virtual Error put_packet(const uint8_t *p_buffer, int p_buffer_size) override;
	virtual int get_available_packet_count() const override;
	virtual int get_max_packet_size() const override;

protected:
	static void _bind_methods();

private:
	// The host is always peer 1, matching the rest of Godot's multiplayer stack.
	static constexpr int HOST_PEER_ID = 1;

	// Connection state. Main thread only.
	ConnectionStatus connection_status = CONNECTION_DISCONNECTED;
	int unique_id = 0;
	int target_peer = TARGET_PEER_BROADCAST;
	bool is_host = false;
	String activity_title = "Shared Space";

	// Maps SharePlay participant ID strings to Godot peer IDs. Main thread only,
	// mutated from poll() and the public API.
	HashMap<String, int> participant_to_peer;
	HashMap<int, String> peer_to_participant;

	int allocate_peer_id(const String &p_participant_id);
	void remove_peer_id(const String &p_participant_id);
	String get_participant_for_peer(int p_peer_id) const;

	// SharePlay delivers callbacks on its own dispatch queue, so incoming events are
	// buffered here and drained on the main thread in poll(). This keeps all peer
	// bookkeeping and signal emission single-threaded.
	enum class EventType {
		MESSAGE,
		PARTICIPANT_JOINED,
		PARTICIPANT_LEFT,
		SESSION_STARTED,
		SESSION_ENDED,
	};

	struct Event {
		EventType type = EventType::MESSAGE;
		String participant_id;
		Vector<uint8_t> data;
	};

	struct IncomingPacket {
		int from_peer = 0;
		Vector<uint8_t> data;
	};

	Mutex event_mutex;
	List<Event> pending_events;

	// Packets ready for the multiplayer API. Main thread only.
	List<IncomingPacket> incoming_packets;
	IncomingPacket current_packet;
	bool has_current_packet = false;

	void setup_session_callbacks();
	void clear_session_callbacks();

	void _process_event(const Event &p_event);
	void _push_event(Event &&p_event);

public:
	// C bridge callbacks, invoked from the SharePlay dispatch queue.
	void _on_message_received(const uint8_t *p_data, int p_size, const String &p_sender_id);
	void _on_participant_joined(const String &p_participant_id);
	void _on_participant_left(const String &p_participant_id);
	void _on_session_started();
	void _on_session_ended();
};

#endif // VISIONOS_ENABLED
