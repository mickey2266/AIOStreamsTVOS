import Foundation

/**
 * An Xtream catch-up address, as AIOStreams' Xtream addon writes one (`XtreamClient.archiveUrl` in
 * packages/core/src/builtins/xtream/api.ts): `…/timeshift/<user>/<password>/<minutes>/<YYYY-MM-DD:HH-MM>/<stream>.ts`.
 * The archive addresses time rather than bytes, so a programme read straight through, as an origin that
 * answers byte ranges with other bytes has to be (AE#958), seeks by asking for it again from a later
 * minute (`AetherPlayer.seek`). A minute is the finest start it takes.
 *
 * The start is in the server's own time zone, which the address doesn't name. Minutes are added to it as
 * they stand, which is right but across a change of the clocks in that zone, an hour a year.
 */
struct Timeshift: Equatable {
    /// Up to and including `/timeshift/<user>/<password>/`.
    let prefix: String
    /// The programme's length the address asks for.
    let minutes: Int
    /// Its start, as written, read as UTC so minutes add up as they stand.
    let start: Date
    /// `/<stream>.ts`, with any query after it.
    let suffix: String

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.*/timeshift/[^/]+/[^/]+/)(\d+)/(\d{4}-\d{2}-\d{2}:\d{2}-\d{2})(/[^/]+)$"#
    )

    private static let format: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd:HH-mm"
        return format
    }()

    init?(_ address: String) {
        let whole = NSRange(address.startIndex..., in: address)
        guard let match = Self.pattern.firstMatch(in: address, range: whole), match.numberOfRanges == 5,
              let prefix = Range(match.range(at: 1), in: address),
              let minutes = Range(match.range(at: 2), in: address),
              let start = Range(match.range(at: 3), in: address),
              let suffix = Range(match.range(at: 4), in: address),
              let length = Int(address[minutes]), length > 0,
              let begins = Self.format.date(from: String(address[start]))
        else { return nil }
        self.prefix = String(address[prefix])
        self.minutes = length
        self.start = begins
        self.suffix = String(address[suffix])
    }

    /// The same programme from `offset` minutes into it, to its end; at least its last minute.
    func address(from offset: Int) -> String {
        let into = min(max(0, offset), minutes - 1)
        let from = Self.format.string(from: start.addingTimeInterval(Double(into) * 60))
        return "\(prefix)\(minutes - into)/\(from)\(suffix)"
    }
}
