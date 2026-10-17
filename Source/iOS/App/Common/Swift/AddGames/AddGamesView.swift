// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(tvOS)
import PVWebServer
import SwiftUI

/// The tvOS Add Games screen (iFly's layout in iCube's tokens): the Wi-Fi upload card with a QR code
/// of the upload page, then a row into Nearby to continue a game from another device. Presented full
/// screen from the library's Import menu; iOS keeps `LibraryWebImportView`.
///
/// tvOS focus: Done and each row are single focus targets. The card is not focusable.
struct AddGamesView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var server = AddGamesServerState.make(isRunning: false, webURL: nil, webDavURL: nil)
  @FocusState private var focus: Focus?

  private enum Focus: Hashable { case done, continuity }

  private static let contentWidth: CGFloat = 1100
  private static let qrSide: CGFloat = 320
  private static let statusDot: CGFloat = 12

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
          header
          wifiCard
          continuityRow
        }
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, ICubeDesign.Spacing.l.rawValue)
      }
      .scrollClipDisabled()
      .background { ICubeRoom(style: .gradient) }
      .defaultFocus($focus, .continuity)
    }
    .onAppear {
      // Opening this screen is an explicit request for the server: start it on demand rather than
      // show "Starting…" at the one moment the user is asking for it. On the stack, not the root,
      // so pushing Nearby keeps the server up.
      NotificationCenter.default.post(name: Notification.Name(PVWebServerUserAccessRequestedNotificationName), object: nil)
      refresh()
    }
    .onDisappear {
      NotificationCenter.default.post(name: Notification.Name(PVWebServerUserAccessReleasedNotificationName), object: nil)
    }
    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center) {
      ICubeLeafHeader(title: L("Add Games"), subtitle: L("Library"))
      Spacer()
      Button(L("Done")) { dismiss() }
        .icubeText(.nav)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
        .buttonStyle(ICubeRowButtonStyle())
        .fixedSize()
        .focused($focus, equals: .done)
    }
    .focusSection()
  }

  // MARK: Wi-Fi card

  private var wifiCard: some View {
    VStack(spacing: ICubeDesign.Spacing.m.rawValue) {
      HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
        iconBadge("network")
        Text(L("Upload over Wi-Fi"))
          .icubeText(.section)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
        Spacer()
        statusBadge
      }

      QRCodeImage(string: server.qrPayload ?? "")
        .frame(width: Self.qrSide, height: Self.qrSide)
        .padding(ICubeDesign.Spacing.s.rawValue)
        .background(Color.white, in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
        .opacity(server.qrPayload == nil ? 0.3 : 1)
        .accessibilityLabel(L("QR code for the upload address"))

      if let url = server.uploadURL {
        urlPill(url)
        if let webDav = server.webDavURL {
          urlPill(webDav, label: L("Finder / WebDAV"))
        }
      } else {
        Text(server.status == .running ? L("Resolving network address…") : L("Starting…"))
          .icubeText(.body)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }

      Text(L("Scan the code or open the address in a browser on the same Wi-Fi, then drop in GameCube and Wii games. On a Mac, choose Go › Connect to Server in Finder and connect as Guest."))
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(ICubeDesign.Spacing.l.rawValue)
    .frame(maxWidth: .infinity)
    .icubePanel()
  }

  private var statusBadge: some View {
    HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
      Circle()
        .fill(server.status == .running
              ? Color.green // design-lint: allow server status dot; no status colour token yet
              : ICubeDesign.color(.textTertiary))
        .frame(width: Self.statusDot, height: Self.statusDot)
      Text(server.status == .running ? L("Running") : L("Starting…"))
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .accessibilityElement(children: .combine)
  }

  private func urlPill(_ url: String, label: String? = nil) -> some View {
    HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      if let label {
        Text(label)
          .icubeText(.tag)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      Text(url)
        .icubeText(.body)
        .monospaced()
        .foregroundStyle(ICubeDesign.color(.accent))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
    .padding(.vertical, ICubeDesign.Spacing.xs.rawValue)
    .background(Capsule().fill(ICubeDesign.color(.selectedFill)))
  }

  // MARK: Rows

  /// Pick up a session another device offers ("Continue on Another Device" in its pause menu). tvOS has
  /// no system Handoff, so Nearby is how a game in progress reaches the TV.
  private var continuityRow: some View {
    NavigationLink {
      // A pushed screen is transparent over the cover, which would show the library through it.
      ContinuityBrowseView()
        .environment(\.icubeLeafParentTitle, L("Add Games"))
        .background { ICubeRoom(style: .gradient) }
    } label: {
      rowLabel(icon: "iphone.gen3.radiowaves.left.and.right.circle",
               title: L("Continue from Another Device"),
               subtitle: L("Pick up a game in progress on your other iCube devices"))
    }
    .buttonStyle(ICubeRowButtonStyle())
    .focused($focus, equals: .continuity)
  }

  private func rowLabel(icon: String, title: String, subtitle: String) -> some View {
    HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
      iconBadge(icon)
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(title)
          .icubeText(.body)
          .foregroundStyle(ICubeDesign.color(.textPrimary))
        Text(subtitle)
          .icubeText(.detail)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      Spacer()
      Image(systemName: "chevron.right")
        .icubeText(.detail)
        .foregroundStyle(ICubeDesign.color(.textTertiary))
    }
  }

  private func iconBadge(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(ICubeDesign.symbolFont(.rail))
      .foregroundStyle(ICubeDesign.color(.accent))
      .frame(width: ICubeDesign.IconBadge.size, height: ICubeDesign.IconBadge.size)
      .background(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
          .fill(ICubeDesign.color(.accent).opacity(ICubeDesign.IconBadge.tintOpacity))
      )
  }

  private func refresh() {
    let web = PVWebServer.shared
    server = .make(isRunning: web.isWWWUploadServerRunning, webURL: web.urlString, webDavURL: web.webDavURLString)
  }
}
#endif
