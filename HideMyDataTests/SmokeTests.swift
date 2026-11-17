import Testing
@testable import HideMyData

struct SmokeTests {
    @Test func appModuleLoads() {
        #expect(Bool(true))
    }
}
