# Architecture

Writekin is a native macOS app (SwiftUI + GRDB + [mlx-swift]) that reads
the writing already on your Mac, curates it into a corpus, fine-tunes a
local language model on it (QLoRA), and then drafts new text in your voice.
Everything — ingestion, training, generation — happens on-device. Nothing
is uploaded.

This page is the trailhead: what the pipeline is, which folder owns each
stage, and the invariants that keep it honest.

## The pipeline

```
 detect ──▶ ingest ──▶ passes ──▶ corpus ──▶ curate ──▶ pairs ──▶ train ──▶ promote ──▶ compose
 (found?)   (read)     (clean,     (kept     (people,   (draft/   (QLoRA    (adapter    (rewrite/
                        filter,     items)    timeline)  target)   runs)     in use)     generate)
                        dedupe,
                        label)
```

1. **Detect** — each source's adapter probes whether data exists and how
   much, feeding onboarding's source cards. No data is stored.
2. **Ingest** — each source's ingestor parses raw material (emlx files,
   SQLite stores, transcripts, documents) into `RawItem`s and batch-writes
   them through the serial `CorpusWriter` actor. Parsing is parallel
   (bounded TaskGroup workers); writing is serial. Fingerprints
   (file listings, size:mtime, high-water dates) make re-ingests
   incremental — an unchanged source costs near zero.
3. **Passes** — a shared post-ingest stage: clean (strip quotes/signatures),
   filter (drop what isn't the user's voice — see `drop_reason`s), dedupe
   (simhash), label (a small local model tags each item's mode). Items end
   up `kept` or `filtered_out`, never deleted.
4. **Curate** — People maps senders to personas and recipients to audience
   buckets; Timeline finds the AI-contamination cutoff so post-AI text
   never trains the voice.
5. **Pairs → Train** — the pair generator degrades kept items into
   draft→target pairs; `LocalTrainer` runs QLoRA on the compose model with
   checkpoints/resume; `RunAdvice` turns loss curves into plain-language
   guidance.
6. **Promote → Compose** — a succeeded run's adapter is promoted and
   Compose realizes drafts through it, with harness-side enforcement
   (word surgery, chunked rewrites, draft conventions).

## Folder map

One folder per sidebar tab, one folder per pipeline layer.

| Folder | Owns | Start reading at |
|---|---|---|
| `App/` | App shell: scenes, environment, settings window, menus, identity, localization | `WritekinApp.swift`, `AppEnvironment.swift` |
| `App/Settings/` | The Settings window, one file per tab | `SettingsView.swift` |
| `App/Locales/` | One translation file per language | `L10nTables+English.swift` |
| `Onboarding/` | Welcome tour: welcome → permission → detect → models | `OnboardingFlow.swift` |
| `Overview/` | Overview tab: stats, charts, next-step card | `OverviewView.swift` |
| `Sources/` | Sources tab: per-source rows, ingest controls | `SourcesView.swift` |
| `Browse/` | Browse tab: corpus inspector, exclude/restore | `ItemBrowser.swift` |
| `People/` | People tab: accounts/personas + audience buckets | `PeopleView.swift` |
| `Contamination/` | Timeline tab: AI-tell scan, cutoff proposals | `ContaminationModel.swift` |
| `Training/` | Train tab: datasets, runs, advice, the trainer | `TrainModel.swift`, `LocalTrainer.swift` |
| `Voice/` | Your Voice tab: style profile readout | `VoiceProfileView.swift` |
| `Compose/` | Compose tab: engine, enforcement, register controls | `ComposeEngine.swift` |
| `ML/` | Models tab + model plumbing: manifest, downloads, runtime, scout | `ModelLibrary.swift` |
| `Detection/` | Source-detection framework (protocol, runner, kinds) | `SourceAdapter.swift` |
| `Ingestion/` | Ingest framework: coordinator, writer, passes | `IngestCoordinator.swift`, `CorpusWriter.swift` |
| `Ingestion/Sources/<Source>/` | One folder per source: adapter + ingestor + its machinery | e.g. `AppleMail/`, `Messages/` |
| `Ingestion/Mail/` | Shared mail parsing (emlx/mbox/MIME) used by both mail sources | `MailMessageParser.swift` |
| `Ingestion/Passes/` | The four post-ingest passes | `FilterPass.swift` |
| `Database/` | GRDB records, migrations, generic stores | `AppDatabase.swift` |
| `Permissions/` | Full Disk Access probing/polling | `FullDiskAccessMonitor.swift` |
| `Support/` | Pure utilities: hashing, simhash, text boundaries, cancellation | — |

`WritekinTests/` mirrors these folders one-to-one.

## Adding a source

Every source is: an **adapter** (`SourceAdapter.detect()` → `SourceReport`)
plus an **ingestor** (`SourceIngestor.ingest(into:progress:)`), co-located
in `Ingestion/Sources/<Source>/`, registered in `SourceKind` (display name, symbol,
category, FDA requirement) and `AppEnvironment.defaultAdapters`. Make
re-ingest incremental from day one: fingerprint whatever lets you skip
unchanged data without opening it.

## Invariants

These are load-bearing; most were earned the hard way.

- **The model supplies voice; the harness supplies obedience.** The
  fine-tuned adapter follows instructions poorly by design (it learned a
  voice, not obedience). Anything that must be *guaranteed* — banned
  words, length, orthography — is enforced by Compose harness code
  (word surgery, chunked rewrites, `DraftConventions`), never by asking
  the model to comply. Corollary: never let the model regenerate whole
  text to fix one word; it re-rolls every token.
- **Raw values stored, localized at render.** The DB and engine speak raw
  tokens (`"email"`, `"family"`, `"Work"`, drop reasons, ingest phases).
  Display goes through `Localization` (`L10nKey`, live language switching)
  via typed values or `@MainActor` mappers — background code never
  renders text. Completeness and placeholder-parity are test-enforced.
- **The writer is serial; parsing is parallel.** `CorpusWriter` is an
  actor and the single write path. Ingestors may fan out CPU work to
  TaskGroup workers but always feed results back through it.
- **Nothing destructive without a trace.** Filtering marks items
  `filtered_out` with a `drop_reason`; exclusion marks
  `not_your_writing`; original files/mail are never touched. Reset
  Corpus is the one deliberate exception, behind a confirmation.
- **The test host is the real app.** `WritekinApp.init` short-circuits
  under XCTest, and tests must never write `UserDefaults.standard` or any
  real-path store — inject and use the same instance end-to-end. Tests
  asserting localized English pin the language for their duration.
- **Statics on `@MainActor`/View types are implicitly isolated.** Mark
  them `nonisolated` if tests call them, or make the tests `@MainActor` —
  a mismatch has crashed the suite mid-run (SIGTRAP) before.
- **`AppIdentity` is the single place the brand lives.** Renaming the app
  is editing that file (plus four project.yml lines); the FROZEN list in
  its header (bundle id, App Support folder, DB filename, settings keys,
  log subsystem) must never change or users lose their data.
- **GPL stays out of the bundle.** Messages support downloads
  `imessage-exporter` at runtime (checksum-pinned) rather than bundling
  it; `scripts/release.sh` has a guard.

## Project generation

`project.yml` + [XcodeGen]: the `.xcodeproj` is generated, never edited.
After adding/moving files: `xcodegen generate`, then build.

[mlx-swift]: https://github.com/ml-explore/mlx-swift
[XcodeGen]: https://github.com/yonaskolb/XcodeGen
