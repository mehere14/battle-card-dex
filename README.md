# Battle Card Dex

A SwiftUI iPhone/iPad app for browsing a card and creature catalog, viewing interactive card finishes, opening virtual packs, and saving scanned cards and pack pulls to a personal library.

The native app reads a shared CloudKit catalog. A separate macOS loader imports catalog data. The scanner runs camera capture and OCR on device, sends OCR text to Gemini through Firebase AI Logic, and matches the returned identity against the catalog. Personal acquisitions sync through the user's private CloudKit database.

This repository is not a self-contained backend: building the app does not populate CloudKit or configure Firebase. Forks should use their own Apple identifiers, CloudKit container, Firebase project, and credentials.

## Requirements

- A Mac with Xcode and an iOS SDK supporting the project's current **iOS/iPadOS 26.5** deployment target. Use a compatible physical device running that version or later.
- Apple Developer Program access to configure signing, iCloud/CloudKit, push notifications, and production App Attest provisioning. Accept outstanding Apple agreements before refreshing profiles.
- A connected physical iPad, preferred for this project, or iPhone. Enable Developer Mode and trust the Mac as required. **Do not run the app or iOS tests in simulators.**
- An iCloud account on the device for library saves and sync. First-time saving requires identifying that account online; subsequent saves can queue offline.
- Internet access for initial catalog/artwork loading, Gemini recognition, and cloud sync. Cached catalog content can remain available offline; scanning still requires the AI service.
- A Firebase project configured for Firebase AI Logic and App Check.
- For catalog administration: Swift 6 tooling on macOS (the loader package declares macOS 13+), a CloudKit server-to-server key, and upstream network access.
- Optional artwork tooling: Python 3.10+ and Pillow. The separate browser mockup uses Node.js/npm.

Xcode resolves Firebase via Swift Package Manager; the project pins `firebase-ios-sdk` to **12.5.0**. CocoaPods and a direct Gemini API key are not required.

## After cloning: recreate local-only files

A GitHub clone intentionally omits the original developer's Firebase configuration, signing identifiers, credentials, and device state. **Recreate these files locally using your own accounts; keep them ignored by Git.** Do not remove their ignore rules or use `git add -f` to include them.

Run setup commands from the repository root. The copy commands use `-n` to preserve any existing local configuration; edit an existing file instead of replacing it. Start with:

```sh
cp -n Configuration/Local.xcconfig.example Configuration/Local.xcconfig
chmod 600 Configuration/Local.xcconfig
```

Edit `Configuration/Local.xcconfig` before building. Use your Apple Developer team ID, an app bundle ID you own, and the CloudKit container associated with that app. `Configuration/Project.xcconfig` automatically includes this local override; no project-file edits are needed. The checked-in example identifiers do not grant access to a populated catalog.

| Ignored file or directory | When needed | How to recreate it |
| --- | --- | --- |
| `Configuration/Local.xcconfig` | Running/signing the native app on your device | Copy the checked-in `.example` file above and fill in your own identifiers. See section 1. |
| `BattleCardDex/GoogleService-Info.plist` | Live scanner recognition | Register an Apple app in your own Firebase project with the exact local bundle ID, download its configuration, and save it at this exact path. See section 5. |
| `.env.local` | Running the catalog loader against your CloudKit container | Copy `.env.example`, restrict permissions, and replace placeholders with your own settings. It is not read by the iOS app. See section 3. |
| CloudKit signing key (`.p8` or `.pem`) | Authenticated loader reads/publication | Create/register your own server-to-server key and store the private file **outside the repository**. Point `.env.local` at its absolute path. The loader rejects private keys inside the repository. |
| Private `Card Scanner Local` scheme under `xcuserdata` | Optional App Check debug-provider testing | Create a non-shared Debug scheme in Xcode; add only your own local debug-provider environment settings. Normal device scanning uses real attestation and does not require this scheme. |
| Xcode user state and provisioning profiles | Local Xcode/device setup | Xcode regenerates user state. Configure signing and let Xcode obtain profiles for your own team; do not copy another developer's state. |
| `.loader-cache/`, `.loader-state/`, `.generated/` | Catalog/artwork administration | The loader and artwork scripts regenerate these. No maintainer cache is required to build the app. See sections 3 and 4 before populating your backend. |
| `Loader/.build/`, browser `node_modules/` and `dist/` | Building their respective tools | SwiftPM recreates loader build output. In `Design Mockup/`, run `npm ci` and `npm run build` for browser output. |

