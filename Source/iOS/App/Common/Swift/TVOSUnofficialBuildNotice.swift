import SwiftUI
import UIKit

private struct TVUnofficialBuildNoticeView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Unofficial Build")
                    .font(.largeTitle).bold()
                    .foregroundStyle(.white)
                Text("This is an unofficial build intended for testing on tvOS. Features may be incomplete or unstable.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: 900)
                Button(action: onContinue) {
                    Text("Continue").bold()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }
}

@objc
final class TVOSUnofficialBuildNoticeHost: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: TVUnofficialBuildNoticeView { [weak self] in
            self?.dismiss(animated: true)
        })
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@_cdecl("TVOSMakeUnofficialBuildNoticeController")
public func TVOSMakeUnofficialBuildNoticeController() -> UIViewController {
    return TVOSUnofficialBuildNoticeHost()
}
