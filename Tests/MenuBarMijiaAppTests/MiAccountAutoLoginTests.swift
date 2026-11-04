import Testing
import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
struct MiAccountAutoLoginTests {
    @Test("Automatic QR login requires Xiaomi Cloud and an automatic-login request")
    func autoLoginRequiresXiaomiCloud() {
        #expect(MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: true, homeBackend: .xiaomiCloud
        ))
        #expect(!MiAccountSection.shouldAutoStartQRLogin(
            autoStartsQRLogin: false, homeBackend: .xiaomiCloud
        ))
        for backend in [HomeBackend.homeAssistant, .demo] {
            #expect(!MiAccountSection.shouldAutoStartQRLogin(
                autoStartsQRLogin: true, homeBackend: backend
            ))
            #expect(!MiAccountSection.shouldAutoStartQRLogin(
                autoStartsQRLogin: false, homeBackend: backend
            ))
        }
    }
}
