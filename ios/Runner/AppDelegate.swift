import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let savedFiles = SavedAttachmentAccess()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "mailshelf/saved_files",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result("unavailable") }
      self.savedFiles.handle(call, result: result)
    }
  }
}

// Keep the picker URL itself: converting it to a path discards provider access.
// Tokens are session-only, never persisted or logged.
private final class SavedAttachmentAccess: NSObject, UIDocumentPickerDelegate,
  UIDocumentInteractionControllerDelegate {
  private var pendingSave: FlutterResult?
  private var locations: [String: (url: URL, scoped: Bool)] = [:]
  private var previewPresenter: UIViewController?
  private var viewer: UIDocumentInteractionController?

  private var presenter: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var controller = scenes.filter { $0.activationState == .foregroundActive }
      .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "save":
      guard pendingSave == nil, let controller = presenter,
        let path = args["source"] as? String else {
        result(FlutterError(code: "save_unavailable", message: "Unable to show the file picker.", details: nil))
        return
      }
      let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      let roots = [URL(fileURLWithPath: NSTemporaryDirectory())]
        + FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
      let isPrivateTemporary = roots.contains { root in
        let path = root.resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return source.path.hasPrefix("/" + path + "/")
      }
      guard isPrivateTemporary,
        FileManager.default.fileExists(atPath: source.path) else {
        result(FlutterError(code: "invalid_source", message: "The temporary attachment is unavailable.", details: nil))
        return
      }
      pendingSave = result
      let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
      picker.delegate = self
      controller.present(picker, animated: true)
    case "open":
      guard viewer == nil, let token = args["location"] as? String,
        let entry = locations[token], let controller = presenter else {
        result("unavailable")
        return
      }
      // This check runs while the original picker URL's access is still active.
      guard FileManager.default.fileExists(atPath: entry.url.path) else {
        result("unavailable")
        return
      }
      let document = UIDocumentInteractionController(url: entry.url)
      document.delegate = self
      previewPresenter = controller
      viewer = document
      if document.presentPreview(animated: true) {
        result("opened")
      } else if document.presentOpenInMenu(
        from: CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1),
        in: controller.view, animated: true
      ) {
        result("opened")
      } else {
        viewer = nil
        previewPresenter = nil
        result("no_app")
      }
    case "release":
      if let token = args["location"] as? String,
        let entry = locations.removeValue(forKey: token), entry.scoped {
        entry.url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let completion = pendingSave else { return }
    pendingSave = nil
    guard let url = urls.first else { completion(nil); return }
    let token = UUID().uuidString
    locations[token] = (url, url.startAccessingSecurityScopedResource())
    // The source can now be cleaned up; only the chosen destination is retained.
    completion(token)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let completion = pendingSave
    pendingSave = nil
    completion?(nil)
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    return previewPresenter ?? UIViewController()
  }

  func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    viewer = nil
    previewPresenter = nil
  }

  func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
    viewer = nil
    previewPresenter = nil
  }

  deinit {
    for entry in locations.values where entry.scoped {
      entry.url.stopAccessingSecurityScopedResource()
    }
  }
}
