import Foundation

/// A catalog entry: the verified release plus whatever compatibility manifest
/// was published for it. `compatibility == nil` means "not published for this
/// historical release" — compatibility unknown, never guessed.
struct CatalogRelease: Identifiable, Equatable {
    let release: SoftwareRelease
    let compatibility: ReleaseCompatibility?

    var id: String { release.version.description }
    var channel: AppChannel { release.isPrerelease ? .beta : .stable }

    func relation(to currentVersion: String) -> VersionRelation {
        release.relation(to: currentVersion)
    }

    var compatibilityState: ConfigurationCompatibility {
        ConfigurationCompatibility(release: self)
    }
}

struct VersionCatalog: Equatable {
    /// Sorted by SemVer precedence, newest first. GitHub orders by date, which
    /// is not a reliable version order, so the catalog never trusts it.
    let releases: [CatalogRelease]
    let latestStable: SoftwareVersion?
    let latestBeta: SoftwareVersion?
    let fetchedAt: Date

    init(releases: [CatalogRelease], fetchedAt: Date) {
        let sorted = releases.sorted { $0.release.version > $1.release.version }
        self.releases = sorted
        latestStable = sorted.first { $0.channel == .stable }?.release.version
        latestBeta = sorted.first { $0.channel == .beta }?.release.version
        self.fetchedAt = fetchedAt
    }
}

/// Separate from `SoftwareUpdateState` on purpose: loading the history list
/// must never make the menu bar claim "checking for updates" or clobber the
/// result of a check the user just ran.
enum ReleaseCatalogState: Equatable {
    case idle
    case loading
    case loaded(VersionCatalog)
    case failed(SoftwareUpdateFailure)
}

/// Fetches every installable release for the Version Manager.
///
/// Only releases that carry a verified archive for this CPU (HTTPS URL, GitHub
/// SHA-256 digest, matching version) are listed; a release without one is
/// filtered out entirely instead of being shown with a disabled install
/// button. Results are cached for five minutes so repeatedly opening the page
/// does not walk the GitHub API each time; a manual refresh bypasses the cache.
@MainActor
final class ReleaseCatalogService: ObservableObject {
    static let cacheInterval: TimeInterval = 300

    @Published private(set) var state: ReleaseCatalogState = .idle

    private let session: URLSession
    private let currentVersion: String
    private let architecture: AppArchitecture
    private let now: () -> Date
    private var cache: VersionCatalog?
    private var loadTask: Task<Void, Never>?

    init(
        session: URLSession = .shared,
        currentVersion: String = AppVersionInfo.current().version,
        architecture: AppArchitecture = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.currentVersion = currentVersion
        self.architecture = architecture
        self.now = now
    }

    func load(forceRefresh: Bool = false) async {
        if let cache, !forceRefresh, now().timeIntervalSince(cache.fetchedAt) < Self.cacheInterval {
            state = .loaded(cache)
            return
        }
        if let loadTask {
            _ = await loadTask.value
            return
        }
        state = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.fetchCatalog()
                self.cache = catalog
                self.state = .loaded(catalog)
            } catch {
                self.state = .failed(SoftwareUpdateFailure(error))
            }
            self.loadTask = nil
        }
        loadTask = task
        _ = await task.value
    }

    /// Catalog entries the Version Manager offers install actions for.
    func installableReleases() -> [CatalogRelease]? {
        guard case .loaded(let catalog) = state else { return nil }
        return catalog.releases
    }

    private func fetchCatalog() async throws -> VersionCatalog {
        var responses: [GitHubReleaseResponse] = []
        var page = 1
        while true {
            let url = URL(string: "https://api.github.com/repos/\(AppIdentity.githubRepository)/releases?per_page=100&page=\(page)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MacPilot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SoftwareUpdateError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw SoftwareUpdateError.invalidResponse
            }
            responses += try JSONDecoder().decode([GitHubReleaseResponse].self, from: data)
            guard httpResponse.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true else {
                break
            }
            page += 1
        }

        var entries: [CatalogRelease] = []
        for response in responses where !response.draft {
            let channel: AppChannel = response.prerelease ? .beta : .stable
            guard let release = try? SoftwareRelease.decode(
                response,
                architecture: architecture,
                channel: channel
            ) else {
                // No verified archive for this CPU (or the tag does not match
                // the channel): not installable, so it stays out of the list.
                continue
            }
            let compatibility = await VersionCompatibilityService.fetch(
                for: response,
                session: session,
                currentVersion: currentVersion
            )
            entries.append(CatalogRelease(release: release, compatibility: compatibility))
        }
        return VersionCatalog(releases: entries, fetchedAt: now())
    }
}
