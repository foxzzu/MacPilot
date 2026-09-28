import Foundation

enum ReleaseFetcher {
    static func selectBeta(_ data: Data, architecture: AppArchitecture = .current) throws -> SoftwareRelease? {
        try JSONDecoder().decode([GitHubReleaseResponse].self, from: data)
            .compactMap { try? SoftwareRelease.decode($0, architecture: architecture, channel: .beta) }
            .max { $0.version < $1.version }
    }

    /// Scan every page: GitHub orders releases by date, not SemVer precedence.
    static func fetchBeta(session: URLSession, currentVersion: String) async throws -> SoftwareRelease? {
        var page = 1
        var best: SoftwareRelease?
        while true {
            let url = URL(string: "https://api.github.com/repos/\(AppIdentity.githubRepository)/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw SoftwareUpdateError.invalidResponse
            }
            if let candidate = try selectBeta(data), best.map({ $0.version < candidate.version }) ?? true {
                best = candidate
            }
            guard response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true else { return best }
            page += 1
        }
    }
}
