import SwiftUI

struct AnimatedSplashView: View {
    @State private var isVisible = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
            VStack(spacing: 16) {
                // App icon — large rounded square with a black → dark gray gradient.
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 80, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.black, Color(white: 0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    // Subtle pulse — oscillates between 1.0 and 1.05.
                    .scaleEffect(isPulsing ? 1.05 : 1.0)

                Text("Shirox")
                    .font(.system(size: 48, weight: .heavy, design: .rounded))

                Text("Anime · Manga · Tracker")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .opacity(isVisible ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.6)) { isVisible = true }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }
}
