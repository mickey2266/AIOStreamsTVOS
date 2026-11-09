import CoreImage
import Network
import UIKit

/**
 * The app menu's report as a text file a phone on the same network opens, for a log to keep or send:
 * tvOS has no AirDrop or share sheet for an app. While `LogShareScreen` shows, `LogServer` answers at
 * `http://<the Apple TV's address>:<port>/<random>/aiostreams-log.txt`, which the screen shows as a QR
 * code and as text. The random part keeps others on the network from guessing it; the server stops
 * when the screen closes. Stream addresses are cut to their host and file name first (`LogExport`),
 * as debrid links and the page's server addresses carry tokens in their paths and queries.
 */
enum LogExport {
    /// `text` with every address cut to `scheme://host/…/file`, without its path, query or credentials.
    static func redacted(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "\\b[A-Za-z][A-Za-z0-9+.-]*://[^\\s\"'<>()\\[\\]]+")
        else { return text }
        let source = text as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: last, length: match.range.location - last))
            out += shortened(source.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        out += source.substring(from: last)
        return out
    }

    private static func shortened(_ address: String) -> String {
        guard let url = URL(string: address), let scheme = url.scheme, let host = url.host else {
            // Something URL can't read as an address: only its scheme is kept.
            return (address.components(separatedBy: "://").first ?? "") + "://…"
        }
        let port = url.port.map { ":\($0)" } ?? ""
        let file = url.lastPathComponent
        let path = file.isEmpty || file == "/" ? "" : (url.pathComponents.count > 2 ? "/…/" : "/") + file
        let more = url.query != nil || url.fragment != nil ? "?…" : ""
        return "\(scheme)://\(host)\(port)\(path)\(more)"
    }
}

/// Serves one text file to the local network until stopped. Main thread only.
@MainActor
final class LogServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let body: Data
    private let path: String

    /// Ports tried in turn, so the address is easy to type; any free one after them.
    private static let ports: [UInt16] = [8080, 8081, 8082, 8088, 8090]
    private static let fileName = "aiostreams-log.txt"
    /// The most of a request read; a phone's GET is far less.
    private static let requestLimit = 16 * 1024

    init(text: String) {
        body = Data(text.utf8)
        let token = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        path = "/\(token)/\(Self.fileName)"
    }

    /// Starts listening; `ready` gets the address to open, or nil with why it couldn't.
    func start(ready: @escaping (URL?, String?) -> Void) {
        guard let host = Self.localAddress() else {
            return ready(nil, "The Apple TV has no address on a local network.")
        }
        let ports = Self.ports.compactMap { NWEndpoint.Port(rawValue: $0) } + [.any]
        listen(on: ports[...], host: host, ready: ready)
    }

    /// The first of `ports` that opens; a port in use moves on to the next.
    private func listen(on ports: ArraySlice<NWEndpoint.Port>, host: String, ready: @escaping (URL?, String?) -> Void) {
        guard let port = ports.first else { return ready(nil, "The address couldn't open.") }
        let rest = ports.dropFirst()
        guard let listener = try? NWListener(using: .tcp, on: port) else {
            return listen(on: rest, host: host, ready: ready)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    ready(URL(string: "http://\(host):\(listener.port?.rawValue ?? 0)\(self.path)"), nil)
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    if rest.isEmpty {
                        ready(nil, "The address couldn't open: \(error.localizedDescription)")
                    } else {
                        self.listen(on: rest, host: host, ready: ready)
                    }
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.connections[id] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        read(connection, received: Data())
    }

    /// Reads until the request's headers end, then answers once and closes.
    private func read(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var request = received
                if let data { request.append(data) }
                if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                    return self.answer(connection, request: request.subdata(in: request.startIndex..<end.lowerBound))
                }
                if done || error != nil || request.count > Self.requestLimit { return connection.cancel() }
                self.read(connection, received: request)
            }
        }
    }

    private func answer(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? String(parts[1]) : ""
        let found = (method == "GET" || method == "HEAD") && target == path
        var head = found
            ? "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
                + "Content-Disposition: inline; filename=\"\(Self.fileName)\"\r\nContent-Length: \(body.count)\r\n"
            : "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var reply = Data(head.utf8)
        if found, method == "GET" { reply.append(body) }
        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The Apple TV's IPv4 address on its Ethernet or Wi-Fi, for a phone on the same network.
    private static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            // A self-assigned address reaches no phone.
            if address.hasPrefix("169.254.") { continue }
            found.append((name, address))
        }
        return found.sorted { $0.name < $1.name }.first?.address
    }
}

/**
 * The address of the app menu's report, as a QR code for a phone's camera and as text, while it
 * serves it. Menu or Done closes it, and the address with it.
 */
final class LogShareScreen: UIViewController {
    /// The screen has closed, however it was.
    var closed: () -> Void = {}

    private let server: LogServer
    private let qr = UIImageView()
    private let address = UILabel()
    private let note = UILabel()
    private let done = UIButton(type: .system)

    init(text: String) {
        server = LogServer(text: LogExport.redacted(text))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.85)

        let title = UILabel()
        title.text = "Open the log on a phone"
        title.font = .systemFont(ofSize: 48, weight: .bold)
        title.textColor = .white

        qr.contentMode = .scaleAspectFit
        qr.layer.magnificationFilter = .nearest
        qr.backgroundColor = .white
        qr.layer.cornerRadius = 12
        qr.clipsToBounds = true

        address.text = "Opening the address…"
        address.font = .monospacedSystemFont(ofSize: 30, weight: .medium)
        address.textColor = .white
        address.textAlignment = .center
        address.adjustsFontSizeToFitWidth = true
        address.minimumScaleFactor = 0.5

        note.text = "Scan the code with a phone on the same network as the Apple TV, or type the address. "
            + "It opens the app menu's report as a text file, with stream addresses cut to their host and "
            + "file name. The address works only while this shows."
        note.font = .systemFont(ofSize: 26)
        note.textColor = UIColor(white: 0.75, alpha: 1)
        note.numberOfLines = 0
        note.textAlignment = .center

        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(close), for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [title, qr, address, note, done])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 32
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            column.widthAnchor.constraint(equalToConstant: 1100),
            qr.widthAnchor.constraint(equalToConstant: 420),
            qr.heightAnchor.constraint(equalToConstant: 420),
            address.widthAnchor.constraint(equalTo: column.widthAnchor),
            note.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        server.start { [weak self] url, failure in
            guard let self else { return }
            if let url {
                self.address.text = url.absoluteString
                self.qr.image = Self.code(for: url.absoluteString)
            } else {
                self.address.text = failure ?? "The address couldn't open."
                self.qr.isHidden = true
            }
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [done] }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        server.stop()
        closed()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    /// A QR code of `text`, drawn sharp at the size it shows.
    private static func code(for text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = 420 / max(output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
