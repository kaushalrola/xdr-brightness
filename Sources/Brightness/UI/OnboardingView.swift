import SwiftUI

struct OnboardingView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Brightness").font(.title.weight(.semibold))
                    Text("Unlock the full range of your XDR display")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                point(
                    icon: "display",
                    title: "What this does",
                    body: "Your display can reach far higher brightness than macOS normally allows for ordinary content. This app unlocks that range and applies it system-wide."
                )
                point(
                    icon: "battery.25",
                    title: "Battery and heat",
                    body: "Running at full brightness draws noticeably more power and warms the machine. You can have it turn off automatically on battery."
                )
                point(
                    icon: "film",
                    title: "HDR video",
                    body: "Boost would otherwise push HDR highlights past what the panel can show, so it eases off on its own while video is playing. You can adjust how far, or turn it off, in Settings."
                )
            }

            Spacer()

            HStack {
                Spacer()
                Button("Get Started", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480, height: 430)
    }

    private func point(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
