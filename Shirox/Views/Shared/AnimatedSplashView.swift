import SwiftUI

struct AnimatedSplashView: View {
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
            VStack(spacing: 12) {
                Text("Shirox")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                Text("Anime · Manga · Tracker")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1.0 : 0.7)
        }
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.6)) { isVisible = true }
            }
        }
    }
}
