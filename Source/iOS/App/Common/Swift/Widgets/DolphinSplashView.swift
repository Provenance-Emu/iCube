import SwiftUI

/// A delightful animated splash screen featuring multiple jumping dolphins
struct DolphinSplashView: View {
  @State private var dolphinOffsets: [CGFloat] = [0, 0, 0, 0, 0]
  @State private var dolphinRotations: [Double] = [0, 0, 0, 0, 0]
  @State private var dolphinScales: [CGFloat] = [1, 1, 1, 1, 1]
  @State private var titleScale: CGFloat = 0.8
  @State private var titleOpacity: Double = 0.0
  @State private var versionOpacity: Double = 0.0
  @State private var waveOffset: CGFloat = 0
  @State private var sparkleOpacity: Double = 0

  private var appVersion: String {
    VersionManager.shared().appVersion.userFacing
  }

  private var coreVersion: String {
    VersionManager.shared().coreVersion
  }

  var body: some View {
    ZStack {
      // Gradient background
      LinearGradient(
        colors: [
          Color.blue.opacity(0.3),
          Color.cyan.opacity(0.2),
          Color.blue.opacity(0.1)
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      // Animated wave background
      WaveShape(offset: waveOffset)
        .fill(LinearGradient(
          colors: [Color(.dolphinTint).opacity(0.2), Color.cyan.opacity(0.3)],
          startPoint: .leading,
          endPoint: .trailing
        ))
        .frame(height: 120)
        .offset(y: 100)
        .animation(.linear(duration: 3.0).repeatForever(autoreverses: false), value: waveOffset)

      VStack(spacing: 32) {
        Spacer()

        // Multiple jumping dolphins
        ZStack {
          ForEach(0..<5, id: \.self) { index in
            Image("DolphinLogo")
              .resizable()
              .scaledToFit()
              .frame(width: dolphinSize(for: index), height: dolphinSize(for: index))
              .foregroundColor(dolphinColor(for: index))
              .scaleEffect(dolphinScales[index])
              .rotationEffect(.degrees(dolphinRotations[index]))
              .offset(
                x: dolphinXPosition(for: index),
                y: dolphinOffsets[index]
              )
              .animation(
                .easeInOut(duration: dolphinDuration(for: index))
                .delay(dolphinDelay(for: index))
                .repeatForever(autoreverses: true),
                value: dolphinOffsets[index]
              )
              .animation(
                .easeInOut(duration: dolphinDuration(for: index) * 0.8)
                .delay(dolphinDelay(for: index))
                .repeatForever(autoreverses: true),
                value: dolphinRotations[index]
              )
              .animation(
                .easeInOut(duration: dolphinDuration(for: index) * 1.2)
                .delay(dolphinDelay(for: index))
                .repeatForever(autoreverses: true),
                value: dolphinScales[index]
              )
          }

          // Sparkle effects
          ForEach(0..<12, id: \.self) { index in
            Image(systemName: "sparkle")
              .font(.system(size: CGFloat.random(in: 8...16)))
              .foregroundColor(Color(.dolphinTint).opacity(0.6))
              .offset(
                x: cos(Double(index) * .pi / 6) * 140,
                y: sin(Double(index) * .pi / 6) * 140
              )
              .opacity(sparkleOpacity)
              .animation(
                .easeInOut(duration: 1.5)
                .delay(Double(index) * 0.1)
                .repeatForever(autoreverses: true),
                value: sparkleOpacity
              )
          }
        }
        .frame(height: 200)

        // App title with animation
        VStack(spacing: 16) {
          Text("DolphiniOS")
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .foregroundStyle(
              LinearGradient(
                colors: [.blue, .cyan, .blue],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .scaleEffect(titleScale)
            .opacity(titleOpacity)
            .animation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.5), value: titleScale)
            .animation(.easeIn(duration: 0.8).delay(0.3), value: titleOpacity)

          Text("🐬 GameCube & Wii emulator 🌊")
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundColor(.blue.opacity(0.8))
            .multilineTextAlignment(.center)
            .opacity(titleOpacity)
            .animation(.easeIn(duration: 0.8).delay(0.8), value: titleOpacity)
        }

        Spacer()

        // Version information with cute formatting
        VStack(spacing: 8) {
          Text("© 2003-2015+ Dolphin Team")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)

          Text("© 2019-2025+ DolphiniOS Project")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .scaledToFit()

          HStack(spacing: 20) {
            VStack(spacing: 4) {
              Text("App Version")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.blue.opacity(0.7))
              Text(appVersion)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            }

            VStack(spacing: 4) {
              HStack(spacing: 4) {
                Image("DolphinLogo")
                  .resizable()
                  .scaledToFit()
                  .frame(width: 12, height: 12)
                Text("Core Version")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundColor(.blue.opacity(0.7))
              }
              Text(coreVersion)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            }
          }
        }
        .opacity(versionOpacity)
        .animation(.easeIn(duration: 0.6).delay(1.5), value: versionOpacity)

        Spacer()
      }
      .padding(.horizontal, 32)
    }
    .onAppear {
      startSplashAnimation()
    }
  }