For the loader, create its separate local configuration only when needed:

```sh
cp -n .env.example .env.local
chmod 600 .env.local
```

Set `BATTLE_CARD_DEX_CLOUDKIT_CONTAINER_IDENTIFIER` to the same container as `APP_CLOUDKIT_CONTAINER_IDENTIFIER`. Replace the Development key ID and private-key path. **Delete unused optional API-key and Production-credential lines**, rather than leaving placeholder values: nonempty placeholders are treated as configured credentials. Supply both Production credential fields only if using a separate destination key; otherwise omit both. Never paste secret values into terminal commands that you intend to share.

For Firebase, keep the downloaded filename exactly `GoogleService-Info.plist` (no numeric download suffix) and place it inside `BattleCardDex/`. This is an Xcode filesystem-synchronized app folder, so a local file there is bundled without adding it to Git. Confirm it appears in the app target's resources/built app. Its `BUNDLE_ID` must match `APP_BUNDLE_IDENTIFIER`; otherwise the scanner reports missing configuration. Firebase provider registration, App Check, and model access still need the setup in section 5.

Confirm the three local configuration files are ignored:

```sh
git check-ignore Configuration/Local.xcconfig BattleCardDex/GoogleService-Info.plist .env.local
python3 Scripts/check_repository_privacy.py
```

`git check-ignore` should list each supplied path. Before committing changes, run the privacy checker again with `--staged`. These commands should never print credential values.

A new clone has no on-device catalog cache or personal library. Populate your own CloudKit catalog before expecting live browsing/scanning to work; install and browse the app to build its local cache. Personal library data is created by saves and synced through the signed-in user's private CloudKit database, not restored from repository files. A scanner fixture UI test can run without live Firebase, but that does not configure a real camera-to-Gemini scan.

## What each feature needs

| Feature | Required setup |
| --- | --- |
| Creature/card browsing and search | Public CloudKit schema, populated records and manifest, query indexes; source image hosts for artwork |
| Interactive card viewer | Catalog card details/artwork and bundled rendering resources |
| Packs | Bundled generated pack list, public `PackArtworkRecord` images and `CardSetIndexRecord` card lists |
| Scanner | Camera permission, Firebase configuration, AI Logic model access, valid App Check, and matching catalog data/set metadata |
| Your Library | Local SwiftData storage, signed-in iCloud account, private `LibraryAcquisition` schema and CloudKit sync capabilities |
| Production build | Production CloudKit schema **and data**, production attestation/signing, and successful Release build |

## 1. Configure Apple identifiers and signing

1. Open `Battle Card Dex.xcodeproj` in Xcode and allow package resolution.
2. Copy `Configuration/Local.xcconfig.example` to the ignored `Configuration/Local.xcconfig` alongside the shared `Project.xcconfig`, then set:

   ```xcconfig
   APP_DEVELOPMENT_TEAM = YOUR_TEAM_ID
   APP_BUNDLE_IDENTIFIER = com.example.YourApp
   APP_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.com.example.YourApp
   ```

3. Set those local values to identifiers owned by your team. The shared configuration contains example identifiers only. App/test bundle IDs, signing, CloudKit entitlements, and the runtime container derive from these settings.
4. Associate your app identifier with that CloudKit container. Verify iCloud/CloudKit, Push Notifications, the `remote-notification` background mode, and production App Attest provisioning.
5. Regenerate provisioning profiles after capability changes; verify that the resolved signed entitlements match the intended environment.
6. Configure the loader's matching `BATTLE_CARD_DEX_CLOUDKIT_CONTAINER_IDENTIFIER` in ignored `.env.local`. Keep the downloaded `BattleCardDex/GoogleService-Info.plist` local too; it is intentionally excluded from Git.

See [repository privacy and local configuration](Documentation/repository-privacy.md) before sharing or publishing.

## 2. Create the CloudKit schema and permissions

Use CloudKit Console for your own container. Start in **Development**.

