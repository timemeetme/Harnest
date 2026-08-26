import Foundation
import UIKit
import Contacts
import EventKit
import CoreLocation
import AVFoundation
import Photos
import PhotosUI
import UserNotifications
import Network
import UniformTypeIdentifiers

/// UI operations the bridge needs from the host (pickers). Mirrors UiLauncher.kt.
protocol UiLauncher: AnyObject {
    func takePicture() async -> URL?
    func pickImage() async -> URL?
    func pickDocument(mime: String?) async -> URL?
}

/// Presents system pickers on the key window; wraps delegate callbacks in continuations.
final class PickerLauncher: NSObject, UiLauncher, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {

    private var pictureCont: CheckedContinuation<URL?, Never>?
    private var imageCont: CheckedContinuation<URL?, Never>?
    private var docCont: CheckedContinuation<URL?, Never>?
    private let main = DispatchQueue.main

    private func topVC() -> UIViewController? {
        // 主线程直接计算；仅非主线程调用时才 sync 到主队列。
        // 反例（已修）：无条件 main.sync —— 调用方在 main.async 闭包内再 sync 主队列
        // 会触发 libdispatch DISPATCH_CLIENT_CRASH（EXC_BREAKPOINT），pick/camera 工具必崩。
        func compute() -> UIViewController? {
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            var top = window?.rootViewController
            while let p = top?.presentedViewController { top = p }
            return top
        }
        if Thread.isMainThread { return compute() }
        return main.sync { compute() }
    }

    func takePicture() async -> URL? {
        let available = await MainActor.run { UIImagePickerController.isSourceTypeAvailable(.camera) }
        guard available else { return nil }
        return await withCheckedContinuation { cont in
            main.async {
                guard let top = self.topVC() else { cont.resume(returning: nil); return }
                self.pictureCont = cont
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.cameraCaptureMode = .photo
                picker.delegate = self
                top.present(picker, animated: true)
            }
        }
    }

    func pickImage() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            main.async {
                guard let top = self.topVC() else { cont.resume(returning: nil); return }
                self.imageCont = cont
                var config = PHPickerConfiguration()
                config.filter = .images
                config.selectionLimit = 1
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                top.present(picker, animated: true)
            }
        }
    }

    func pickDocument(mime: String?) async -> URL? {
        await withCheckedContinuation { cont in
            main.async {
                guard let top = self.topVC() else { cont.resume(returning: nil); return }
                self.docCont = cont
                let types: [UTType] = mime.flatMap { UTType(mimeType: $0) }.map { [$0] } ?? [.data]
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
                picker.delegate = self
                picker.allowsMultipleSelection = false
                top.present(picker, animated: true)
            }
        }
    }

    // UIImagePickerController
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        let cont = pictureCont
        pictureCont = nil
        guard let image = info[.originalImage] as? UIImage,
              let jpeg = image.jpegData(compressionQuality: 0.92) else {
            cont?.resume(returning: nil)
            return
        }
        cont?.resume(returning: Self.savePhoto(jpeg))
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        let cont = pictureCont
        pictureCont = nil
        cont?.resume(returning: nil)
    }

    // PHPicker
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let cont = imageCont
        imageCont = nil
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            cont?.resume(returning: nil)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { obj, _ in
            guard let image = obj as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.92) else {
                cont?.resume(returning: nil)
                return
            }
            cont?.resume(returning: Self.savePhoto(jpeg))
        }
    }

    // UIDocumentPicker
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let cont = docCont
        docCont = nil
        cont?.resume(returning: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let cont = docCont
        docCont = nil
        cont?.resume(returning: nil)
    }

    static func savePhoto(_ jpeg: Data) -> URL? {
        let dir = AppPaths.harnessDir.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("photo_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
        do { try jpeg.write(to: url); return url } catch { return nil }
    }
}

/// iOS device bridge — phase-1 ops with the same tool contract as HarmonyOS/Android.
final class DeviceBridge {

    private let engine: HarnessEngine
    private let launcher = PickerLauncher()

