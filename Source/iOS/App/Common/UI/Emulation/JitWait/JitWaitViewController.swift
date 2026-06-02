// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class JitWaitViewController: UIViewController {
  @objc weak var delegate: JitWaitViewControllerDelegate?

  var timer: Timer?
  var isShowingError: Bool = false

  override func viewDidLoad() {
    super.viewDidLoad()

    timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(checkJit), userInfo: nil, repeats: true)

    JitManager.shared().acquireJitByAltServer()
    JitManager.shared().acquireJitByJitStreamer()
  }

  override func viewWillAppear(_ animated: Bool) {
    showAcquisitionErrorIfNecessary()
  }

  @objc func checkJit() {
    if isShowingError {
      return
    }

    let manager = JitManager.shared()

    manager.recheckIfJitIsAcquired()

    if manager.acquiredJit {
      timer?.invalidate()
      delegate?.didFinishJitScreen(result: .jitAcquired, sender: self)

      return
    }

    showAcquisitionErrorIfNecessary()
  }

  func showAcquisitionErrorIfNecessary() {
    let manager = JitManager.shared()

    if let error = manager.acquisitionError {
      manager.acquisitionError = nil
      isShowingError = true

      let alertController = UIAlertController(title: DOLCoreLocalizedString("Error"), message: error, preferredStyle: .alert)
      alertController.addAction(UIAlertAction(title: DOLCoreLocalizedString("OK"), style: .default, handler: { _ in
        self.isShowingError = false
      }))

      present(alertController, animated: true, completion: nil)
    }
  }

  @IBAction func helpPressed(_ sender: Any) {
    let url = URL(string: "https://dolphinios.oatmealdome.me/jit-help")
    UIApplication.shared.open(url!, options: [:], completionHandler: nil)
  }

  @IBAction func noJitPressed(_ sender: Any) {
    timer?.invalidate()
    delegate?.didFinishJitScreen(result: .noJitRequested, sender: self)
  }

  @IBAction func cancelPressed(_ sender: Any) {
    timer?.invalidate()
    delegate?.didFinishJitScreen(result: .cancel, sender: self)
  }
}
