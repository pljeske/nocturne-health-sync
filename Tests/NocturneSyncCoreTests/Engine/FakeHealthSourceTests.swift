import Foundation
import Synchronization
import Testing

@testable import NocturneSyncCore

/// The engine tests in steps 6 and 7 trust this fake to behave like an anchored HealthKit query, so
/// its paging rules are pinned here.
@Suite struct FakeHealthSourceTests {
  let base = Date(timeIntervalSince1970: 1_720_000_000)

  func samples(_ offsets: [TimeInterval]) -> [HeartRateSample] {
    offsets.enumerated().map { index, offset in
      HeartRateSample(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
        date: base.addingTimeInterval(offset), beatsPerMinute: 60 + Double(index), device: "Watch7,1")
    }
  }

  @Test func pagesThroughTheLogInAnchorOrder() async throws {
    let source = FakeHealthSource(heartRates: samples([0, 1, 2, 3, 4]))
    let first = try await source.heartRateSamples(after: nil, startingAt: base, limit: 2)
    let second = try await source.heartRateSamples(after: first.anchor, startingAt: base, limit: 2)
    let third = try await source.heartRateSamples(after: second.anchor, startingAt: base, limit: 2)
    #expect(first.samples.map(\.beatsPerMinute) == [60, 61])
    #expect(first.mightHaveMore)
    #expect(second.samples.map(\.beatsPerMinute) == [62, 63])
    #expect(second.mightHaveMore)
    #expect(third.samples.map(\.beatsPerMinute) == [64])
    #expect(!third.mightHaveMore)
  }

  @Test func shortPageAnchorPicksUpDataAddedLater() async throws {
    let source = FakeHealthSource(heartRates: samples([0]))
    let first = try await source.heartRateSamples(after: nil, startingAt: base, limit: 10)
    await source.appendHeartRates(samples([5, 6]))
    let next = try await source.heartRateSamples(after: first.anchor, startingAt: base, limit: 10)
    #expect(next.samples.count == 2)
    #expect(!next.mightHaveMore)
    let empty = try await source.heartRateSamples(after: next.anchor, startingAt: base, limit: 10)
    #expect(empty.samples.isEmpty)
    #expect(empty.anchor == next.anchor)
  }

  @Test func startDatePredicateFiltersWithoutStallingTheAnchor() async throws {
    // Old samples interleaved with new ones in insertion order, as a late history import produces.
    let source = FakeHealthSource(heartRates: samples([-100, 10, -50, 20, -10, 30]))
    let page = try await source.heartRateSamples(after: nil, startingAt: base, limit: 2)
    #expect(page.samples.map { $0.date.timeIntervalSince(base) } == [10, 20])
    #expect(page.mightHaveMore)
    let rest = try await source.heartRateSamples(after: page.anchor, startingAt: base, limit: 2)
    #expect(rest.samples.map { $0.date.timeIntervalSince(base) } == [30])
    #expect(!rest.mightHaveMore)
  }

  @Test func recordsQueriesAndConsumesErrorsOnePerCall() async throws {
    let source = FakeHealthSource(heartRates: samples([0]))
    await source.failNextHeartRateQueries(.databaseInaccessible)
    let error = await thrownHealthError { () throws(HealthSourceError) in
      try await source.heartRateSamples(after: nil, startingAt: base, limit: 5)
    }
    guard case .databaseInaccessible = error else {
      Issue.record("expected .databaseInaccessible, got \(String(describing: error))")
      return
    }
    let page = try await source.heartRateSamples(after: nil, startingAt: base, limit: 5)
    #expect(page.samples.count == 1)
    #expect(
      await source.heartRateQueries == [
        .init(anchor: nil, start: base, limit: 5), .init(anchor: nil, start: base, limit: 5),
      ])
  }

  @Test func foreignAnchorIsInvalid() async {
    let source = FakeHealthSource()
    let error = await thrownHealthError { () throws(HealthSourceError) in
      try await source.heartRateSamples(after: Data([0xFF]), startingAt: base, limit: 5)
    }
    guard case .invalidAnchor = error else {
      Issue.record("expected .invalidAnchor, got \(String(describing: error))")
      return
    }
  }

  @Test func stepTotalsHonourTheHalfOpenWindow() async throws {
    let buckets = StepBucket.buckets(
      overlapping: DateInterval(start: Date(timeIntervalSince1970: 1_720_000_200), duration: 1500))
    let source = FakeHealthSource(
      stepTotals: buckets.enumerated().map { StepBucketTotal(bucket: $1, steps: Double($0 * 10)) })
    let window = DateInterval(start: buckets[1].start, end: buckets[4].start)
    let totals = try await source.stepTotals(in: window, bucketSeconds: 300)
    #expect(totals.map(\.bucket) == Array(buckets[1..<4]))
    #expect(await source.stepQueries == [.init(interval: window, bucketSeconds: 300)])
  }

  @Test func lateUpdateReplacesABucketTotal() async throws {
    let bucket = StepBucket(containing: base)
    let source = FakeHealthSource(stepTotals: [StepBucketTotal(bucket: bucket, steps: 10)])
    await source.setStepTotals([StepBucketTotal(bucket: bucket, steps: 25)])
    let totals = try await source.stepTotals(in: bucket.interval, bucketSeconds: 300)
    #expect(totals.map(\.steps) == [25])
  }

  @Test func observerRegistrationIsIdempotentAndFires() async throws {
    let source = FakeHealthSource()
    let calls = Mutex<[String]>([])
    try await source.observeChanges(of: .heartRate) { calls.withLock { $0.append("first") } }
    try await source.observeChanges(of: .heartRate) { calls.withLock { $0.append("second") } }
    await source.simulateChange(of: .heartRate)
    await source.simulateChange(of: .stepCount)
    #expect(calls.withLock { $0 } == ["first"])
    #expect(await source.observedTypes == [.heartRate])
  }
}

@Suite struct StepBucketBoundaryTests {
  @Test func acceptsExactBoundaries() {
    #expect(StepBucket(startingAt: Date(timeIntervalSince1970: 1_699_999_800))?.startUnixSeconds == 1_699_999_800)
    #expect(StepBucket(startingAt: Date(timeIntervalSince1970: 0))?.startUnixSeconds == 0)
    #expect(StepBucket(startingAt: Date(timeIntervalSince1970: -300))?.startUnixSeconds == -300)
  }

  @Test func toleratesSubMillisecondDrift() {
    #expect(StepBucket(startingAt: Date(timeIntervalSince1970: 1_699_999_800.0004)) != nil)
    #expect(StepBucket(startingAt: Date(timeIntervalSince1970: 1_699_999_799.9996)) != nil)
  }

  @Test(arguments: [1_699_999_801.0, 1_699_999_800.5, 1_699_999_800.002, 1_699_999_950, -150])
  func rejectsOffBoundaryStarts(seconds: TimeInterval) {
    #expect(StepBucket(startingAt: Date(timeIntervalSince1970: seconds)) == nil)
  }

  @Test func boundaryMatchesContainingBucket() {
    let date = Date(timeIntervalSince1970: 1_730_611_800)
    #expect(StepBucket(startingAt: date) == StepBucket(containing: date))
  }
}
