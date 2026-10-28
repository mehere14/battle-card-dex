> Current shutter behavior: a single manual shutter calls the system camera’s `takePicture()` with standard review controls hidden, then immediately starts the existing OCR/recognition flow when capture finishes. There is no Use Photo confirmation and no automatic capture.

> Current capture flow (October 16): the scanner uses Apple’s `UIImagePickerController` rear photo camera with its native shutter, Retake, and Use Photo controls. Automatic capture and the custom camera session have been removed. The accepted full-resolution photo runs through the existing perspective correction and OCR passes; if no rectangle is detected, OCR uses the full photo. The displayed photo is no longer deliberately blurred. Earlier custom-camera implementation notes below are historical. This system interface does not promise the identical processing pipeline of the standalone Camera app. Physical-device sharpness verification remains required.

# Debug card scanner

Open **Scan Card** on the home screen in a Debug build on a physical iPhone or iPad. A fixed, dashed card guide shows where to position the card. The rear camera outlines a detected card-shaped rectangle centred inside the guide and automatically triggers a still-photo capture after it stays steady for 0.85 seconds. The manual shutter can trigger capture without rectangle detection. A mint line sweeps downward every 2.6 seconds while scanning or processing (static with Reduce Motion).

Still photos are captured through AVCapturePhotoOutput. The camera captures one quality-prioritized JPEG with flash off after autofocus and exposure remain settled for 0.35 seconds. A three-second timeout asks the user to adjust distance or lighting. Triple or dual-wide virtual cameras are preferred when available to allow close-focus lens switching; other devices use the rear wide camera. Each exposure is perspective-corrected when a rectangle is detected, or cropped to the fixed guide otherwise. On-device whole-card OCR runs on each exposure, selecting the text with strongest mean confidence plus confidence in a footer fraction. Only that selected text is sent to Gemini. Apple Vision reads its text on a serial background queue; only the OCR text goes to Gemini `gemini-flash-lite-latest` through Firebase AI Logic. The raw OCR and structured JSON appear in disclosure groups and the Xcode console. No Gemini API key is embedded. Firebase's client configuration contains a Firebase project API key, which is distinct from a Gemini secret.

## Firebase setup

1. Register the iOS app with bundle ID `com.example.BattleCardDex` in the intended Firebase project. Put its downloaded `GoogleService-Info.plist` in `BattleCardDex/` with app target membership. Initialization is deferred until a debug scan; missing or mismatched configuration produces an actionable error while retaining OCR.
2. Enable Firebase AI Logic with the Gemini Developer API provider and ensure the selected model is available to the project.
3. Debug and Release use App Attest on supported physical devices, with DeviceCheck for unsupported devices. Register the providers for this Apple app in Firebase App Check and enable enforcement for Firebase AI Logic. The debug provider is available only when explicitly enabled with `BATTLE_CARD_DEX_USE_APP_CHECK_DEBUG_PROVIDER=1`; that override requires a registered debug token.
4. Keep debug tokens private. Firebase 12.5.0 is pinned for compatibility with the installed Xcode toolchain. No analytics dependency is added.

