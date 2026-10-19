import Foundation

/// Why reading Health failed. The engine reacts per case; none of them is ever retried in a loop.
public enum HealthSourceError: Error, Sendable {
  /// The device is locked and the HealthKit store is encrypted. Retry later; do not advance anything
  /// and do not surface it as an error.
  case databaseInaccessible
  /// HealthKit does not exist on this device.
  case healthDataUnavailable
  /// Read access was never requested. (A denial is indistinguishable from "no data" by design.)
  case authorizationNotDetermined
  /// The persisted anchor cannot be decoded. The engine drops it and starts over; the server upsert
  /// makes the re-upload harmless.
  case invalidAnchor(any Error)
  /// A statistics interval did not start on an epoch-aligned bucket boundary. Means the HealthKit
  /// bucketing assumption broke; nothing from that query may be uploaded.
  case misalignedStatistics(start: Date)
  case other(any Error)
}

/// One page of an anchored heart rate query.
public struct HeartRatePage: Sendable, Hashable {
  public var samples: [HeartRateSample]
  /// Archived `HKQueryAnchor` positioned after this page. Commit it only once every sample in
  /// `samples` has been uploaded.
  public var anchor: Data
  /// The query hit its limit, so another page may follow. Set from samples plus deleted objects,
  /// because HealthKit's limit may count both; a page can be full with fewer than `limit` samples.
  public var mightHaveMore: Bool

  public init(samples: [HeartRateSample], anchor: Data, mightHaveMore: Bool) {
    self.samples = samples
    self.anchor = anchor
    self.mightHaveMore = mightHaveMore
  }
}

/// Read-only view of HealthKit. The live implementation is `HealthKitSource` in the app target; the
/// engine and its tests only ever see this protocol.
public protocol HealthSource: Sendable {
  /// Asks for read access to every `HealthDataType`. Succeeds whether or not the user granted it.
  func requestReadAuthorization() async throws(HealthSourceError)

  /// Heart rate samples added after `anchor` (nil = from the beginning) whose start date is at or
  /// after `start`, at most `limit` of them, in HealthKit's anchor order. Deleted samples are not
  /// reported (deletions are not propagated; see CLAUDE.md).
  func heartRateSamples(after anchor: Data?, startingAt start: Date, limit: Int) async throws(HealthSourceError)
    -> HeartRatePage

  /// Source-prioritised step totals per epoch-aligned bucket for every bucket in `interval` that has
  /// data, ordered by start. `interval.start` must lie on a bucket boundary. Buckets with no samples
  /// are omitted; buckets whose total is zero may be returned.
  func stepTotals(in interval: DateInterval, bucketSeconds: Int) async throws(HealthSourceError) -> [StepBucketTotal]

  /// Every sleep sample of every source and stage that overlaps `interval`, ordered by start. Sleep has
  /// no anchor: the pipeline re-reads a window and rebuilds its sessions from scratch.
  func sleepSamples(overlapping interval: DateInterval) async throws(HealthSourceError) -> [SleepSample]

  /// Registers background delivery for `type`. Must be called at every launch.
  func enableBackgroundDelivery(for type: HealthDataType) async throws(HealthSourceError)

  /// Calls `onChange` whenever HealthKit reports new data for `type`, including in the background.
  /// The implementation tells HealthKit it is done only after `onChange` returns. Registering the same
  /// type twice is a no-op.
  func observeChanges(of type: HealthDataType, onChange: @escaping @Sendable () async -> Void)
    async throws(HealthSourceError)
}
