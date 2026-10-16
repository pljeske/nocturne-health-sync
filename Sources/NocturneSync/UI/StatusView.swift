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
          "iOS decides when background syncs run. Heart rate usually arrives within minutes; steps at most hourly."
        )
      }
    }
    .navigationTitle("NocturneSync")
    .refreshable { await model.syncNow() }
    .task { await model.refreshStatus() }
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
