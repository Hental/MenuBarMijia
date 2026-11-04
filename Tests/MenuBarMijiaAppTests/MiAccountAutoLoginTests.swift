import Testing
import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
struct MiAccountAutoLoginTests {
    @Test("Automatic QR login needs an automatic-login request plus Xiaomi Cloud or an expired Mi session")
    func autoLoginNeedsAReason() {
        #expect(MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: true, homeBackend: .xiaomiCloud, miSessionShowsExpired: false
        ))
        #expect(MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: true, homeBackend: .homeAssistant, miSessionShowsExpired: true
        ))
        #expect(!MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: false, homeBackend: .xiaomiCloud, miSessionShowsExpired: true
        ))
        for backend in [HomeBackend.homeAssistant, .demo] {
            #expect(!MiAccountSection.shouldAutoStartQRLogin(
                autoStartsQRLogin: true, homeBackend: backend, miSessionShowsExpired: false
            ))
        }
    }
}
