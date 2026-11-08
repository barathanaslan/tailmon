// First-launch agent setup: Tailmon.app carries the tailmon binary
// (Contents/Resources/tailmon). If nothing answers on 127.0.0.1:7020 at
// launch, the app registers the agent service from that binary once
// (`tailmon service install`), so `brew install --cask …/tailmon-app` is the
// whole install. An agent installed any other way (~/bin, brew services)
// answers the probe and is left alone. One subprocess, only in that case.
import Foundation

enum AgentSetup {
    static var bundledBinary: URL? {
        guard let url = Bundle.main.url(forResource: "tailmon", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Returns a log line describing what happened.
    static func ensureAgent(session: URLSession) async -> String? {
        if await agentAnswers(session) { return nil }
        guard let bin = bundledBinary else { return "no local agent and no bundled tailmon binary" }
        // A fresh login can race the LaunchAgent: look once more before installing.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if await agentAnswers(session) { return nil }
        return await Task.detached { install(bin) }.value
    }

    private static func agentAnswers(_ session: URLSession) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:7020/health") else { return false }
        do {
            let (_, resp) = try await session.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private static func install(_ bin: URL) -> String {
        let p = Process()
        p.executableURL = bin
        p.arguments = ["service", "install", "--bin", bin.path]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let killer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        defer { killer.cancel() }
        do {
            try p.run()
        } catch {
            return "agent install failed to start: \(error.localizedDescription)"
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let summary = text.split(separator: "\n").first.map(String.init) ?? ""
        return p.terminationStatus == 0
            ? "installed the agent service from the app bundle: \(summary)"
            : "agent install exited \(p.terminationStatus): \(text)"
    }
}
