import Foundation

@testable import NocturneSyncCore

/// Scriptable `HealthSource`. Heart rate samples live in an insertion-ordered log; an anchor is a
/// position in that log, so paging, the start-date predicate, and data arriving between runs behave
/// like an anchored HealthKit query. Errors are queued per query kind and consumed one per call.
actor FakeHealthSource: HealthSource {
  struct HeartRateQuery: Equatable {
    var anchor: Data?
    var start: Date
    var limit: Int
  }

  struct StepQuery: Equatable {
    var interval: DateInterval
    var bucketSeconds: Int
  }

  struct BadAnchor: Error {}

  private(set) var heartRateLog: [HeartRateSample]
  private(set) var stepTotalsByStart: [Int: StepBucketTotal]
  private(set) var sleepSamplesByID: [UUID: SleepSample]
  private(set) var heartRateQueries: [HeartRateQuery] = []
  private(set) var stepQueries: [StepQuery] = []
  private(set) var sleepQueries: [DateInterval] = []
  private(set) var authorizationRequests = 0
  private(set) var backgroundDeliveryRequests: [HealthDataType] = []
  private var observers: [HealthDataType: @Sendable () async -> Void] = [:]
  private var heartRateErrors: [HealthSourceError] = []
  private var stepErrors: [HealthSourceError] = []
  private var sleepErrors: [HealthSourceError] = []

  init(heartRates: [HeartRateSample] = [], stepTotals: [StepBucketTotal] = [], sleep: [SleepSample] = []) {
    heartRateLog = heartRates
    stepTotalsByStart = Dictionary(uniqueKeysWithValues: stepTotals.map { ($0.bucket.startUnixSeconds, $0) })
    sleepSamplesByID = Dictionary(uniqueKeysWithValues: sleep.map { ($0.id, $0) })
  }

  // MARK: Scripting

  func appendHeartRates(_ samples: [HeartRateSample]) {
    heartRateLog.append(contentsOf: samples)
  }

  /// Replaces the total of each given bucket, as a late Watch sync would.
  func setStepTotals(_ totals: [StepBucketTotal]) {
    for total in totals { stepTotalsByStart[total.bucket.startUnixSeconds] = total }
  }

  func failNextHeartRateQueries(_ errors: HealthSourceError...) {
    heartRateErrors.append(contentsOf: errors)
  }

  func failNextStepQueries(_ errors: HealthSourceError...) {
    stepErrors.append(contentsOf: errors)
  }

  /// Adds or replaces sleep samples by id, as a late Watch sync or an edit in Health would.
  func setSleepSamples(_ samples: [SleepSample]) {
    for sample in samples { sleepSamplesByID[sample.id] = sample }
  }

  func removeSleepSamples(_ ids: [UUID]) {
    for id in ids { sleepSamplesByID[id] = nil }
  }

  func failNextSleepQueries(_ errors: HealthSourceError...) {
    sleepErrors.append(contentsOf: errors)
  }

  var observedTypes: Set<HealthDataType> { Set(observers.keys) }

  /// Fires the observer registered for `type` and waits for it, like HealthKit waiting for the
  /// completion handler.
  func simulateChange(of type: HealthDataType) async {
    await observers[type]?()
  }

  static func anchor(position: Int) -> Data {
    Data("fake-anchor:\(position)".utf8)
  }

  // MARK: HealthSource

  func requestReadAuthorization() async throws(HealthSourceError) {
    authorizationRequests += 1
  }

  func heartRateSamples(after anchor: Data?, startingAt start: Date, limit: Int) async throws(HealthSourceError)
    -> HeartRatePage
  {
    precondition(limit > 0, "HealthKit requires a positive limit here")
    heartRateQueries.append(HeartRateQuery(anchor: anchor, start: start, limit: limit))
    if !heartRateErrors.isEmpty { throw heartRateErrors.removeFirst() }

    var position = try Self.position(of: anchor)
    var page: [HeartRateSample] = []
    while position < heartRateLog.count, page.count < limit {
      if heartRateLog[position].date >= start { page.append(heartRateLog[position]) }
      position += 1
    }
    return HeartRatePage(samples: page, anchor: Self.anchor(position: position), mightHaveMore: page.count >= limit)
  }

  func stepTotals(in interval: DateInterval, bucketSeconds: Int) async throws(HealthSourceError) -> [StepBucketTotal] {
    precondition(
      StepBucket(startingAt: interval.start, bucketSeconds: bucketSeconds) != nil,
      "interval.start must be bucket-aligned")
    stepQueries.append(StepQuery(interval: interval, bucketSeconds: bucketSeconds))
    if !stepErrors.isEmpty { throw stepErrors.removeFirst() }

    return stepTotalsByStart.values
      .filter { total in
        total.bucket.bucketSeconds == bucketSeconds && total.bucket.start >= interval.start
          && total.bucket.start < interval.end
      }
      .sorted { $0.bucket.startUnixSeconds < $1.bucket.startUnixSeconds }
  }

  func sleepSamples(overlapping interval: DateInterval) async throws(HealthSourceError) -> [SleepSample] {
    sleepQueries.append(interval)
    if !sleepErrors.isEmpty { throw sleepErrors.removeFirst() }
    return sleepSamplesByID.values
      .filter { $0.start < interval.end && $0.end > interval.start }
      .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
  }

  func enableBackgroundDelivery(for type: HealthDataType) async throws(HealthSourceError) {
    backgroundDeliveryRequests.append(type)
  }

  func observeChanges(of type: HealthDataType, onChange: @escaping @Sendable () async -> Void)
    async throws(HealthSourceError)
  {
    guard observers[type] == nil else { return }
    observers[type] = onChange
  }

  private static func position(of anchor: Data?) throws(HealthSourceError) -> Int {
    guard let anchor else { return 0 }
    let prefix = "fake-anchor:"
    guard let text = String(data: anchor, encoding: .utf8), text.hasPrefix(prefix),
      let position = Int(text.dropFirst(prefix.count))
    else { throw .invalidAnchor(BadAnchor()) }
    return position
  }
}

/// Runs `body` and returns the `HealthSourceError` it threw, or nil if it succeeded.
func thrownHealthError<T>(_ body: () async throws(HealthSourceError) -> T) async -> HealthSourceError? {
  do {
    _ = try await body()
    return nil
  } catch {
    return error
  }
}
