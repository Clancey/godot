/**************************************************************************/
/*  SharePlayBridge.swift                                                 */
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

import Foundation

// C-callable bridge functions that forward to SharePlaySessionManager.
// These are used by the Godot SharePlayMultiplayerPeer (.mm) to avoid
// needing the generated -Swift.h header in the Scons build system.

// MARK: - Stored C callbacks

private var messageCallback: godot_shareplay_message_callback_t?
private var messageCallbackUserdata: UnsafeMutableRawPointer?

private var participantJoinedCallback: godot_shareplay_participant_callback_t?
private var participantJoinedCallbackUserdata: UnsafeMutableRawPointer?

private var participantLeftCallback: godot_shareplay_participant_callback_t?
private var participantLeftCallbackUserdata: UnsafeMutableRawPointer?

private var sessionStartedCallback: godot_shareplay_session_callback_t?
private var sessionStartedCallbackUserdata: UnsafeMutableRawPointer?

private var sessionEndedCallback: godot_shareplay_session_callback_t?
private var sessionEndedCallbackUserdata: UnsafeMutableRawPointer?

// MARK: - Session Lifecycle

@_cdecl("godot_shareplay_set_activity_title")
func godot_shareplay_set_activity_title(_ title: UnsafePointer<CChar>?) {
    guard let title = title else { return }
    SharePlaySessionManager.shared.activityTitle = String(cString: title)
}

@_cdecl("godot_shareplay_start_activity")
func godot_shareplay_start_activity() {
    // Wire up callbacks from SessionManager to our stored C function pointers.
    let mgr = SharePlaySessionManager.shared

    mgr.onMessageReceived = { data, senderID in
        guard let cb = messageCallback else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            senderID.withCString { senderCStr in
                cb(ptr, Int32(buffer.count), senderCStr, messageCallbackUserdata)
            }
        }
    }

    mgr.onParticipantJoined = { participantID in
        guard let cb = participantJoinedCallback else { return }
        participantID.withCString { cStr in
            cb(cStr, participantJoinedCallbackUserdata)
        }
    }

    mgr.onParticipantLeft = { participantID in
        guard let cb = participantLeftCallback else { return }
        participantID.withCString { cStr in
            cb(cStr, participantLeftCallbackUserdata)
        }
    }

    mgr.onSessionStarted = {
        sessionStartedCallback?(sessionStartedCallbackUserdata)
    }

    mgr.onSessionEnded = {
        sessionEndedCallback?(sessionEndedCallbackUserdata)
    }

    mgr.startActivity()
}

@_cdecl("godot_shareplay_end_activity")
func godot_shareplay_end_activity() {
    SharePlaySessionManager.shared.endActivity()
}

// MARK: - State Queries

@_cdecl("godot_shareplay_is_session_active")
func godot_shareplay_is_session_active() -> Bool {
    return SharePlaySessionManager.shared.isSessionActive
}

// Note: Returns a pointer to a static buffer. Not thread-safe for concurrent reads.
private var localParticipantIDBuffer: [CChar] = []

@_cdecl("godot_shareplay_get_local_participant_id")
func godot_shareplay_get_local_participant_id() -> UnsafePointer<CChar>? {
    let idStr = SharePlaySessionManager.shared.localParticipantID
    localParticipantIDBuffer = Array(idStr.utf8CString)
    return localParticipantIDBuffer.withUnsafeBufferPointer { $0.baseAddress }
}

@_cdecl("godot_shareplay_get_participant_count")
func godot_shareplay_get_participant_count() -> Int32 {
    return Int32(SharePlaySessionManager.shared.participantCount)
}

// MARK: - Messaging

@_cdecl("godot_shareplay_send_message")
func godot_shareplay_send_message(_ data: UnsafePointer<UInt8>?, _ length: Int32, _ recipientID: UnsafePointer<CChar>?) {
    guard let data = data, length > 0 else { return }

    let nsData = Data(bytes: data, count: Int(length))
    let recipient: String? = recipientID != nil ? String(cString: recipientID!) : nil

    if let recipient = recipient {
        SharePlaySessionManager.shared.sendMessage(nsData, toParticipantID: recipient)
    } else {
        SharePlaySessionManager.shared.sendMessage(nsData, toParticipantID: nil)
    }
}

// MARK: - Callback Registration

@_cdecl("godot_shareplay_set_message_callback")
func godot_shareplay_set_message_callback(_ callback: godot_shareplay_message_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    messageCallback = callback
    messageCallbackUserdata = userdata
}

@_cdecl("godot_shareplay_set_participant_joined_callback")
func godot_shareplay_set_participant_joined_callback(_ callback: godot_shareplay_participant_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    participantJoinedCallback = callback
    participantJoinedCallbackUserdata = userdata
}

@_cdecl("godot_shareplay_set_participant_left_callback")
func godot_shareplay_set_participant_left_callback(_ callback: godot_shareplay_participant_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    participantLeftCallback = callback
    participantLeftCallbackUserdata = userdata
}

@_cdecl("godot_shareplay_set_session_started_callback")
func godot_shareplay_set_session_started_callback(_ callback: godot_shareplay_session_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    sessionStartedCallback = callback
    sessionStartedCallbackUserdata = userdata
}

@_cdecl("godot_shareplay_set_session_ended_callback")
func godot_shareplay_set_session_ended_callback(_ callback: godot_shareplay_session_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    sessionEndedCallback = callback
    sessionEndedCallbackUserdata = userdata
}
