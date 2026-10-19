import Foundation

/// The per-session vital-sign summary Nocturne's `SleepSession` carries (decision 14). Only readings
/// taken while asleep count: the start of each reading must fall in an asleep stage interval of the
/// session (`Light`, `Deep`, `Rem` or `Asleep`). In-bed and awake time are left out, because they
/// raise the averages and an iPhone in-bed band can span long stretches awake.
///
/// A session with no asleep interval (iPhone in-bed only), or no reading of a kind while asleep, has
/// nil for that field. Values are rounded to one decimal, as the server stores floats and shows one
/// decimal; the rounding also keeps the content digest stable against floating-point noise.
public struct SleepBiometrics: Sendable, Hashable {
  /// bpm.
  public var averageHeartRate: Double?
  /// bpm.
  public var minimumHeartRate: Double?
  /// SDNN, ms.
  public var averageHRV: Double?
  /// breaths/min.
  public var averageRespiratoryRate: Double?
  /// Percent, 0...100.
  public var averageOxygenSaturation: Double?

  public init(
    averageHeartRate: Double? = nil, minimumHeartRate: Double? = nil, averageHRV: Double? = nil,
    averageRespiratoryRate: Double? = nil, averageOxygenSaturation: Double? = nil
  ) {
    self.averageHeartRate = averageHeartRate
    self.minimumHeartRate = minimumHeartRate
    self.averageHRV = averageHRV
    self.averageRespiratoryRate = averageRespiratoryRate
    self.averageOxygenSaturation = averageOxygenSaturation
  }

  public var isEmpty: Bool { self == SleepBiometrics() }

  /// Summarises `samples` over the asleep intervals of `stages`. Readings that cannot be valid (not
  /// finite, negative, SpO2 above 100 %) are skipped and logged, never fatal.
  public static func summarize(_ samples: [BiometricSample], stages: [SleepSessionRecord.StageInterval])
    -> SleepBiometrics
  {
    let asleep = stages.filter(\.stage.isAsleep)
    guard !asleep.isEmpty else { return SleepBiometrics() }
    var values: [BiometricSample.Kind: [Double]] = [:]
    for sample in samples where asleep.contains(where: { $0.start <= sample.date && sample.date < $0.end }) {
      guard let value = normalized(sample) else {
        EngineLog.skippedSample(.sleep, .invalidBiometric(sample.value))
        continue
      }
      values[sample.kind, default: []].append(value)
    }
    let heartRates = values[.heartRate] ?? []
    return SleepBiometrics(
      averageHeartRate: average(heartRates),
      minimumHeartRate: heartRates.min().map(rounded),
      averageHRV: average(values[.heartRateVariability] ?? []),
      averageRespiratoryRate: average(values[.respiratoryRate] ?? []),
      averageOxygenSaturation: average(values[.oxygenSaturation] ?? []))
  }

  /// The value in Nocturne's unit, or nil when it cannot be a real reading.
  private static func normalized(_ sample: BiometricSample) -> Double? {
    guard sample.value.isFinite, sample.value >= 0 else { return nil }
    switch sample.kind {
    case .heartRate, .heartRateVariability, .respiratoryRate: return sample.value
    case .oxygenSaturation: return sample.value <= 1 ? sample.value * 100 : nil
    }
  }

  private static func average(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : rounded(values.reduce(0, +) / Double(values.count))
  }

  private static func rounded(_ value: Double) -> Double {
    (value * 10).rounded(.toNearestOrAwayFromZero) / 10
  }
}
