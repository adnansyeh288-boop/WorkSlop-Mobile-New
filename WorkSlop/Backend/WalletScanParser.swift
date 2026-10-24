import Foundation

/// Payment network inferred from a payment applet AID prefix.
/// Ported from AirCard-iOS `ios-app/WalletScanParser.swift` (HEAD 40640c4);
/// `public` dropped — this is an internal WorkSlop module, not a library.
enum WalletPaymentNetwork: String, CaseIterable, Codable {
    case visa = "Visa"
    case mastercard = "Mastercard"
    case amex = "American Express"
    case unionPay = "UnionPay"
    case discover = "Discover"
    case jcb = "JCB"
    case appleCard = "Apple Card"
    case transit = "Transit Card"
    case unknown = "Payment Card"

    var iconName: String {
        switch self {
        case .appleCard: return "apple.logo"
        case .transit: return "tram.fill"
        case .unknown: return "creditcard"
        default: return "creditcard.fill"
        }
    }

    var displayName: String { rawValue }

    static func from(activationID: String) -> WalletPaymentNetwork {
        let upper = activationID.uppercased()
        if upper.hasPrefix("A000000003") { return .visa }
        if upper.hasPrefix("A000000004") { return .mastercard }
        if upper.hasPrefix("A000000025") { return .amex }
        if upper.hasPrefix("A000000333") { return .unionPay }
        if upper.hasPrefix("A000000152") { return .discover }
        if upper.hasPrefix("A000000065") { return .jcb }
        return .unknown
    }

    static func fromAID(_ aid: String) -> WalletPaymentNetwork? {
        let net = from(activationID: aid)
        return net == .unknown ? nil : net
    }
}

/// One payment-applet activation seen in a syslog line.
struct WalletActivationMatch: Equatable {
    let aid: String
    let network: WalletPaymentNetwork?
    let id: String?
}

