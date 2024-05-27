//
//  AppDelegate.swift
//  assistant2
//
//  Created by User on 24.05.2024.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    /// Called when the app finishes launching, used here to set global app settings.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Disable screen dimming and auto-lock to keep the app active during long operations.
        UIApplication.shared.isIdleTimerDisabled = true

        // Enable battery monitoring to allow the app to adapt its behavior based on battery level.
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Store the app version and build version in UserDefaults for easy access elsewhere in the app.
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            UserDefaults.standard.set("\(appVersion) (\(buildVersion))", forKey: "app_version")
        }

        // Store the device's UUID in UserDefaults for identification purposes.
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            UserDefaults.standard.set(uuid, forKey: "uuid")
        }

        // Ensure UserDefaults changes are immediately saved.
        UserDefaults.standard.synchronize()

        return true
    }
}