    init(engine: HarnessEngine) {
        self.engine = engine
    }

    func dispatch(id: Int, reqJson: String, report: @escaping (Bool, String) -> Void) {
        Task {
            let (ok, json) = (try? await handle(reqJson)) ?? (false, "{\"error\":\"op failed\"}")
            report(ok, json)
        }
    }

    private func handle(_ reqJson: String) async throws -> (Bool, String) {
        guard let req = (try? JSONSerialization.jsonObject(with: Data(reqJson.utf8))) as? [String: Any] else {
            return (false, "{\"error\":\"bad request\"}")
        }
        let op = req["op"] as? String ?? ""
        let tool = req["tool"] as? String ?? (op.isEmpty ? "unknown" : op)
        let args = req["args"] as? [String: Any] ?? [:]
        let out = await execute(tool: tool, args: args)
        let code = (out["code"] as? Int) ?? (((out["ok"] as? Bool) ?? true) ? 0 : 1)
        return (code == 0, Self.encode(out))
    }

    private func execute(tool: String, args: [String: Any]) async -> [String: Any] {
        switch tool {
        case "status": return opStatus()
        case "permissions": return await opPermissions(args)
        case "clipboard": return opClipboard(args)
        case "files": return await opFiles(args)
        case "photos": return await opPhotos(args)
        case "camera": return await opCamera(args)
        case "network": return await opNetwork()
        case "deviceinfo": return await opDeviceInfo()
        case "vibrate": return opVibrate(args)
        case "share": return await opShare(args)
        case "runScript":
            let code = args["code"] as? String ?? ""
            let timeoutMs = args["timeoutMs"] as? Int ?? 60_000
            return ScriptSandbox.shared.runSync(code: code, timeoutMs: timeoutMs)
        case "contacts", "calendar", "mail", "call", "sms", "recorder",
             "app", "location", "settings", "reminder", "gui", "scheduler":
            return ["ok": false, "error": "iOS 端暂未接入: \(tool)"]
        default:
            return ["ok": false, "error": "unknown tool: \(tool)"]
        }
    }

    // ── ops ──────────────────────────────────────────────────

    private func opStatus() -> [String: Any] {
        let device = UIDevice.current
        return [
            "ok": true,
            "engine": "harness-ios",
            "platform": "iOS \(device.systemVersion)",
            "device": "\(device.model) (\(device.name))",
            "app": Bundle.main.bundleIdentifier ?? "harnest",
            "capabilities": [
                "clipboard", "camera", "photos", "files", "network",
                "deviceinfo", "vibrate", "share", "permissions",
            ],
            "note": "iOS port of the Harness device bridge — same tool contract as the HarmonyOS/Android versions; agent-side headless capture is unavailable on iOS, camera uses the system camera UI",
        ]
    }

