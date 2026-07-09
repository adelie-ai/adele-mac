import Foundation

/// Obtains a WebSocket bearer token from the daemon's `/login` endpoint.
///
/// This is the macOS auth path: with no local D-Bus token minter, the client
/// POSTs HTTP basic-auth credentials to `/login` (derived from the ws URL) and
/// receives a JWT, which it then stages via `AdeleCore.setWSJWT` before
/// connecting. Mirrors the Rust `request_ws_login_token` /
/// `derive_login_url_from_ws_url` logic in `client-common`.
public enum WSLogin {
    public enum Failure: Error, CustomStringConvertible {
        case badURL(String)
        case http(Int, String)
        case noToken
        case transport(String)

        public var description: String {
            switch self {
            case .badURL(let u): return "invalid WebSocket URL: \(u)"
            case .http(let code, let body):
                return "/login failed (HTTP \(code))\(body.isEmpty ? "" : ": \(body)")"
            case .noToken: return "/login response did not include a token"
            case .transport(let m): return m
            }
        }
    }

    /// `ws://host:port/ws` → `http://host:port/login` (and `wss` → `https`).
    public static func loginURL(fromWS ws: String) -> URL? {
        guard var comps = URLComponents(string: ws) else { return nil }
        switch comps.scheme {
        case "ws": comps.scheme = "http"
        case "wss": comps.scheme = "https"
        default: return nil
        }
        comps.path = "/login"
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    private struct LoginResponse: Decodable { let token: String }

    public static func token(
        wsURL: String,
        username: String,
        password: String
    ) async throws -> String {
        guard let url = loginURL(fromWS: wsURL) else { throw Failure.badURL(wsURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure.transport("no HTTP response from \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let decoded = try? JSONDecoder().decode(LoginResponse.self, from: data),
            !decoded.token.isEmpty
        else {
            throw Failure.noToken
        }
        return decoded.token
    }
}
