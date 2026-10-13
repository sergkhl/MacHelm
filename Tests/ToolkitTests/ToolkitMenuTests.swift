import XCTest
@testable import ToolkitCore

// The owner's request of 2026-10-11 and SR-Q5: the menu bar menu has no list
// of services, no Cursor Fix and no diagnostics; Open MacHelm at Login
// stays. Since 2026-10-12 it holds Keep Awake and Sleep Now and lists the
// five heaviest processes by CPU (Q9 and Q17 of the Power and Storage record).
final class ToolkitMenuTests: XCTestCase {
    private let five = [
        ToolkitMenuProcess(name: "Blender", origin: "from codex ← Ghostty", value: "221%"),
        ToolkitMenuProcess(name: "Claude", value: "22%"),
        ToolkitMenuProcess(name: "WindowServer", value: "18%"),
        ToolkitMenuProcess(name: "ChatGPT", value: "14%"),
        ToolkitMenuProcess(name: "Brave Browser", value: "7.2%")
    ]

    func testTheMenuIsOpenFanControlPowerTheHeaviestLoginAndQuit() {
        let entries = ToolkitMenu.entries(fanSubtitle: "Tap to enable", fanOn: false, fanCanToggle: true,
                                          keepAwakeOn: true, keepAwakeNote: "Paused at 18% on battery",
                                          heaviest: five, span: "10 seconds", openAtLogin: true)
        XCTAssertEqual(entries, [
            .openDashboard,
            .separator,
            .fanControl(subtitle: "Tap to enable", on: false, canToggle: true),
            .keepAwake(on: true, note: "Paused at 18% on battery"),
            .sleepNow,
            .separator,
            .heaviestHeader("Heaviest by CPU, last 10 seconds"),
            .process(five[0]), .process(five[1]), .process(five[2]), .process(five[3]), .process(five[4]),
            .separator,
            .openAtLogin(on: true),
            .quit
        ])
    }

    func testTheEntriesCarryTheStateTheyWereShownWith() {
        let entries = ToolkitMenu.entries(fanSubtitle: "Recovery required", fanOn: true, fanCanToggle: false,
                                          keepAwakeOn: false, keepAwakeNote: nil,
                                          heaviest: five, span: "5 minutes", openAtLogin: false)
        XCTAssertTrue(entries.contains(.fanControl(subtitle: "Recovery required", on: true, canToggle: false)))
        XCTAssertTrue(entries.contains(.openAtLogin(on: false)))
        XCTAssertTrue(entries.contains(.keepAwake(on: false, note: nil)))
        XCTAssertTrue(entries.contains(.heaviestHeader("Heaviest by CPU, last 5 minutes")))
    }

    func testNoMoreThanFiveAreListed() {
        let entries = ToolkitMenu.entries(fanSubtitle: "", fanOn: false, fanCanToggle: true, keepAwakeOn: false, keepAwakeNote: nil,
                                          heaviest: five + [ToolkitMenuProcess(name: "Sixth", value: "1%")], span: "10 seconds",
                                          openAtLogin: true)
        XCTAssertEqual(entries.filter { if case .process = $0 { return true } else { return false } }.count, 5)
        XCTAssertFalse(entries.contains(.process(ToolkitMenuProcess(name: "Sixth", value: "1%"))))
    }

    func testBeforeTheFirstFiguresTheMenuSaysItIsMeasuring() {
        let entries = ToolkitMenu.entries(fanSubtitle: "", fanOn: false, fanCanToggle: true, keepAwakeOn: false, keepAwakeNote: nil, heaviest: nil, span: "10 seconds",
                                          openAtLogin: true)
        XCTAssertEqual(Array(entries[6...8]), [.heaviestHeader("Heaviest by CPU"), .measuring, .separator])
    }

    func testWithNothingToListTheMenuSaysSo() {
        let entries = ToolkitMenu.entries(fanSubtitle: "", fanOn: false, fanCanToggle: true, keepAwakeOn: false, keepAwakeNote: nil, heaviest: [], span: "10 seconds",
                                          openAtLogin: true)
        XCTAssertEqual(Array(entries[6...8]), [.heaviestHeader("Heaviest by CPU, last 10 seconds"),
                                              .process(ToolkitMenuProcess(name: "Nothing to list", value: "")), .separator])
    }
}