    private func opPermissions(_ args: [String: Any]) async -> [String: Any] {
        let op = args["op"] as? String ?? "list"
        if op == "list" {
            var arr: [[String: Any]] = []
            arr.append(["name": "contacts", "granted": CNContactStore.authorizationStatus(for: .contacts) == .authorized])
            arr.append(["name": "calendar", "granted": EKEventStore.authorizationStatus(for: .event) == .fullAccess])
            let loc = CLLocationManager().authorizationStatus
            arr.append(["name": "location", "granted": loc == .authorizedAlways || loc == .authorizedWhenInUse])
            let mic: Bool
            if #available(iOS 17.0, *) {
                mic = AVAudioApplication.shared.recordPermission == .granted
            } else {
                mic = AVAudioSession.sharedInstance().recordPermission == .granted
            }
            arr.append(["name": "microphone", "granted": mic])
            arr.append(["name": "camera", "granted": AVCaptureDevice.authorizationStatus(for: .video) == .authorized])
            arr.append(["name": "photos", "granted": PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized])
            let notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            arr.append(["name": "notifications", "granted": notifStatus == .authorized])
            return ["ok": true, "permissions": arr]
        }
        if op == "request" {
            let name = args["name"] as? String ?? ""
            let granted: Bool
            switch name {
            case "camera":
                granted = await withCheckedContinuation { cont in
                    AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
                }
            case "microphone":
                if #available(iOS 17.0, *) {
                    granted = await AVAudioApplication.requestRecordPermission()
                } else {
                    granted = await withCheckedContinuation { cont in
                        AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
                    }
                }
            case "photos":
                granted = await withCheckedContinuation { cont in
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
                        cont.resume(returning: st == .authorized || st == .limited)
                    }
                }
            case "notifications":
                granted = await withCheckedContinuation { cont in
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                        cont.resume(returning: ok)
                    }
                }
            case "contacts":
                granted = await withCheckedContinuation { cont in
                    CNContactStore().requestAccess(for: .contacts) { ok, _ in cont.resume(returning: ok) }
                }
            case "calendar":
                granted = await withCheckedContinuation { cont in
                    EKEventStore().requestFullAccessToEvents { ok, _ in cont.resume(returning: ok) }
                }
            default:
                return ["ok": false, "error": "unknown permission: \(name)"]
            }
            return ["ok": true, "name": name, "granted": granted]
        }
        return ["ok": false, "error": "unknown op: \(op)"]
    }

    private func opClipboard(_ args: [String: Any]) -> [String: Any] {
        let op = args["op"] as? String ?? "read"
        if op == "read" {
            let text = UIPasteboard.general.string ?? ""
            return ["ok": true, "text": text, "empty": text.isEmpty]
        }
        if op == "write" {
            let text = args["text"] as? String ?? ""
            UIPasteboard.general.string = text
            return ["ok": true]
        }
        return ["ok": false, "error": "unknown op: \(op)"]
    }

    private func opFiles(_ args: [String: Any]) async -> [String: Any] {
        let op = args["op"] as? String ?? "list"
        if op == "pick" {
            guard let src = await launcher.pickDocument(mime: args["mime"] as? String) else {
                return ["ok": false, "cancelled": true]
            }
            let name = args["name"] as? String ?? src.lastPathComponent
            let dir = ScriptSandbox.shared.sandboxRoot.appendingPathComponent("picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let dest = dir.appendingPathComponent("\(stamp)_\(name)")
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
                return ["ok": true, "path": "picked/\(dest.lastPathComponent)", "size": size, "uri": src.absoluteString]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        }
        // sandbox ops delegate to FsBridge
        var req: [String: Any] = [
            "op": op,
            "path": args["path"] as? String ?? "",
            "data": args["data"] as? String ?? "",
            "base64": args["base64"] as? Bool ?? false,
            "text": args["text"] as? Bool ?? true,
        ]
        if let rec = args["recursive"] as? Bool { req["recursive"] = rec }
        let resultJson = FsBridge.handle(engine: engine, reqJson: Self.encode(req))
        if let parsed = (try? JSONSerialization.jsonObject(with: Data(resultJson.utf8))) as? [String: Any] {
            return parsed
        }
        return ["ok": false, "error": "fs bridge failed"]
    }

    private func opPhotos(_ args: [String: Any]) async -> [String: Any] {
        let op = args["op"] as? String ?? "pick"
        if op == "pick" {
            guard let url = await launcher.pickImage() else {
                return ["ok": false, "cancelled": true]
            }
            let dir = ScriptSandbox.shared.sandboxRoot.appendingPathComponent("picked", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let dest = dir.appendingPathComponent("\(stamp)_\(url.lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
            if args["base64"] as? Bool ?? false {
                guard let data = try? Data(contentsOf: dest) else {
                    return ["ok": false, "error": "cannot open \(dest.lastPathComponent)"]
                }
                return ["ok": true, "uri": dest.lastPathComponent, "size": size, "base64": data.base64EncodedString()]
            }
            return ["ok": true, "uri": dest.lastPathComponent, "size": size, "path": "picked/\(dest.lastPathComponent)"]
        }
        if op == "save" {
            return ["ok": false, "error": "iOS 暂不支持写入系统相册，请使用 share 分享图片"]
        }
        return ["ok": false, "error": "unknown op: \(op)"]
    }

    private func opCamera(_ args: [String: Any]) async -> [String: Any] {
        let op = args["op"] as? String ?? "capture"
        guard op == "capture" || op == "auto" || op == "manual" else {
            return ["ok": false, "error": "unknown op: \(op)"]
        }
        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
        }
        guard granted else {
            return ["ok": false, "error": "camera permission denied — enable it in Settings > Privacy > Camera"]
        }
        guard let url = await launcher.takePicture() else {
            return ["ok": false, "cancelled": true, "error": "camera cancelled — no photo captured"]
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let attached = VisionAttach.pushFile(url)
        return [
            "ok": true,
            "uri": url.path,
            "path": url.path,
            "size": size,
            "automatic": false,
            "imageAttached": attached,
            "note": "Photo confirmed by the user in the system camera UI. " + (attached
                ? "The photo is ALSO attached to your NEXT model request as an image (image_url part) — analyze it directly, do not guess or invent its content."
                : "The image could not be attached to your next request."),
        ]
    }

    private func opNetwork() async -> [String: Any] {
        await withCheckedContinuation { cont in
            let monitor = NWPathMonitor()
            let q = DispatchQueue(label: "harnest.netprobe")
            q.async { [weak monitor] in
                monitor?.pathUpdateHandler = { path in
                    monitor?.cancel()
                    let type: String
                    if path.usesInterfaceType(.wifi) { type = "wifi" }
                    else if path.usesInterfaceType(.cellular) { type = "cellular" }
                    else if path.usesInterfaceType(.wiredEthernet) { type = "wired" }
                    else { type = "other" }
                    cont.resume(returning: ["ok": true, "online": path.status == .satisfied, "type": type])
                }
                monitor?.start(queue: q)
            }
        }
    }

    private func opDeviceInfo() async -> [String: Any] {
        var deviceInfo = await MainActor.run { () -> [String: Any] in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let batteryLevel = Int(device.batteryLevel * 100)
            let batteryState: String
            switch device.batteryState {
            case .charging: batteryState = "charging"
            case .full: batteryState = "full"
            case .unplugged: batteryState = "unplugged"
            default: batteryState = "unknown"
            }
            let windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            let screen = windowScene?.screen
            return [
                "batteryLevel": batteryLevel,
                "batteryState": batteryState,
                "platform": "iOS \(device.systemVersion)",
                "model": device.model,
                "name": device.name,
                "idfv": device.identifierForVendor?.uuidString ?? "",
                "screen": screen.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height)) @\(Int($0.scale))x" } ?? "unknown",
            ]
        }
        let free = ((try? AppPaths.baseDir.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        deviceInfo["ok"] = true
        deviceInfo["storageFreeBytes"] = free
        deviceInfo["appVersion"] = version
        return deviceInfo
    }

    private func opVibrate(_ args: [String: Any]) -> [String: Any] {
        let style = (args["pattern"] as? String) ?? (args["style"] as? String)
        DispatchQueue.main.async {
            let gen: UIImpactFeedbackGenerator
            switch style {
            case "heavy": gen = UIImpactFeedbackGenerator(style: .heavy)
            case "light": gen = UIImpactFeedbackGenerator(style: .light)
            default: gen = UIImpactFeedbackGenerator(style: .medium)
            }
            gen.impactOccurred()
        }
        return ["ok": true]
    }

    private func opShare(_ args: [String: Any]) async -> [String: Any] {
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty else { return ["ok": false, "error": "text required"] }
        await MainActor.run {
            let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let top = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController })
                .first {
                var presenter = top
                while let p = presenter.presentedViewController { presenter = p }
                if let popover = av.popoverPresentationController {
                    popover.sourceView = presenter.view
                }
                presenter.present(av, animated: true)
            }
        }
        return ["ok": true]
    }

    private static func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
