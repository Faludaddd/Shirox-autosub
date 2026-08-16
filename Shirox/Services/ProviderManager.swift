import Foundation
import SwiftUI
import Combine

@MainActor
final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    @Published var orderedProviders: [any MediaProvider] = []
    @Published var fallbackActive = false

    /// Per-provider rate-limit cooldowns. When a provider returns a 429 (or
    /// `AniListError.rateLimited`), we record the time at which it's safe to
    /// retry. Calls during the cooldown skip the rate-limited provider
    /// entirely instead of hammering it on every retry.
    ///
    /// **Why this matters:** before this map existed, a 429 from the primary
    /// would immediately try the fallback. If the fallback *also* returned
    /// 429 (common when AniList and MAL are both throttling), every
    /// subsequent call inside the 30s fallback window would burn a request
    /// against both providers — making the rate limit worse, not better.
    @Published var rateLimitUntil: [ProviderType: Date] = [:]

    /// Default rate-limit cooldown (seconds). Used when the response doesn't
    /// include a `Retry-After` header. Long enough to let the upstream
    /// limiter recover, short enough that the user doesn't sit on a dead
    /// provider for minutes.
    private let defaultRateLimitCooldown: TimeInterval = 60

    /// The 30s fallback-reset task. Cancelled when the fallback (or primary)
    /// succeeds so we don't leave `fallbackActive = true` dangling while a
    /// new operation is in flight.
    private var fallbackResetTask: Task<Void, Never>?

    private let orderKey = "providerOrder"

    private init() {}

    func setup(providers: [any MediaProvider]) {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        if saved.isEmpty {
            orderedProviders = providers
        } else {
            var sorted: [any MediaProvider] = []
            for key in saved {
                if let p = providers.first(where: { $0.providerType.rawValue == key }) {
                    sorted.append(p)
                }
            }
            for p in providers where !sorted.contains(where: { $0.providerType == p.providerType }) {
                sorted.append(p)
            }
            orderedProviders = sorted
        }
    }

    func saveOrder() {
        UserDefaults.standard.set(orderedProviders.map { $0.providerType.rawValue }, forKey: orderKey)
    }

    func moveProvider(from source: IndexSet, to destination: Int) {
        orderedProviders.move(fromOffsets: source, toOffset: destination)
        saveOrder()
    }

    func selectProvider(_ type: ProviderType) {
        guard let idx = orderedProviders.firstIndex(where: { $0.providerType == type }), idx != 0 else { return }
        orderedProviders.move(fromOffsets: IndexSet(integer: idx), toOffset: 0)
        fallbackActive = false
        cancelFallbackReset()
        saveOrder()
    }

    var primary: (any MediaProvider)? { orderedProviders.first }
    var fallback: (any MediaProvider)? { orderedProviders.count > 1 ? orderedProviders[1] : nil }

    func call<T: Sendable>(_ operation: @MainActor (any MediaProvider) async throws -> T) async throws -> T {
        guard let primary else { throw ProviderError.unauthenticated }

        // If primary is currently rate-limited, skip straight to fallback
        // (don't burn a request that we know will 429).
        if isRateLimited(primary.providerType) {
            return try await callFallback(operation, primaryError: ProviderError.serverError(429))
        }

        do {
            let result = try await operation(primary)
            // Primary succeeded — clear any stale fallback flag and cancel
            // the pending reset task so it can't fire later and clobber a
            // new fallback state.
            if fallbackActive {
                fallbackActive = false
                cancelFallbackReset()
            }
            return result
        } catch {
            // Offline errors aren't recoverable by switching providers —
            // propagate immediately so the caller can show offline UI.
            if Self.isOfflineError(error) { throw error }

            // Record rate-limit cooldown if this was a 429.
            if let cooldown = Self.rateLimitCooldown(for: error) {
                recordRateLimit(primary.providerType, duration: cooldown)
            }

            return try await callFallback(operation, primaryError: error)
        }
    }

    /// Tries the fallback provider, or throws `primaryError` if no fallback
    /// is available or the fallback is itself rate-limited. Sets
    /// `fallbackActive = true` for the duration of the fallback attempt so
    /// the UI (e.g. source switcher, library) can reflect the temporary
    /// provider change.
    private func callFallback<T: Sendable>(
        _ operation: @MainActor (any MediaProvider) async throws -> T,
        primaryError: Error
    ) async throws -> T {
        // Cancellation is intentional (SwiftUI view disappeared, a newer
        // request replaced this one, etc.) — NOT a provider failure. Skip
        // the fallback entirely and re-throw without logging so the logs
        // aren't spammed with "fallback check — error: cancelled" every
        // time the user navigates.
        if Self.isCancellationError(primaryError) {
            throw primaryError
        }

        let eligible = isFallbackEligible(primaryError)
        Logger.shared.log(
            "ProviderManager fallback check — error: \(primaryError), eligible: \(eligible), fallback: \(fallback?.providerType.rawValue ?? "nil")",
            type: "Provider"
        )
        guard eligible, let fallback else { throw primaryError }

        // If the fallback is also rate-limited, don't bother — throw the
        // original error so the caller sees the real cause (429) instead of
        // a generic "fallback also failed" message.
        if isRateLimited(fallback.providerType) {
            Logger.shared.log(
                "ProviderManager fallback \(fallback.providerType.rawValue) is also rate-limited; throwing primary error",
                type: "Provider"
            )
            throw primaryError
        }

        fallbackActive = true
        Logger.shared.log(
            "ProviderManager switching to fallback: \(fallback.providerType.rawValue)",
            type: "Provider"
        )
        // Schedule a safety reset in case the fallback hangs or the success
        // path doesn't fire (e.g. user backgrounds the app mid-request).
        scheduleFallbackReset()

        do {
            let result = try await operation(fallback)
            // Fallback succeeded — clear the flag now rather than waiting
            // for the 30s timer. The next call will retry primary first.
            fallbackActive = false
            cancelFallbackReset()
            return result
        } catch {
            // Fallback also failed — record its rate-limit cooldown if 429.
            if let cooldown = Self.rateLimitCooldown(for: error) {
                recordRateLimit(fallback.providerType, duration: cooldown)
            }
            throw error
        }
    }

    nonisolated static func isOfflineError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .timedOut:
            return true
        default:
            return false
        }
    }

    /// True when the error represents an intentional request cancellation
    /// (URLError.cancelled = -999, or Swift's CancellationError). These are
    /// NOT provider failures — they happen every time a SwiftUI view
    /// disappears mid-request, or when a newer search/detail request
    /// supersedes an in-flight one. Treating them as fallback-eligible
    /// caused log spam and occasional unnecessary MAL fallback.
    nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func isFallbackEligible(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let pe = error as? ProviderError { return pe.isFallbackEligible }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let aniError = error as? AniListError {
            switch aniError {
            case .httpError(let code):
                // 403 = blocked/rate-limited → try MAL
                // 404 = not found on AniList → might exist on MAL
                // 429 = rate limited → try MAL
                // 5xx = server error → try MAL
                // Do NOT fall back on 400/401 (bad request/unauthorized — these
                // will fail on MAL too, and the fallback just adds latency).
                return code == 403 || code == 404 || code == 429 || code >= 500
            case .rateLimited: return true
            default: return false
            }
        }
        return false
    }

    // MARK: - Rate Limit Tracking

    /// True when `type` is currently inside its rate-limit cooldown window.
    private func isRateLimited(_ type: ProviderType) -> Bool {
        guard let until = rateLimitUntil[type] else { return false }
        if until > Date() { return true }
        // Cooldown expired — clear the entry so the dictionary doesn't grow.
        rateLimitUntil[type] = nil
        return false
    }

    /// Records a rate-limit cooldown for `type`. `duration` is in seconds.
    private func recordRateLimit(_ type: ProviderType, duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        rateLimitUntil[type] = until
        Logger.shared.log(
            "[ProviderManager] \(type.rawValue) rate-limited for \(Int(duration))s (until \(until))",
            type: "Provider"
        )
    }

    /// Returns a cooldown duration (seconds) if `error` represents a 429 /
    /// rate-limit condition; nil otherwise. Used by `call` to record
    /// per-provider cooldowns so we don't keep hammering a throttled
    /// provider across consecutive calls.
    nonisolated static func rateLimitCooldown(for error: Error) -> TimeInterval? {
        if let aniError = error as? AniListError {
            switch aniError {
            case .rateLimited: return 60
            case .httpError(let code) where code == 429: return 60
            default: return nil
            }
        }
        if let pe = error as? ProviderError {
            switch pe {
            case .serverError(let code) where code == 429: return 60
            default: return nil
            }
        }
        return nil
    }

    /// Returns a human-readable remaining cooldown (in seconds) for `type`,
    /// or nil if not currently rate-limited. Surfaces via `@Published
    /// rateLimitUntil` so views can show "rate-limited, retry in 30s" if
    /// desired.
    func rateLimitRemainingSeconds(for type: ProviderType) -> Int? {
        guard let until = rateLimitUntil[type], until > Date() else { return nil }
        return Int(until.timeIntervalSinceNow.rounded(.up))
    }

    // MARK: - Fallback Reset Timer

    /// Schedules a 30s safety reset of `fallbackActive`. Cancelled if the
    /// fallback (or a subsequent primary) succeeds before the timer fires.
    private func scheduleFallbackReset() {
        cancelFallbackReset()
        fallbackResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.fallbackActive {
                Logger.shared.log(
                    "[ProviderManager] 30s fallback safety timer fired — resetting fallbackActive",
                    type: "Provider"
                )
                self.fallbackActive = false
            }
            self.fallbackResetTask = nil
        }
    }

    private func cancelFallbackReset() {
        fallbackResetTask?.cancel()
        fallbackResetTask = nil
    }
}
