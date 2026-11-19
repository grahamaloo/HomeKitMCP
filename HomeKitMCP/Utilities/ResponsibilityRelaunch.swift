import Darwin
import Foundation

/// Re-spawns the headless server as its own TCC responsible process, so the
/// MCP client's host app is not blamed. See README Troubleshooting.
enum ResponsibilityRelaunch {
    static let markerKey = "HOMEKITMCP_RESPONSIBILITY_DISCLAIMED"

    // MARK: - Pure decision logic (unit-tested)

    static func shouldRelaunch(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--headless") && environment[markerKey] != "1"
    }

    static func childEnvironment(from environment: [String: String]) -> [String: String] {
        var env = environment
        env[markerKey] = "1"
        return env
    }

    /// Shell convention: the exit status for a normal exit, 128 + N for signal N.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    // MARK: - Process control

    /// Relaunches with responsibility disclaimed when needed. Never returns in
    /// the parent once the child has started.
    static func relaunchIfNeeded() {
        let info = ProcessInfo.processInfo
        guard shouldRelaunch(arguments: info.arguments, environment: info.environment) else { return }

        guard let executable = Bundle.main.executablePath else {
            Log.error("ResponsibilityRelaunch: no executable path; running without disclaim (HomeKit access may be killed by TCC)")
            return
        }

        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            Log.error("ResponsibilityRelaunch: responsibility_spawnattrs_setdisclaim not found; running without disclaim (HomeKit access may be killed by TCC)")
            return
        }
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

        var attr: posix_spawnattr_t?
        let initResult = posix_spawnattr_init(&attr)
        guard initResult == 0 else {
            Log.error("ResponsibilityRelaunch: posix_spawnattr_init failed: \(String(cString: strerror(initResult))); running without disclaim")
            return
        }
        defer { posix_spawnattr_destroy(&attr) }

        let disclaimResult = setDisclaim(&attr, 1)
        guard disclaimResult == 0 else {
            Log.error("ResponsibilityRelaunch: setdisclaim failed (\(disclaimResult)); running without disclaim")
            return
        }

        // The child starts with an empty signal mask, not the parent's blocked one.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        let maskResult = posix_spawnattr_setsigmask(&attr, &emptyMask)
        let flagsResult = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK))
        guard maskResult == 0, flagsResult == 0 else {
            Log.error("ResponsibilityRelaunch: spawn signal-mask setup failed (\(maskResult), \(flagsResult)); running without disclaim")
            return
        }

        let envStrings = childEnvironment(from: info.environment).map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        // Block the forwarded signals until childPID and the handlers are set,
        // so a signal in that window is held, then forwarded, not lost.
        var forwarded = sigset_t()
        sigemptyset(&forwarded)
        for sig in forwardedSignals { sigaddset(&forwarded, sig) }
        var previousMask = sigset_t()
        guard sigprocmask(SIG_BLOCK, &forwarded, &previousMask) == 0 else {
            Log.error("ResponsibilityRelaunch: sigprocmask failed: \(String(cString: strerror(errno))); running without disclaim")
            return
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, nil, &attr, CommandLine.unsafeArgv, &envp)
        guard spawnResult == 0 else {
            sigprocmask(SIG_SETMASK, &previousMask, nil)
            Log.error("ResponsibilityRelaunch: posix_spawn failed: \(String(cString: strerror(spawnResult))); running without disclaim")
            return
        }

        childPID = pid
        for sig in forwardedSignals {
            signal(sig, forwardSignalToChild)
        }
        sigprocmask(SIG_SETMASK, &previousMask, nil)
        Log.info("ResponsibilityRelaunch: started disclaimed child pid \(pid)")

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else {
                Log.error("ResponsibilityRelaunch: waitpid failed: \(String(cString: strerror(errno)))")
                exit(1)
            }
        }
        exit(exitCode(fromWaitStatus: status))
    }
}

private let forwardedSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

/// The child's pid, read by the C signal handler below.
private var childPID: pid_t = 0

private func forwardSignalToChild(_ sig: Int32) {
    if childPID > 0 {
        kill(childPID, sig)
    }
}
