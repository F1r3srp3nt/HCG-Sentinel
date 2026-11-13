import SentinelCore
import SwiftUI
import UIKit

@main
struct HCGSentinelApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var router = Router()

    init() {
        HCGSentinelApp.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(ModelInjection(app: app, router: router))
                .onAppear { app.start() }
                .onOpenURL { url in
                    // Deep links navigate only. They can never start an operation.
                    if let section = DeepLink.section(from: url) { router.open(section) }
                }
        }
    }

    private static func configureAppearance() {
        let background = UIColor.black
        let text = UIColor(red: 0.94, green: 0.96, blue: 0.98, alpha: 1)
        let cyan = UIColor(red: 0.25, green: 0.87, blue: 0.96, alpha: 1)

        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = background
        navigation.titleTextAttributes = [.foregroundColor: text]
        navigation.largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().tintColor = cyan

        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = background
        UITabBar.appearance().standardAppearance = tabs
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabs
        }
        UITabBar.appearance().tintColor = cyan
        UITabBar.appearance().unselectedItemTintColor = UIColor(white: 0.62, alpha: 1)

        // TextEditor draws its own background on iOS 14 and 15 unless the underlying text view is cleared.
        UITextView.appearance().backgroundColor = .clear
    }
}

/// Supplies every shared model to a view tree. Sheets get their own copy so
/// they work the same on iOS 14 as on later releases.
struct ModelInjection: ViewModifier {
    let app: AppModel
    let router: Router

    func body(content: Content) -> some View {
        content
            .environmentObject(app)
            .environmentObject(router)
            .environmentObject(app.bluetooth)
            .environmentObject(app.network)
            .environmentObject(app.radio)
            .environmentObject(app.requests)
            .environmentObject(app.helper)
            .environmentObject(app.networkCheck)
            .environmentObject(app.connection)
    }
}
