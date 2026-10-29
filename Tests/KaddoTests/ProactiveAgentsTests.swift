import XCTest
@testable import Kaddo

@MainActor final class ProactiveAgentsTests: XCTestCase {
    func testDamagedSettingsPauseDiscoveryPreserveBytesAndRecoverOptOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs"), autoStart: false, executor: { _, _ in "unused" })
        let url = folder.appendingPathComponent("suggestions.json")
        var captures = 0; var generations = 0
        func makeController() -> ProactiveAgentsController {
            ProactiveAgentsController(model: model, jobs: jobs, screenContext: { captures += 1; return "screen" },
                onStart: { _ in false }, storageURL: url,
                generator: { _ in generations += 1; return "{\"suggestions\":[]}" }, presentsWindow: false)
        }
        let original = makeController()
        XCTAssertFalse(original.settingsLoadFailed)
        original.useScreenContext = false
        let validData = try Data(contentsOf: url)
        let damaged = Data("{\"enabled\":false,\"useScreenContext\":false,".utf8)
        try damaged.write(to: url)
        let paused = makeController()
        XCTAssertTrue(paused.settingsLoadFailed)
        XCTAssertFalse(paused.enabled); XCTAssertFalse(paused.useScreenContext)
        // Even programmatic preference changes cannot overwrite or bypass a failed load.
        paused.enabled = true; paused.useScreenContext = true
        await paused.checkNow()
        XCTAssertEqual(captures, 0); XCTAssertEqual(generations, 0)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        paused.reloadSettings()
        XCTAssertTrue(paused.settingsLoadFailed)
        try validData.write(to: url)
        paused.reloadSettings()
        XCTAssertFalse(paused.settingsLoadFailed)
        XCTAssertFalse(paused.useScreenContext)
        await paused.checkNow()
        XCTAssertEqual(captures, 0); XCTAssertEqual(generations, 1)
        paused.stop(); original.stop(); jobs.shutdown()
    }

    func testUnreadableSettingsPathIsPreservedWithoutDiscovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("suggestions.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let marker = url.appendingPathComponent("original")
        try Data("preserve".utf8).write(to: marker)
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs"), autoStart: false, executor: { _, _ in "unused" })
        let controller = ProactiveAgentsController(model: model, jobs: jobs,
            screenContext: { XCTFail("Failed settings must not capture"); return "" }, onStart: { _ in false }, storageURL: url,
            generator: { _ in XCTFail("Failed settings must not generate"); return "" }, presentsWindow: false)
        XCTAssertTrue(controller.settingsLoadFailed)
        await controller.checkNow()
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
        controller.stop(); jobs.shutdown()
    }

    func testContextIsBoundedAndScreenFailureFallsBackToHistoryOnly() throws {
        var helper = HelperProfile(name: "Research", instructions: String(repeating: "i", count: 1_000))
        helper.characterSeed = 1
        let conversation = Conversation(
            title: "Recent work",
            messages: [ChatMessage(role: "user", content: String(repeating: "c", count: 1_000))],
            updatedAt: Date(timeIntervalSince1970: 100),
            helperID: helper.id
        )

        let withScreen = ProactiveAgentsPolicy.contextSnapshot(
            helpers: [helper], conversations: [conversation],
            screenText: String(repeating: "s", count: 3_000), includeScreen: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(withScreen.json.utf8)) as? [String: Any])
        let helperRows = try XCTUnwrap(json["helpers"] as? [[String: String]])
        let chatRows = try XCTUnwrap(json["recent_chat_snippets"] as? [[String: String]])
        let screen = try XCTUnwrap(json["current_screen_text"] as? String)
        XCTAssertEqual(helperRows.first?["instructions"]?.count, ProactiveAgentsPolicy.maximumHelperInstructionCharacters)
        XCTAssertEqual(chatRows.first?["text"]?.count, ProactiveAgentsPolicy.maximumSnippetCharacters)
        XCTAssertEqual(screen.count, ProactiveAgentsPolicy.maximumScreenCharacters)

        let captureFailure = ProactiveAgentsPolicy.contextSnapshot(
            helpers: [helper], conversations: [conversation],
            screenText: "Screen context unavailable. Use recent conversation context only.", includeScreen: true
        )
        let failedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(captureFailure.json.utf8)) as? [String: Any])
        XCTAssertNil(failedJSON["current_screen_text"])

        let disabled = ProactiveAgentsPolicy.contextSnapshot(
            helpers: [helper], conversations: [conversation], screenText: "visible", includeScreen: false
        )
        let disabledJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(disabled.json.utf8)) as? [String: Any])
        XCTAssertNil(disabledJSON["current_screen_text"])
    }

    func testFingerprintChangesOnlyWhenContextChanges() {
        let helper = HelperProfile(name: "Writer", instructions: "Help with writing.")
        let firstConversation = Conversation(
            title: "Draft",
            messages: [ChatMessage(role: "user", content: "Edit the introduction")],
            updatedAt: Date(timeIntervalSince1970: 100),
            helperID: helper.id
        )
        let first = ProactiveAgentsPolicy.contextSnapshot(helpers: [helper], conversations: [firstConversation], includeScreen: false)
        let same = ProactiveAgentsPolicy.contextSnapshot(helpers: [helper], conversations: [firstConversation], includeScreen: false)
        var changedConversation = firstConversation
        changedConversation.messages[0].content = "Edit the conclusion"
        let changed = ProactiveAgentsPolicy.contextSnapshot(helpers: [helper], conversations: [changedConversation], includeScreen: false)

        XCTAssertTrue(ProactiveAgentsPolicy.isUnchanged(currentFingerprint: same.fingerprint, previousFingerprint: first.fingerprint))
        XCTAssertFalse(ProactiveAgentsPolicy.isUnchanged(currentFingerprint: changed.fingerprint, previousFingerprint: first.fingerprint))
        XCTAssertFalse(ProactiveAgentsPolicy.isUnchanged(currentFingerprint: first.fingerprint, previousFingerprint: nil))
    }

    func testParserAcceptsEmptyListAndDeduplicatesEquivalentCandidates() throws {
        let helper = HelperProfile(name: "Research", instructions: "Find reliable evidence.")
        let empty = try ProactiveAgentsPolicy.parseResponse("{\"suggestions\":[]}", helpers: [helper])
        XCTAssertTrue(empty.isEmpty)

        let response = try encode([
            candidate(title: "Review the report", reason: "A draft is ready.", task: "Check the report for unsupported claims.", helperID: helper.id),
            candidate(title: " review   the report ", reason: "A duplicate proposal.", task: "Check the report for unsupported claims.", helperID: helper.id)
        ])
        let suggestions = try ProactiveAgentsPolicy.parseResponse(response, helpers: [helper])
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.helperID, helper.id)
        XCTAssertEqual(ProactiveAgentsPolicy.unseen(suggestions, seenIDs: [suggestions[0].dedupeID]), [])
    }

    func testParserRejectsUnknownHelpersOversizedTextAndMoreThanSevenSuggestions() throws {
        let helper = HelperProfile(name: "Research", instructions: "Find reliable evidence.")
        let unknown = try encode([candidate(title: "Review report", reason: "A draft is ready.", task: "Check the report for unsupported claims.", helperID: UUID())])
        XCTAssertThrowsError(try ProactiveAgentsPolicy.parseResponse(unknown, helpers: [helper]))

        let oversized = try encode([candidate(title: String(repeating: "x", count: 101), reason: "A draft is ready.", task: "Check the report for unsupported claims.", helperID: helper.id)])
        XCTAssertThrowsError(try ProactiveAgentsPolicy.parseResponse(oversized, helpers: [helper]))

        let tooMany = try encode((0..<8).map { index in
            candidate(title: "Suggestion \(index)", reason: "A useful follow-up.", task: "Check this small deliverable number \(index).", helperID: helper.id)
        })
        XCTAssertThrowsError(try ProactiveAgentsPolicy.parseResponse(tooMany, helpers: [helper]))
    }

    func testAutomaticChecksRespectEnablementCooldownDailyLimitAndContextFingerprint() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day = ProactiveAgentsPolicy.dayKey(now)
        XCTAssertTrue(ProactiveAgentsPolicy.shouldAutomaticallyCheck(enabled: true, now: now, lastAutomaticCheck: nil, automaticChecksToday: 0, recordedDay: nil))
        XCTAssertFalse(ProactiveAgentsPolicy.shouldAutomaticallyCheck(enabled: false, now: now, lastAutomaticCheck: nil, automaticChecksToday: 0, recordedDay: nil))
        XCTAssertFalse(ProactiveAgentsPolicy.shouldAutomaticallyCheck(enabled: true, now: now, lastAutomaticCheck: now.addingTimeInterval(-119), automaticChecksToday: 1, recordedDay: day))
        XCTAssertTrue(ProactiveAgentsPolicy.shouldAutomaticallyCheck(enabled: true, now: now, lastAutomaticCheck: now.addingTimeInterval(-120), automaticChecksToday: 1, recordedDay: day))
        XCTAssertFalse(ProactiveAgentsPolicy.shouldAutomaticallyCheck(enabled: true, now: now, lastAutomaticCheck: nil, automaticChecksToday: 32, recordedDay: day))
        XCTAssertTrue(ProactiveAgentsPolicy.shouldAutomaticallyCheck(enabled: true, now: now, lastAutomaticCheck: nil, automaticChecksToday: 32, recordedDay: "previous-day"))
        XCTAssertEqual(ProactiveAgentsPolicy.firstCheckDelay, 45)
        XCTAssertEqual(ProactiveAgentsPolicy.automaticInterval, 15 * 60)
    }

    func testInjectedGeneratorRequiresExplicitStartAndPersistsDedupeAcrossControllerInstances() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-proactive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(storageURL: folder.appendingPathComponent("conversations.json"), useKeychain: false)
        model.addHelper(name: "Research", instructions: "Analyze follow-ups")
        let helper = try XCTUnwrap(model.helpers.last)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs", isDirectory: true), autoStart: false, executor: { _, _ in "unused" })
        let storeURL = folder.appendingPathComponent("proactive-agents.json")
        let response = try encode([candidate(title: "Organize the notes", reason: "A recent chat has an unfinished outline.", task: "Review the notes and make a concise outline.", helperID: helper.id)])
        var generationCount = 0
        var screenCaptureCount = 0
        var startedSuggestion: ProactiveSuggestion?

        let controller = ProactiveAgentsController(
            model: model,
            jobs: jobs,
            screenContext: { screenCaptureCount += 1; return "screen text" },
            onStart: { startedSuggestion = $0; return true },
            storageURL: storeURL,
            generator: { messages in
                generationCount += 1
                XCTAssertEqual(messages.count, 2)
                XCTAssertFalse(messages[1].content.isEmpty)
                return response
            },
            presentsWindow: false
        )
        controller.useScreenContext = false

        await controller.checkNow()
        XCTAssertEqual(generationCount, 1)
        XCTAssertEqual(screenCaptureCount, 0)
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertNil(startedSuggestion)
        XCTAssertTrue(jobs.jobs.isEmpty)
        let suggestionID = try XCTUnwrap(controller.suggestions.first?.id)
        XCTAssertNotNil(controller.suggestions.first?.sourceContext)

        let restored = ProactiveAgentsController(
            model: model,
            jobs: jobs,
            screenContext: { screenCaptureCount += 1; return "screen text" },
            onStart: { _ in XCTFail("Loading suggestions must not start a task"); return false },
            storageURL: storeURL,
            generator: { _ in generationCount += 1; return response },
            presentsWindow: false
        )
        XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertFalse(restored.isPanelPresented)

        controller.markStarted(suggestionID)
        XCTAssertEqual(startedSuggestion?.id, suggestionID)
        XCTAssertTrue(jobs.jobs.isEmpty)

        let afterStart = ProactiveAgentsController(
            model: model,
            jobs: jobs,
            screenContext: { "" },
            onStart: { _ in XCTFail("A started suggestion must not reappear"); return false },
            storageURL: storeURL,
            generator: { _ in generationCount += 1; return response },
            presentsWindow: false
        )
        XCTAssertEqual(afterStart.pendingCount, 0)
        await afterStart.checkNow()
        XCTAssertEqual(generationCount, 2)
        XCTAssertEqual(afterStart.pendingCount, 0)
        XCTAssertFalse(afterStart.isPanelPresented)
        controller.stop(); restored.stop(); afterStart.stop(); jobs.shutdown()
    }

    func testDismissalIsPersistedAndDoesNotInvokeStartHandler() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-proactive-dismiss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(storageURL: folder.appendingPathComponent("conversations.json"), useKeychain: false)
        let helper = try XCTUnwrap(model.helpers.first)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs", isDirectory: true), autoStart: false, executor: { _, _ in "unused" })
        let response = try encode([candidate(title: "Tidy project notes", reason: "The latest discussion left notes unfinished.", task: "Turn the latest project notes into a short checklist.", helperID: helper.id)])
        var startCalled = false
        let controller = ProactiveAgentsController(
            model: model,
            jobs: jobs,
            screenContext: { "" },
            onStart: { _ in startCalled = true; return false },
            storageURL: folder.appendingPathComponent("dismiss.json"),
            generator: { _ in response },
            presentsWindow: false
        )
        controller.useScreenContext = false
        await controller.checkNow()
        let id = try XCTUnwrap(controller.suggestions.first?.id)
        controller.dismissPanel()
        XCTAssertFalse(controller.isPanelPresented)
        XCTAssertEqual(controller.pendingCount, 1, "Closing the card must keep today's suggestions")
        controller.showPopup()
        XCTAssertTrue(controller.isPanelPresented)
        XCTAssertFalse(controller.isReviewing)
        XCTAssertFalse(startCalled)
        controller.showSuggestions()
        XCTAssertTrue(controller.isReviewing)
        XCTAssertEqual(controller.suggestions.first?.id, id)
        controller.enabled = false
        XCTAssertFalse(controller.isPanelPresented)
        controller.showSuggestions()
        XCTAssertTrue(controller.isPanelPresented, "Explicit review must open even when discovery is paused")
        XCTAssertTrue(controller.isReviewing)
        XCTAssertFalse(controller.enabled, "Opening review must not enable background discovery")
        XCTAssertFalse(controller.checking)
        controller.dismiss(id)

        XCTAssertFalse(startCalled)
        XCTAssertEqual(controller.pendingCount, 0)
        let saved = try Data(contentsOf: folder.appendingPathComponent("dismiss.json"))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("dismissedIDs"))
        XCTAssertTrue(jobs.jobs.isEmpty)
        controller.stop(); jobs.shutdown()
    }

    func testFailedStartKeepsSuggestionUntilEnqueueSucceeds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-proactive-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(storageURL: folder.appendingPathComponent("conversations.json"), useKeychain: false)
        let helper = try XCTUnwrap(model.helpers.first)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs", isDirectory: true), autoStart: false, executor: { _, _ in "unused" })
        let response = try encode([candidate(title: "Review project notes", reason: "A recent chat left a useful follow-up.", task: "Review the project notes and extract the open questions.", helperID: helper.id)])
        var enqueueSucceeds = false
        var startAttempts = 0
        let storeURL = folder.appendingPathComponent("proactive.json")
        let controller = ProactiveAgentsController(
            model: model,
            jobs: jobs,
            screenContext: { "" },
            onStart: { _ in startAttempts += 1; return enqueueSucceeds },
            storageURL: storeURL,
            generator: { _ in response },
            presentsWindow: false
        )
        controller.useScreenContext = false
        await controller.checkNow()
        let suggestionID = try XCTUnwrap(controller.suggestions.first?.id)

        controller.markStarted(suggestionID)
        XCTAssertEqual(startAttempts, 1)
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertNotNil(controller.error)
        let failedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let dedupeID = try XCTUnwrap(controller.suggestions.first?.dedupeID)
        XCTAssertFalse((failedState["startedIDs"] as? [String] ?? []).contains(dedupeID))

        enqueueSucceeds = true
        controller.markStarted(suggestionID)
        XCTAssertEqual(startAttempts, 2)
        XCTAssertEqual(controller.pendingCount, 0)
        XCTAssertNil(controller.error)
        XCTAssertTrue(jobs.jobs.isEmpty)
        controller.stop(); jobs.shutdown()
    }

    func testPauseDiscardsInFlightDiscovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-proactive-pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false, executor: { _, _ in "unused" })
        let helper = try XCTUnwrap(model.helpers.first)
        let response = try encode([candidate(title: "Review notes", reason: "Notes have open questions.", task: "Summarize the open questions in the notes.", helperID: helper.id)])
        var resume: CheckedContinuation<String, Never>?
        let controller = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "" }, onStart: { _ in XCTFail("Must not start"); return false }, storageURL: folder.appendingPathComponent("ideas.json"), generator: { _ in
            await withCheckedContinuation { resume = $0 }
        }, presentsWindow: false)
        let check = Task { await controller.checkNow() }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        controller.enabled = false
        resume?.resume(returning: response)
        await check.value
        XCTAssertEqual(controller.pendingCount, 0)
        XCTAssertFalse(controller.checking)
        XCTAssertFalse(controller.isPanelPresented)
        XCTAssertTrue(jobs.jobs.isEmpty)
        controller.stop(); jobs.shutdown()
    }

    func testAppSwitchDiscardsInFlightDiscovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-proactive-pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false, executor: { _, _ in "unused" })
        let helper = try XCTUnwrap(model.helpers.first)
        let response = try encode([candidate(title: "Review notes", reason: "Notes have open questions.", task: "Summarize the open questions in the notes.", helperID: helper.id)])
        var resume: CheckedContinuation<String, Never>?
        let controller = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "" }, onStart: { _ in XCTFail("Must not start"); return false }, storageURL: folder.appendingPathComponent("ideas.json"), generator: { _ in
            await withCheckedContinuation { resume = $0 }
        }, presentsWindow: false)
        let check = Task { await controller.checkNow() }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        controller.screenSourceChanged()
        resume?.resume(returning: response)
        await check.value
        XCTAssertEqual(controller.pendingCount, 0)
        XCTAssertFalse(controller.checking)
        XCTAssertFalse(controller.isPanelPresented)
        XCTAssertTrue(jobs.jobs.isEmpty)
        controller.stop(); jobs.shutdown()
    }

    func testIsolatedAutomaticModeBypassesExhaustedDailyBudgetAndDiscardsOldApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs"), autoStart: false, executor: { _, _ in "unused" })
        defer { jobs.shutdown() }
        let production = folder.appendingPathComponent("production.json")
        let productionBytes = Data("production budget must remain unchanged: 32".utf8)
        try productionBytes.write(to: production)
        let mode = ProactiveSuggestionTestMode(directory: folder.appendingPathComponent("qa"), debounce: 0.01, cooldown: 0.01)
        try FileManager.default.createDirectory(at: mode.directory, withIntermediateDirectories: true)
        let saved: [String: Any] = ["enabled": true, "useScreenContext": true, "suggestions": [], "seenIDs": [], "dismissedIDs": [], "startedIDs": [], "automaticChecksToday": 32, "automaticCheckDay": ProactiveAgentsPolicy.dayKey(Date()), "lastAutomaticCheck": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: saved).write(to: mode.storageURL)
        let helper = try XCTUnwrap(model.helpers.first)
        let oldResponse = try encode([candidate(title: "Old app task", reason: "Old screen", task: "Summarize the old app notes.", helperID: helper.id)])
        let newResponse = try encode([candidate(title: "New app checklist", reason: "New screen", task: "Write the new app keyboard navigation checklist.", helperID: helper.id)])
        var pending: CheckedContinuation<String, Never>?
        var calls = 0
        var screen = "Screen text:\nApp: TextEdit\nOld notes"
        let controller = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { screen }, onStart: { _ in XCTFail("QA must never start agents"); return true }, storageURL: production, generator: { _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { pending = $0 } }
            return newResponse
        }, presentsWindow: false, testMode: mode)
        controller.start()
        for _ in 0..<200 where pending == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(pending)
        screen = "Screen text:\nApp: Aside\nKeyboard navigation checklist needed"
        controller.screenSourceChanged()
        pending?.resume(returning: oldResponse)
        for _ in 0..<300 where controller.pendingCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(controller.suggestions.map(\.title), ["New app checklist"])
        XCTAssertFalse(controller.suggestions.contains { $0.title == "Old app task" })
        XCTAssertTrue(controller.suggestions.first?.sourceContext?.contains("App: Aside") == true)
        controller.markStarted(try XCTUnwrap(controller.suggestions.first?.id))
        XCTAssertTrue(jobs.jobs.isEmpty)
        XCTAssertEqual(controller.pendingCount, 1)
        controller.showPopup()
        XCTAssertTrue(controller.isPanelPresented)
        controller.screenSourceChanged()
        XCTAssertFalse(controller.isPanelPresented)
        XCTAssertEqual(controller.pendingCount, 0)
        controller.stop()
        XCTAssertEqual(try Data(contentsOf: production), productionBytes)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mode.storageURL)) as? [String: Any])
        XCTAssertEqual(stored["automaticChecksToday"] as? Int, 32)
        let events = try String(contentsOf: mode.directory.appendingPathComponent("events.json"), encoding: .utf8)
        XCTAssertTrue(events.contains("automatic-start"))
        XCTAssertTrue(events.contains("discarded-response"))
    }

    func testExplicitQAStartRunsOnceAndAppSwitchDoesNotCancelAgent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let helper = try XCTUnwrap(model.helpers.first)
        var completion: CheckedContinuation<String, Never>?
        let jobs = AgentJobStore(storageDirectory: folder.appendingPathComponent("jobs"), autoStart: false, executor: { _, _ in
            await withCheckedContinuation { completion = $0 }
        })
        defer { jobs.shutdown() }
        let mode = ProactiveSuggestionTestMode(directory: folder.appendingPathComponent("qa"), debounce: 0.01, cooldown: 0.01, permitsAgentStart: true)
        var title = "Draft continuity runbook"
        let controller = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "Screen text:\nApp: TextEdit\nContinuity acceptance brief" }, onStart: { suggestion in
            jobs.enqueue(title: suggestion.title, prompt: suggestion.agentPrompt, helper: helper) != nil
        }, generator: { _ in
            try self.encode([self.candidate(title: title, reason: "The brief needs a local deliverable.", task: title + " from the supplied continuity brief and save a local report.", helperID: helper.id)])
        }, presentsWindow: false, testMode: mode)
        controller.start()
        for _ in 0..<200 where controller.pendingCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertTrue(jobs.jobs.isEmpty) // Automatic discovery alone never starts work.
        controller.markStarted(try XCTUnwrap(controller.suggestions.first?.id))
        for _ in 0..<200 where completion == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let jobID = try XCTUnwrap(jobs.jobs.first?.id)
        XCTAssertEqual(jobs.jobs.first?.state, .running)
        controller.screenSourceChanged()
        XCTAssertEqual(jobs.jobs.first?.id, jobID)
        XCTAssertEqual(jobs.jobs.first?.state, .running)
        title = "Analyze a different failure trace"
        await controller.checkNow()
        if let second = controller.suggestions.first { controller.markStarted(second.id) }
        XCTAssertEqual(jobs.jobs.count, 1)
        XCTAssertEqual(mode.agentStarts, 1)
        completion?.resume(returning: "Continuity report completed after app switch")
        for _ in 0..<200 where jobs.jobs.first?.state != .succeeded { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(jobs.jobs.first?.state, .succeeded)
        XCTAssertTrue(jobs.jobs.first?.result?.contains("after app switch") == true)
        controller.stop()
    }

    func testLiveCodexDiscoveryWithSyntheticContext() async throws {
        guard ProcessInfo.processInfo.environment["KADDO_LIVE_PROACTIVE"] == "1" else { throw XCTSkip("Set KADDO_LIVE_PROACTIVE=1 for synthetic-context Codex discovery.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kaddo-proactive-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chats.json"), useKeychain: false)
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false, executor: { _, _ in "unused" })
        let controller = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "Synthetic QA: A project note says draft an outline for a garden planting guide. The outline is unfinished." }, onStart: { _ in XCTFail("Discovery must not execute tasks"); return false }, storageURL: folder.appendingPathComponent("ideas.json"), presentsWindow: false)
        await controller.checkNow()
        XCTAssertNil(controller.error)
        XCTAssertNotNil(controller.lastChecked)
        XCTAssertTrue(jobs.jobs.isEmpty)
        XCTAssertLessThanOrEqual(controller.pendingCount, 7)
        controller.stop(); jobs.shutdown()
    }

    func testPopupIsCenteredAndAttachedOnEitherDisplay() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 100, width: 1920, height: 1080)] {
            let frame = ProactiveAgentsPolicy.panelFrame(screen: screen, size: CGSize(width: 440, height: 130), margin: 0)
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertTrue(screen.contains(frame))
        }
        let small = CGRect(x: -100, y: 20, width: 300, height: 100)
        XCTAssertTrue(small.contains(ProactiveAgentsPolicy.panelFrame(screen: small, size: CGSize(width: 440, height: 130), margin: 0)))
    }

    func testRecentOutcomesAreBoundedAndProvidedToStartedAgent() throws {
        let helper = HelperProfile(name: "Research", instructions: "Analyze evidence")
        var task = AgentJob(title: "Completed review", prompt: "Review", helperID: helper.id, helperName: helper.name, helperInstructions: helper.instructions)
        task.state = .succeeded; task.result = String(repeating: "x", count: 800)
        let context = ProactiveAgentsPolicy.contextSnapshot(helpers: [helper], conversations: [], jobs: [task], includeScreen: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.json.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(json["recent_helper_outcomes"] as? [[String: String]])
        XCTAssertEqual(rows.first?["state"], "succeeded")
        XCTAssertEqual(rows.first?["outcome"]?.count, 400)
        var suggestion = ProactiveSuggestion(title: "Follow up", reason: "Review has questions", task: "Summarize open questions", helperID: helper.id, dedupeID: "test")
        XCTAssertEqual(suggestion.agentPrompt, suggestion.task)
        suggestion.sourceContext = context.json
        XCTAssertTrue(suggestion.agentPrompt.contains("Completed review"))
        XCTAssertTrue(suggestion.agentPrompt.hasPrefix(suggestion.task))
        XCTAssertEqual(ProactiveSuggestion.displayPrompt(suggestion.agentPrompt), suggestion.task)
        XCTAssertEqual(ProactiveSuggestion.displayPrompt("Ordinary task"), "Ordinary task")
        XCTAssertEqual(try JSONDecoder().decode(ProactiveSuggestion.self, from: JSONEncoder().encode(suggestion)).sourceContext, context.json)
    }

    func testOverflowSuggestionsCanBeOfferedAfterSpaceOpens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proactive-capacity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(storageURL: folder.appendingPathComponent("chat.json"), useKeychain: false)
        let helper = try XCTUnwrap(model.helpers.first)
        let jobs = AgentJobStore(storageDirectory: folder, autoStart: false, executor: { _, _ in "unused" })
        var response = try encode((0..<7).map { candidate(title: "Task \($0)", reason: "An unfinished follow-up", task: "Review project section \($0)", helperID: helper.id) })
        let controller = ProactiveAgentsController(model: model, jobs: jobs, screenContext: { "" }, onStart: { _ in false }, storageURL: folder.appendingPathComponent("ideas.json"), generator: { _ in response }, presentsWindow: false)
        await controller.checkNow()
        XCTAssertEqual(controller.pendingCount, 7)
        response = try encode([candidate(title: "Later task", reason: "Another unfinished follow-up", task: "Review the remaining section", helperID: helper.id)])
        await controller.checkNow()
        XCTAssertFalse(controller.suggestions.contains { $0.title == "Later task" })
        controller.dismiss(try XCTUnwrap(controller.suggestions.first?.id))
        await controller.checkNow()
        XCTAssertEqual(controller.pendingCount, 7)
        XCTAssertTrue(controller.suggestions.contains { $0.title == "Later task" })
        controller.stop(); jobs.shutdown()
    }

    private func candidate(title: String, reason: String, task: String, helperID: UUID) -> [String: String] {
        ["title": title, "reason": reason, "task": task, "helper_id": helperID.uuidString]
    }

    private func encode(_ suggestions: [[String: String]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["suggestions": suggestions], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
