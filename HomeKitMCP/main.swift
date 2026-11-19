// Entry point. Runs before UIKit starts, so the headless parent process
// never touches HomeKit or the UI. See ResponsibilityRelaunch.
import SwiftUI

#if targetEnvironment(macCatalyst)
ResponsibilityRelaunch.relaunchIfNeeded()
#endif
HomeKitMCPApp.main()
