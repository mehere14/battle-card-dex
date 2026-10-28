# Your Library

The native app now has a third home tab, **Your Library**, with **Scanned Cards** and **Pack Pulls** sharing one responsive grid. Quantities are grouped by collection source and catalog card ID. Card tiles open the existing interactive viewer. Empty states link to scanning or packs.

## Storage and sync

`LibraryRepository` owns a separate SwiftData store under Application Support/UserLibrary/<environment>.sqlite. It does not use the disposable catalog cache. Each acquisition has a UUID, schema version, source, timestamp, optional pack set ID, and complete card-detail snapshots. Scans contain one card; opened packs contain ten. One pack is one persisted event, so closing during the reveal retains every pull.

An acquisition and its pending-upload flag are committed together before UI confirmation. Repeated commits use the first timestamp and cannot increase counts. Distinct acquisition IDs merge across devices. Artwork uses existing URL/image caching; no captured photos, raw OCR, Gemini responses, or App Check tokens are persisted in the library.

The private `UserLibrary` CloudKit zone is synchronized through CKSyncEngine. The app persists engine serialization, pending acquisitions, and CloudKit system fields. It reconstructs the pending queue at startup. A duplicate immutable server event is acknowledged only if its payload matches. Local persistence failures suppress sync-token advancement; retry rebuilds the engine from its last durable state. Remote record deletions remove corresponding acquisitions; deleting the remote zone retains only unsynced events for recovery.

Store rows and sync state are scoped to the iCloud user and build environment. Account changes hide old-account data before network work. Pending acquisitions never transfer to another account. Offline saving requires an account identified earlier on this installation; first-time saving requires signing into iCloud and identifying the account. Auto-add is a device-local preference, initially off.

## Scanner

The normal scanner uses shared production-capable camera/OCR, set metadata, and recognition services. The Debug lab retains aliases to those same services. The existing OCR/Gemini prompt and matching rules are unchanged.

The camera occupies the full screen in either orientation. Its typed capture-start event triggers the loader before local OCR begins. Manual and automatic capture share the capture latch. Successful recognition presents artwork and identifying details; multiple results require artwork selection even when auto-add is enabled. Manual Add, immediate/future auto-add, saved confirmation, Scan Another, Done, permission denial, camera failure, unreadable text, no match, recognition failure, and failed-save retry are supported. Backgrounding cancels recognition and stops the camera; stale results cannot add cards.

Debug and Release use App Attest when supported, with DeviceCheck fallback. Both entitlement files declare the production App Attest environment required by Firebase. A private Debug scheme can explicitly opt into the debug provider using `BATTLE_CARD_DEX_USE_APP_CHECK_DEBUG_PROVIDER=1`. Neither path embeds a Gemini secret. Camera usage text is included in both configurations. Debug diagnostics remain in the lab and Debug console; Release suppresses scanner diagnostic logs.

## CloudKit deployment

Container: `iCloud.com.example.BattleCardDex`. Private database only; zone creation is managed by the app. The public catalog remains read-only.

Create or verify this record type in the **Development** schema:

| Record type | Field | Type | Index |
| --- | --- | --- | --- |
| LibraryAcquisition | schemaVersion | Int64 | None |
| LibraryAcquisition | source | String | Queryable |
| LibraryAcquisition | acquiredAt | Date/Time | Queryable, Sortable |
| LibraryAcquisition | packSetID | String | None |
| LibraryAcquisition | payload | Bytes | None |

Record names are acquisition UUIDs. Card IDs live in the versioned payload as strings; they are not cross-database CKRecord references. Private ownership governs access. Do not grant public read/write access to library records.

A first Development save can create fields, but indexes and Production deployment must be verified in CloudKit Console. Export and preserve the existing full schema before any CLI import; do not replace the catalog schema with a library-only fragment. A schema backup and additive import are checked in under `Documentation/CloudKit/`. The Development import was validated and applied through CloudKit Console. The user approved the full additive schema deployment, including the existing catalog/artwork types, and completed it in the console; LibraryAcquisition and its indexes were then verified in Production. No record data was copied.

After testing Development acquisition saves, duplicates, offline recovery, account changes, and a second-device sync, deploy the schema to Production using CloudKit Console. Debug and Release libraries are separate databases; this is not a data migration. No mockup/browser data is imported.