The schema reference is [`Documentation/CloudKit/development-with-library.ckdb`](Documentation/CloudKit/development-with-library.ckdb). Compare it with your container before making changes. For an existing container, export a backup first and apply an additive schema change; do not overwrite its schema blindly.

Create/verify these record types and their fields/indexes from the schema:

- `CatalogManifest`, `CreatureCatalogRecord`, `EvolutionCatalogRecord`, and `CardCatalogRecord` for the catalog.
- `CardSetIndexRecord` for per-set card lists and `PackArtworkRecord` for pack images.
- `LibraryAcquisition` for personal acquisitions in the private database. The app manages its private `UserLibrary` zone.

The catalog manifest record name is **`catalog-manifest-v1`**, with schema version `1`. Queryable/sortable fields matter: records existing without the required indexes can still cause searches or catalog queries to fail.

Keep public catalog distribution separate from private library writes. Catalog clients should have public read access without general client create/write permission; publishing belongs to the trusted loader. Library records must remain private to their owner. The checked-in Development schema includes `_icloud` create/write grants on some public types: it is a historical development snapshot, not a hardened public deployment policy. Review permissions explicitly before deployment and verify client mutation denial.

See [catalog record contracts and indexes](Documentation/public-cloudkit-catalog.md) and [library schema and sync](Documentation/your-library.md). Some older documents describe earlier milestones; current source and the complete schema reference take precedence over historical status notes.

## 3. Populate the public catalog

The iOS app does not fetch missing structured catalog data directly from upstream providers. Run the separate loader on your Mac; its credentials must never be bundled in the app.

1. Create/register a CloudKit server-to-server key for your own container. Keep its private key outside this repository.
2. Create local configuration at the repository root:

   ```sh
   cp -n .env.example .env.local
   chmod 600 .env.local
   ```

3. Edit `.env.local` with your own values:

   ```dotenv
   BATTLE_CARD_DEX_CLOUDKIT_CONTAINER_IDENTIFIER=iCloud.com.example.YourApp
   BATTLE_CARD_DEX_CARD_SOURCE_API_KEY=<optional-upstream-card-api-key>
   BATTLE_CARD_DEX_CLOUDKIT_KEY_ID=<your-cloudkit-server-key-id>
   BATTLE_CARD_DEX_CLOUDKIT_PRIVATE_KEY_PATH=/absolute/path/outside/repository/private-key.p8
   ```

   Remove unused optional API-key and Production-credential lines from the copied template; do not leave placeholders as real values. The key file must be in the signing format expected by `CloudKitRequestSigner`. Process environment values override `.env.local`; CI should inject credentials from its secret store. The loader does not read macOS Keychain.

4. From the repository root, run:

   ```sh
   swift test --package-path Loader
   swift run --package-path Loader battle-card-dex-loader dry-run --range 1...30
   swift run --package-path Loader battle-card-dex-loader seed --range 1...30
   swift run --package-path Loader battle-card-dex-loader validate
   ```

5. For broader coverage, use the resumable full sync, then create per-set card indexes:

   ```sh
   swift run --package-path Loader battle-card-dex-loader sync --all
   swift run --package-path Loader battle-card-dex-loader sync-card-indexes
   ```

`sync-card-indexes` derives indexes from cards already in CloudKit; it cannot supply cards absent from that catalog. A seed of 30 creatures is useful for setup verification but cannot support every scanned card or every pack. Full sync can be lengthy and consume provider quotas. Inspect each JSON report and exit status rather than treating an interrupted run as complete.

The loader uses `.loader-cache` for successful upstream responses and `.loader-state` for resumable progress. These are local, gitignored files. Standard catalog artwork remains source image URLs, so image availability still depends on those hosts. Ordinary sync commands target **Development/public**. The dedicated `promote-production` command copies the published Development catalog into Production/public with an explicit dry-run or apply mode.

See [loader commands, credentials, caching, and validation](Documentation/loader-cli.md).

### Cache first, then upload

There are two different local caches:

| Cache | Location | How it is populated |
| --- | --- | --- |
| Loader response cache on your Mac | `.loader-cache/<SHA256-of-request-URL>.json` | Loader upstream GET requests; stores status, headers and response body, not normalized CloudKit records |
| App catalog mirror on the device | App-managed SwiftData store | Normal app browsing/fetches read the public CloudKit catalog and persist successfully decoded documents |

