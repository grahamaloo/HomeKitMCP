//
//  HomeKitMCPApp.swift
//  HomeKitMCP
//
//  Created by Graham Kelly on 2/6/26.
//

import SwiftUI

// Entry point is main.swift (ResponsibilityRelaunch runs first).
struct HomeKitMCPApp: App {
    @StateObject private var serverManager = MCPServerManager(startServer: false)
    @Environment(\.scenePhase) private var scenePhase

    private static let isHeadless = CommandLine.arguments.contains("--headless")

    init() {
        #if targetEnvironment(macCatalyst)
        if !Self.isHeadless {
            StatusBarLoader.load()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst)
            VStack(spacing: 12) {
                Image(systemName: "house.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("HomeKit MCP is running")
                    .font(.headline)
                Text("You can close this window. The server continues in the menu bar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(minWidth: 300, minHeight: 200)
            .task {
                // This runs after the view has been fully rendered
                dismissWindow()

                // Start the MCP server (deferred from init so the test host never starts it)
                await serverManager.startServer()
            }
            .task {
                // Wait for termination notification and shut down cleanly
                await withCheckedContinuation { continuation in
                    NotificationCenter.default.addObserver(
                        forName: UIApplication.willTerminateNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        continuation.resume()
                    }
                }
                await serverManager.shutdown()
            }
            #else
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text("Not Supported")
                    .font(.headline)
                Text("HomeKit MCP requires macOS. Build and run this app as a Mac Catalyst target.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(minWidth: 300, minHeight: 200)
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    private func dismissWindow() {
        if let bridge = StatusBarLoader.bridge {
            bridge.hideAllWindows()
        } else if Self.isHeadless {
            // No status bar plugin in headless mode — hide windows and dock icon directly
            for window in UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows) {
                window.isHidden = true
            }
        }
    }
    #endif
}
