import CryptoKit
import Foundation

/// Validates a generated `Exthost/extensions` directory with the shipping catalog code.
/// This deliberately reads package directories in place so large language-server trees are
/// not copied just to run the post-packaging check.
@main
struct ExtensionCatalogLayoutCheck {
    static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--cache-check" {
            do {
                let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[2]))!
                let root = try NativeExtensionCatalog.bundledHostRoot(bundle: bundle,
                    applicationSupport: URL(fileURLWithPath: CommandLine.arguments[3]))
                print(root.path)
            } catch { exit(1) }
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--self-test" {
            do { try checkResourceCache(); print("PASS resource-cache integrity checks") }
            catch { fputs("FAIL resource-cache check: \(error)\n", stderr); exit(1) }
            return
        }
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: catalog-layout-check <Exthost>\n", stderr)
            exit(64)
        }

        let hostRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard hostRoot.lastPathComponent == "Exthost" else {
            fputs("expected the generated Exthost directory: \(hostRoot.path)\n", stderr)
            exit(64)
        }
        let root = hostRoot.appendingPathComponent("extensions", isDirectory: true)

        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let packages = try NativeExtensionCatalog.validateExtensionEntries(entries, isBuiltin: true)
            print("PASS shipping catalog validated \(packages.count) packages at \(root.path)")

            guard let typescriptExtension = packages.first(where: { entry in
                let manifest = entry["manifest"] as? [String: Any] ?? [:]
                return (manifest["publisher"] as? String)?.lowercased() == "vscode" &&
                    (manifest["name"] as? String)?.lowercased() == "typescript-language-features"
            }), let location = typescriptExtension["extensionLocation"] as? String,
               let extensionURL = URL(string: location), extensionURL.isFileURL else {
                throw LayoutCheckError.missingTypeScriptExtension
            }

            // Pinned VS Code versionProvider.electron.ts resolves this as
            // extension.extensionPath + ['..', 'node_modules', 'typescript', 'lib', 'tsserver.js'].
            let resolvedServer = URL(fileURLWithPath: extensionURL.path + "/../node_modules/typescript/lib/tsserver.js")
                .standardizedFileURL
            let expectedServer = root.appendingPathComponent("node_modules/typescript/lib/tsserver.js")
                .standardizedFileURL
            guard resolvedServer.path == expectedServer.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedServer.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                throw LayoutCheckError.missingBundledTypeScriptServer(resolvedServer.path)
            }
            print("PASS upstream bundled TypeScript server resolves at \(resolvedServer.path)")
        } catch {
            fputs("FAIL shipping catalog rejected \(root.path): \(error)\n", stderr)
            exit(1)
        }
    }

    private static func checkResourceCache() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent("Fixture.bundle")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let exthost = resources.appendingPathComponent("Exthost")
        let support = temporary.appendingPathComponent("Support")
        try fm.createDirectory(at: exthost, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.codipad.cache-test"],
            format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let files = ["payload.js": Data("original".utf8),
                     "executable-modes.json": Data("{\"schemaVersion\":1,\"entries\":[]}".utf8)]
        for (name, data) in files { try data.write(to: exthost.appendingPathComponent(name)) }
        let inventory = files.map { name, data in
            ["path": name, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject: ["extensionHostBundle": inventory])
            .write(to: resources.appendingPathComponent("BuildReceipt.json"))

        // Each check gets a new process, like a cold app launch (no process-local root cache).
        func check() throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--cache-check", bundle.path, support.path]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let (coldStatus, path) = try check()
        precondition(coldStatus == 0, "first staging must succeed")
        let (warmStatus, warmPath) = try check()
        precondition(warmStatus == 0 && warmPath == path, "unchanged cache must be reusable")
        let payload = URL(fileURLWithPath: path).appendingPathComponent("payload.js")
        let attributes = try fm.attributesOfItem(atPath: payload.path)
        try Data("modified".utf8).write(to: payload)
        try fm.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: payload.path)
        let tampered = try check()
        precondition(tampered.0 != 0, "same-size content tampering must be rejected")
        try files["payload.js"]!.write(to: payload)
        let restored = try check()
        precondition(restored.0 == 0, "restored content must verify")
        try fm.removeItem(at: payload)
        try fm.createSymbolicLink(at: payload, withDestinationURL: exthost.appendingPathComponent("payload.js"))
        let symlinked = try check()
        precondition(symlinked.0 != 0, "symlink substitution must be rejected")
    }
}

private enum LayoutCheckError: Error, CustomStringConvertible {
    case missingTypeScriptExtension
    case missingBundledTypeScriptServer(String)

    var description: String {
        switch self {
        case .missingTypeScriptExtension:
            return "catalog has no vscode.typescript-language-features package"
        case .missingBundledTypeScriptServer(let path):
            return "upstream bundled TypeScript server does not resolve to a regular file: \(path)"
        }
    }
}