To download and validate a small catalog locally before publishing, run from the repository root:

```sh
# Fetch upstream JSON into .loader-cache and build/validate a normalized batch.
# No CloudKit writes; no CloudKit server key is required for this command.
swift run --package-path Loader battle-card-dex-loader dry-run --range 1...30

# With CloudKit credentials configured, rebuild from cached responses and publish.
# Any missing upstream responses are fetched automatically.
swift run --package-path Loader battle-card-dex-loader seed --range 1...30

# Independently read Development/public CloudKit and validate the uploaded catalog.
swift run --package-path Loader battle-card-dex-loader validate
```

A bare `dry-run` without `--range` returns a report without fetching data. A ranged dry run does not export a ready-to-upload normalized catalog file: `seed`/`sync` reconstruct the normalized records from response data. They reconcile existing hashes, upload data batches, checkpoint progress in `.loader-state`, and publish the manifest last. The cache is populated during ordinary `seed`/`sync` too; a separate prefetch step is optional.

For a larger staged import, repeat the dry run with the desired inclusive range and then `sync --range LOWER...UPPER`. There is no `dry-run --all` command or strict offline-upload flag. `sync --all` performs a resumable fetch-and-upload flow rather than waiting for a separate complete download. Preserve its cache and checkpoints when resuming; do not reuse another container's publication checkpoints for a new empty container.

Successful cached GETs are reused without a freshness TTL in the current implementation. Re-running sync can therefore reuse old upstream data. To refresh a particular response, identify and remove its cache entry deliberately; to rebuild everything, plan a clean cache/checkpoint workflow rather than assuming sync forces a network refresh. Never treat `.loader-cache` as the on-device database or copy it into the app bundle.

After upload, launch the Debug app against the same Development container and browse the catalog to warm its device cache. A fresh installation needs a reachable, populated catalog; it does not import your Mac's `.loader-cache`. Release reads Production, which needs its own data publication process.

### API endpoints used by the current loader

These paths are taken from `CatalogPipeline.swift` and `CloudKitWebService.swift`. Identifiers and query values are substituted/URL-encoded at runtime.

| Service | Method and endpoint | Purpose/authentication |
| --- | --- | --- |
| PokéAPI | `GET https://pokeapi.co/api/v2/pokemon-species` | Discover species count for full sync; no API key |
| PokéAPI | `GET https://pokeapi.co/api/v2/pokemon/{id}` | Creature details |
| PokéAPI | `GET https://pokeapi.co/api/v2/pokemon-species/{id}` | Species text and evolution-chain reference |
| PokéAPI | `GET https://pokeapi.co/api/v2/pokemon/{id}/encounters` | Encounter locations |
| PokéAPI | `GET https://pokeapi.co/api/v2/evolution-chain/{chainID}` | Evolution data |
| PokéAPI | `GET https://pokeapi.co/api/v2/move/{moveID}` | Move details |
| Pokémon TCG API | `GET https://api.pokemontcg.io/v2/cards?q=nationalPokedexNumbers:{id}&page={page}&pageSize=250` | Paginated cards for a creature; optional `X-Api-Key` from local secrets |
| Apple CloudKit Web Services | `POST https://api.apple-cloudkit.com/database/1/{container}/development/public/records/lookup` | Existing record/hash lookup; signed server-to-server request |
| Apple CloudKit Web Services | `POST https://api.apple-cloudkit.com/database/1/{container}/development/public/records/query` | Queries, validation and set-index input; signed server-to-server request |
| Apple CloudKit Web Services | `POST https://api.apple-cloudkit.com/database/1/{container}/development/public/records/modify` | Trusted loader publication; signed server-to-server request |

Base URLs are code defaults in `LoaderPipelineConfiguration`, not `.env` options. The general adapter in `UpstreamClients.swift` exposes additional resource shapes, but the table above describes the concrete live catalog pipeline. Creature/card image URLs come from upstream response payloads and are fetched separately by the app; the catalog loader does not mirror those image bytes. Pack-art downloads use the community gallery linked in the artwork guide.

