# Integration tests

`Tests/NocturneSyncIntegrationTests` uploads synthetic records to a development Nocturne and reads
them back. It checks the contract that unit tests can only assume:

- the request bodies are accepted;
- re-uploading the same `syncIdentifier` (or, for sleep, `originalId`) updates the row in place;
- more than one request's worth of records is chunked and stored;
- an invalid token comes back as `unauthorized`.

Every test is skipped unless `NOCTURNE_INTEGRATION_URL` is set, so `swift test` stays offline by
default. Never point it at an instance holding real data.

## Run

1. Start Nocturne in Development from a checkout (`aspire start`; the API listens on
   `http://localhost:1610`). The dev-only endpoints below exist only in Development builds.
2. Seed a tenant. The response carries the tenant `url` and an `accessToken`:

   ```sh
   curl -s -X POST http://localhost:1610/api/v4/dev-only/admin/seed-tenant \
     -H 'Content-Type: application/json' \
     -d '{"slug":"nsync","displayName":"NocturneSync tests","ownerUsername":"tester"}'
   ```

3. Run the suite against that tenant:

   ```sh
   NOCTURNE_INTEGRATION_URL=<url from the response> \
   NOCTURNE_INTEGRATION_TOKEN=<accessToken from the response> \
   swift test --filter NocturneSyncIntegrationTests
   ```

   Without `NOCTURNE_INTEGRATION_TOKEN`, the suite fetches a token from
   `GET /api/v4/dev-only/auth/login?format=json`. That works when the URL's host names the tenant,
   or when the instance has a single tenant. Otherwise set `NOCTURNE_INTEGRATION_TENANT=<slug>`.

Record the Nocturne commit and release you ran against in `docs/compat.md`.
