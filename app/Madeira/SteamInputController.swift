// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Who the player's controller is to Valve's client (milestone 5).
///
/// Steam Input reads one virtual HID controller that the wineserver serves to
/// Dock only (build/hidpad, `MADEIRA_HIDPAD_OWNER=dockhost.exe`). A PlayStation
/// pad is the virtual DualSense, the proven identity. The on-screen controls
/// and any other pad are an Xbox Wireless Controller, so games that take
/// glyphs from Steam show Xbox buttons and Steam does not assume trackpads,
/// gyro or rear buttons the player does not have. The Xbox identity is behind
/// `env.MADEIRA_STEAM_INPUT_XBOX` until a device confirms Valve's client opens
/// it; without it every session uses the DualSense, as before.
///
/// The on-screen controls and a physical pad remain one merged player
/// (owner decision, 2026-11-15); its identity follows the physical pad.
enum SteamInputController: String, Codable, CaseIterable, Sendable {
    case dualSense
    case xbox

    /// Steam's name for the type January's client gives this virtual device.
    var steamType: String {
        switch self {
        case .dualSense: return "controller_ps5"
        case .xbox: return "controller_xboxone"
        }
    }
    /// January's EControllerType (SH_INPUT_TYPE_DUALSENSE / _XBOX_ONE).
    var steamTypeID: UInt32 {
        switch self {
        case .dualSense: return 45
        case .xbox: return 32
        }
    }
    /// The virtual device's USB/Bluetooth IDs (build/hidpad/hidpad_ids.h).
    var vendor: UInt32 { self == .dualSense ? 0x054c : 0x045e }
    var product: UInt32 { self == .dualSense ? 0x0ce6 : 0x0b13 }
    /// MADEIRA_HIDPAD for the wineserver.
    var hidpad: String { self == .dualSense ? "dualsense" : "xbox" }
    /// The stable selection identity. The DualSense keeps the identity every
    /// earlier selection was saved under, so nothing saved is lost.
    var controllerID: UUID {
        switch self {
        case .dualSense: return UUID(uuidString: "77F4893A-244E-4808-994C-617331E9DC25")!
        case .xbox: return UUID(uuidString: "5C1B7E2D-8A43-4F19-B6E0-3D9A2C71F804")!
        }
    }
    var name: String { self == .dualSense ? "DualSense" : "Xbox controller" }

    /// Layout types January's client treats as made for this controller
    /// (SteamUI 0x731ca0, pinned by madeira-dock tools/check-steam-input-compat.py).
    var compatibleTypes: Set<String> {
        switch self {
        case .dualSense: return ["controller_ps5", "controller_ps4"]
        case .xbox: return ["controller_xboxone", "controller_xbox360", "controller_generic",
                            "controller_ps3", "controller_apple", "controller_android"]
        }
    }
    /// True when a layout of `type` was made for this controller. Steam writes
    /// the type in lower case; it is compared without case, as January does.
    func accepts(type: String) -> Bool { compatibleTypes.contains(type.lowercased()) }

    /// Steam's "Gamepad" template for this controller, the explicit generic choice.
    var genericTemplate: String { steamType + "_gamepad_joystick.vdf" }

    /// The controller whose layouts these are, from the virtual device Dock
    /// reported (vendor and product words). Nil for anything else.
    init?(vendor: UInt32, product: UInt32) {
        guard let match = Self.allCases.first(where: { $0.vendor == vendor && $0.product == product }) else { return nil }
        self = match
    }
    /// The controller a layout of `type` was made for, when it is one Madeira presents.
    init?(layoutType type: String) {
        guard let match = Self.allCases.first(where: { $0.accepts(type: type) }) else { return nil }
        self = match
    }

    /// Opt-in until device evidence: 1 presents the Xbox identity for the
    /// on-screen controls and non-PlayStation pads (`env.MADEIRA_STEAM_INPUT_XBOX`).
    @MainActor static var xboxEnabled: Bool { environment.xboxSwitch() }

    /// The identity for a session: a PlayStation pad is the DualSense, any
    /// other pad or none (the on-screen controls) the Xbox controller, when
    /// that identity is enabled.
    static func choose(physicalIsPlayStation: Bool?, xboxEnabled: Bool) -> Self {
        guard xboxEnabled else { return .dualSense }
        return physicalIsPlayStation == true ? .dualSense : .xbox
    }

    /// What the app supplies (MadeiraApp installs the real readers; host
    /// checks install their own): the opt-in switch, player 1's paired pad as
    /// GamepadInput assigns it (nil: none, so the on-screen controls), and the log.
    struct Environment {
        var xboxSwitch: @MainActor () -> Bool = { false }
        var pairedIsPlayStation: @MainActor () -> Bool? = { nil }
        var log: @MainActor (String) -> Void = { _ in }
    }
    @MainActor static var environment = Environment()

    /// Decided once per Steam Input launch, before Dock's handoff, and read by
    /// the selection store, the client's settings and the HID device, so all
    /// three agree even if a pad connects in between. Nil outside Steam Input.
    @MainActor private(set) static var session: SteamInputController?

    @MainActor @discardableResult
    static func beginSession() -> SteamInputController {
        let physical = environment.pairedIsPlayStation()
        let value = choose(physicalIsPlayStation: physical, xboxEnabled: xboxEnabled)
        session = value
        environment.log("[steam-input] controller identity=\(value.rawValue) physical="
                        + (physical.map { $0 ? "playstation" : "other" } ?? "none")
                        + " xbox-switch=\(xboxEnabled ? 1 : 0)")
        return value
    }
    @MainActor static func endSession() { session = nil }
    /// The running session's identity, else the one a launch would choose now:
    /// the controller whose layouts Game details and the editor work with.
    @MainActor static var current: SteamInputController {
        session ?? choose(physicalIsPlayStation: environment.pairedIsPlayStation(), xboxEnabled: xboxEnabled)
    }
}
