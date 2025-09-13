import SwiftUI

/// A delightful loading animation featuring the cute dolphin logo
struct DolphinLoadingView: View {
  @State private var animationOffset: CGFloat = -100
  @State private var rotationAngle: Double = 0
  @State private var scale: CGFloat = 1.0

  let message: String
  let showMessage: Bool

  init(message: String = L("Loading..."), showMessage: Bool = true) {
    self.message = message
    self.showMessage = showMessage
  }

  var body: some View {
    VStack(spacing: 20) {
      // Animated swimming dolphin
      ZStack {
        // Wave-like background
        RoundedRectangle(cornerRadius: 20)
          .fill(LinearGradient(
            colors: [Color.blue.opacity(0.1), Color.cyan.opacity(0.2)],
            startPoint: .leading,
            endPoint: .trailing
          ))
          .frame(width: 200, height: 80)

        // Swimming dolphin
        Image("DolphinLogo")
          .resizable()
          .scaledToFit()
          .frame(width: 40, height: 40)
          .foregroundColor(.blue)
          .scaleEffect(scale)
          .rotationEffect(.degrees(rotationAngle))
          .offset(x: animationOffset)
          .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: animationOffset)
          .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: rotationAngle)
          .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: scale)
      }
      .clipShape(RoundedRectangle(cornerRadius: 20))

      // Loading message
      if showMessage {
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: Color("DolphinTint")))
              .scaleEffect(0.8)

            Text(message)
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.secondary)
          }

          // Copyright footer (no clipping)
          Text("© DolphiniOS Team")
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
            .frame(maxWidth: 240)
        }
      }
    }
    .onAppear {
      startAnimation()
    }
  }

  private func startAnimation() {
    withAnimation {
      animationOffset = 100
      rotationAngle = 15
      scale = 1.2
    }
  }
}

/// Compact version for inline use
struct CompactDolphinLoader: View {
  @State private var isRotating = false

  var body: some View {
    Image("DolphinLogo")
      .resizable()
      .scaledToFit()
      .frame(width: 24, height: 24)
      .foregroundColor(.blue)
      .rotationEffect(.degrees(isRotating ? 360 : 0))
      .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: isRotating)
      .onAppear { isRotating = true }
  }
}

#if DEBUG
struct DolphinLoadingView_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 40) {
      DolphinLoadingView(message: "Loading games...")
      CompactDolphinLoader()
    }
    .padding()
    .previewLayout(.sizeThatFits)
  }
}
#endif
