import NocturneSyncCore
import NocturneSyncFeatures
import SwiftUI

/// What was synced and when. Shows counts and times only, never health values (not a medical device).
struct StatusView: View {
  let model: AppModel
  let instance: URL

  var body: some View {
    List {
      Section {
        LabeledContent("Instance", value: instance.host() ?? instance.absoluteString)
      }
      if !model.activity.isEmpty {
        Section("Syncing now") {
          ForEach(model.activity, id: \.type) { progress in
            SyncActivityRow(progress: progress)
          }
        }
      }
      ForEach(model.statuses) { status in
        Section(status.title) {
          DataTypeStatusRows(status: status)
        }
      }
      Section {
        Button {
          Task { await model.syncNow() }
        } label: {
          HStack {
            Text("Sync now")
            if model.isSyncing {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(model.isSyncing)
        Button("Sign out", role: .destructive) {
          Task { await model.signOut() }
        }
      } footer: {
        Text(
          "iOS decides when background syncs run, about hourly when there is new data. Sync now also re-sends the last day of steps and the last three days of sleep."
        )
      }
    }
    .navigationTitle("NocturneSync")
    .refreshable { await model.syncNow() }
    .task { await model.refreshStatus() }
  }
}

/// One data type's live progress. Steps and sleep have a real fraction; heart rate shows a spinner,
/// because HealthKit returns samples in insertion order and the amount left is unknown.
private struct SyncActivityRow: View {
  let progress: SyncProgress

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(progress.type.title)
        Spacer()
        Text("\(progress.uploaded.formatted()) uploaded")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      if let fraction = progress.fractionCompleted {
        ProgressView(value: fraction)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let reached = progress.reached {
        Text(reachedText(reached))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func reachedText(_ date: Date) -> String {
    let formatted = date.formatted(date: .abbreviated, time: .shortened)
    return progress.fractionCompleted == nil
      ? "Newest record so far: \(formatted)" : "History uploaded up to \(formatted)"
  }
}

private struct DataTypeStatusRows: View {
  let status: DataTypeStatus

  var body: some View {
    LabeledContent("Last sync") {
      if let date = status.lastSuccessfulSync {
        Text(date.formatted(.relative(presentation: .named)))
      } else {
        Text("Never")
      }
    }
    LabeledContent("Records uploaded", value: status.uploadedCount.formatted())
    LabeledContent("History", value: backfillText)
    if status.noDataSeen {
      Text(
        "No data seen yet. Health may have none, or read access may be off in Settings › Health › Data Access & Devices."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
    if let error = status.lastError {
      VStack(alignment: .leading, spacing: 4) {
        Label(error.message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text(error.occurredAt.formatted(.relative(presentation: .named)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var backfillText: String {
    switch status.backfill {
    case .notStarted: "Not started"
    case .inProgress(through: let date?): "Uploaded back to \(date.formatted(date: .abbreviated, time: .omitted))"
    case .inProgress(through: nil): "Catching up"
    case .complete: "Complete"
    }
  }
}
