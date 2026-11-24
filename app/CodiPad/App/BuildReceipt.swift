import Foundation

/// Read-only access to the build receipt bundled by `scripts/build.py`.
///
/// This is a utility, not a screen: the workbench is the only product UI.
enum BuildReceipt {
    private static let resource = "BuildReceipt"
    private static let extensionName = "json"

    private struct Snapshot {
        let identifiers: [String: String]
        let rootfsSHA256: String?
    }

    // The signed main bundle is immutable for this process. Swift initializes
    // static constants once, safely across threads. Do not cache test/override
    // bundles: their receipts may legitimately change between calls.
    private static let mainSnapshot: Snapshot? = load(bundle: .main)

    private static func snapshot(bundle: Bundle) -> Snapshot? {
        bundle === Bundle.main ? mainSnapshot : load(bundle: bundle)
    }

    /// Small identifiers for device evidence without copying the full manifest into every log.
    static func identifiers(bundle: Bundle = .main) -> [String: String] {
        snapshot(bundle: bundle)?.identifiers ?? [:]
    }

    static func rootfsSHA256(bundle: Bundle = .main) -> String? {
        snapshot(bundle: bundle)?.rootfsSHA256
    }

    private static func load(bundle: Bundle) -> Snapshot? {
        guard let object = loadObject(bundle: bundle) else { return nil }
        let dictionary = object as? [String: Any]
        var identifiers: [String: String] = [:]
        if let build = dictionary?["buildInputSha256"] as? String,
           let source = dictionary?["source"] as? [String: Any],
           let inputs = source["input_sha256"] as? String {
            identifiers = ["buildInputSha256": build, "sourceInputSha256": inputs]
        }
        let runtime = dictionary?["nativeRuntime"] as? [String: Any]
        let shell = runtime?["shell"] as? [String: Any]
        return Snapshot(identifiers: identifiers, rootfsSHA256: shell?["rootfsSha256"] as? String)
    }

    private static func loadObject(bundle: Bundle) -> Any? {
        guard let url = bundle.url(forResource: resource, withExtension: extensionName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

