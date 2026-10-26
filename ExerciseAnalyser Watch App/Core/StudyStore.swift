import Foundation

enum StudyStoreError: LocalizedError {
    case unsupportedSchema
    case invalidResponse
    case expiredPrompt

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "The saved study data uses an unsupported version. It has not been overwritten."
        case .invalidResponse: "This invitation is no longer available."
        case .expiredPrompt: "This invitation has expired. Check for a fresh opportunity."
        }
    }
}

// All callers serialize mutations on the main actor in the watch app.
// Write-before-publish ensures a failed save cannot silently lose a response.
final class StudyStore {
    private(set) var state: StudyState
    let url: URL
    var sessionID: UUID?
    private var mutationVersion = 0
    private var journalURL: URL { url.appendingPathExtension("events.jsonl") }

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try Self.decoder.decode(StudyState.self, from: Data(contentsOf: url))
            guard state.schemaVersion == 1 else { throw StudyStoreError.unsupportedSchema }
        } else {
            state = StudyState()
        }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let data = try Data(contentsOf: journalURL)
            var validLength = 0
            // Only a final partial line can be an interrupted append. Complete malformed records fail closed.
            for line in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
                let event = try Self.decoder.decode(StudyEvent.self, from: Data(line))
                guard let sequence = event.sequence, sequence > 0, event.participantID == state.participantID else { throw StudyStoreError.unsupportedSchema }
                if sequence > state.events.count {
                    guard sequence == state.events.count + 1 else {
                        throw StudyStoreError.unsupportedSchema
                    }
                    if let session = event.exerciseSession {
                        guard let index = state.prompts.firstIndex(where: { $0.id == event.promptID }) else {
                            throw StudyStoreError.unsupportedSchema
                        }
                        state.prompts[index].exerciseSession = session
                    }
                    state.events.append(event)
        mutationVersion += 1
                }
                validLength += line.count + 1
            }
            if validLength < data.count {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(validLength))
            }
        }
    }

    func appendEvent(_ original: StudyEvent) throws {
        let promptIndex = state.prompts.firstIndex(where: { $0.id == original.promptID })
        if original.exerciseSession != nil, promptIndex == nil { throw StudyStoreError.invalidResponse }
        // Establish the installation identity before the first journal entry.
        if !FileManager.default.fileExists(atPath: url.path) { try transaction { _ in } }
        var event = original
        event.sequence = state.events.count + 1
        event.participantID = state.participantID
        if event.sessionID == nil { event.sessionID = sessionID }
        if event.settings == nil { event.settings = state.settings }
        var data = try Self.encoder.encode(event)
        data.append(10)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            #if os(watchOS) || os(iOS)
            try Data().write(to: journalURL, options: .completeFileProtectionUntilFirstUserAuthentication)
            #else
            try Data().write(to: journalURL)
            #endif
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do { try handle.write(contentsOf: data) }
        catch { try? handle.truncate(atOffset: offset); throw error }
        state.events.append(event)
        mutationVersion += 1
        if let session = event.exerciseSession, let promptIndex {
            state.prompts[promptIndex].exerciseSession = session
        }
    }

    func saveSession(_ session: ExerciseSession, promptID: UUID, kind: String, at date: Date = Date()) throws {
        guard let prompt = state.prompts.first(where: { $0.id == promptID }) else { throw StudyStoreError.invalidResponse }
        // Timer transitions append one durable record instead of encoding the entire study history.
        // Replay restores the session and event together; failed writes publish neither.
        try appendEvent(.init(date: date, kind: kind, promptID: promptID,
                              exerciseID: prompt.selectedExerciseID, source: "timer", exerciseSession: session))
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = try? fractional.parse(value) { return date }
            guard let date = try? wholeSeconds.parse(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
            }
            return date
        }
        return decoder
    }

    func transaction(_ change: (inout StudyState) throws -> Void) throws {
        var next = state
        try change(&next)
        for index in state.events.count..<next.events.count {
            next.events[index].sequence = index + 1
            next.events[index].participantID = next.participantID
            if next.events[index].sessionID == nil { next.events[index].sessionID = sessionID }
            if next.events[index].settings == nil { next.events[index].settings = next.settings }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(next)
        #if os(watchOS) || os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        state = next
        mutationVersion += 1
        // The snapshot is committed first. Replay skips its sequence numbers if cleanup is interrupted.
        // Remove atomically instead of truncating a file that could contain a partially written line.
        try? FileManager.default.removeItem(at: journalURL)
    }

    @MainActor
    func appendManualPrompt(_ prompt: ExercisePrompt) async throws {
        // Prepare a complete durable snapshot off the UI executor. If another callback
        // changes the store while suspended, retry against its latest state.
        while true {
            try Task.checkCancellation()
            let version = mutationVersion
            var next = state
            next.prompts.append(prompt)
            var event = StudyEvent(date: prompt.createdAt, kind: "manual_intervention", promptID: prompt.id, source: "app")
            event.sequence = next.events.count + 1
            event.participantID = next.participantID
            event.sessionID = sessionID
            event.settings = next.settings
            next.events.append(event)
            let temporaryURL = try await Self.prepareSnapshot(next, beside: url)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try Task.checkCancellation()
            guard version == mutationVersion else { continue }
            // Only the atomic rename and publication happen on the main actor.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            state = next
            mutationVersion += 1
            try? FileManager.default.removeItem(at: journalURL)
            return
        }
    }

    @concurrent
    nonisolated private static func prepareSnapshot(_ state: StudyState, beside url: URL) async throws -> URL {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pending")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            #if os(watchOS) || os(iOS)
            try data.write(to: temporaryURL, options: .completeFileProtectionUntilFirstUserAuthentication)
            #else
            try data.write(to: temporaryURL)
            #endif
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    @discardableResult
    func respond(promptID: UUID, exerciseID: String?, source: String, at now: Date) throws -> Bool {
        guard let index = state.prompts.firstIndex(where: { $0.id == promptID }) else { throw StudyStoreError.invalidResponse }
        let prompt = state.prompts[index]
        guard [.scheduled, .prepared].contains(prompt.status) else {
            try transaction { state in
                state.events.append(.init(date: now, kind: "response_ignored", promptID: promptID, exerciseID: exerciseID,
                                          source: source, detail: "Invitation already has status \(prompt.status.rawValue)."))
            }
            return false
        }
        guard prompt.expiresAt > now else { throw StudyStoreError.expiredPrompt }
        guard (prompt.snoozedUntil ?? prompt.plannedFor ?? prompt.createdAt) <= now else { throw StudyStoreError.invalidResponse }
        if let exerciseID, !prompt.options.contains(where: { $0.id == exerciseID }) { throw StudyStoreError.invalidResponse }
        try transaction { state in
            if source == "notification", state.prompts[index].scheduledAt == nil {
                state.prompts[index].scheduledAt = prompt.createdAt
                state.events.append(.init(date: now, kind: "schedule_evidence_from_response", promptID: promptID, source: source,
                                          detail: "Response proves the request existed. Original scheduling timestamp was not saved; createdAt is used as a proxy."))
            }
            state.prompts[index].status = exerciseID == nil ? .dismissed : .selected
            state.prompts[index].selectedExerciseID = exerciseID
            state.prompts[index].respondedAt = now
            state.events.append(.init(date: now, kind: exerciseID == nil ? "dismissed" : "selected", promptID: promptID,
                                      exerciseID: exerciseID, source: source))
        }
        return true
    }

    func reselect(promptID: UUID, exerciseID: String, at now: Date) throws {
        guard let index = state.prompts.firstIndex(where: { $0.id == promptID }),
              state.prompts[index].isActive(at: now),
              state.prompts[index].options.contains(where: { $0.id == exerciseID }) else { throw StudyStoreError.invalidResponse }
        try transaction { state in
            let previous = state.prompts[index].selectedExerciseID
            state.prompts[index].selectedExerciseID = exerciseID
            state.prompts[index].exerciseSession = nil
            state.prompts[index].respondedAt = now
            // An explicit new selection starts a new window; simply reopening does not.
            state.events.append(.init(date: now, kind: "exercise_reselected", promptID: promptID, exerciseID: exerciseID,
                                      source: "app", attributes: ["previousExerciseID": previous ?? ""]))
        }
    }

    func expire(at now: Date) throws {
        guard state.prompts.contains(where: { ([.scheduled, .prepared].contains($0.status) && $0.expiresAt <= now) || $0.shouldIgnore(at: now) }) else { return }
        try transaction { state in
            for index in state.prompts.indices where state.prompts[index].shouldIgnore(at: now) {
                state.prompts[index].status = state.prompts[index].isManual ? .cancelled : .ignored
                guard !state.prompts[index].isManual else { continue }
                state.events.append(.init(date: now, kind: "ignored_break", promptID: state.prompts[index].id,
                                          source: "reconciliation", detail: "Ten-minute feedback window elapsed without completion or abandonment.",
                                          attributes: ["ignoredAt": String(state.prompts[index].activeUntil.timeIntervalSince1970)]))
            }
            for index in state.prompts.indices where [.scheduled, .prepared].contains(state.prompts[index].status) && state.prompts[index].expiresAt <= now {
                let prompt = state.prompts[index]
                state.prompts[index].status = prompt.isManual ? .cancelled : (prompt.openedAt == nil ? .expired : .ignored)
                guard !prompt.isManual else { continue }
                state.events.append(.init(date: now, kind: prompt.openedAt == nil ? "expired_no_response" : "ignored_break", promptID: prompt.id, source: "reconciliation",
                                          detail: prompt.openedAt == nil ? "No response recorded before expiry; delivery is unknown." : "Opened invitation expired without a response."))
            }
        }
    }

    func leaveInvitation(promptID: UUID, at now: Date) throws {
        guard let index = state.prompts.firstIndex(where: { $0.id == promptID }),
              [.prepared, .scheduled, .selected].contains(state.prompts[index].status),
              state.prompts[index].completedAt == nil, state.prompts[index].abandonedAt == nil else { return }
        try transaction { state in
            let manual = state.prompts[index].isManual
            state.prompts[index].status = manual ? .cancelled : .ignored
            state.prompts[index].exerciseSession?.pause(at: now)
            if !manual {
                state.events.append(.init(date: now, kind: "ignored_break", promptID: promptID, source: "app",
                                          detail: "User confirmed leaving effort selection."))
            }
        }
    }

    func finish(promptID: UUID, completed: Bool, at now: Date, session: ExerciseSession? = nil) throws {
        guard let index = state.prompts.firstIndex(where: { $0.id == promptID }), state.prompts[index].status == .selected,
              state.prompts[index].completedAt == nil, state.prompts[index].abandonedAt == nil else { return }
        try transaction { state in
            if let session { state.prompts[index].exerciseSession = session }
            if completed { state.prompts[index].completedAt = now } else { state.prompts[index].abandonedAt = now }
            state.events.append(.init(date: now, kind: completed ? "completed_self_report" : "abandoned", promptID: promptID,
                                      exerciseID: state.prompts[index].selectedExerciseID, source: "app"))
        }
    }

    func export(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("exercise-study.json")
        let csv = directory.appendingPathComponent("exercise-choices.csv")
        try Self.encoder.encode(state).write(to: json, options: .atomic)
        let header = "participant_id,prompt_id,created_at,policy,method,method_probability,slate_assignment_probability,randomization_seed,effort,exercise_id,option_probability,selected,status,responded_at,completed_at,abandoned_at,opportunity_score,response_latency_seconds,planned_for,delivery_reason,notification_requested_at,cancelled_at"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows = [header]
        for prompt in state.prompts {
            for option in prompt.options {
                let values = [state.participantID.uuidString, prompt.id.uuidString, formatter.string(from: prompt.createdAt),
                              prompt.policyVersion, option.method.rawValue, String(prompt.methodProbability), String(prompt.slateAssignmentProbability),
                              prompt.randomizationSeed ?? "", option.exercise.effort.rawValue,
                              option.id, String(option.selectionProbability), String(prompt.selectedExerciseID == option.id), prompt.status.rawValue,
                              prompt.respondedAt.map(formatter.string) ?? "", prompt.completedAt.map(formatter.string) ?? "",
                              prompt.abandonedAt.map(formatter.string) ?? "", String(prompt.decision.score),
                              prompt.respondedAt.map { String($0.timeIntervalSince(prompt.notificationDate ?? prompt.createdAt)) } ?? "",
                              prompt.plannedFor.map(formatter.string) ?? "", prompt.deliveryReason ?? "immediate_opportunity",
                              prompt.scheduledAt.map(formatter.string) ?? "", prompt.cancelledAt.map(formatter.string) ?? ""]
                rows.append(values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
        let eventsURL = directory.appendingPathComponent("exercise-events.jsonl")
        let eventLines = try state.events.map { event in
            String(decoding: try Self.encoder.encode(event), as: UTF8.self)
        }.joined(separator: "\n")
        try (eventLines + (eventLines.isEmpty ? "" : "\n")).write(to: eventsURL, atomically: true, encoding: .utf8)
        return [json, csv, eventsURL]
    }
}
