import Foundation
import HealthKit
import NocturneSyncCore
import Synchronization
import os

/// `HealthSource` on HealthKit. Read-only: nothing is ever written to the store.
///
/// Apple behaviour relied on (verify on device; none of it can be unit-tested):
/// - `HKAnchoredObjectQueryDescriptor` returns a new anchor per result. Passing that anchor back with
///   the same predicate resumes after the last object returned. `limit` bounds each result.
/// - Whether `limit` counts deleted objects as well as samples is not documented clearly, so
///   `mightHaveMore` counts both. Over-reporting costs one empty extra query; under-reporting would
///   only defer the remainder to the next run.
/// - `HKStatisticsCollectionQueryDescriptor` with `.cumulativeSum` applies Health's source
///   prioritisation, so iPhone and Watch steps for the same minutes are not double-counted.
/// - Statistics intervals are stepped from `anchorDate`. Using the bucket-aligned window start as the
///   anchor and a fixed interval in whole minutes (the unit Apple's examples use) yields epoch-aligned
///   buckets. Every bucket start is checked,
///   and a misaligned one fails the query instead of producing wrong identifiers.
/// - A locked device fails queries with `HKError.Code.errorDatabaseInaccessible`.
/// - Unanswered `HKObserverQuery` deliveries make iOS throttle background delivery, so the completion
///   handler is called on every path.
/// - Denied read access looks like "no data"; it never surfaces as an error.
///
/// `HKHealthStore` is `Sendable` in the iOS 18 SDK; if a future SDK drops that, the build fails here.
final class HealthKitSource: HealthSource {
  private let store: HKHealthStore
  private let observed = Mutex<Set<HealthDataType>>([])
  private static let logger = Logger(subsystem: "com.pljeske.NocturneSync.HealthKit", category: "HealthKitSource")

  init(store: HKHealthStore = HKHealthStore()) {
    self.store = store
  }

  // MARK: HealthSource

  func requestReadAuthorization() async throws(HealthSourceError) {
    guard HKHealthStore.isHealthDataAvailable() else { throw .healthDataUnavailable }
    let read = Set(HealthDataType.allCases.map { Self.quantityType($0) as HKObjectType })
    do {
      try await store.requestAuthorization(toShare: [], read: read)
    } catch {
      throw Self.mapError(error)
    }
  }

  func heartRateSamples(after anchorData: Data?, startingAt start: Date, limit: Int) async throws(HealthSourceError)
    -> HeartRatePage
  {
    precondition(limit > 0, "an unbounded anchored query can return more than one run can upload")
    var anchor: HKQueryAnchor?
    if let anchorData { anchor = try Self.unarchive(anchorData) }

    let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
    let descriptor = HKAnchoredObjectQueryDescriptor(
      predicates: [.quantitySample(type: Self.quantityType(.heartRate), predicate: predicate)],
      anchor: anchor,
      limit: limit)

    let result: HKAnchoredObjectQueryDescriptor<HKQuantitySample>.Result
    do {
      result = try await descriptor.result(for: store)
    } catch {
      throw Self.mapError(error)
    }

    let unit = HKUnit.count().unitDivided(by: .minute())
    let samples = result.addedSamples.map { sample in
      HeartRateSample(
        id: sample.uuid,
        date: sample.startDate,
        beatsPerMinute: sample.quantity.doubleValue(for: unit),
        timeZoneIdentifier: sample.metadata?[HKMetadataKeyTimeZone] as? String,
        device: Self.deviceName(sample.sourceRevision))
    }
    return HeartRatePage(
      samples: samples,
      anchor: try Self.archive(result.newAnchor),
      mightHaveMore: result.addedSamples.count + result.deletedObjects.count >= limit)
  }

