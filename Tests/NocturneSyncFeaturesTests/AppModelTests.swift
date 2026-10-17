import Foundation
import NocturneSyncCore
import Testing

@testable import NocturneSyncFeatures

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@MainActor
@Suite struct AppModelLaunchTests {
  @Test func startsSignedOutWithTheSavedAddressPrefilled() {
    let harness = ModelHarness()
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
    #expect(harness.model.instanceText == "https://alice.nocturne.example")
    #expect(harness.instancesMade.isEmpty)
  }

  @Test func launchWithAValidSignInRegistersHealthDeliveryAndLoadsStatus() async {
    let harness = ModelHarness()
    await harness.sync.setState(SyncState(heartRate: .init(lastSuccessfulSync: Fixtures.now, uploadedCount: 5)))

    await harness.model.launch()

    #expect(harness.model.phase == .signedIn(instance: Fixtures.instance))
    #expect(await harness.health.deliveryEnabled == [.heartRate, .stepCount])
    #expect(await harness.health.observedTypes == [.heartRate, .stepCount])
    #expect(harness.model.statuses.first { $0.type == .heartRate }?.uploadedCount == 5)
    // A launch alone does not sync: background launches are for delivery, foreground calls becameActive.
    #expect(await harness.sync.reasons.isEmpty)
  }

  @Test func launchWithoutSignInRegistersNothing() async {
    let harness = ModelHarness(signedIn: false)
    await harness.model.launch()
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
    #expect(await harness.health.deliveryEnabled.isEmpty)
  }

  @Test func launchWithoutAnInstanceDoesNothing() async {
    let harness = ModelHarness(savedInstance: nil)
    await harness.model.launch()
    #expect(harness.model.phase == .signedOut(instance: nil))
    #expect(harness.instancesMade.isEmpty)
  }

  @Test func observersAreRegisteredOncePerLaunch() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.launch()
    #expect(await harness.health.deliveryEnabled == [.heartRate, .stepCount])
  }

  @Test func becomingActiveAsksForHealthAccessAndSyncsEverything() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.becameActive()
    #expect(await harness.health.authorizationRequests == 1)
    #expect(await harness.sync.reasons == [.launch])
    #expect(harness.scheduler.scheduled == [Fixtures.now.addingTimeInterval(3600)])
  }

  @Test func healthAccessIsRequestedOncePerProcess() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.becameActive()
    await harness.model.becameActive()
    await harness.model.becameActive()
    #expect(await harness.health.authorizationRequests == 1)
    #expect(await harness.sync.reasons.count == 3)
  }

  @Test func becomingActiveWhileSignedOutDoesNothing() async {
    let harness = ModelHarness(signedIn: false)
    await harness.model.launch()
    await harness.model.becameActive()
    #expect(await harness.health.authorizationRequests == 0)
    #expect(await harness.sync.reasons.isEmpty)
  }
}

