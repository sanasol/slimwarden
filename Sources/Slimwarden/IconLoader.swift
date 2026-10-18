import AppKit
import CryptoKit
import SlimwardenCore
import SwiftUI

/// Website icons from the Vaultwarden icon service (`/icons/<host>/icon.png`), cached in memory and on disk.
@MainActor
final class IconLoader {
    static let shared = IconLoader()

    private let memory = NSCache<NSString, NSImage>()
    private var missing = Set<String>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var placeholderHash: Data?
    private let directory: URL
    private let session: URLSession

    private init() {
        memory.countLimit = 400
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Slimwarden/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    static func host(for item: VaultItem) -> String? {
        for uri in item.uris {
            let s = uri.contains("://") ? uri : "https://\(uri)"
            guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", var host = comps.host?.lowercased(), host.contains(".")
            else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        return nil
    }

    func cached(_ host: String) -> NSImage? { memory.object(forKey: host as NSString) }

    func image(for host: String, server: String) async -> NSImage? {
        if let image = memory.object(forKey: host as NSString) { return image }
        if missing.contains(host) { return nil }
        if let task = inFlight[host] { return await task.value }

        let file = directory.appendingPathComponent(host + ".png")
        let task = Task<NSImage?, Never> { [session] in
            if let data = try? Data(contentsOf: file) {
                return data.isEmpty ? nil : Self.thumbnail(data)
            }
            guard let url = URL(string: "\(server)/icons/\(host)/icon.png"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            let isPlaceholder = await self.isPlaceholder(data, server: server)
            // An empty file remembers "no icon" so we don't ask again.
            try? (isPlaceholder ? Data() : data).write(to: file)
            return isPlaceholder ? nil : Self.thumbnail(data)
        }
        inFlight[host] = task
        let image = await task.value
        inFlight[host] = nil
        if let image { memory.setObject(image, forKey: host as NSString) } else { missing.insert(host) }
        return image
    }

    /// The server answers unknown sites with a generic image; detect it by comparing with a known-bad domain.
    private func isPlaceholder(_ data: Data, server: String) async -> Bool {
        if placeholderHash == nil, let url = URL(string: "\(server)/icons/slimwarden-no-such-site.invalid/icon.png"),
           let (fallback, _) = try? await session.data(from: url) {
            placeholderHash = Data(SHA256.hash(data: fallback))
        }
        return placeholderHash == Data(SHA256.hash(data: data))
    }

    /// Downscale so thousands of icons stay cheap in memory.
    nonisolated static func thumbnail(_ data: Data, size: CGFloat = 64) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init)
        else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        return image
    }

    func clearCache() {
        memory.removeAllObjects()
        missing.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

struct ItemIcon: View {
    @Environment(AppModel.self) private var model
    let item: VaultItem
    var size: CGFloat = 30
    @State private var image: NSImage?

    var body: some View {
        let host = model.showIcons ? IconLoader.host(for: item) : nil
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = image ?? host.flatMap(IconLoader.shared.cached) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(size * 0.12)
                        .background(.white, in: RoundedRectangle(cornerRadius: size * 0.24))
                } else if item.type == .card, let brand = CardBrand(item.values["brand"], number: item.values["number"]) {
                    brand.badge(size: size)
                } else {
                    Image(systemName: item.type.symbol)
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.secondary)
                        .frame(width: size, height: size)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.24))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))

            if item.favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.06)
                    .background(Circle().fill(Color.orange))
                    .offset(x: size * 0.12, y: size * 0.12)
            }
        }
        .task(id: host) {
            guard let host, let server = model.account?.server else { image = nil; return }
            image = await IconLoader.shared.image(for: host, server: server)
        }
    }
}

enum CardBrand {
    case visa, mastercard, amex, mir, unionpay, discover, jcb, other(String)

    init?(_ brand: String?, number: String?) {
        let b = (brand ?? "").lowercased()
        let n = (number ?? "").filter(\.isNumber)
        if b.contains("visa") || n.hasPrefix("4") { self = .visa }
        else if b.contains("master") || n.range(of: "^(5[1-5]|2[2-7])", options: .regularExpression) != nil { self = .mastercard }
        else if b.contains("amex") || b.contains("american") || n.hasPrefix("34") || n.hasPrefix("37") { self = .amex }
        else if b.contains("mir") || b.contains("мир") || n.hasPrefix("220") { self = .mir }
        else if b.contains("union") || n.hasPrefix("62") { self = .unionpay }
        else if b.contains("discover") || n.hasPrefix("6011") { self = .discover }
        else if b.contains("jcb") || n.hasPrefix("35") { self = .jcb }
        else if !b.isEmpty { self = .other(String(brand!.prefix(4)).uppercased()) }
        else { return nil }
    }

    @ViewBuilder
    func badge(size: CGFloat) -> some View {
        switch self {
        case .mastercard:
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.13)
                HStack(spacing: -size * 0.14) {
                    Circle().fill(Color(red: 0.92, green: 0.0, blue: 0.11))
                    Circle().fill(Color(red: 0.97, green: 0.62, blue: 0.11).opacity(0.9))
                }
                .frame(width: size * 0.72, height: size * 0.44)
            }
        case .visa:
            text("VISA", Color(red: 0.08, green: 0.2, blue: 0.6), size: size, italic: true)
        case .amex:
            text("AMEX", Color(red: 0.0, green: 0.45, blue: 0.8), size: size)
        case .mir:
            text("МИР", Color(red: 0.0, green: 0.55, blue: 0.35), size: size)
        case .unionpay:
            text("UP", Color(red: 0.8, green: 0.1, blue: 0.15), size: size)
        case .discover:
            text("DISC", Color(red: 0.95, green: 0.45, blue: 0.1), size: size)
        case .jcb:
            text("JCB", Color(red: 0.0, green: 0.35, blue: 0.65), size: size)
        case .other(let s):
            text(s, .gray, size: size)
        }
    }

    private func text(_ s: String, _ color: Color, size: CGFloat, italic: Bool = false) -> some View {
        ZStack {
            color
            Text(s)
                .font(.system(size: size * (s.count > 3 ? 0.27 : 0.32), weight: .heavy))
                .italic(italic)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
    }
}
