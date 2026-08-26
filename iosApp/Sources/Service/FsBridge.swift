import Foundation

/// Sandboxed fs ops for harness.js — mirrors FsBridge.kt / fs_bridge.cpp.
/// All paths resolve inside the engine sandbox; canonicalized prefix-checked.
enum FsBridge {

    static func handle(engine: HarnessEngine, reqJson: String) -> String {
        guard let req = (try? JSONSerialization.jsonObject(with: Data(reqJson.utf8))) as? [String: Any] else {
            return err("bad fs request json")
        }
        let op = req["op"] as? String ?? ""
        let path = req["path"] as? String ?? ""
        guard let resolved = resolve(engine: engine, path: path) else {
            return err("path escapes sandbox: \(path)")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false

        switch op {
        case "exists":
            let ok = fm.fileExists(atPath: resolved.path, isDirectory: &isDir)
            return json(["ok": true, "exists": ok, "isDir": isDir.boolValue])

        case "readFile":
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue,
                  let bytes = fm.contents(atPath: resolved.path) else {
                return err("open failed: \(path)")
            }
            if req["text"] as? Bool ?? true {
                return json(["ok": true, "data": String(data: bytes, encoding: .utf8) ?? ""])
            }
            return json(["ok": true, "data": bytes.base64EncodedString()])

        case "writeFile":
            let data = req["data"] as? String ?? ""
            let payload: Data
            if req["base64"] as? Bool ?? false {
                payload = Data(base64Encoded: data) ?? Data()
            } else {
                payload = Data(data.utf8)
            }
            if !resolved.deletingLastPathComponent().path.isEmpty {
                try? fm.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if fm.createFile(atPath: resolved.path, contents: payload) {
                return json(["ok": true])
            }
            return err("write failed: \(path)")

        case "readdir":
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue,
                  let names = try? fm.contentsOfDirectory(atPath: resolved.path) else {
                return err("not a directory: \(path)")
            }
            return json(["ok": true, "entries": names])

        case "mkdir":
            let recursive = req["recursive"] as? Bool ?? true
            do {
                try fm.createDirectory(atPath: resolved.path, withIntermediateDirectories: recursive)
                return json(["ok": true])
            } catch {
                if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                    return json(["ok": true])
                }
                return err("mkdir failed: \(error.localizedDescription)")
            }

        case "rm":
            let recursive = req["recursive"] as? Bool ?? false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
                return json(["ok": false])
            }
            if isDir.boolValue && !recursive {
                let entries = (try? fm.contentsOfDirectory(atPath: resolved.path)) ?? []
                if !entries.isEmpty { return json(["ok": false]) }
            }
            do {
                try fm.removeItem(atPath: resolved.path)
                return json(["ok": true])
            } catch {
                return json(["ok": false])
            }

        case "rename":
            let newPath = req["newPath"] as? String ?? ""
            guard let target = resolve(engine: engine, path: newPath) else {
                return err("path escapes sandbox: \(newPath)")
            }
            guard fm.fileExists(atPath: resolved.path) else {
                return err("not found: \(path)")
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                do { try fm.removeItem(atPath: target.path) } catch {
                    return err("rename failed: target busy")
                }
            }
            do {
                try fm.moveItem(atPath: resolved.path, toPath: target.path)
                return json(["ok": true])
            } catch {
                return err("rename failed: \(error.localizedDescription)")
            }

        case "realpath":
            return json(["ok": true, "path": resolved.path])

        case "stat":
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
                return err("not found: \(path)")
            }
            let attrs = try? fm.attributesOfItem(atPath: resolved.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return json([
                "ok": true,
                "isDir": isDir.boolValue,
                "size": isDir.boolValue ? 0 : size,
                "mtimeMs": Int64(mtime * 1000),
            ])

        default:
            return err("unknown fs op: \(op)")
        }
    }

    static func resolve(engine: HarnessEngine, path: String) -> URL? {
        let root = engine.sandboxRoot.standardizedFileURL.resolvingSymlinksInPath()
        let f = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        let canonical = f.standardizedFileURL.resolvingSymlinksInPath()
        let cp = canonical.path
        let rp = root.path
        if cp == rp || cp.hasPrefix(rp + "/") { return canonical }
        return nil
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{\"ok\":false}" }
        return String(data: data, encoding: .utf8) ?? "{\"ok\":false}"
    }

    private static func err(_ msg: String) -> String {
        json(["ok": false, "error": msg])
    }
}