@MainActor
@Suite struct AppModelSignInTests {
  @Test func successfulSignInSavesTheInstanceAndStartsSyncing() async {
    let harness = ModelHarness(savedInstance: nil, signedIn: false)
    let authenticator = FakeAuthenticator()
    harness.model.instanceText = "  Alice.Nocturne.Example/ "

    await harness.model.signIn(using: authenticator)

    #expect(harness.model.phase == .signedIn(instance: Fixtures.instance))
    #expect(harness.settings.instanceURL() == Fixtures.instance)
    #expect(harness.model.instanceText == "https://alice.nocturne.example")
    #expect(harness.instancesMade == [Fixtures.instance])
    #expect(authenticator.requests.map(\.scheme) == [Fixtures.scheme])
    #expect(authenticator.requests.first?.url == Fixtures.pending().url)
    #expect(
      await harness.auth.calls == [
        .begin, .complete(URL(string: "com.pljeske.NocturneSync://oauth/callback?code=c0de&state=st4te")!),
      ])
    #expect(await harness.health.authorizationRequests == 1)
    #expect(await harness.health.observedTypes == [.heartRate, .stepCount])
    #expect(await harness.sync.reasons == [.launch])
    #expect(!harness.model.isSigningIn)
    #expect(harness.model.message == nil)
  }

  @Test func invalidAddressIsRejectedBeforeAnyNetwork() async {
    let harness = ModelHarness(savedInstance: nil, signedIn: false)
    harness.model.instanceText = "http://nocturne.example"
    await harness.model.signIn(using: FakeAuthenticator())
    #expect(harness.model.message?.text == InstanceURLError.insecure.message)
    #expect(harness.instancesMade.isEmpty)
  }

  @Test func cancellingTheSheetIsSilent() async {
    let harness = ModelHarness(savedInstance: Fixtures.instance, signedIn: false)
    let authenticator = FakeAuthenticator()
    authenticator.error = .cancelled
    await harness.model.signIn(using: authenticator)
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
    #expect(harness.model.message == nil)
    #expect(await harness.auth.calls == [.begin])
    #expect(harness.settings.instanceURL() == Fixtures.instance)
  }

  @Test func registrationRateLimitHasAnActionableMessage() async {
    let harness = ModelHarness(savedInstance: Fixtures.instance, signedIn: false)
    await harness.auth.failBegin(with: .registrationFailed(.rateLimited(retryAfter: nil)))
    await harness.model.signIn(using: FakeAuthenticator())
    #expect(harness.model.message?.text == "Nocturne is limiting app registrations. Try again in an hour.")
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
  }

  @Test func deniedConsentIsReported() async {
    let harness = ModelHarness(savedInstance: Fixtures.instance, signedIn: false)
    await harness.auth.failComplete(with: .authorizationDenied(code: "access_denied", description: nil))
    await harness.model.signIn(using: FakeAuthenticator())
    #expect(harness.model.message?.text == "Access was declined in Nocturne.")
    #expect(await harness.sync.reasons.isEmpty)
  }

  @Test func signingInToAnotherInstanceBuildsSeparateServices() async {
    let harness = ModelHarness(savedInstance: Fixtures.instance, signedIn: false)
    await harness.model.launch()
    harness.model.instanceText = "https://bob.nocturne.example"
    await harness.model.signIn(using: FakeAuthenticator())
    #expect(harness.instancesMade == [Fixtures.instance, URL(string: "https://bob.nocturne.example")!])
    #expect(harness.settings.instanceURL() == URL(string: "https://bob.nocturne.example")!)
  }

  @Test func signOutCancelsSyncRevokesAndKeepsTheAddress() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.signOut()
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
    #expect(harness.model.statuses.isEmpty)
    #expect(await harness.sync.cancelCount == 1)
    #expect(await harness.auth.calls == [.signOut])
    #expect(harness.settings.instanceURL() == Fixtures.instance)
  }

  @Test func signOutIsLocalEvenWhenRevokeFails() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.auth.failSignOut(with: .revokeFailed(.transport(URLError(.notConnectedToInternet))))
    await harness.model.signOut()
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
    #expect(harness.model.message?.text.hasPrefix("Signed out on this device") == true)
  }
}

@MainActor
@Suite struct AppModelSyncTests {
  @Test func healthObserverSyncsOnlyItsType() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.health.simulateChange(of: .stepCount)
    #expect(await harness.sync.reasons == [.healthChange(.stepCount)])
  }

  @Test func observerAfterSignOutDoesNotSync() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.signOut()
    await harness.health.simulateChange(of: .heartRate)
    #expect(await harness.sync.reasons.isEmpty)
  }

  @Test func syncNowRunsAllTypesAndRefreshesStatus() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.sync.setState(SyncState(stepCount: .init(lastSuccessfulSync: Fixtures.now, uploadedCount: 9)))
    await harness.model.syncNow()
    #expect(await harness.sync.reasons == [.manual])
    #expect(harness.model.statuses.first { $0.type == .stepCount }?.uploadedCount == 9)
  }

  @Test func isSyncingCoversTheRun() async throws {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.sync.holdNextRun()
    let model = harness.model
    let run = Task { await model.syncNow() }
    for _ in 0..<1000 where !(await harness.sync.isHolding) { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.isSyncing)
    await harness.sync.release()
    await run.value
    #expect(!model.isSyncing)
  }

  @Test func lostGrantSignsOutWithAMessage() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.sync.enqueue(Fixtures.report([.heartRate: .failed(.upload(.auth(.signedOut)))]))
    await harness.model.syncNow()
    #expect(harness.model.phase == .signedOut(instance: Fixtures.instance))
    #expect(harness.model.message?.text == "Signed out. Sign in again to resume syncing.")
  }

  @Test func backgroundRefreshReportsCompletionAndReschedules() async {
    let harness = ModelHarness()
    await harness.model.launch()
    #expect(await harness.model.performBackgroundRefresh())
    await harness.sync.enqueue(Fixtures.report([.heartRate: .completed, .stepCount: .deferred]))
    #expect(await !harness.model.performBackgroundRefresh())
    #expect(await harness.sync.reasons == [.backgroundRefresh, .backgroundRefresh])
    #expect(harness.scheduler.scheduled.count == 2)
  }

  @Test func backgroundRefreshWhileSignedOutIsAFailureWithoutWork() async {
    let harness = ModelHarness(signedIn: false)
    await harness.model.launch()
    #expect(await !harness.model.performBackgroundRefresh())
    #expect(await harness.sync.reasons.isEmpty)
  }

  @Test func expirationCancelsTheRun() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.model.cancelSync()
    #expect(await harness.sync.cancelCount == 1)
  }

  @Test func healthAccessFailureIsShown() async {
    let harness = ModelHarness()
    await harness.model.launch()
    await harness.health.failAuthorization(with: .healthDataUnavailable)
    await harness.model.becameActive()
    #expect(harness.model.message?.text == "Health data is not available on this device.")
  }
}
