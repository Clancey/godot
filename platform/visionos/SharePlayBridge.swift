/**************************************************************************/
/*  SharePlayBridge.swift                                               */
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

// C-callable bridge forwarding to `SharePlaySessionManager`.
//
// `SharePlayMultiplayerPeer` (Objective-C++) calls these through
// `shareplay_bridge.h`, which avoids needing the generated `-Swift.h` header in
// the SCons build. The matching C function *declarations* deliberately live in a
// header that is not part of the Swift bridging header, so these `@_cdecl`
// definitions do not collide with an imported declaration of the same name.

/// Lock-guarded storage for the callbacks registered by the Godot side.
///
/// Callbacks are registered from the main thread but invoked on the SharePlay
/// dispatch queue, so every access goes through a lock.
private final class SharePlayCallbacks: @unchecked Sendable {
    static let shared = SharePlayCallbacks()

    private let lock = NSLock()

    private var message: godot_shareplay_message_callback_t?
    private var messageUserdata: UnsafeMutableRawPointer?
    private var participantJoined: godot_shareplay_participant_callback_t?
    private var participantJoinedUserdata: UnsafeMutableRawPointer?
    private var participantLeft: godot_shareplay_participant_callback_t?
    private var participantLeftUserdata: UnsafeMutableRawPointer?
    private var sessionStarted: godot_shareplay_session_callback_t?
    private var sessionStartedUserdata: UnsafeMutableRawPointer?
    private var sessionEnded: godot_shareplay_session_callback_t?
    private var sessionEndedUserdata: UnsafeMutableRawPointer?

    /// Backing storage for the string returned by `godot_shareplay_get_local_participant_id`.
    /// It stays valid until the next call, which is all the caller needs.
    private var localParticipantIDBuffer: UnsafeMutablePointer<CChar>?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setMessage(_ callback: godot_shareplay_message_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
        withLock {
            message = callback
            messageUserdata = userdata
        }
    }

    func setParticipantJoined(_ callback: godot_shareplay_participant_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
        withLock {
            participantJoined = callback
            participantJoinedUserdata = userdata
        }
    }

    func setParticipantLeft(_ callback: godot_shareplay_participant_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
        withLock {
            participantLeft = callback
            participantLeftUserdata = userdata
        }
    }

    func setSessionStarted(_ callback: godot_shareplay_session_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
        withLock {
            sessionStarted = callback
            sessionStartedUserdata = userdata
        }
    }

    func setSessionEnded(_ callback: godot_shareplay_session_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
        withLock {
            sessionEnded = callback
            sessionEndedUserdata = userdata
        }
    }

    func invokeMessage(_ data: Data, _ senderID: String) {
        guard let (callback, userdata) = withLock({ message.map { ($0, messageUserdata) } }) else { return }
        data.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            senderID.withCString { senderCString in
                callback(pointer, Int32(buffer.count), senderCString, userdata)
            }
        }
    }

    func invokeParticipantJoined(_ participantID: String) {
        guard let (callback, userdata) = withLock({ participantJoined.map { ($0, participantJoinedUserdata) } }) else { return }
        participantID.withCString { callback($0, userdata) }
    }

    func invokeParticipantLeft(_ participantID: String) {
        guard let (callback, userdata) = withLock({ participantLeft.map { ($0, participantLeftUserdata) } }) else { return }
        participantID.withCString { callback($0, userdata) }
    }

    func invokeSessionStarted() {
        guard let (callback, userdata) = withLock({ sessionStarted.map { ($0, sessionStartedUserdata) } }) else { return }
        callback(userdata)
    }

    func invokeSessionEnded() {
        guard let (callback, userdata) = withLock({ sessionEnded.map { ($0, sessionEndedUserdata) } }) else { return }
        callback(userdata)
    }

    func cacheLocalParticipantID(_ value: String) -> UnsafePointer<CChar>? {
        withLock {
            if let existing = localParticipantIDBuffer {
                free(existing)
            }
            localParticipantIDBuffer = strdup(value)
            return UnsafePointer(localParticipantIDBuffer)
        }
    }
}

// MARK: - Session lifecycle

@_cdecl("godot_shareplay_set_activity_title")
func godot_shareplay_set_activity_title_impl(_ title: UnsafePointer<CChar>?) {
    guard let title else { return }
    SharePlaySessionManager.shared.activityTitle = String(cString: title)
}

@_cdecl("godot_shareplay_start_activity")
func godot_shareplay_start_activity_impl() {
    let manager = SharePlaySessionManager.shared
    let callbacks = SharePlayCallbacks.shared

    manager.onMessageReceived = { callbacks.invokeMessage($0, $1) }
    manager.onParticipantJoined = { callbacks.invokeParticipantJoined($0) }
    manager.onParticipantLeft = { callbacks.invokeParticipantLeft($0) }
    manager.onSessionStarted = { callbacks.invokeSessionStarted() }
    manager.onSessionEnded = { callbacks.invokeSessionEnded() }

    manager.startActivity()
}

@_cdecl("godot_shareplay_end_activity")
func godot_shareplay_end_activity_impl() {
    SharePlaySessionManager.shared.endActivity()
}

// MARK: - State queries

@_cdecl("godot_shareplay_is_session_active")
func godot_shareplay_is_session_active_impl() -> Bool {
    return SharePlaySessionManager.shared.isSessionActive
}

@_cdecl("godot_shareplay_get_local_participant_id")
func godot_shareplay_get_local_participant_id_impl() -> UnsafePointer<CChar>? {
    return SharePlayCallbacks.shared.cacheLocalParticipantID(SharePlaySessionManager.shared.localParticipantID)
}

@_cdecl("godot_shareplay_get_participant_count")
func godot_shareplay_get_participant_count_impl() -> Int32 {
    return Int32(SharePlaySessionManager.shared.participantCount)
}

// MARK: - Messaging

@_cdecl("godot_shareplay_send_message")
func godot_shareplay_send_message_impl(_ data: UnsafePointer<UInt8>?, _ length: Int32, _ recipientID: UnsafePointer<CChar>?) {
    guard let data, length > 0 else { return }

    let payload = Data(bytes: data, count: Int(length))
    let recipient = recipientID.map { String(cString: $0) }

    SharePlaySessionManager.shared.sendMessage(payload, toParticipantID: recipient)
}

// MARK: - Callback registration

@_cdecl("godot_shareplay_set_message_callback")
func godot_shareplay_set_message_callback_impl(_ callback: godot_shareplay_message_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    SharePlayCallbacks.shared.setMessage(callback, userdata)
}

@_cdecl("godot_shareplay_set_participant_joined_callback")
func godot_shareplay_set_participant_joined_callback_impl(_ callback: godot_shareplay_participant_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    SharePlayCallbacks.shared.setParticipantJoined(callback, userdata)
}

@_cdecl("godot_shareplay_set_participant_left_callback")
func godot_shareplay_set_participant_left_callback_impl(_ callback: godot_shareplay_participant_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    SharePlayCallbacks.shared.setParticipantLeft(callback, userdata)
}

@_cdecl("godot_shareplay_set_session_started_callback")
func godot_shareplay_set_session_started_callback_impl(_ callback: godot_shareplay_session_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    SharePlayCallbacks.shared.setSessionStarted(callback, userdata)
}

@_cdecl("godot_shareplay_set_session_ended_callback")
func godot_shareplay_set_session_ended_callback_impl(_ callback: godot_shareplay_session_callback_t?, _ userdata: UnsafeMutableRawPointer?) {
    SharePlayCallbacks.shared.setSessionEnded(callback, userdata)
}
