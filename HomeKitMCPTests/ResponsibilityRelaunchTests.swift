import Testing
@testable import HomeKitMCP

struct ResponsibilityRelaunchTests {

    private let marker = ResponsibilityRelaunch.markerKey

    // MARK: - shouldRelaunch

    @Test func relaunchesWhenHeadlessAndNotYetDisclaimed() {
        #expect(ResponsibilityRelaunch.shouldRelaunch(
            arguments: ["/path/HomeKitMCP", "--headless"],
            environment: [:]
        ))
    }

    @Test func doesNotRelaunchTheDisclaimedChild() {
        #expect(!ResponsibilityRelaunch.shouldRelaunch(
            arguments: ["/path/HomeKitMCP", "--headless"],
            environment: [marker: "1"]
        ))
    }

    @Test func doesNotRelaunchWithoutHeadless() {
        // GUI launches via LaunchServices are already their own responsible
        // process, and the XCTest host never passes --headless.
        #expect(!ResponsibilityRelaunch.shouldRelaunch(
            arguments: ["/path/HomeKitMCP"],
            environment: [:]
        ))
    }

    @Test func relaunchesWhenMarkerHasAnotherValue() {
        #expect(ResponsibilityRelaunch.shouldRelaunch(
            arguments: ["/path/HomeKitMCP", "--headless"],
            environment: [marker: "0"]
        ))
    }

    // MARK: - childEnvironment

    @Test func childEnvironmentAddsMarkerAndKeepsTheRest() {
        let env = ResponsibilityRelaunch.childEnvironment(from: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        #expect(env[marker] == "1")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/x")
        #expect(env.count == 3)
    }

    // MARK: - exitCode(fromWaitStatus:)

    @Test func exitCodeForNormalExit() {
        #expect(ResponsibilityRelaunch.exitCode(fromWaitStatus: 0) == 0)
        #expect(ResponsibilityRelaunch.exitCode(fromWaitStatus: 1 << 8) == 1)
        #expect(ResponsibilityRelaunch.exitCode(fromWaitStatus: 42 << 8) == 42)
    }

    @Test func exitCodeForSignalUsesShellConvention() {
        // SIGABRT (6) and SIGTERM (15): 128 + signal number.
        #expect(ResponsibilityRelaunch.exitCode(fromWaitStatus: 6) == 134)
        #expect(ResponsibilityRelaunch.exitCode(fromWaitStatus: 15) == 143)
    }
}
