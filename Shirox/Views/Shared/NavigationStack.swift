import SwiftUI

// iOS 15 backport — shadows SwiftUI.NavigationStack (iOS 16+).
// iOS 16+ gets the real NavigationStack. Only iOS 15 falls back to NavigationView (.stack style,
// so iPad shows no sidebar): on iOS 27 a NavigationView stopped pushing for good after a
// swipe-back began during a push animation, which left every link in the app dead.
struct NavigationStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if !os(iOS)
            SwiftUI.NavigationStack { content }
        #else
            if #available(iOS 16, *) {
                SwiftUI.NavigationStack { content }
            } else {
                NavigationView { content }
                    .navigationViewStyle(.stack)
            }
        #endif
    }
}