The iOS app uses Apple's native CloudKit SDK for public reads/private library sync and Firebase AI Logic's SDK for Gemini; it does not invoke these loader REST endpoints or use the loader's server credentials.

## 4. Supply pack artwork

Pack art is a separate pipeline from catalog JSON. If rebuilding the artwork dataset:

```sh
python3 -m venv /tmp/battle-card-dex-art-venv
source /tmp/battle-card-dex-art-venv/bin/activate
python3 -m pip install Pillow
python3 Scripts/pack_art_pipeline.py --dry-run
python3 Scripts/pack_art_pipeline.py
```

The pipeline maps source artwork to set metadata in `.loader-cache`, so populate the loader cache first. Review `.generated/booster-pack-art/qa/`, mapping warnings, and the manifest. Confirm rights to use the images before publication. Then publish the generated artwork to Development:

```sh
swift run --package-path Loader battle-card-dex-loader sync-pack-artwork
```

The app already contains `BattleCardDex/Features/GeneratedBoosterPackCatalog.swift`. Regenerate it only when intentionally updating the available pack list:

```sh
python3 Scripts/generate_booster_catalog.py
```

Every listed set needs corresponding artwork and card-index records for a complete experience. See [artwork processing and provenance](Documentation/booster-pack-art-pipeline.md).

## 5. Configure Firebase AI Logic and the scanner

