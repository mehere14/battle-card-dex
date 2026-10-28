# Production public catalog publication

Verified October 16, 2026 (America/Toronto).

The loader promoted the published Development public catalog into Production for `iCloud.com.example.BattleCardDex`. Separate server-to-server credentials were used for each environment. Private key files remain outside the repository; local credential configuration is gitignored.

| Record type | Verified records |
| --- | ---: |
| CreatureCatalogRecord | 1,025 |
| EvolutionCatalogRecord | 541 |
| CardCatalogRecord | 17,181 |
| CardSetIndexRecord | 173 |
| PackArtworkRecord | 137 |
| CatalogManifest | 1 |
| Total | 19,058 |

The read-only plan validated source payload hashes, manifest counts, and creature relationships. Publication preserved source record IDs, payloads, timestamps, and query fields. Each saved batch was checked against Production hashes. The upload resumed after an interruption: the final pass skipped 3,200 matching records, wrote and verified 15,858, and published the manifest last. No records were deleted and no private library database was accessed.

Independent Production lookups confirmed:

- Duraludon `me2-74` (collector number 74, set `me2`). A Production name query for `duraludon` returned this exact card.
- Set index `catalog-card-set-index-me2`, containing 110 card entries, including Duraludon.
- Previously missing sample records for Togepi `mcd16-9` and Croconaw `me2pt5-42`.
- `catalog-manifest-v1`, advertising 17,181 cards.

The loader's 38 host-only tests passed, including read-only isolation, separate credential handling, source ID lookups, corrupted-payload and dangling-reference rejection, bounded concurrency, resumability, and manifest ordering. The signed Release app built successfully and was installed on the connected physical iPad. Server-side verification does not replace a live camera scan on that device.

Successful local plan/publication reports are in `.loader-state/production-plan.json` and `.loader-state/production-publish.json`. To update the catalog later, run `promote-production --dry-run`, review the plan, and then `promote-production --apply`. Source records must first be published to Development using the ordinary sync commands.