References: [AI Logic setup](https://firebase.google.com/docs/ai-logic/get-started?platform=ios), [App Check](https://firebase.google.com/docs/ai-logic/app-check), [structured output](https://firebase.google.com/docs/ai-logic/generate-structured-output).

## Matching and presentation

The scanner queries the configured public CloudKit database by normalized name, reads all query pages, validates card records using the existing codec, then matches collector number with leading-zero normalization. Debug set metadata derived from the existing raw loader cache provides printed totals and set codes for 173 sets. Printed totals are not inferred from catalog card counts. Missing set metadata cannot constrain a match. A printed set code is not used as a provider set ID.

One match opens the same `InteractiveCardViewer` used by the creature detail's card panel. Multiple matches require choosing artwork; no match retains diagnostics. The public catalog is never mutated and scans are not added to an ownership collection in this experiment. Scan another card resets the capture latch. Dismissal cancels outstanding work, and leaving the foreground stops the camera.

## Physical-device acceptance

- Test permission grant, denial, and unavailable camera.
- Scan flat cards on contrasting backgrounds, with sleeves, glare, tilt, portrait and landscape orientations. Verify bounds track the card and a moving card does not capture.
- Verify automatic capture, footer OCR, JSON console logging, successful CloudKit lookup, and viewer dismissal.
- Test missing Firebase config, unregistered debug token, network failure, unreadable footer, multiple printings, missing catalog cards, and repeated scans.
- Verify Reduce Motion, background/foreground transitions, cancellation, and absence of scanner entry points and camera permission text in Release.

Rectangle detection is geometric rather than a trained card classifier. A similarly shaped object can trigger OCR. Video is used only for rectangle detection. Still-photo resolution is chosen from supported dimensions, preferring the largest up to approximately 12 MP for OCR latency. Single-photo capture avoids bright bracket exposures that can introduce motion blur. Focus settlement does not guarantee sharpness when a card is inside the lens’s minimum focus distance; physical-device testing is required. Languages and finish variants require further catalog support. Structured output is evidence for human verification, not a guarantee of identification accuracy.

## Verification on October 7, 2026

- Final generic iOS Debug build passed with `CODE_SIGNING_ALLOWED=NO` and `EXCLUDED_SOURCE_FILE_NAMES=*.metal`. The latter is a validation-only override: this Xcode installation lacks the Metal compiler required by the existing card shaders. No shader or project exclusion was changed.
- Four matching cases passed when executed directly with the Swift toolchain, using the actual identity, set metadata, domain types, and test bodies: leading zeros/name distinctions, set denominator/code disambiguation, null fields, and letter prefixes.
- The iOS simulator compiled the app and test bundles, but the test runner stalled before reporting results and was stopped. No simulator test pass is claimed.
- Release verification was blocked by the existing `Validate Neutral Terminology` script's findings in old files, generated assets, and existing app source. Scanner source, entry point, Gemini code, and generated scanner metadata use `#if DEBUG`; camera permission text is configured only for Debug.
- `git diff --check` passed. Live Firebase/App Check, CloudKit recognition, and physical camera acceptance remain unverified pending the project's Firebase configuration and a device trial.

## Local Firebase configuration

The supplied Firebase configuration is installed at `BattleCardDex/GoogleService-Info.plist`; its bundle ID matches `com.example.BattleCardDex`. Normal Debug launches use real attestation, including from the Home Screen. A private local Debug scheme can opt into the debug provider with `BATTLE_CARD_DEX_USE_APP_CHECK_DEBUG_PROVIDER=1` and optionally supply a registered `FIRAAppCheckDebugToken`. Such schemes must stay gitignored; tokens must not be in shared schemes or app source. App Attest provider registration is required for normal use. Under App Check → APIs, use baseline enforcement for Firebase AI Logic and leave replay protection disabled because the SDK call does not request limited-use tokens.

## App Check troubleshooting

The scanner verifies an App Check token before calling Gemini (now reusing valid cached tokens) and logs whether its debug secret comes from the Xcode launch environment or the device-generated token. The supplied private scheme token was successfully exchanged with Firebase App Check on October 7, 2026; the issued authentication token was neither printed nor stored. If the running app still fails, stop it and launch from Xcode using **Card Scanner Local**. Launching a previously installed app from its Home Screen does not supply the scheme environment; register its device-generated token from Firebase console logs instead. The UI retains OCR and explains which registration path to check.

## October 8 capture changes

Added an always-available manual shutter, a dashed 63:88 card guide, and automatic/manual still-photo exposure bracketing. Repeated shutter taps are ignored during a capture. All image processing remains on device; Gemini receives only the selected OCR text. Rectangle detector thresholds remain unchanged. A dedicated footer OCR pass was subsequently added: see the footer OCR section below.

The October 8 capture changes passed the generic iOS Debug build with the same validation-only Metal shader exclusion, and the camera source passed a separate Swift type check against the installed iOS SDK. `git diff --check` passed. Physical-device acceptance for bracket support, moving cards, glare, shutter retries, photo orientation, and guide alignment remains pending.

## Landscape alignment and lookup requirements

The scanner now uses AVCaptureDevice.RotationCoordinator after the camera session starts, observing preview and capture rotation independently rather than applying a hard-coded angle during layout before connections exist. Landscape places the camera beside shutter/status controls and sizes the viewport to the available height. Verify both landscape directions, portrait transitions, guide alignment, and manual guide cropping on a physical device. Generic iOS Debug compilation passed with the existing Metal validation override; whitespace checks passed.

For the current catalog, `setIdentifier` plus `collectorNumber` identifies a printing. Printed set codes need mapping to the provider set ID. The denominator (`printedTotal`) is useful evidence but is not a unique set identifier. The current debug lookup still requires name plus collector number because it queries CloudKit by normalized name; cached set codes and denominators narrow those results. Name is not an inherent requirement of a future set-and-number lookup. This orientation change leaves recognition and matching logic unchanged.

## Separate footer OCR

Each bracketed exposure now receives three local OCR readings: the whole card, the original bottom 22% strip, and a grayscale/high-contrast version of that strip. The strip is enlarged up to 3× when narrower than 2400 pixels; it is never downsampled. Enlarging does not recreate lost detail. Footer OCR uses accurate recognition, a smaller text-height threshold, and no language correction. Raw text retains prefixes and zeros.

Exposure selection prioritizes confidence in a collector-number fraction read from either footer variant, alongside whole-card confidence. The selected exposure's three readings are labelled `WHOLE_CARD_OCR`, `FOOTER_ORIGINAL_OCR`, and `FOOTER_HIGH_CONTRAST_OCR` in the UI, console, and text-only Gemini input. Gemini is instructed to use whole-card text for the name and footer text for numbers/set codes, treat repeated readings as corroboration, preserve prefixes/zeros, and return null for unresolved conflicts. No images leave the device. Footer variant errors retain other readable results.

Verify original and contrast readings with yellow, silver, and holographic cards, including glare, letter-prefixed numbers, and manual guide crops. The bottom-strip assumption expects an upright card inside the guide.

## Kakuna matching and latency diagnostics

The reported Kakuna is cached as `me4-2`, Chaos Rising, collector number `2`, printed total `86`, set code `CRI`. Its screenshot response used `CR`; strict matching correctly normalized `002` and `086` but rejected the truncated code. Identity extraction now reconciles absent or truncated set codes against uniquely observed known codes on OCR lines, optionally followed by a language marker and constrained by the printed total. It does not substitute a conflicting full code or resolve ambiguous observations. Raw Gemini JSON remains visible, with an explicit correction note when the catalog identity differs.

App Check now reuses valid cached tokens instead of forcing a network refresh on every scan. Logs separately time local OCR, App Check, the Gemini request, and CloudKit lookup. Gemini still receives one text-only request with the same model alias, temperature, and output limit. Footer OCR increased both local work (up to nine OCR passes across three exposures) and the size/instructions of the Gemini input. Actual model latency changes require the new timing logs; no live speed improvement is claimed.

## October 16 camera sharpness correction

Capture now configures continuous autofocus and autoexposure at the guide center, prefers near focus when supported, and waits for focus/exposure to settle for both manual and automatic capture. A single quality-prioritized still replaces exposure bracketing. The OCR passes, Gemini prompt, matching, and catalog/library behavior are unchanged. Verify close and farther card distances, low light, both capture modes, rotation, and devices without macro support on physical hardware.