  // MARK: - Animation Helpers

  private func startSplashAnimation() {
    // Start wave animation
    waveOffset = 200

    // Start dolphin jumping animations
    for i in 0..<5 {
      dolphinOffsets[i] = -CGFloat.random(in: 30...80)
      dolphinRotations[i] = Double.random(in: -15...15)
      dolphinScales[i] = CGFloat.random(in: 1.1...1.3)
    }

    // Start text animations
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      titleOpacity = 1.0
      titleScale = 1.0
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      sparkleOpacity = 0.8
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      versionOpacity = 1.0
    }
  }

  // MARK: - Dolphin Animation Properties

  private func dolphinSize(for index: Int) -> CGFloat {
    switch index {
    case 0: return 56 // Main central dolphin
    case 1, 2: return 44 // Side dolphins
    case 3, 4: return 32 // Smaller background dolphins
    default: return 40
    }
  }

  private func dolphinColor(for index: Int) -> Color {
    switch index {
    case 0: return .blue
    case 1, 2: return .cyan
    case 3, 4: return .blue.opacity(0.7)
    default: return .blue
    }
  }

  private func dolphinXPosition(for index: Int) -> CGFloat {
    switch index {
    case 0: return 0     // Center
    case 1: return -60   // Left
    case 2: return 60    // Right
    case 3: return -100  // Far left
    case 4: return 100   // Far right
    default: return 0
    }
  }

  private func dolphinDuration(for index: Int) -> Double {
    switch index {
    case 0: return 2.0   // Main dolphin - steady rhythm
    case 1: return 1.8   // Slightly faster
    case 2: return 2.2   // Slightly slower
    case 3: return 1.5   // Quick jumps
    case 4: return 2.5   // Leisurely jumps
    default: return 2.0
    }
  }

  private func dolphinDelay(for index: Int) -> Double {
    Double(index) * 0.2  // Staggered start times
  }
}

// MARK: - Wave Shape

struct WaveShape: Shape {
  var offset: CGFloat

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

    for x in stride(from: 0, through: width, by: 2) {
      let relativeX = x / width
      let sine = sin((relativeX * .pi * 4) + (offset * 0.02))
      let y = midHeight + sine * (height * 0.3)
      path.addLine(to: CGPoint(x: x, y: y))
    }

    path.addLine(to: CGPoint(x: width, y: height))
    path.addLine(to: CGPoint(x: 0, y: height))
    path.closeSubpath()

    return path
  }
}

#if DEBUG
struct DolphinSplashView_Previews: PreviewProvider {
  static var previews: some View {
    DolphinSplashView()
      .previewLayout(.sizeThatFits)
  }
}
#endif
