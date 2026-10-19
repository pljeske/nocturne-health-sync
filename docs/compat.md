# Nocturne compatibility

Record here which Nocturne version the client was verified against, and any deviation from the
contract in `CLAUDE.md`.

| Date | Nocturne release | Commit | Verified by | Notes |
| --- | --- | --- | --- | --- |
| 2026-10-15 | v0.2.3 (contract read from `main`) | – | reading the source only | No integration run yet. |
| 2026-10-15 | v0.2.7 (contract read from `main`) | 806cb31 | reading the source only | Step 2 client: request models, 1000-record limit, empty array → 400, 503 setup-gate body re-checked against `V4BulkValidation.cs` and `TenantSetupMiddleware.cs`. No integration run yet. |
| 2026-10-15 | v0.2.7 (contract read from `main`) | 806cb31 | reading the source only | Step 3 auth: `OAuthController` (register/authorize/token/revoke), `PkceValidator`, `OAuthTokenService` refresh rotation and `invalid_grant` cases. No integration run yet. |
| 2026-10-16 | v0.2.7 (contract read from `main`) | 806cb31 | reading the source only | Step 10: integration suite written against `HealthSeriesControllerBase` (ranged GET `from`/`to`/`count`, max 100 000), read models (`data_source`, `enteredBy`), dev-only `seed-tenant` and `auth/login` DTOs. Smoke-run against a local stub only; **not yet run against a real Nocturne**. |
| 2026-10-19 | v0.2.7 (contract read from `main`) | c28fdd6 | reading the source only | Step 11 sleep: `SleepController` (`POST api/v4/sleep/sessions/bulk`, max 100, 201), `SleepSession`/`SleepStageInterval`/`SleepEnums` models (string enums), `SleepSessionRepository.UpsertSessionAsync` dedup by `(tenant, source, original_id)` with `ux_sleep_sessions_tenant_source_original`, `Scope.SleepReadWrite`, `OAuthController.Authorize` scope checks (no per-client scope). Deviation between v0.2.7 and `main`: the bulk endpoint on v0.2.7 answers 409 for a whole request that contains a user-deleted session; `main` drops that session silently. Heart rate/step contract unchanged since 806cb31. **Not yet run against a real Nocturne.** |
