import Testing
import Foundation
@testable import Laes

@MainActor struct OfflineTests {
    let list = TaskList(id: "L", name: "Tasks", isDefault: true)
    let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func edit(_ taskID: String, _ kind: PendingEdit.Kind) -> PendingEdit {
        PendingEdit(taskID: taskID, listID: "L", kind: kind)
    }

    @Test func unsentEditsSurviveAReload() {
        let server = [TodoTask(id: "a", title: "A", listName: "Tasks", listID: "L"),
                      TodoTask(id: "b", title: "B", listName: "Tasks", listID: "L")]
        let edits = [edit("a", .setDue(day)), edit("a", .setNotes("call")), edit("b", .complete),
                     edit("new-1", .create(title: "C", due: day)), edit("new-1", .setNotes("later")),
                     edit("gone", .setNotes("ignored")), edit("a", .setTitle("A2")), edit("a", .setImportant(true)),
                     edit("a", .setReminder(day)), edit("a", .setRepeat(RepeatRule(unit: .monthly), due: day))]
        let tasks = applying(edits, to: server, lists: [list])
        #expect(tasks.map(\.id) == ["a", "new-1"])
        #expect(tasks[0].due == day)
        #expect(tasks[0].notes == "call")
        #expect(tasks[0].title == "A2")
        #expect(tasks[0].isImportant)
        #expect(tasks[0].reminder == day)
        #expect(tasks[0].recurrence == "Repeats monthly")
        #expect(tasks[1].title == "C")
        #expect(tasks[1].notes == "later")
        #expect(tasks[1].listName == "Tasks")
        // Applying twice (reload after reload) changes nothing more.
        #expect(applying(edits, to: tasks, lists: [list]) == tasks)
    }

    @Test func unsentStepEditsSurviveAReload() {
        let server = [ChecklistItem(id: "s1", title: "UPS"), ChecklistItem(id: "s2", title: "URBN")]
        let edits = [edit("a", .checkStep(stepID: "s1", checked: true)), edit("a", .renameStep(stepID: "s2", title: "Urban")),
                     edit("a", .addStep(stepID: "new-9", title: "ZigZag")), edit("other", .addStep(stepID: "new-8", title: "x"))]
        #expect(applying(edits, toSteps: server, of: "a") == [
            ChecklistItem(id: "s1", title: "UPS", isChecked: true), ChecklistItem(id: "s2", title: "Urban"),
            ChecklistItem(id: "new-9", title: "ZigZag"),
        ])
    }

    @Test func laterEditsFollowTheAssignedID() {
        let queue = [edit("new-1", .setNotes("n")), edit("new-1", .addStep(stepID: "new-2", title: "s")),
                     edit("new-1", .checkStep(stepID: "new-2", checked: true)), edit("z", .complete)]
        let afterTask = replacingID("new-1", with: "real", in: queue)
        #expect(afterTask.map(\.taskID) == ["real", "real", "real", "z"])
        let afterStep = replacingID("new-2", with: "step", in: afterTask)
        #expect(afterStep[1].kind == .addStep(stepID: "step", title: "s"))
        #expect(afterStep[2].kind == .checkStep(stepID: "step", checked: true))
    }

    @Test func queueRoundTripsThroughJSON() throws {
        let queue = [edit("a", .create(title: "T", due: day)), edit("a", .complete), edit("a", .setDue(day)),
                     edit("a", .renameStep(stepID: "s", title: "t"))]
        let data = try JSONEncoder().encode(queue)
        #expect(try JSONDecoder().decode([PendingEdit].self, from: data) == queue)
    }

    @Test func savedFilesSurviveFormatChanges() throws {
        let real = Disk.folder
        Disk.folder = FileManager.default.temporaryDirectory.appending(path: "laes-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: Disk.folder); Disk.folder = real }
        try FileManager.default.createDirectory(at: Disk.folder, withIntermediateDirectories: true)
        let files = { try FileManager.default.contentsOfDirectory(atPath: Disk.folder.path).sorted() }

        // An unversioned queue from an older build, with one edit this build can't read: the rest still go out.
        let good = try String(decoding: JSONEncoder().encode(edit("a", .complete)), as: UTF8.self)
        try Data("[\(good), {\"taskID\": \"b\", \"kind\": {\"archive\": {}}}]".utf8).write(to: Disk.folder.appending(path: "outbox.json"))
        #expect(Disk.loadList(PendingEdit.self, from: "outbox.json") == [edit("a", .complete)])
        #expect(try files().contains { $0.hasPrefix("outbox.json.unread-") })   // the original is kept

        // Saved files carry their version and read back.
        try Disk.save([edit("c", .setTitle("C"))], to: "outbox.json")
        #expect(Disk.loadList(PendingEdit.self, from: "outbox.json") == [edit("c", .setTitle("C"))])

        // A file that doesn't read at all is moved aside, so the next save can't overwrite it.
        try Data("{\"tasks\": 1}".utf8).write(to: Disk.folder.appending(path: "tasks.json"))
        #expect(Disk.load(TaskSnapshot.self, from: "tasks.json") == nil)
        #expect(try !files().contains("tasks.json") && files().contains { $0.hasPrefix("tasks.json.unread-") })
    }
}

@Test func markdownFormatsBulletsCheckboxesAndInline() {
    let text = String(renderMarkdown("# Plan\n- one **bold**\n  - [x] done\n- [ ] open\nplain").characters)
    #expect(text == "Plan\n• one bold\n  ☑ done\n☐ open\nplain")
}

@Test func httpRequestWaitsForTheWholeBody() {
    let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nContent-Length: 4\r\n\r\n{}"
    #expect(HTTPRequest(Data(raw.utf8)) == nil)
    let request = HTTPRequest(Data((raw + "  ").utf8))
    #expect(request?.method == "POST" && request?.path == "/mcp" && request?.headers["host"] == "127.0.0.1:47821" && request?.body.count == 4)
}

@Test func localAndOffsetTimesParse() {
    #expect(MCPServer.parseTime("2026-11-23T14:00:00+01:00") == MCPServer.parseTime("2026-11-23T13:00:00Z"))
    #expect(MCPServer.parseTime("2026-11-23T14:00") != nil)
    #expect(MCPServer.parseTime("tomorrow") == nil)
}
