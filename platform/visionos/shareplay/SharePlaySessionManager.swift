/**************************************************************************/
/*  SharePlaySessionManager.swift                                         */
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
import GroupActivities
import Combine

/// Manages the SharePlay GroupActivity session lifecycle and messaging.
/// Exposed to ObjC/C++ via @objc for the Godot multiplayer peer bridge.
@objc class SharePlaySessionManager: NSObject, @unchecked Sendable {
    @objc static let shared = SharePlaySessionManager()

    // MARK: - Public State

    @objc var activityTitle: String = "Shared Space"
    @objc private(set) var isSessionActive: Bool = false
    @objc private(set) var localParticipantID: String = ""
    @objc private(set) var participantCount: Int = 0

    // MARK: - Callbacks (set from C++/ObjC side)

    @objc var onMessageReceived: ((Data, String) -> Void)?
    @objc var onParticipantJoined: ((String) -> Void)?
    @objc var onParticipantLeft: ((String) -> Void)?
    @objc var onSessionStarted: (() -> Void)?
    @objc var onSessionEnded: (() -> Void)?

    // MARK: - Private State

    private var groupSession: GroupSession<GodotGroupActivity>?
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    private var sessionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var participantIDs: [Participant.ID: String] = [:]
    private let queue = DispatchQueue(label: "org.godotengine.shareplay", qos: .userInteractive)

    // MARK: - Session Lifecycle

    @objc func startActivity() {
        sessionTask = Task {
            do {
                let activity = GodotGroupActivity()
                let activated = try await activity.activate()
                // The system handles activation; we observe sessions via prepareForActivation below.
                _ = activated
            } catch {
                print("visionOS SharePlay: Failed to activate group activity: \(error)")
            }
        }

        // Observe incoming sessions.
        Task {
            for await session in GodotGroupActivity.sessions() {
                await configureSession(session)
            }
        }
    }

    @objc func endActivity() {
        groupSession?.end()
        cleanup()
    }

    @objc func sendMessage(_ data: Data, toParticipantID participantID: String?) {
        guard let messenger = messenger, let session = groupSession else {
            return
        }

        let message = GodotSharePlayMessage(senderID: localParticipantID, payload: data)

        Task {
            do {
                if let targetID = participantID {
                    // Send to specific participant.
                    let targetParticipant = session.activeParticipants.first { p in
                        participantIDs[p.id] == targetID
                    }
                    if let target = targetParticipant {
                        try await messenger.send(message, to: .only(target))
                    }
                } else {
                    // Broadcast to all.
                    try await messenger.send(message)
                }
            } catch {
                print("visionOS SharePlay: Failed to send message: \(error)")
            }
        }
    }

    @objc func getParticipantIDs() -> [String] {
        return Array(participantIDs.values)
    }

    // MARK: - Session Configuration

    @MainActor
    private func configureSession(_ session: GroupSession<GodotGroupActivity>) {
        // Clean up any previous session.
        cleanup()

        groupSession = session
        messenger = GroupSessionMessenger(session: session)

        // Generate local participant ID.
        localParticipantID = session.localParticipant.id.description

        // Track participant IDs.
        participantIDs[session.localParticipant.id] = localParticipantID

        // Observe session state.
        session.$state
            .sink { [weak self] state in
                guard let self = self else { return }
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

        // Observe participants.
        session.$activeParticipants
            .sink { [weak self] participants in
                guard let self = self else { return }
                self.queue.async {
                    self.handleParticipantChange(participants)
                }
            }
            .store(in: &subscriptions)

        // Start receiving messages.
        messageTask = Task {
            guard let messenger = self.messenger else { return }
            do {
                for try await (message, _) in messenger.messages(of: GodotSharePlayMessage.self) {
                    self.queue.async {
                        self.onMessageReceived?(message.payload, message.senderID)
                    }
                }
            } catch {
                print("visionOS SharePlay: Message receiving ended: \(error)")
            }
        }

        // Join the session.
        session.join()
    }

    private func handleParticipantChange(_ participants: Set<Participant>) {
        let currentIDs = Set(participantIDs.keys)
        let newParticipantKeys = Set(participants.map { $0.id })

        // Detect joined participants.
        for participant in participants {
            if !currentIDs.contains(participant.id) {
                let idStr = participant.id.description
                participantIDs[participant.id] = idStr
                onParticipantJoined?(idStr)
            }
        }

        // Detect left participants.
        for existingID in currentIDs {
            if !newParticipantKeys.contains(existingID) {
                if let idStr = participantIDs[existingID] {
                    onParticipantLeft?(idStr)
                }
                participantIDs.removeValue(forKey: existingID)
            }
        }

        participantCount = participants.count
    }

    private func cleanup() {
        messageTask?.cancel()
        messageTask = nil
        sessionTask?.cancel()
        sessionTask = nil
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
