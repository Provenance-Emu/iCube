import SwiftUI

/// A delightful progress view featuring a swimming dolphin
struct DolphinProgressView: View {
  let progress: Double // 0.0 to 1.0
  let width: CGFloat
  let showPercentage: Bool
  let direction: Direction

  enum Direction {
    case leftToRight
    case rightToLeft
  }

  @State private var isAnimating = false
  @State private var waveOffset: CGFloat = 0

  init(progress: Double, width: CGFloat = 140, showPercentage: Bool = false, direction: Direction = .leftToRight) {
    self.progress = progress
    self.width = width
    self.showPercentage = showPercentage
    self.direction = direction
  }

  var body: some View {
    HStack(spacing: 8) {
      // Swimming dolphin progress bar
      ZStack(alignment: direction == .leftToRight ? .leading : .trailing) {
        // Background wave
        RoundedRectangle(cornerRadius: 8)
          .fill(LinearGradient(
            colors: [Color.blue.opacity(0.1), Color.cyan.opacity(0.15)],
            startPoint: direction == .leftToRight ? .leading : .trailing,
            endPoint: direction == .leftToRight ? .trailing : .leading
          ))
          .frame(width: width, height: 16)

        // Animated wave pattern
        WaveProgressShape(offset: waveOffset, direction: direction)
          .fill(LinearGradient(
            colors: [Color.blue.opacity(0.3), Color.cyan.opacity(0.4)],
            startPoint: direction == .leftToRight ? .leading : .trailing,
            endPoint: direction == .leftToRight ? .trailing : .leading
          ))
          .frame(width: width, height: 16)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: waveOffset)

        // Progress fill
        RoundedRectangle(cornerRadius: 8)
          .fill(LinearGradient(
            colors: [Color.blue.opacity(0.6), Color.cyan.opacity(0.7)],
            startPoint: direction == .leftToRight ? .leading : .trailing,
            endPoint: direction == .leftToRight ? .trailing : .leading
          ))
          .frame(width: max(0, width * CGFloat(progress)), height: 16)
          .animation(.easeInOut(duration: 0.3), value: progress)

        // Swimming dolphin
        HStack {
          if direction == .rightToLeft { Spacer() }

          Image("DolphinLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .foregroundColor(.blue)
            .scaleEffect(isAnimating ? 1.1 : 0.9, anchor: .center)
            .rotationEffect(.degrees(isAnimating ? 2 : -2))
            .scaleEffect(x: direction == .leftToRight ? -1 : 1) // Mirror for left-to-right to face right
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
            .offset(x: (width - 20) * CGFloat(progress) * (direction == .leftToRight ? 1 : -1))
            .animation(.easeInOut(duration: 0.3), value: progress)

          if direction == .leftToRight { Spacer() }
        }
        .frame(width: width)
      }
      .onAppear {
        isAnimating = true
        waveOffset = 100
      }

      // Optional percentage
      if showPercentage {
        Text("\(Int(progress * 100))%")
          .font(.caption2)
          .foregroundColor(.secondary)
          .monospacedDigit()
          .frame(minWidth: 32)
      }
    }
  }
}

/// Compact version for smaller spaces
struct CompactDolphinProgress: View {
  let progress: Double
  let direction: DolphinProgressView.Direction

  @State private var isSwimming = false

  init(progress: Double, direction: DolphinProgressView.Direction = .leftToRight) {
    self.progress = progress
    self.direction = direction
  }

  var body: some View {
    HStack(spacing: 6) {
      // Mini swimming dolphin
      Image("DolphinLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
        .foregroundColor(.blue)
        .scaleEffect(isSwimming ? 1.1 : 0.9)
        .scaleEffect(x: direction == .leftToRight ? -1 : 1)
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isSwimming)
        .onAppear { isSwimming = true }

      // Mini progress bar
      ProgressView(value: progress)
        .progressViewStyle(.linear)
        .frame(width: 60)
        .tint(.blue)

      Text("\(Int(progress * 100))%")
        .font(.caption2)
        .foregroundColor(.secondary)
        .monospacedDigit()
    }
  }
}

/// Wave shape for animated background
struct WaveProgressShape: Shape {
  var offset: CGFloat
  let direction: DolphinProgressView.Direction

  var animatableData: CGFloat {
    get { offset }
    set { offset = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()

    let width = rect.width
    let height = rect.height
    let midHeight = height * 0.5

    path.move(to: CGPoint(x: 0, y: midHeight))

    let waveLength: CGFloat = 30
    let amplitude: CGFloat = 3

    for x in stride(from: 0, through: width, by: 1) {
      let progress = x / width
      let waveProgress = (progress * waveLength + offset * 0.1).truncatingRemainder(dividingBy: waveLength * 2)
      let sine = sin(waveProgress * .pi / waveLength)
      let y = midHeight + sine * amplitude

      if x == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }

    // Close the shape for filling
    path.addLine(to: CGPoint(x: width, y: height))
    path.addLine(to: CGPoint(x: 0, y: height))
    path.closeSubpath()

    return path
  }
}

#if DEBUG
struct DolphinProgressView_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 20) {
      // Different progress values
      DolphinProgressView(progress: 0.3, width: 140, showPercentage: true, direction: .leftToRight)
      DolphinProgressView(progress: 0.7, width: 80, direction: .rightToLeft)

      // Compact versions
      CompactDolphinProgress(progress: 0.5, direction: .leftToRight)
      CompactDolphinProgress(progress: 0.8, direction: .rightToLeft)

      // Full width
      DolphinProgressView(progress: 0.65, width: 200, showPercentage: true, direction: .leftToRight)
    }
    .padding()
    .previewLayout(.sizeThatFits)
  }
}
#endif
