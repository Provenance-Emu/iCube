// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(iOS)
struct GeckoCodesModal: UIViewControllerRepresentable {
  let item: TVGameItem
  func makeUIViewController(context: Context) -> UIViewController {
    let sb = UIStoryboard(name: "Gecko", bundle: nil)
    let vc = sb.instantiateInitialViewController()!
    let list: UIViewController = (vc as? UINavigationController)?.topViewController ?? vc
    // Bridge C++ property types
    if let gcv = list as? NSObject {
      // gameId std::string
      let gid = item.gameID as NSString
      if gcv.responds(to: Selector(("setGameIdString:"))) { gcv.perform(Selector(("setGameIdString:")), with: gid) } else { gcv.setValue(gid, forKey: "gameId") }
      // gametdbId std::string
      let gtdb = item.gametdbID as NSString
      if gcv.responds(to: Selector(("setGametdbIdString:"))) { gcv.perform(Selector(("setGametdbIdString:")), with: gtdb) } else { gcv.setValue(gtdb, forKey: "gametdbId") }
      // revision u16
      let rev = NSNumber(value: Int(item.revision))
      if gcv.responds(to: Selector(("setRevisionNumber:"))) { gcv.perform(Selector(("setRevisionNumber:")), with: rev) } else { gcv.setValue(rev, forKey: "revision") }
    }
    let nav = (vc as? UINavigationController) ?? UINavigationController(rootViewController: list)
    list.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: context.coordinator, action: #selector(Coordinator.close))
    return nav
  }
  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator: NSObject { @objc func close() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.keyWindow?.rootViewController { root.dismiss(animated: true) } } }
}

struct ActionReplayCodesModal: UIViewControllerRepresentable {
  let item: TVGameItem
  func makeUIViewController(context: Context) -> UIViewController {
    let sb = UIStoryboard(name: "ActionReplay", bundle: nil)
    let vc = sb.instantiateInitialViewController()!
    let list: UIViewController = (vc as? UINavigationController)?.topViewController ?? vc
    if let ar = list as? NSObject {
      // gameId std::string
      let gid = item.gameID as NSString
      if ar.responds(to: Selector(("setGameIdString:"))) { ar.perform(Selector(("setGameIdString:")), with: gid) } else { ar.setValue(gid, forKey: "gameId") }
      // revision u16
      let rev = NSNumber(value: Int(item.revision))
      if ar.responds(to: Selector(("setRevisionNumber:"))) { ar.perform(Selector(("setRevisionNumber:")), with: rev) } else { ar.setValue(rev, forKey: "revision") }
    }
    let nav = (vc as? UINavigationController) ?? UINavigationController(rootViewController: list)
    list.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: context.coordinator, action: #selector(Coordinator.close))
    return nav
  }
  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator() }
  final class Coordinator: NSObject { @objc func close() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, let root = scene.keyWindow?.rootViewController { root.dismiss(animated: true) } } }
}
#endif
