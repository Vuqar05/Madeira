#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Host check for SteamSession's pending jobs; never contacts Steam.

Each request (callServiceMethod, sendAndWait, sendAndWaitPICS) parks a
CheckedContinuation in a dictionary. Whoever removes it from the dictionary
resumes it, exactly once: the response, the timeout, disconnect() or a failed
send. A second resume traps the app.

This builds the production SteamSession.swift with a stand-in SteamConnection
whose send() parks until the check releases it and then fails, the way a write
fails on a socket that is closing. For each request the check runs the order
that crashed the app: the send is in flight, disconnect() fails the request,
then the send fails too.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
steam = root / 'app/Madeira/SwiftSteam'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


# The gzip helper at the end of the file needs Apple's Compression; no job path uses it.
session = (steam / 'Core/SteamSession.swift').read_text()
session = 'import Observation\n' + session[:session.index('// MARK: - Data Extensions')]

def declaration(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

# Compile the real page's account lookup as well: a redraw after a refused
# import must not disable the picker just because the Steam connection idled.
owned = (root / 'app/Madeira/SteamOwnedLibrary.swift').read_text()
page = (root / 'app/Madeira/SteamInputCommunityView.swift').read_text()
account_lookup = declaration(page, '    private var accountID: UInt32').replace('private var', 'var', 1)
account_methods = declaration(owned, '    var workshopAccountID: UInt32')
if '    var personalLayoutAccountID: UInt32' in owned:
    account_methods += '\n' + declaration(owned, '    var personalLayoutAccountID: UInt32')

stubs = r'''
import Foundation
enum SteamLog { static func trace(_ m: @autoclosure () -> String) {}; static func event(_ m: String) {} }
enum SteamDevice { static let name = "host" }
@MainActor enum SteamSignIn {
    static var credentialReads = 0
    static var credentials: (accountName: String, refreshToken: String)?
    static var accountName: String? { credentials?.accountName }
    static func credentialsForDock() -> (accountName: String, refreshToken: String)? { credentialReads += 1; return credentials }
}
actor CMServerList {}
extension Data { func gunzip(expectedSize: Int = 0) -> Data? { nil } }

/// Stand-in for the WebSocket. send() parks until release(), then fails.
actor SteamConnection {
    nonisolated(unsafe) static var last: SteamConnection?
    private var parked: CheckedContinuation<Void, Never>?
    private var handler: ((Data) -> Void)?
    private var automatic = false
    private var logonSteamID: UInt64 = 0x01A0_0000_0000_0001
    private(set) var sent: [SteamMessageCodec.IncomingMessage] = []
    init() { Self.last = self }
    var isConnected: Bool { true }
    var isSending: Bool { parked != nil }
    func setMessageHandler(_ handler: @escaping (Data) -> Void) { self.handler = handler }
    func setDisconnectHandler(_ handler: @escaping (Error?) -> Void) {}
    func connect() async throws {}
    func reconnect() async throws {}
    func disconnect() {}
    func send(_ data: Data) async throws {
        if automatic {
            let message = try SteamMessageCodec.decode(data)
            sent.append(message)
            if message.eMsg == .clientLogon {
                var body = ProtobufEncoder(); body.writeUInt32(fieldNumber: 1, value: 1); body.writeUInt32(fieldNumber: 3, value: 30)
                handler?(SteamMessageCodec.encodeClientMessage(eMsg: .clientLogonResponse, body: body.data,
                    steamID: logonSteamID, sessionID: 7))
            }
            return
        }
        await withCheckedContinuation { parked = $0 }
        throw SteamError.disconnected
    }
    func automaticLogon(steamID: UInt64 = 0x01A0_0000_0000_0001) { automatic = true; logonSteamID = steamID }
    func release() { parked?.resume(); parked = nil }
}
'''

stubs += r'''
@MainActor enum DockSteamInputService {
    struct Selection { let appID: UInt32; let accountID: UInt32 }
    static var selection: Selection?
}
@MainActor final class SteamOwnedLibrary {
    static var shared: SteamOwnedLibrary!
    let session: SteamSession
    var signedIn: Bool { SteamSignIn.accountName != nil }
    init(_ session: SteamSession) { self.session = session }
''' + account_methods + r'''
}
@MainActor struct PersonalAccountHarness {
    let appID: UInt32
''' + account_lookup + r'''
}
'''

checks = r'''
import Foundation
var failures = 0
@MainActor func require(_ condition: Bool, _ label: String) {
    if condition { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

/// Sends a request, disconnects while its send is in flight, then fails the send.
@MainActor func disconnectDuringSend(_ label: String, _ request: @escaping @MainActor (SteamSession) async throws -> Void) async throws {
    let session = SteamSession()
    let connection = SteamConnection.last!
    let call = Task { @MainActor () -> String in
        do { try await request(session); return "returned" } catch { return "\(error)" }
    }
    while !(await connection.isSending) { try await Task.sleep(nanoseconds: 1_000_000) }
    session.disconnect()
    let outcome = await call.value
    require(outcome == "disconnected", "\(label): disconnect() fails the request in flight (\(outcome))")
    await connection.release()
    // The send's failure reaches the main actor next; a second resume would trap here.
    try await Task.sleep(nanoseconds: 200_000_000)
    require(true, "\(label): the send failing afterwards does not resume the request again")
}

@main struct Checks {
    @MainActor static func main() async throws {
        try await disconnectDuringSend("callServiceMethod") { session in
            _ = try await session.callServiceMethod(method: .getOwnedGames, body: Data(), timeout: 60)
        }
        try await disconnectDuringSend("sendAndWait") { session in
            _ = try await session.sendAndWait(eMsg: .clientPICSAccessTokenRequest, body: Data(),
                                              responseEMsg: .clientPICSAccessTokenResponse, timeout: 60)
        }
        try await disconnectDuringSend("sendAndWaitPICS") { session in
            _ = try await session.sendAndWaitPICS(eMsg: .clientPICSProductInfoRequest, body: Data(), timeout: 60)
        }
        let publicSession = SteamSession(anonymous: true)
        let publicConnection = SteamConnection.last!
        await publicConnection.automaticLogon()
        let reads = SteamSignIn.credentialReads
        try await publicSession.ensureConnected()
        require(publicSession.connectionState == .authenticated && SteamSignIn.credentialReads == reads,
                "anonymous logon authenticates without reading the signed-in account")
        let sent = await publicConnection.sent
        let logon = sent.first { $0.eMsg == .clientLogon }!
        require(logon.header.steamid == 0x01A0_0000_0000_0000, "public connection uses the anonymous-user SteamID type")
        var decoder = ProtobufDecoder(logon.body)
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 50 || tag.fieldNumber == 108 {
                require(try decoder.readString().isEmpty, "anonymous logon sends no account name or refresh token")
            } else { try decoder.skip(wireType: tag.wireType) }
        }
        publicSession.disconnect()
        // Local import must remain available when an authenticated connection
        // goes idle while a file picker or validation refusal is displayed.
        let personalSession = SteamSession()
        let personalConnection = SteamConnection.last!
        SteamSignIn.credentials = ("fixture-account", "fixture-token")
        SteamOwnedLibrary.shared = SteamOwnedLibrary(personalSession)
        let personalPage = PersonalAccountHarness(appID: 480)
        require(personalPage.accountID == 0, "a local account is not guessed before successful authentication")
        await personalConnection.automaticLogon(steamID: 0x0110_0001_0000_0018)
        try await personalSession.ensureConnected()
        require(personalPage.accountID == 24, "the import page uses the authenticated account")
        personalSession.disconnect()
        require(personalSession.steamID == 0, "idle disconnect clears only the live protocol identity")
        require(personalPage.accountID == 24, "personal import remains enabled after idle disconnect and refusal redraw")
        DockSteamInputService.selection = .init(appID: 480, accountID: 24)
        SteamSignIn.credentials = nil
        require(personalPage.accountID == 0, "sign-out prevents imports under the previous account")
        SteamSignIn.credentials = ("another-account", "another-fixture-token")
        require(personalPage.accountID == 0, "switching accounts cannot reuse a previous identity")
        SteamSignIn.credentials = ("fixture-account", "fixture-token")
        try await personalSession.ensureConnected()
        require(personalPage.accountID == 24, "the same account can reconnect and retry without relaunching Madeira")
        personalSession.disconnect()
        SteamSignIn.credentials = nil
        DockSteamInputService.selection = nil
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all SteamSession job checks")
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'session.swift').write_text(session)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'checks.swift').write_text(checks)
    sources = [tmp / 'session.swift', tmp / 'stubs.swift', tmp / 'checks.swift',
               steam / 'Proto/SteamProtoMessages.swift', steam / 'Core/SteamError.swift', steam / 'Core/SteamProtocol.swift',
               steam / 'Core/SteamMessageCodec.swift', steam / 'Core/SteamCMSession.swift', steam / 'Core/LicenseListBox.swift',
               steam / 'Content/SteamLANPeer.swift', tmp / 'lan-stub.swift']
    (tmp / 'lan-stub.swift').write_text('enum ContentDecryptor { static let maximumChunkBytes = 64 * 1024 * 1024 }\n')
    exe = tmp / 'swift-checks'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe)] + [str(s) for s in sources],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'production SteamSession.swift compiles on the host with a stand-in connection')
    if build.returncode:
        sys.stdout.write(build.stderr[-6000:])
    else:
        # The Swift crash handler would sit on the pipes after a trap; the trap message is enough.
        run = subprocess.run([str(exe)], env=dict(os.environ, SWIFT_BACKTRACE='enable=no'), capture_output=True, text=True, timeout=120)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-3000:])
        require(run.returncode == 0, 'Swift checks exit cleanly (no continuation resumed twice)')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: all SteamSession job host checks')
