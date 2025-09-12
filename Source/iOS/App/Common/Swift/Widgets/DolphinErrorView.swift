import SwiftUI

/// A cute dolphin error state that makes failures less frustrating
struct DolphinErrorView: View {
  let title: String
  let message: String
  let retryAction: (() -> Void)?

  @State private var isWiggling = false

  init(title: String, message: String, retryAction: (() -> Void)? = nil) {
    self.title = title
    self.message = message
    self.retryAction = retryAction
  }

  var body: some View {
    VStack(spacing: 24) {
      // Sad but cute dolphin
      ZStack {
        // Subtle wave background
        RoundedRectangle(cornerRadius: 16)
          .fill(LinearGradient(
            colors: [Color.red.opacity(0.1), Color.orange.opacity(0.1)],
            startPoint: .leading,
            endPoint: .trailing
          ))
          .frame(width: 120, height: 80)

        // Dolphin with sad expression (using rotation to suggest sadness)
        Image("DolphinLogo")
          .resizable()
          .scaledToFit()
          .frame(width: 48, height: 48)
          .foregroundColor(.orange)
          .rotationEffect(.degrees(isWiggling ? -5 : 5))
          .scaleEffect(isWiggling ? 0.95 : 1.0)
          .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isWiggling)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16))

      VStack(spacing: 12) {
        // Error title with emoji
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
          Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.primary)
        }

        // Error message
        Text(message)
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)

        // Retry button if provided
        if let retry = retryAction {
          Button(action: retry) {
            HStack(spacing: 8) {
              Image(systemName: "arrow.clockwise")
              Text(L("Try Again"))
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(32)
    .onAppear {
      isWiggling = true
    }
  }
}

/// Compact version for inline error states
struct CompactDolphinError: View {
  let message: String
  @State private var isSad = false

  var body: some View {
    HStack(spacing: 12) {
      Image("DolphinLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
        .foregroundColor(.orange)
        .rotationEffect(.degrees(isSad ? -10 : 0))
        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isSad)
        .onAppear { isSad = true }

      Text(message)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.secondary)

      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.orange)
        .font(.system(size: 12))
    }
  }
}

#if DEBUG
struct DolphinErrorView_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 40) {
      DolphinErrorView(
        title: "Connection Failed",
        message: "Unable to connect to the game server. Please check your internet connection and try again.",
        retryAction: {}
      )

      CompactDolphinError(message: "Failed to load data")
    }
    .padding()
    .previewLayout(.sizeThatFits)
  }
}
#endif
