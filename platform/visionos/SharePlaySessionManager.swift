/**************************************************************************/
/*  SharePlaySessionManager.swift                                       */
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

import Combine
import Foundation
import GroupActivities

/// Manages the SharePlay GroupActivity session lifecycle and messaging.
///
/// This type is only consumed from Swift; `SharePlayBridge.swift` exposes the
/// pieces Godot needs through plain C entry points.
final class SharePlaySessionManager: @unchecked Sendable {
    static let shared = SharePlaySessionManager()

    // MARK: - Public state

    var activityTitle: String = "Shared Space"
    private(set) var isSessionActive: Bool = false
    private(set) var localParticipantID: String = ""
    private(set) var participantCount: Int = 0

    // MARK: - Callbacks, invoked on `queue`

    var onMessageReceived: ((Data, String) -> Void)?
    var onParticipantJoined: ((String) -> Void)?
    var onParticipantLeft: ((String) -> Void)?
    var onSessionStarted: (() -> Void)?
    var onSessionEnded: (() -> Void)?

    // MARK: - Private state

    private var groupSession: GroupSession<GodotGroupActivity>?
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    private var activationTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var participantIDs: [Participant.ID: String] = [:]
    private let queue = DispatchQueue(label: "org.godotengine.shareplay", qos: .userInteractive)

    // MARK: - Session lifecycle

    func startActivity() {
        activationTask = Task {
            do {
                _ = try await GodotGroupActivity().activate()
            } catch {
                print("visionOS SharePlay: Failed to activate group activity: \(error)")
            }
        }

        // Observe incoming sessions, including ones started by another participant.
        sessionsTask = Task { [weak self] in
            for await session in GodotGroupActivity.sessions() {
                await self?.configureSession(session)
            }
        }
    }

    func endActivity() {
        groupSession?.end()
        cleanup()
    }

    func sendMessage(_ data: Data, toParticipantID participantID: String?) {
        guard let messenger, let session = groupSession else {
            return
        }

        let message = GodotSharePlayMessage(senderID: localParticipantID, payload: data)

        Task {
            do {
                if let participantID {
                    let target = session.activeParticipants.first { participantIDs[$0.id] == participantID }
                    if let target {
                        try await messenger.send(message, to: .only(target))
                    }
                } else {
                    try await messenger.send(message)
                }
            } catch {
                print("visionOS SharePlay: Failed to send message: \(error)")
            }
        }
    }

    // MARK: - Session configuration

    @MainActor
    private func configureSession(_ session: GroupSession<GodotGroupActivity>) {
        // Drop any previous session before adopting the new one.
        cleanup()

        groupSession = session
        let sessionMessenger = GroupSessionMessenger(session: session)
        messenger = sessionMessenger

        localParticipantID = session.localParticipant.id.description
        participantIDs[session.localParticipant.id] = localParticipantID

        session.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .joined:
                    self.queue.async {
                        self.isSessionActive = true
                        self.onSessionStarted?()
                    }
                case .invalidated:
                    self.queue.async {
                        self.cleanup()
                    }
                default:
                    break
                }
            }
            .store(in: &subscriptions)

        session.$activeParticipants
            .sink { [weak self] participants in
                guard let self else { return }
                self.queue.async {
                    self.handleParticipantChange(participants)
                }
            }
            .store(in: &subscriptions)

        messageTask = Task { [weak self] in
            for await (message, _) in sessionMessenger.messages(of: GodotSharePlayMessage.self) {
                guard let self else { return }
                self.queue.async {
                    self.onMessageReceived?(message.payload, message.senderID)
                }
            }
        }

        session.join()
    }

    private func handleParticipantChange(_ participants: Set<Participant>) {
        let knownIDs = Set(participantIDs.keys)
        let currentIDs = Set(participants.map(\.id))

        for participant in participants where !knownIDs.contains(participant.id) {
            let idString = participant.id.description
            participantIDs[participant.id] = idString
            onParticipantJoined?(idString)
        }

        for knownID in knownIDs where !currentIDs.contains(knownID) {
            if let idString = participantIDs[knownID] {
                onParticipantLeft?(idString)
            }
            participantIDs.removeValue(forKey: knownID)
        }

        participantCount = participants.count
    }

    private func cleanup() {
        messageTask?.cancel()
        messageTask = nil
        sessionsTask?.cancel()
        sessionsTask = nil
        activationTask?.cancel()
        activationTask = nil
        subscriptions.removeAll()
        messenger = nil
        groupSession = nil
        participantIDs.removeAll()

        let wasActive = isSessionActive
        isSessionActive = false
        localParticipantID = ""
        participantCount = 0

        if wasActive {
            onSessionEnded?()
        }
    }
}