/// Regex extraction of card identifiers from device syslog lines.
/// Ported from AirCard-iOS `ios-app/WalletScanParser.swift` in full: the
/// card-reference patterns, the `passIDs[...]` session list, the 27-character
/// fallback token, the activation/AID patterns, and — critically — the dummy
/// hash filter. Those four placeholder hashes appear in Passbook logs for
/// cards that are not real, and flashing a skin onto one of them would write
/// to a path no card owns.
enum WalletScanParser {
    static let cardReferences: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"/([-A-Za-z0-9_+=]{20,64})\.(?:pkpass|cache|pkcache)(?=[/\s\"'\),]|$)"#),
        try! NSRegularExpression(pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?=[/\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"VerificationCheck\.([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"selected pass uniqueID\s*:?\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s*for\s+([-A-Za-z0-9_+=]{20,80})(?=[,\s\"'\)]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s+([-A-Za-z0-9_+=]{20,80})\s+-"#, options: .caseInsensitive),
    ]

    static let inSessionList = try! NSRegularExpression(
        pattern: #"passIDs\[(?:InSession|global)\]\s*[:=]\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive
    )

    static let cardID = try! NSRegularExpression(pattern: #"(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,64}(?![-A-Za-z0-9_+=])"#)

    static let activation = try! NSRegularExpression(
        pattern: #"setActivePaymentApplet.{0,4096}?requestedApplet\s*:.{0,4096}?(?:identifier\s*=\s*|\"identifier\"\s*:\s*\")([A-Fa-f0-9]{10,64})\b"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static let fallbackToken = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9+/=])([A-Za-z0-9+/_-]{27}=)(?![-A-Za-z0-9+/=])"#
    )

    /// Placeholder hashes Passbook logs for non-real cards. Never flashed.
    static let placeholders: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
    ]

    static func cardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        var result: [String] = []

        func add(_ id: String) {
            guard !placeholders.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }

        for pattern in cardReferences {
            for match in pattern.matches(in: line, range: lineRange) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                add(String(line[range]))
            }
        }

        for match in inSessionList.matches(in: line, range: lineRange) {
            guard let range = Range(match.range(at: 1), in: line) else { continue }
            let sessionString = String(line[range])
            let sessionRange = NSRange(sessionString.startIndex..., in: sessionString)
            for cardMatch in cardID.matches(in: sessionString, range: sessionRange) {
                guard let cardRange = Range(cardMatch.range, in: sessionString) else { continue }
                add(String(sessionString[cardRange]))
            }
        }

        return result
    }

    static func fallbackCardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        return fallbackToken.matches(in: line, range: lineRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            let id = String(line[range])
            guard !placeholders.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func activationMatches(in line: String) -> [WalletActivationMatch] {
        var matches: [WalletActivationMatch] = []
        let lineRange = NSRange(line.startIndex..., in: line)

        let jsonPattern = try! NSRegularExpression(
            pattern: #"\"aid\"\s*:\s*\"([A-Fa-f0-9]{10,64})\"[^}]*\"passId\"\s*:\s*\"([-A-Za-z0-9_+=]{20,64})\""#,
            options: .caseInsensitive
        )
        for match in jsonPattern.matches(in: line, range: lineRange) {
            guard let r1 = Range(match.range(at: 1), in: line),
                  let r2 = Range(match.range(at: 2), in: line) else { continue }
            matches.append(WalletActivationMatch(aid: String(line[r1]).uppercased(),
                                                 network: WalletPaymentNetwork.fromAID(String(line[r1])),
                                                 id: String(line[r2])))
        }

        let passAndAidPattern = try! NSRegularExpression(
            pattern: #"(?:activating payment pass ID|pass ID)\s*:\s*([-A-Za-z0-9_+=]{20,64}).*?AID\s*:\s*([A-Fa-f0-9]{10,64})"#,
            options: .caseInsensitive
        )
        for match in passAndAidPattern.matches(in: line, range: lineRange) {
            guard let r1 = Range(match.range(at: 1), in: line),
                  let r2 = Range(match.range(at: 2), in: line) else { continue }
            matches.append(WalletActivationMatch(aid: String(line[r2]).uppercased(),
                                                 network: WalletPaymentNetwork.fromAID(String(line[r2])),
                                                 id: String(line[r1])))
        }

        for match in activation.matches(in: line, range: lineRange) {
            guard let range = Range(match.range(at: 1), in: line) else { continue }
            let aid = String(line[range]).uppercased()
            if !matches.contains(where: { $0.aid == aid }) {
                matches.append(WalletActivationMatch(aid: aid,
                                                     network: WalletPaymentNetwork.fromAID(aid),
                                                     id: nil))
            }
        }

        return matches
    }
}

/// A card identifier discovered from one syslog line, with its network when
/// an activation line supplied one.
struct DiscoveredCard: Equatable {
    let id: String
    let network: String?
}

/// Stateful syslog-line filter for the Wallet scanner, ported from AirCard's
/// `AppViewModel.processSyslogLine`.
///
/// Two filters, in order: the subsystem filter (the line must come from a
/// Passbook-related subsystem) and the context filter (it must be about a
/// card/pass). Only then are IDs extracted — high-confidence patterns first,
/// the 27-character fallback token only when nothing else matched. The
/// last-seen payment network is carried across lines, exactly as AirCard
/// does, so a card first seen without an activation still gets a network
/// when one appears later.
///
/// Cheap enough to run on the FFI reader thread: the caller pre-filters with
/// `prefilter` (substring check) before handing a line here, and the UI
/// update happens on the main actor from the discovered results.
final class WalletCardScanner {
    private var lastObservedNetwork: WalletPaymentNetwork?

    /// Background-thread substring pre-filter, mirroring AirCard's scan loop.
    static func prefilter(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("pass") || lower.contains("card") || lower.contains("stockholm")
            || lower.contains("wallet") || lower.contains("nanopass")
            || lower.contains("verificationcheck") || lower.contains("nfcd")
            || lower.contains("dashboard") || lower.contains("activation")
            || lower.contains("setactivepaymentapplet")
    }

    /// Returns newly discovered cards for this line (possibly empty).
    /// The caller dedupes against already-known cards and persists.
    func process(line: String) -> [DiscoveredCard] {
        let lower = line.lowercased()
        let isWalletSubsystem = lower.contains("passd") || lower.contains("passbook")
            || lower.contains("passkit") || lower.contains("stockholm")
            || lower.contains("nanopassd") || lower.contains("wallet")
            || lower.contains("pdcardfilemanager") || lower.contains("pdpasslibrary")
            || lower.contains("verificationcheck") || lower.contains("/cards/")
            || lower.contains("nfcd") || lower.contains("dashboard")
            || lower.contains("activation")
        guard isWalletSubsystem else { return [] }

        let isWalletContext = lower.contains("card") || lower.contains("pass")
            || lower.contains("payment") || lower.contains("pkpass")
            || lower.contains("uniqueid") || lower.contains("identifier")
            || lower.contains("face") || lower.contains("cache")
            || lower.contains("stockholm") || lower.contains("pdcardfilemanager")
            || lower.contains("pdpasslibrary") || lower.contains("verificationcheck")
            || lower.contains("/cards/") || lower.contains("dashboard loading")
            || lower.contains("passids") || lower.contains("applet")
            || lower.contains("nfexpressmodemanager")
        guard isWalletContext else { return [] }

        var found: [DiscoveredCard] = []
        var seen = Set<String>()
        func add(_ id: String, network: WalletPaymentNetwork?) {
            guard let clean = WalletCardSkin.cleanCardId(id),
                  !WalletScanParser.placeholders.contains(clean),
                  seen.insert(clean).inserted else { return }
            found.append(DiscoveredCard(id: clean, network: network?.displayName))
        }

        for act in WalletScanParser.activationMatches(in: line) {
            if let net = act.network { lastObservedNetwork = net }
            if let id = act.id {
                add(id, network: act.network ?? lastObservedNetwork)
            }
        }

        let candidates = WalletScanParser.cardIDs(in: line)
        for cand in candidates {
            add(cand, network: lastObservedNetwork)
        }

        if candidates.isEmpty {
            for cand in WalletScanParser.fallbackCardIDs(in: line) {
                add(cand, network: lastObservedNetwork)
            }
        }

        return found
    }
}
