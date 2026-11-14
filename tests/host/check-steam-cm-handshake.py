#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise production WebSocket handshake completion with scripted callbacks, offline."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/SwiftSteam/Core/SteamConnection.swift').read_text()
start = source.index('    private func connect(to server:')
handshake = source[start:source.index('\n    }', start) + 6]
handshake = handshake.replace('URLSessionConfiguration', 'ScriptedConfiguration').replace('URLSession', 'ScriptedSession')
guard_start = source.find('private final class SteamConnectionHandshake')
guard = source[guard_start:source.index('// MARK: - SteamConnection', guard_start)] if guard_start >= 0 else ''
program = r'''
import Foundation
enum SteamLog { static func trace(_ text: String) {} }
enum CMServerList {
    struct CMServer {
        var endpoint: String { "offline.invalid:443" }
        var url: URL { URL(string: "wss://offline.invalid")! }
    }
}
final class ScriptedConfiguration {
    static var `default`: ScriptedConfiguration { .init() }
    var timeoutIntervalForRequest: TimeInterval = 0
}
final class ScriptedTask: @unchecked Sendable {
    enum CloseCode { case goingAway }
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?
    private var cancellationCount = 0
    func resume() {}
    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        lock.lock(); callback = pongReceiveHandler; lock.unlock()
    }
    func cancel(with: CloseCode, reason: Data?) {
        lock.lock(); cancellationCount += 1; lock.unlock()
    }
    func fire(_ error: Error?) {
        lock.lock(); let action = callback; lock.unlock()
        precondition(action != nil)
        action?(error)
    }
    var registered: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellationCount > 0 }
}
enum Script { static var task = ScriptedTask() }
final class ScriptedSession {
    init(configuration: ScriptedConfiguration, delegate: NSObject, delegateQueue: OperationQueue?) {}
    func webSocketTask(with: URL, protocols: [String]) -> ScriptedTask { Script.task }
}
''' + guard + r'''
actor Harness {
    var currentEndpoint: String?
    var urlSession: ScriptedSession?
    var webSocketTask: ScriptedTask?
    let wsDelegate = NSObject()
    func start() async throws { try await connect(to: CMServerList.CMServer()) }
''' + handshake + r'''
}
func waitForPing(_ task: ScriptedTask) async {
    while !task.registered { await Task.yield() }
}
@main struct Check {
    static func main() async throws {
        let failure = URLError(.cancelled)
        // The real iPad crash: one ping callback receives multiple errors.
        Script.task = ScriptedTask()
        let failed = Script.task, first = Task { try await Harness().start() }
        await waitForPing(failed)
        failed.fire(failure); failed.fire(failure)
        do { try await first.value; fatalError("failure accepted") } catch { precondition(error is URLError) }

        // A successful ping is also terminal, even if a late failure follows.
        Script.task = ScriptedTask()
        let success = Script.task, second = Task { try await Harness().start() }
        await waitForPing(success)
        success.fire(nil); success.fire(failure); success.fire(nil)
        try await second.value

        // Cancellation must finish without waiting for URLSession's callback.
        Script.task = ScriptedTask()
        let cancelled = Script.task, third = Task { try await Harness().start() }
        await waitForPing(cancelled)
        third.cancel()
        do { try await third.value; fatalError("cancellation ignored") } catch { precondition(error is CancellationError) }
        while !cancelled.cancelled { await Task.yield() }
        cancelled.fire(nil); cancelled.fire(failure); cancelled.fire(failure)

        // Simultaneous callbacks must still claim the continuation only once.
        for _ in 0..<100 {
            Script.task = ScriptedTask()
            let racing = Script.task, request = Task { try await Harness().start() }
            await waitForPing(racing)
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                racing.fire(index.isMultiple(of: 2) ? nil : failure)
            }
            _ = try? await request.value
        }
        // Cancellation before continuation installation must also be retained.
        __EARLY_CANCELLATION__
        // A cancelled handshake never prevents a new one succeeding.
        Script.task = ScriptedTask()
        let retry = Script.task, fourth = Task { try await Harness().start() }
        await waitForPing(retry); retry.fire(nil); try await fourth.value
        print("PASS: production CM ping handshake tolerates duplicate and concurrent callbacks, cancellation, late results and retry")
    }
}
'''
early = r'''
        let early = SteamConnectionHandshake()
        early.finish(.failure(CancellationError()))
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in early.install(continuation) }
            fatalError("early cancellation lost")
        } catch { precondition(error is CancellationError) }
'''
program = program.replace('__EARLY_CANCELLATION__', early if guard else '')
with tempfile.TemporaryDirectory(prefix='madeira-cm-handshake-') as directory:
    path = Path(directory)
    (path / 'check.swift').write_text(program)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '5', '-warnings-as-errors', '-parse-as-library',
                    str(path / 'check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True, timeout=30)
