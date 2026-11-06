import Foundation

public struct StalkedLine: Sendable, Identifiable {
    public let id = UUID()
    public let text: String
    public let at: Date
}

/// The site's record of what someone has said, behind `/stalk`.
public enum ChatHistory {
    private struct Reply: Decodable {
        struct Body: Decodable {
            struct Line: Decodable {
                let text: String
                let timestamp: Double
            }
            let lines: [Line]?
        }
        let success: Bool?
        let data: Body?
    }

    /// Oldest first. The site refuses guests, so this needs a key.
    public static func stalk(_ nick: String, limit: Int, loginKey: String?) async throws -> [StalkedLine] {
        var parts = URLComponents(string: "https://www.destiny.gg/api/chat/stalk")!
        parts.queryItems = [URLQueryItem(name: "username", value: nick),
                            URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: parts.url!)
        request.httpShouldHandleCookies = false
        if let loginKey { request.setValue("authtoken=\(loginKey)", forHTTPHeaderField: "Cookie") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return (reply.data?.lines ?? []).map {
            StalkedLine(text: $0.text, at: Date(timeIntervalSince1970: $0.timestamp))
        }
    }
}