  func stepTotals(in interval: DateInterval, bucketSeconds: Int) async throws(HealthSourceError) -> [StepBucketTotal] {
    precondition(
      StepBucket(startingAt: interval.start, bucketSeconds: bucketSeconds) != nil,
      "interval.start must be bucket-aligned")
    precondition(bucketSeconds.isMultiple(of: 60), "statistics intervals are expressed in whole minutes")
    // Overlap, not strict start: a sample that began before the window still contributes its share.
    let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
    let descriptor = HKStatisticsCollectionQueryDescriptor(
      predicate: .quantitySample(type: Self.quantityType(.stepCount), predicate: predicate),
      options: .cumulativeSum,
      anchorDate: interval.start,
      intervalComponents: DateComponents(minute: bucketSeconds / 60))

    let collection: HKStatisticsCollection
    do {
      collection = try await descriptor.result(for: store)
    } catch {
      throw Self.mapError(error)
    }

    var totals: [StepBucketTotal] = []
    for statistics in collection.statistics() {
      guard statistics.startDate >= interval.start, statistics.startDate < interval.end,
        let sum = statistics.sumQuantity()
      else { continue }
      guard let bucket = StepBucket(startingAt: statistics.startDate, bucketSeconds: bucketSeconds) else {
        throw .misalignedStatistics(start: statistics.startDate)
      }
      totals.append(StepBucketTotal(bucket: bucket, steps: sum.doubleValue(for: .count())))
    }
    return totals.sorted { $0.bucket.startUnixSeconds < $1.bucket.startUnixSeconds }
  }

  func enableBackgroundDelivery(for type: HealthDataType) async throws(HealthSourceError) {
    do {
      try await store.enableBackgroundDelivery(for: Self.quantityType(type), frequency: Self.deliveryFrequency(type))
    } catch {
      throw Self.mapError(error)
    }
  }

  func observeChanges(of type: HealthDataType, onChange: @escaping @Sendable () async -> Void)
    async throws(HealthSourceError)
  {
    guard observed.withLock({ $0.insert(type).inserted }) else { return }
    let logger = Self.logger
    let query = HKObserverQuery(sampleType: Self.quantityType(type), predicate: nil) { _, completionHandler, error in
      let completion = ObserverCompletion(completionHandler)
      if let error {
        logger.error(
          "Observer for \(type.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        completion()
        return
      }
      Task {
        await onChange()
        completion()
      }
    }
    store.execute(query)
  }

  // MARK: Mapping

  private static func quantityType(_ type: HealthDataType) -> HKQuantityType {
    switch type {
    case .heartRate: HKQuantityType(.heartRate)
    case .stepCount: HKQuantityType(.stepCount)
    }
  }

  /// Hourly for both (decision 9). `.immediate` heart rate would relaunch the app in the background
  /// on every Watch sync of a few samples, many times an hour; iOS caps step count at hourly anyway.
  private static func deliveryFrequency(_ type: HealthDataType) -> HKUpdateFrequency {
    switch type {
    case .heartRate, .stepCount: .hourly
    }
  }

  /// `productType` ("Watch7,1") when the source reports one, else the source's display name.
  private static func deviceName(_ revision: HKSourceRevision) -> String {
    if let productType = revision.productType, !productType.isEmpty { return productType }
    return revision.source.name
  }

  private static func mapError(_ error: any Error) -> HealthSourceError {
    guard let healthKitError = error as? HKError else { return .other(error) }
    switch healthKitError.code {
    case .errorDatabaseInaccessible: return .databaseInaccessible
    case .errorHealthDataUnavailable: return .healthDataUnavailable
    case .errorAuthorizationNotDetermined: return .authorizationNotDetermined
    default: return .other(error)
    }
  }

  private enum AnchorArchiveError: Error {
    case notAnAnchor
  }

  private static func archive(_ anchor: HKQueryAnchor) throws(HealthSourceError) -> Data {
    do {
      return try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    } catch {
      throw .other(error)
    }
  }

  private static func unarchive(_ data: Data) throws(HealthSourceError) -> HKQueryAnchor {
    let anchor: HKQueryAnchor?
    do {
      anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    } catch {
      throw .invalidAnchor(error)
    }
    guard let anchor else { throw .invalidAnchor(AnchorArchiveError.notAnAnchor) }
    return anchor
  }
}

/// `HKObserverQueryCompletionHandler` is not annotated `@Sendable`, but it has to be called after the
/// async sync run finishes, from whatever thread that ends on. HealthKit invokes the update handler on
/// its own background queue and only requires the completion handler to be called once.
/// `@unchecked` is limited to carrying that one closure across the `Task` boundary.
private struct ObserverCompletion: @unchecked Sendable {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  func callAsFunction() {
    handler()
  }
}
