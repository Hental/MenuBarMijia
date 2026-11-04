import Carbon
import Testing
@testable import MenuBarMijiaApp

@MainActor
struct MiReauthKeyboardTests {
    @Test("Reauthentication consumes Escape and forwards control keys and typing")
    func reauthForwardsNativeControlKeys() {
        #expect(HotkeyAndNotificationManager.miReauthKeyDownResult(
            keyCode: kVK_Escape, isShowingMiReauth: true, isPanelWindow: true
        ) == true)
        for code in [kVK_Tab, kVK_Space, kVK_Return, kVK_ANSI_A, kVK_UpArrow] {
            #expect(HotkeyAndNotificationManager.miReauthKeyDownResult(
                keyCode: code, isShowingMiReauth: true, isPanelWindow: true
            ) == false)
        }
    }

    @Test("Reauthentication leaves other windows and the normal panel routing alone")
    func inactiveReauthDoesNotOverrideRouting() {
        #expect(HotkeyAndNotificationManager.miReauthKeyDownResult(
            keyCode: kVK_Escape, isShowingMiReauth: false, isPanelWindow: true
        ) == nil)
        #expect(HotkeyAndNotificationManager.miReauthKeyDownResult(
            keyCode: kVK_Escape, isShowingMiReauth: true, isPanelWindow: false
        ) == nil)
    }
}