1. Create your own Firebase project and register an Apple app with the **exact bundle ID** used for signing.
2. Download its `GoogleService-Info.plist` to `BattleCardDex/GoogleService-Info.plist`. Replace any local maintainer configuration and verify the file is included in the app target/bundle. Bootstrap explicitly rejects a bundle-ID mismatch or missing configuration.
3. Follow the [Firebase AI Logic setup guide](https://firebase.google.com/docs/ai-logic/get-started?platform=ios), choosing **Gemini Developer API**, matching the code's `.googleAI()` backend. Complete the API/resource setup and review quota/billing settings for your project.
4. Verify that the configured model alias, **`gemini-flash-lite-latest`**, is available to your project. It is defined in `BattleCardDex/Features/Library/CardRecognitionService.swift`; provider model availability can change.
5. Configure App Check for this Firebase Apple app as described below. Verify enforcement for Firebase AI Logic. Leave replay protection disabled for this integration: its current SDK requests do not use limited-use tokens.
6. On the device, grant camera access. If denied, re-enable it in iOS Settings for the app.

Do not add a direct Gemini secret to source or the app bundle. The scanner sends selected OCR text, not captured images, to Gemini. Debug diagnostics can display OCR and model output; keep logs containing personal content private. Recognition still needs a matching catalog card and the bundled scanner set metadata; a successful AI request alone does not guarantee a match. See [scanner details](Documentation/debug-card-scanner.md).

### Debug builds

To create a local development scheme, open **Product → Scheme → Manage Schemes** in Xcode, duplicate **Battle Card Dex**, name the copy **Card Scanner Local**, and turn off **Shared**. In **Edit Scheme → Run → Info**, select **Debug**. This selects the Development catalog; the shared scheme's Run action selects Release/Production. Keep this scheme under Xcode's ignored user data. Add environment overrides under **Run → Arguments** only when deliberately testing the debug provider below.

Debug builds use App Attest on supported physical devices and DeviceCheck otherwise, just like Release. They do not require a debug token, including when opened from the Home Screen. CloudKit still uses Development.

For deliberate authentication debugging only, set `BATTLE_CARD_DEX_USE_APP_CHECK_DEBUG_PROVIDER=1` in a private local Debug scheme and register its device-generated debug token in Firebase. An optional `FIRAAppCheckDebugToken` can supply a registered token for that Xcode launch. These environment overrides are absent when opening from the Home Screen, which uses real attestation. Never put debug tokens in shared schemes or documentation.

### Release builds

The shared **Battle Card Dex** scheme runs Release for the complete app, including scanning. It selects App Attest on supported devices and DeviceCheck otherwise, without a debug token.

- Register [App Attest](https://firebase.google.com/docs/app-check/ios/app-attest-provider) for your Apple app in Firebase App Check, using your own Apple team details.
- Optional: register [DeviceCheck](https://firebase.google.com/docs/app-check/ios/devicecheck-provider) for devices where App Attest is unsupported, supplying its Apple key privately in Firebase. App Attest-capable devices do not need this key.
- Enable the App Attest capability and refresh signing profiles. Both Debug and Release entitlements set `com.apple.developer.devicecheck.appattest-environment` to `production`, as Firebase requires even for Xcode-installed builds.
- Verify a real scan on the physical device and inspect Firebase App Check metrics. Provider registration alone does not prove that the installed app is attesting successfully.

The fallback is selected when App Attest is unsupported; an App Attest registration/network failure does not automatically retry with DeviceCheck.

## 6. Run and verify on a physical device

Select **Battle Card Dex** for normal Release/production-service use, or your local Debug scheme for Development catalog testing. Choose the connected physical iPad and run in Xcode. The main scheme’s Test action still uses Debug for fixture-based tests.

| Configuration | CloudKit | Scanner authentication | Local storage |
| --- | --- | --- | --- |
| Debug | Development public catalog and private library | App Attest / DeviceCheck (debug provider only by explicit override) | Persistent, scoped by environment/account for library |
| Release | Production public catalog and private library | App Attest / DeviceCheck | Persistent, separate library from Debug |
| Test configuration/fixtures | Fake services | Fixture-dependent; no live scan | In-memory |

A Release build does not migrate your Development library or catalog. Changing build configuration is not a database promotion step.

Verify browsing/search, image loading and card effects, opening a populated pack, scanning a known catalog card, saving it, restarting, offline queued saves, and syncing to a second physical device signed into the same iCloud account. Verify account switching does not expose the previous account's library.

For automated iOS tests, substitute the connected device's identifier:

```sh
xcodebuild -project 'Battle Card Dex.xcodeproj' \
  -scheme 'Battle Card Dex' \
  -destination 'platform=iOS,id=<PHYSICAL_DEVICE_UDID>' test
```

Ordinary tests use fakes/fixtures. The **Library Cloud Verification** scheme is an explicit live Development integration path; review its test and cleanup behavior before use. Never aim automated integration tests at Production. Older verification documents contain historical simulator commands; the current project policy requires physical devices for all app execution and iOS test runs.

Host-only checks include:

```sh
python3 Scripts/check_repository_privacy.py
python3 -m unittest discover -s Scripts -p test_repository_privacy.py
swift test --package-path Loader
python3 -m unittest Scripts/test_terminology_compliance.py
PYTHONPATH=Scripts python3 -m unittest Scripts/test_pack_art_pipeline.py
python3 Scripts/terminology_compliance.py source --root .
```

The artwork tests require Pillow.

## 7. Prepare Production separately

For installation without an Xcode provisioning-profile rebuild cycle, distribute the Release app through the App Store. An Xcode-installed Release build still has a signing expiry; TestFlight builds expire after 90 days.

Production catalog promotion uses the published Development public records as its source, including Pokémon, evolutions, cards, set indexes, pack artwork, and the manifest. It does not read or write private library databases. Keep the existing Development credentials. If Production uses a separate key, configure `BATTLE_CARD_DEX_PRODUCTION_CLOUDKIT_KEY_ID` and `BATTLE_CARD_DEX_PRODUCTION_CLOUDKIT_PRIVATE_KEY_PATH` in the owner-only `.env.local` file (or process environment). Promotion uses these only for its destination; ordinary Development commands keep using the original credentials. When omitted, promotion uses the original credentials for both environments. Private key files stay outside the repository. Deploy the catalog schema, indexes, and public read permissions before applying.

```sh
swift run --package-path Loader battle-card-dex-loader promote-production --dry-run
swift run --package-path Loader battle-card-dex-loader promote-production --apply
```

The dry run authenticates to Production, validates the complete source's payload hashes, manifest counts, and creature references, then compares Production hashes without writes. Review its record counts before applying. Applying preserves record IDs, payloads, and search fields, copies changed/missing records only, verifies each saved batch, and publishes the manifest last. It never deletes records. Rerun the command after an interruption: remote hashes determine which batches still need publication, independently of Development checkpoints. Successful reports are saved under `.loader-state/production-plan.json` or `production-publish.json`. A 401 / `AUTHENTICATION_FAILED` means the configured key cannot access Production; resolve key access in CloudKit Console before retrying.

After publication, test a real scan of Duraludon 074/094 PFL (`me2-74`) on the connected iPad using Release. Confirm missing-record logs no longer appear for the published catalog.


Deploy reviewed CloudKit schema/index changes to Production through CloudKit Console. **Schema deployment does not copy Development records.** Use the dedicated promotion command below to publish the verified Development catalog data separately. Verify the manifest, card records, set indexes, pack images, read permissions, and private library schema there before expecting the Release app to function fully.

The `Validate Neutral Terminology` and `Validate Built Product Terminology` phases are temporarily disabled with `ENABLE_TERMINOLOGY_COMPLIANCE = NO`. Their scripts and tests remain available. To reinstate Release enforcement, set that app-target build setting to `YES`; current source/generated/reference content will need cleanup to pass. See [build configuration and compliance](Documentation/build-configuration-and-compliance.md).

The latest recorded device verification is in [Your Library](Documentation/your-library.md). Production signing and live Firebase attestation were not verified by the README work. A valid configuration file or an unsigned compilation is not proof of a working signed Release installation.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Signing/profile error | Team ownership, bundle ID, container association, App Attest/push entitlements, refreshed profiles, outstanding Apple agreements |
| Empty catalog or missing cards | Correct Development/Production environment, populated records, `catalog-manifest-v1`, payload validity, query indexes, public read roles |
| Pack missing art/cards | `PackArtworkRecord`, `CardSetIndexRecord`, matching set IDs, completed artwork/index publication |
| Firebase configuration unavailable | Bundled `GoogleService-Info.plist`, correct target membership and exact bundle ID |
| App Check verification fails in Debug | Correct Firebase project/app, registered device or launch token, actual launch scheme; revoke/re-register compromised tokens |
| App Check verification fails in Release | Production App Attest entitlement, signed profile, Firebase provider registration; DeviceCheck setup on unsupported devices |
| Model request fails | AI Logic/API setup, configured model availability, network access, enforcement metrics and project quotas |
| OCR succeeds but no card matches | Catalog coverage, readable footer/collector number, bundled set metadata, ambiguous printings; inspect Debug diagnostics |
| Library save/sync fails | Signed-in iCloud account, initial online account identification, private schema, account/environment separation and pending sync state |
| Release build stops before/after compilation | Inspect the named failing phase; terminology checks run only if explicitly re-enabled |

## Repository map

- `BattleCardDex/`: shipping SwiftUI app, data layer, rendering resources, scanner and library.
- `BattleCardDexTests/`, `BattleCardDexUITests/`: unit, fixture UI, and opt-in integration tests.
- `Loader/`: independent macOS Swift package for catalog administration; not linked into the app.
- `Scripts/`: catalog/artwork generation and Release compliance tooling.
- `Documentation/`: architecture, record contracts, workflows and historical verification reports.
- `Design Mockup/`: separate Vite browser prototype, not the native app or a backend. Run `npm ci` then `npm run dev` in that directory if working on it.
- `Old Stuff/`, `Reference/`, `Plan/`: historical/reference material; not an alternative setup path.

## Open-source configuration and credentials

App Attest is compatible with publishing source: it relies on signed app identity and device attestation. Contributors should provision their own backend rather than share the maintainer's quotas or debug access.

Firebase client configuration/API keys are public identifiers, not service-account credentials; backend enforcement and access controls still matter. See the [Firebase security checklist](https://firebase.google.com/support/guides/security-checklist). This repository intentionally ignores the downloaded Firebase plist. Recreate it locally using your own Firebase project as described under “After cloning”; keep the ignore rule in place.

Never commit App Check debug tokens, `.env.local`, Apple/CloudKit private keys, signing credentials, service-account JSON, or direct Gemini secrets. Existing ignore rules cover several of these paths but do not remove secrets already committed. Review staged files and history before publication; revoke exposed credentials rather than only deleting their files. Shared schemes must contain no private launch tokens.

No root license file is currently supplied. Before distributing this as an open-source project, choose a license for code you own and review third-party code/data/artwork terms separately. Publishing source does not grant rights to redistribute card images, logos, or other third-party assets. The artwork pipeline preserves provenance for that review.