## Firebase production setup

Register the Apple app for App Attest and DeviceCheck in Firebase App Check, following the provider-specific configuration. Verify enforcement for Firebase AI Logic and the existing model alias. Configure any required DeviceCheck key privately in Firebase; do not commit it. Refresh the Release provisioning profile to include the App Attest entitlement. Apple Developer agreement acceptance is a user-managed prerequisite to updating that profile.

## Verification

Only run the app and automated device tests on the connected physical device. Do not use iPad simulators or simulator execution for this project.

`LibraryTests` exercises persistence, codec validation, grouping, acquisition idempotency, source/account isolation, disk restart, pending uploads, concurrent acquisitions, camera/scanner transitions, manual and auto-add, ambiguity, no-match, failure, cancellation, and failed-save retry. `LibraryUITests` uses explicit Debug launch fixtures for scanner outcomes, leaving live camera and CloudKit out of automated UI checks. Hosted unit-test launches also use an in-memory fixture library.

The standalone macOS core harness used the actual domain, SwiftData store, and CloudKit codec and passed persistence/idempotency/account/source/count/codec/schema/restart/recovery checks. This does not substitute for live-device camera, Firebase, or CloudKit acceptance.

The pre-existing Release terminology scripts report prohibited terminology in generated/reference files and existing app code. Preserve the gates; any isolated Release compilation check with those scripts omitted is compilation evidence only, not a production archive pass.

## Verification on October 8, 2026

- Physical iPad Air 11-inch (M3), iPadOS 27.0.1: 22 library/recognition unit tests and six library UI tests passed.
- A separate opt-in Development private CloudKit round-trip test passed on that iPad, including duplicate-ID rejection and cleanup of its isolated test zone. Use the shared **Library Cloud Verification** scheme to rerun this test; ordinary test runs skip live access.
- Final signed Debug device build passed with the full Metal shaders and was installed on the physical iPad.
- Release code and full Metal shaders compiled successfully without signing in a temporary project copy that omitted the existing terminology phases. Repository gates were not disabled. This is not a signed Release archive pass.
- Apple still rejected App Attest provisioning with the Program License Agreement/profile errors after the user reported acceptance; production signing remains unverified. Firebase production provider registration/attestation and a second-device sync remain manual acceptance items.
- The normal Debug app was launched in Your Library using the existing private scanner scheme’s App Check environment. No debug token was printed or committed.

## Scanner and header follow-up

The library heading and its Scan Cards action are above the main Pokémon/Packs/Your Library selector and appear only while Your Library is selected. The library body begins with Scanned Cards/Pack Pulls. Captured-photo backgrounds and result artwork are constrained to the viewport; failure content can scroll without extending the scanner layout. Primary scanner actions explicitly use the dark on-primary text color in both appearance modes. UI regression fixtures now include a large portrait capture, header positioning, and light/dark saved states.

The follow-up passed all nine library UI tests on the connected physical iPad. Saved-state screenshots verified dark text on the primary actions in light and dark appearances, and the large-portrait-capture failure message/retry action remained in the viewport. Unsigned Release compilation in the isolated validation project also passed.

Portrait sizing follow-up: Collected by you is now a muted subtitle below Your Library. Captured photos use aspect-fit presentation so the entire scan is visible, especially by height in landscape. The interactive viewer uses up to 82% of portrait width, constrained by available height; found-card portrait artwork is enlarged with space reserved for actions. Landscape card sizing is preserved. Four relevant physical-device UI flows passed, followed by passing explicit subtitle-position and portrait-viewer-width assertions.

## Running without scanner debug tokens

Debug also uses real attestation by default and continues to access Development CloudKit. Home Screen launches do not require a registered debug token.

Select the shared **Battle Card Dex** scheme and the connected physical iPad. Its Run action uses Release, selecting App Attest with DeviceCheck fallback without a debug token. App Attest explicitly uses the production environment required by Firebase, independent of push signing settings. Register App Attest in Firebase App Check (DeviceCheck registration is needed only for unsupported-device fallback) and refresh Apple provisioning with the App Attest capability before running. Release uses the Production CloudKit database; existing Debug library entries are not migrated. A successful live scan is required to verify this setup. Existing Release terminology gates still apply.
