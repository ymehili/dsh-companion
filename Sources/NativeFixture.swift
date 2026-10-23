#if DEBUG
import Foundation
import UIKit

/// Explicit UI-test data only. Never used as a network-error fallback.
extension NativeStore {
    func installFixture() {
        paired = true
        connected = true
        status = "Connected to your Mac"
        let now = Date().timeIntervalSince1970 * 1000
        sessions = [
            SessionRow(.obj(["sessionId": .text("fixture-native"), "updatedAt": .number(now), "running": .bool(false), "cwd": .text("/workspace/default-workspace"), "projections": .obj(["values": .obj(["title": .text("A native iPhone conversation")])])]))!,
            SessionRow(.obj(["sessionId": .text("fixture-other"), "updatedAt": .number(now - 60000), "running": .bool(false), "cwd": .text("/workspace/project-notes"), "projections": .obj(["values": .obj(["title": .text("Project notes")])])]))!,
            SessionRow(.obj(["sessionId": .text("fixture-working"), "updatedAt": .number(now - 120000), "running": .bool(true), "cwd": .text("/workspace/default-workspace"), "projections": .obj(["values": .obj(["title": .text("Building your project")])])]))!,
            SessionRow(.obj(["sessionId": .text("fixture-settled"), "updatedAt": .number(now - 3600000), "running": .bool(false), "projections": .obj(["values": .obj(["title": .text("Finished session")])])]))!
        ]
        workspaceState.accept(.obj(["type": .text("baseline"), "value": .obj(["items": .array([]), "archivedSessionIds": .array([]), "pinnedSessionIds": .array([])])]))
        inboxAvailable = true
        inboxHasSnapshot = true
        inboxThreads = [
            "fixture-native": .obj(["facts": .obj(["completedAt": .number(now)])]),
            "fixture-other": .obj(["facts": .obj(["completedAt": .number(now - 60000)])]),
            "fixture-working": .obj(["facts": .obj(["running": .bool(true)])]),
            "fixture-settled": .obj(["settledOverride": .text("settled"), "facts": .obj(["completedAt": .number(now - 3600000)])])
        ]
        desktopProjections["fixture-native"] = .obj([
            "permissions": .obj(["currentValue": .text("danger-full-access")]),
            "modelSelection": .obj(["next": .obj(["provider": .text("fixture"), "model": .text("claude-opus"), "reasoningEffort": .text("high")])]),
            "todos": .array([.obj(["content": .text("Match the Mac interface"), "status": .text("completed")]), .obj(["content": .text("Adapt controls to mobile"), "status": .text("in_progress")])])
        ])
        models = [NativeModelChoice(provider: "fixture", providerName: "Test provider", model: "claude-opus", name: "Claude Opus", efforts: [NativeReasoningChoice(id: "high", name: "High")], defaultEffort: "high")]
        let flags = ProcessInfo.processInfo.arguments
        if flags.contains("-native-sidebar-dock-fixture") {
            for index in 0..<35 {
                let id = "dock-inbox-\(index)"
                sessions.append(SessionRow(.obj(["sessionId": .text(id), "updatedAt": .number(now - Double(index)), "running": .bool(false), "cwd": .text("/workspace/project-notes"), "projections": .obj(["values": .obj(["title": .text("Inbox project \(index + 1)")])])]))!)
                inboxThreads[id] = .obj(["facts": .obj(["completedAt": .number(now)])])
            }
        }
        if flags.contains("-native-multi-photo-fixture") {
            let token = attachments.begin("fixture-native")
            for index in 0..<2 {
                let data = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).jpegData(withCompressionQuality: 0.85) { context in
                    (index == 0 ? UIColor.systemTeal : UIColor.systemOrange).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
                    ("Photo \(index + 1)" as NSString).draw(at: CGPoint(x: 18, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.white])
                }
                _ = try! attachments.append("fixture-native", token: token, data: data, limits: PhotoLimits())
            }
            _ = attachments.finish("fixture-native", token: token, data: nil)
        }
        if flags.contains("-native-mac-sidebar-fixture") {
            func add(_ id: String, _ title: String, _ blank: Bool = false, _ running: Bool = false) {
                sessions.append(SessionRow(.obj(["sessionId": .text(id), "blank": .bool(blank), "running": .bool(running), "updatedAt": .number(now), "cwd": .text("/workspace/project-notes"), "projections": .obj(["values": .obj(["title": .text(title)])])]))!)
            }
            for n in 1...3 { let id = "fixture-inbox-\(n)"; add(id, "Review project \(n)"); inboxThreads[id] = .obj(["facts": .obj(["completedAt": .number(now)])]) }
            add("fixture-working-2", "Another running project", false, true)
            inboxThreads["fixture-working-2"] = .obj(["facts": .obj(["running": .bool(true)])])
            for n in 1...930 { let id = "fixture-settled-\(n)"; add(id, "Completed project \(n)"); inboxThreads[id] = .obj(["settledOverride": .text("settled"), "settledAt": .number(now - Double(n)), "facts": .obj([:])]) }
            for n in 1...56 { add("fixture-blank-\(n)", "Unused blank session", true) }
            let archived = (1...223).map { "fixture-archived-\($0)" }
            for id in archived { add(id, "Archived session without Inbox record") }
            workspaceState.accept(.obj(["type": .text("archived"), "archivedSessionIds": .array(archived.map(JSONValue.text))]))
        }
        if flags.contains("-native-inbox-stale-fixture") { inboxError = "Shelf sync temporarily unavailable. Keeping last Mac snapshot." }
        if flags.contains("-native-inbox-unavailable-fixture") {
            inboxHasSnapshot = false
            inboxAvailable = false
            inboxThreads = [:]
            inboxError = "Couldn’t sync shelves from your Mac. Retrying…"
        }
        if flags.contains("-native-empty-working-fixture") {
            sessions.removeAll { $0.id == "fixture-working" }
            inboxThreads.removeValue(forKey: "fixture-working")
        }
    }
    func fixtureConversation() {
        let text = #"{"type":"snapshot","cursor":4,"hasMore":false,"assistantStream":{"revision":0},"records":[{"type":"event","event":{"type":"user/message","seq":0,"time":1792128600000,"surfaceOp":"append","data":{"content":[{"type":"text","text":"I want the same DSH interface as my Mac, adapted to mobile with SwiftUI components."}]}}},{"type":"event","event":{"type":"tool/call","seq":1,"time":1792128610000,"data":{"name":"Read project","arguments":"{\"path\":\"Sources\"}"}}},{"type":"event","event":{"type":"assistant/message","seq":2,"time":1792128620000,"surfaceOp":"append","data":{"message":{"content":[{"type":"reasoning","text":"Keep the existing DSH visual language and interaction hierarchy. Adapt navigation and controls to touch without replacing the design with iOS cards."},{"type":"text","text":"Same DSH, adapted to your iPhone.\n\nYour conversations stay in the sidebar, assistant replies remain on the white canvas, and the composer keeps its attachment, model and send controls.\n\nEverything here is built with **SwiftUI**, using the same Mac backend."}]}}}},{"type":"event","event":{"type":"turn/end","seq":3,"time":1792128630000,"data":{}}}]}"#
        conversation.accept(try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        let flags = ProcessInfo.processInfo.arguments
        if flags.contains("-native-history-image-fixture") {
            let content: [JSONValue] = [.obj(["type": .text("image"), "attachment": ChatMediaFixtureTransport.reference]), .obj(["type": .text("text"), "text": .text("An authenticated image from this conversation.")])]
            let event: JSONValue = .obj(["type": .text("user/message"), "seq": .number(4), "surfaceOp": .text("append"), "data": .obj(["content": .array(content)])])
            conversation.accept(.obj(["type": .text("event"), "event": event]))
        }
        if flags.contains("-native-scroll-fixture") {
            for index in 4..<64 {
                conversation.accept(.obj(["type": .text("event"), "event": .obj(["type": .text("assistant/message"), "seq": .number(Double(index)), "surfaceOp": .text("append"), "data": .obj(["message": .obj(["content": .array([.obj(["type": .text("text"), "text": .text("Message \(index)\n\n" + String(repeating: "Native scrolling should remain smooth and predictable. ", count: 4))])])])])])]))
            }
        }
        if flags.contains("-native-rich-fixture") {
            conversation.accept(.obj(["type": .text("event"), "event": .obj(["type": .text("assistant/message"), "seq": .number(4), "surfaceOp": .text("append"), "data": .obj(["message": .obj(["content": .array([.obj(["type": .text("text"), "text": .text("## Native code block\n\n- Standard Apple navigation\n- Safe, selectable code\n\n```swift\nlet message = \"Hello, iPhone\"\nprint(message)\n```\n\nNo web view is used.")])])])])])]))
        }
    }
}
#endif
