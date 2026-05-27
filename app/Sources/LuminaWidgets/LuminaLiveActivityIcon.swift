import SwiftUI

struct LuminaLiveActivityIcon: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.yellow, Color.orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: progress >= 1 ? "checkmark" : "sparkles")
                .font(.headline.weight(.bold))
                .foregroundStyle(.black)
        }
        .frame(width: 38, height: 38)
        .shadow(color: Color.yellow.opacity(0.22), radius: 8, y: 3)
    }
}
