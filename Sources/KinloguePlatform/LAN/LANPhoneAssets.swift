import Foundation

public enum LANPhoneAsset: String, CaseIterable, Sendable {
    case page = "/"
    case script = "/app.js"
    case stylesheet = "/styles.css"

    public var contentType: String {
        switch self {
        case .page:
            "text/html; charset=utf-8"
        case .script:
            "application/javascript; charset=utf-8"
        case .stylesheet:
            "text/css; charset=utf-8"
        }
    }

    fileprivate var resourceName: String {
        switch self {
        case .page:
            "index.html"
        case .script:
            "app.js"
        case .stylesheet:
            "styles.css"
        }
    }
}

public struct LANPhoneAssetPayload: Sendable {
    public let data: Data
    public let contentType: String
}

/// Immutable in-memory asset snapshot loaded before the listener is exposed.
/// Request event loops never perform bundle lookup or filesystem I/O.
public struct LANPhoneAssetCatalog: Sendable {
    private let page: LANPhoneAssetPayload
    private let script: LANPhoneAssetPayload
    private let stylesheet: LANPhoneAssetPayload

    public init(page: Data, script: Data, stylesheet: Data) {
        self.page = .init(data: page, contentType: LANPhoneAsset.page.contentType)
        self.script = .init(data: script, contentType: LANPhoneAsset.script.contentType)
        self.stylesheet = .init(
            data: stylesheet,
            contentType: LANPhoneAsset.stylesheet.contentType
        )
    }

    public static func loadBundled() throws -> Self {
        try .init(
            page: LANPhoneAssetLoader.load(.page).data,
            script: LANPhoneAssetLoader.load(.script).data,
            stylesheet: LANPhoneAssetLoader.load(.stylesheet).data
        )
    }

    public func payload(for asset: LANPhoneAsset) -> LANPhoneAssetPayload {
        switch asset {
        case .page: page
        case .script: script
        case .stylesheet: stylesheet
        }
    }
}

public enum LANPhoneAssetLoaderError: Error, Equatable, Sendable {
    case missingBundledAsset(LANPhoneAsset)
}

public enum LANPhoneAssetLoader {
    private static let packagedBundleName = "Kinlogue_KinloguePlatform.bundle"

    public static func load(_ asset: LANPhoneAsset) throws -> LANPhoneAssetPayload {
        guard let bundle = assetBundle(),
              let url = bundle.url(
            forResource: asset.resourceName,
            withExtension: nil,
            subdirectory: "LANUpload"
        ) else {
            throw LANPhoneAssetLoaderError.missingBundledAsset(asset)
        }

        return LANPhoneAssetPayload(
            data: try Data(contentsOf: url, options: .mappedIfSafe),
            contentType: asset.contentType
        )
    }

    private static func assetBundle() -> Bundle? {
        if let resourceURL = Bundle.main.resourceURL {
            let packagedURL = resourceURL.appendingPathComponent(
                packagedBundleName,
                isDirectory: true
            )
            if let values = try? packagedURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
               values.isDirectory == true,
               values.isSymbolicLink != true,
               let packagedBundle = Bundle(url: packagedURL) {
                return packagedBundle
            }
        }

        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return nil
        }
        return Bundle.module
    }
}
