/// Exponential backoff shared by the client (deciding *whether* enough time has passed to retry) and
/// the observers (deciding *how long* to sleep before the next attempt). One source of truth so the
/// two never disagree and double-fetch or stall.
enum RetryPolicy {
    /// Delay before the retry that follows `failureCount` consecutive failures: `base · 2^(n-1)`,
    /// clamped to `cap`. After 1 failure → `base`, after 2 → `2·base`, and so on.
    static func backoff(failureCount: Int, base: Duration, cap: Duration) -> Duration {
        let exponent = min(max(0, failureCount - 1), 16)   // clamp so the shift can't overflow
        let scaled = base * (1 << exponent)
        return min(scaled, cap)
    }
}
