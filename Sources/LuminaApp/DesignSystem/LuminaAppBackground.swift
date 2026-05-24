import SwiftUI

struct LuminaAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    LuminaTheme.pearl,
                    Color(red: 1.00, green: 0.97, blue: 0.90),
                    Color(red: 0.95, green: 1.00, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(LuminaTheme.softAmber.opacity(0.34))
                .blur(radius: 46)
                .frame(width: 240, height: 240)
                .offset(x: -120, y: -220)
            Circle()
                .fill(LuminaTheme.mint.opacity(0.20))
                .blur(radius: 54)
                .frame(width: 220, height: 220)
                .offset(x: 130, y: -60)
            Circle()
                .fill(Color.white.opacity(0.50))
                .blur(radius: 36)
                .frame(width: 260, height: 260)
                .offset(x: 40, y: 300)
        }
        .ignoresSafeArea()
    }
}
