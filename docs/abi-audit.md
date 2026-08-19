# lcms2 ABI audit

The ownership, lifetime, and error conventions of every exported symbol
family, recorded from the vendored 2.19 headers and the reference library's
observed behavior.  This is the document the boundary is written against;
it cannot be recovered from the headers alone, so it is kept current as
each family is implemented.  Cite `lcms2.h`/`lcms2_plugin.h` line numbers
from the vendored copies.

Legend — **owner**: who frees a returned pointer, and with which function.
**errors**: how failure is reported.  lcms2 has no `errno` convention and no
`setjmp` contract; the conventions in play are:

- `L` — log + null: report through the context's error logger
  (`cmsSignalError`), then return `NULL`/`FALSE`/`0`.
- `B` — bare bool/count: return `FALSE`/`0` with **no** log (query functions).
- `V` — cannot fail (void or total function).

## Global facts

- 382 exported functions: 299 `cms*`, 83 `_cms*` (plugin/internal surface).
  18 of the `_cms*` are declared in no shipped header (see
  `Sources/CLCMS2/include/lcms2_unshipped.h`); they are de-facto ABI.
- Zero exported data symbols.  All global state (context pool, alarm codes,
  adaptation state, plugin chunks) is behind functions, so its representation
  is free; its semantics are not.
- `ContextID == NULL` means the global context everywhere a `cmsContext`
  is accepted.  `cmsDupContext` snapshots the global chunks.
- Handles returned by `cmsOpenProfile*`/`cmsCreate*`/`cms*Alloc` are freed
  only by their named counterparts (`cmsCloseProfile`, `cmsDeleteTransform`,
  `cms*Free`); nothing is freed by `free(3)` in the client's hands.
- **Every entry point that takes a pointer copies what it is given.**
  Swept across the implemented families and confirmed against the
  reference: tone curves (tables and segments, including sampled
  points), matrices, CLUT tables, multi-localized strings, named-colour
  names (`strncpy`, so truncated rather than refused), dictionary names,
  values and display MLUs (`cmsMLUdup`), tag payloads (through the type
  handler's duplicate), and alarm codes. The two exceptions are
  deliberate and documented where they occur: `cmsPipelineInsertStage`
  *adopts* the stage, and `_cmsComputeInterpParams` *borrows* the table
  it is pointed at for the life of the parameters.
  A probe that frees the caller's copy only at the end cannot tell a
  copy from a kept pointer, so the probes free before they read.
- Objects are not thread-safe except: concurrent `cmsDoTransform` on one
  transform is legal (transform is immutable after creation), and the
  profile's tag directory is internally serialized (UsrMutex in the
  reference).

## Families

### Context management (6) — `cmsCreateContext`, `cmsDeleteContext`, `cmsDupContext`, `cmsGetContextUserData`, `cmsSetLogErrorHandlerTHR`, … — *implemented*

- **owner**: caller frees contexts with `cmsDeleteContext`.  UserData is
  borrowed — never freed by the library.
- **errors**: `L` (allocation failure logs to the *new* context's default
  logger, returns `NULL`).
- Deleting the context a profile/transform was created against while the
  object lives is client UB in the reference; we match (document, don't
  defend).
- `cmsCreateContext` with a non-null `Plugin` returns `NULL` and logs,
  because registration is not implemented — the reference's own failure
  path for a plugin it cannot register, rather than a context that
  silently ignored what it was given.
- **Snapshot semantics**: `cmsDupContext` copies the settings and the
  logger, and the copy stops hearing about the original.  The reference
  duplicates chunk by chunk; here the settings are one value, so copying
  it is the whole of it.  A null `NewUserData` means "keep the
  original's", which is not the same as "no user data".
- Defaults, which a fresh context starts from regardless of what the
  global context has been set to: alarm codes `{0x7F00, 0x7F00, 0x7F00,
  0…}`, adaptation state `1.0`.
- `cmsSetAdaptationState(THR)` always returns the **previous** value and
  only stores a non-negative one, so a negative argument reads the
  setting without disturbing it.  Zero is a legitimate value to store.

### Memory (6) — `_cmsMalloc`, `_cmsMallocZero`, `_cmsCalloc`, `_cmsRealloc`, `_cmsFree`, `_cmsDupMem` — *implemented*

- **owner**: caller frees with `_cmsFree`.  Blocks come from the
  platform's `malloc`, as the reference's do, so a block can cross
  between the two libraries — which plugins and clients do rely on.
- **errors**: `B` — a refused size returns `NULL` with no log.
- The size ceiling is `512 MiB` (`MAX_MEMORY_FOR_ALLOC` without
  large-file support, which is how the measured reference is built; with
  it the reference's ceiling is 2 GiB).  Zero is refused by `_cmsMalloc`
  and permitted by `_cmsRealloc`.  `_cmsCalloc` refuses a wrapped
  product three separate ways, which is what stops a malformed profile
  claiming a table that cannot exist.

### Mutexes (4) — `_cmsCreateMutex`, `_cmsDestroyMutex`, `_cmsLockMutex`, `_cmsUnlockMutex` — *implemented*

- A `NULL` from `_cmsCreateMutex` means **success**: "no locking needed",
  which is what a context with no mutex implementation reports.  The
  default has one, so ours returns a real pthread mutex.
- `_cmsLockMutex(NULL)` returns `TRUE` for the same reason.

### Error handling + plugin registration (7) — `cmsSignalError` (variadic, C shim), `cmsSetLogErrorHandler`, `cmsPlugin`, `cmsPluginTHR`, `cmsUnregisterPlugins`, …

- Logger receives `(ContextID, ErrorCode, ASCII text)`; text buffer is
  transient — valid only during the callback.
- `cmsPlugin` chains `cmsPluginBase`-prefixed structs; `ExpectedVersion`
  is checked against 2190.  *(stubbed: registration reports unsupported)*

### Profile I/O (16) — `cmsOpenProfileFromFile/Mem/Stream/IOhandler*`, `cmsSaveProfileTo*`, `cmsCloseProfile`, `cmsMD5computeID`, …

- **owner**: profile handle freed by `cmsCloseProfile` only.  `cmsSaveProfileToMem`
  writes into a caller buffer (two-call size-then-fill protocol).
- **errors**: `L`.
- `cmsOpenProfileFromMem` copies the buffer (caller may free immediately).
  `cmsOpenProfileFromFile` keeps the `FILE`/descriptor open until close.
- Custom `cmsIOHANDLER` (public layout, lcms2_plugin.h:118): **the
  profile takes ownership unconditionally.** `cmsCloseProfile` closes
  whatever handler the profile holds, however it was opened — there is
  no borrow-mode entry point, so a caller who passes a handler to
  `cmsOpenProfileFromIOhandler(2)THR` must not close it themselves.
  *(Resolved against cmsio0.c; superseded by the container section
  below, which is the current record for this family.)*

### Profile container + header (46) — `cmsOpenProfileFrom*`, `cmsCloseProfile`, `cmsCreateProfilePlaceholder`, `cmsGet/SetHeader*`, `cmsGetTagCount`, `cmsReadRawTag`, … — *implemented*

- **`_cmsICCPROFILE` carries no layout obligation.** It is declared only
  in `lcms2_internal.h`, appears in neither shipped header, and the
  upstream testbed never names it — so the profile is an ordinary Swift
  object behind an opaque handle, unlike the stage data blocks.
- **owner**: the profile owns its `cmsIOHANDLER` and closes it on
  `cmsCloseProfile`; `cmsGetProfileIOhandler` lends it without transfer.
- **errors**: `L` on open (bad signature / version / class / duplicate
  tag all log); `0`/`-1` on the accessors, which never log.
- A profile is trusted only as far as the file goes: a tag whose
  offset+size falls outside the declared size is **skipped, not
  refused**, and a declared size larger than the file is cut down to the
  file. A *duplicate* tag signature, by contrast, refuses the profile.
- Two tags over the same byte range are one tag under two names only if
  their descriptors match exactly (element count and full type list) —
  so `gXYZ` links to `rXYZ` but `cprt` sharing those bytes does not.
- `cmsGetTagSignature`/`cmsGetTagOffsetAndSize` bound with `>` rather
  than `>=`, so index == tag count reads the next table slot. Zero on a
  freshly read profile. Reproduced rather than tightened.
- The version field is **clamped into shape, not rejected**: major above
  9 becomes 9, each nibble of the second byte clamps separately, and the
  two reserved bytes are discarded. Done on the disk bytes before any
  swap, which is why the answer does not depend on endianness.
- `cmsCreateProfilePlaceholder` stamps the current time, so a new
  profile's creation date is **not** differential-testable; a date read
  out of a file is.
- **Saving is two passes**: once into a counting handler that stores
  nothing, to learn each tag's offset and the total, then for real with
  those numbers in the header. Saving must not change the profile, so
  the offsets, sizes and IO handler are snapshotted and restored — a
  second save of the same profile is byte-identical to the first.
- A **linked tag is not written twice**: it is skipped during the walk
  and then pointed at wherever the tag it links to landed. So a save
  can be smaller than the file it came from, and tags move.
- Two header fields never come from the profile: the magic is always
  `'acsp'`, and the illuminant is always D50 — the field exists but no
  profile may say anything else in it.
- `cmsSaveProfileToFile` **removes the file** if the save fails: a
  half-written profile is worse than none.
- `cmsMD5computeID` hashes the profile as saved with rendering intent,
  flags and the identifier itself zeroed first, then puts all three
  back — so computing the identifier changes only the identifier, and
  the identifier does not depend on those three fields.

### Tag access + tag types — `cmsReadTag`, `cmsWriteTag`, `cmsReadRawTag`, `cmsWriteRawTag`, `cmsLinkTag`, … — *implemented, all types*

- **`cmsReadTag`'s pointer belongs to the profile.** It is valid until
  `cmsCloseProfile`, repeated reads of one tag return the *same* pointer
  (not equal copies), and a caller who frees it has broken the profile.
  The profile therefore caches one materialized object per tag slot.
- `cmsWriteTag` **copies** what it is given, so the caller's struct
  stays the caller's; mutating it afterwards does not change the tag.
- **A failed `cmsWriteTag` still consumes a directory slot.** `_cmsNewTag`
  bumps the tag count before anything can fail, so a refused write
  leaves a slot whose name is zero. Such slots are skipped when saving.
- Deleting a tag (`cmsWriteTag(…, NULL)`) keeps the slot and zeroes its
  name — the same hole. Deleting a tag that is not there returns FALSE.
- **The "already saved as RAW" error in `cmsWriteTag` is unreachable.**
  `_cmsNewTag` runs first, and freeing the previous value is what clears
  the raw flag — so a cooked write over a raw tag always succeeds and
  the tag simply stops being raw.
- **Reading a raw-stored tag as cooked destroys it.** The refusal path
  frees the stored bytes but leaves the slot marked raw, so a following
  `cmsReadRawTag` falls through to the on-disk path; on a profile with
  no IO handler (one built by `cmsCreateProfilePlaceholder`) the
  reference dereferences NULL there. Ours returns 0. A crash is not a
  behaviour to reproduce.
- `cmsReadRawTag` has three paths: bytes still in the file (seek and
  read), bytes stored raw (copy them out), and an object held in memory
  (serialize it into a memory handler — a null buffer counts instead of
  storing, giving the size). It drops the profile lock across its
  internal `cmsReadTag`, which takes the same non-recursive lock.
- Type quirks reproduced: the chromaticity type recovers from an early
  lcms1 bug that wrote a leading zero count (recognised by the tag being
  32 bytes); colorant order is a full-width array with `0xFF` marking
  absent entries, and its stored length counts every entry that is not
  the marker, wherever it sits; plain text is handed back as a
  multi-localized container so all three text types read alike.
- **Which type a tag is written as depends on the profile version, and
  sometimes on the object.** Curves go out parametrically only on a
  version 4 profile and only when they are one non-inverted ICC-form
  segment; text moves from the flat `text`/`desc` forms to `mluc` at
  version 4; A2B/B2A follow the pipeline's own save-as-8-bits flag
  before version 4 and have one answer after. `DecideXYZtype` ignores
  both its arguments, so the broken Corbis type is readable but never
  written.
- A consequence worth stating: **a gamma loses precision on version 2
  and keeps it on version 4.** `curv` stores a single exponent in 8.8,
  so 2.2 comes back as 2.1992; `para` stores it in 15.16 and it comes
  back exact.
- `desc` (version 2) holds the same text three times — ASCII, UTF-16,
  and a dead Macintosh ScriptCode block the reference fills with zeroes
  and steps over. Its Unicode entry is filed under `cmsV2Unicode`,
  which the header spells `"\xff\xff"`: two bytes chosen not to collide
  with a real language and country. The format keeps **one** string, so
  a two-language description written to a version 2 profile reads back
  as the same string under both.
- The specification concedes `desc` is misaligned by design (the Unicode
  fields follow the ASCII text immediately), and says readers must cope.
  The reference pads the *tag* to a four-byte length rather than the
  fields.
- `mluc` stores a directory plus one pooled block of UTF-16. The
  reference keeps that pool verbatim and writes it back untouched; ours
  rebuilds it by laying the strings out in order, which reproduces what
  the reference emits (it appends each string once and refuses a
  repeated language/country pair). A hand-crafted profile whose pool has
  strings sharing bytes re-emits with the same strings but not the same
  bytes.
- **The type is decided again at save time**, from the profile's version
  and the object as it then stands — not remembered from what the tag
  was read as. Two consequences that look like bugs and are not:
  reading a v2 profile and saving it back **promotes its LUTs from
  `mft1` to `mft2`** and grows the file, because the save-as-8-bits flag
  lives on the in-memory pipeline and the reader does not restore it;
  and changing a profile's version after loading re-encodes its tags to
  match on the way out.
- `mft1`/`mft2` hold exactly four stages in one order — matrix, input
  curves, CLUT, output curves — and refuse anything else, so an
  optimized or extended pipeline cannot be written back. Both require a
  **square** grid: one node count covers every dimension, so a granular
  CLUT is refused.
- `mft1` widens each byte by replication (`0xFF` becomes `0xFFFF`, not
  `0xFF00`) and its curve tables must be exactly 256 entries — except an
  identity ramp, which it recognises by shape and writes as the
  identity. `mft2` stores its own table lengths, and a length of zero is
  a Little CMS extension meaning the stage is absent.
- `mAB`/`mBA` store five **optional** elements, each at its own offset
  from the tag base — so any may be absent and they may sit in the file
  in any order, while the pipeline they build is always A, CLUT, M,
  matrix, B one way and the reverse the other. The offsets are measured
  from eight bytes before the handler starts reading, because the type
  signature and its reserved word are already consumed.
- Exactly **four shapes** are writable either way, tried in turn; a
  pipeline matching none is refused. Unlike `mft1`/`mft2` these accept a
  **granular** grid, and their matrix always carries an offset vector
  (zeroes if the stage has none). Sample width is one or two bytes, said
  by a precision byte and chosen by the pipeline's save-as-8-bits flag.
- Curves inside these types are written as whichever curve type can hold
  them: tabulated or inverted curves fall back to `curv` even on a
  version 4 profile, since `para` cannot spell either.
- The fixed-layout structs (`meas`, `view`, `cicp`) are plain blocks the
  caller owns a copy of. `cicp` refuses a tag that is not exactly four
  bytes rather than reading a short one.
- `clrt` is a named-colour list in which each entry is a 32-byte name
  and its PCS coordinates. The name is **truncated at 32 bytes on the
  way out**, so a longer one set through the named-colour API does not
  survive a save.
- `cmsAppendNamedColor`'s prototype declares its colorant argument as
  `cmsUInt16Number[cmsMAXCHANNELS]`, which entitles the callee to read
  sixteen entries; the implementation reads only as many as the list has
  colorants. A caller passing a narrower array is correct in practice
  and wrong by the declaration, and gcc says so. Pass the full width.
- `ncl2` stores a **list-wide** prefix and suffix and a per-entry root,
  all cut to 32 bytes. The name a user sees is prefix + root + suffix,
  but `cmsNamedColorIndex` matches the **root alone** — so a caller that
  assembles the displayed name and looks it up finds nothing.
- `vcgt` is the only tag handed back as an **array of three curves**
  rather than one object. It has two on-disk flavours: three parametric
  formulas, used only when all three curves are exactly parametric type
  5, and otherwise a sampled table — **always 256 words**, so a curve of
  any other length is resampled and does not survive a save at its
  original resolution. It also carries a fixup for a depth Adobe once
  wrote wrongly, recognised by the tag's own length.
- `meta` is a directory of fixed-width records then the data they point
  at. The record length — 16, 24 or 32 — is decided by what **any** one
  entry carries, so a single display name widens every record in the
  tag. An offset of zero means the string is *absent*, not at the start
  of the tag, which is how a key with no value is encoded.
- **A dictionary does not round-trip byte-identically.** Entries are
  prepended as they are read, so reading reverses their order and
  writing them back lays the same content out differently. Same size,
  different bytes — and the reference does exactly the same.
- `cmsAllocProfileSequenceDescription` leaves all three descriptions
  **null**; a caller that wants text must allocate the containers
  itself. `pseq` writes a null description as an empty one rather than
  refusing, since an unfilled sequence is the normal case.
- Each `pseq` entry embeds two descriptions in whichever text type the
  profile's version calls for, so the same sequence is different bytes
  in a v2 and a v4 profile. **The v2 form does not survive a round
  trip**: the reference writes it and then fails to read it back, its
  size accounting having run out against the larger `desc` records. Ours
  fails identically.
- `psid` is the same sequence structure reached through a **position
  table** — a directory of offset and size pairs, then the elements — so
  each element can be a different length, which an embedded description
  certainly is. The count is checked against what the file can hold
  before anything is allocated. Unlike `pseq`, it round-trips.
- `bfd` holds two sampled curves and then a description with **no
  length of its own** — it runs to the end of the tag, so the tag's size
  is the only thing that says where the text stops.
- `scrn` **clamps** a channel count past the ceiling rather than
  refusing it, so a malformed tag reads back shorter than it claimed
  instead of failing.
- `crdi` files five counted strings in one multi-localized container
  under a made-up language of `PS` with section codes for a country.
  They are not locales; the container is being used as a five-slot
  record.
- `MHC2` reaches its three curves and its 3x4 matrix through offsets, so
  an identity matrix is written as **absent** rather than as ones and
  zeroes — 300 bytes against 348. Each curve block is preceded by a type
  signature and a filler word the reader steps over without checking.
- Two reference leaks are **not** reproduced (`Type_Signature_Read` and
  `Type_DateTime_Read` drop their block on a failed read). A leak is not
  observable through the ABI.

### Tag access (10) — `cmsReadTag`, `cmsWriteTag`, `cmsReadRawTag`, `cmsWriteRawTag`, `cmsLinkTag`, `cmsTagLinkedTo`, `cmsGetTagCount`, `cmsGetTagSignature`, …

- **`cmsReadTag` is the load-bearing lifetime contract**: returns a pointer
  to **library-owned** memory typed by tag signature; stable across repeated
  reads of the same tag; invalidated by `cmsWriteTag` of that tag and by
  `cmsCloseProfile`.  Caller must never free it.
- **errors**: `L` (returns `NULL`; unknown tag/type logs).
- Payload C layouts the arena must reproduce exactly: `cmsICCData`
  (flexible array), `cmsSEQ`/`cmsPSEQDESC` (caller *mutates* `seq[i]`
  members, including swapping `cmsMLU*`), `cmsDICTentry` (intrusive list),
  `cmsScreening`, `cmsUcrBg`, measurement/viewing conditions,
  `cmsDateTimeNumber`, `cmsVideoSignalType`, `cmsMHC2Type`, curves/MLU/
  named-color-list/pipeline object handles.

### Tone curves (23) — `cmsBuild*ToneCurve`, `cmsFreeToneCurve`, `cmsEvalToneCurve*`, `cmsGetToneCurveEstimatedTable`, `cmsGetToneCurveSegment`, …

- **owner**: caller frees with `cmsFreeToneCurve(Triple)`; curves read from
  tags are profile-owned (arena).
- **errors**: `L` on build; `B` on queries.
- `cmsGetToneCurveEstimatedTable` returns a `const cmsUInt16Number*` into
  curve-owned storage (lifetime = curve).  `cmsGetToneCurveSegment` returns
  `const cmsCurveSegment*` likewise (layout lcms2.h:1232).

### Pipelines + stages (34) — `cmsPipelineAlloc/Free/Dup/Eval*`, `cmsStageAlloc*`, `cmsStageData`, `cmsStageSampleCLut*`, …

- **owner**: pipeline owns inserted stages (`cmsPipelineInsertStage`
  transfers ownership); `cmsStageDup` gives the caller a copy.
- **`cmsStageAllocToneCurves` copies the curves it is given.** The
  caller keeps what it passed and may free it the moment the call
  returns — which the reference's own 8-bit LUT reader does. A stage
  holding the caller's pointers instead looks identical until someone
  frees them, so the probe frees them and *then* evaluates.
- **errors**: `L` on alloc; `B` on eval (void).
- `cmsStageData` returns the **live** stage payload (`_cmsStage*Data`,
  public layouts lcms2_plugin.h:516–542); clients read and, via the
  sampling idiom, observe mutation.  `_cmsStageCLutData.Params` points to
  the live `cmsInterpParams` (public layout, lcms2_plugin.h:290).
- A CLUT stage is **three pieces of memory that must be one**: the table,
  the `_cmsStageCLutData` block, and the `cmsInterpParams` pointing at
  that table.  A client samples by writing through `Tab.T` and then
  evaluates, so the evaluator reads the pointer the client wrote through
  — and calls through `Params->Interpolation`, so a replaced kernel takes
  effect.  Duplicating a stage must break all three apart: a shared table
  makes two stages one, and a shared `Params` frees twice.
- `cmsPipelineInsertStage` reports a chain mismatch by returning FALSE
  but **leaves the stage inserted** — the caller is left holding exactly
  the pipeline it asked for.  `cmsPipelineUnlinkStage` re-checks and
  ignores the answer.
- `cmsSliceSpace16/Float` hand the sampler a **null output**: there is no
  table behind the walk.  `SAMPLER_INSPECT` keeps the output buffer but
  discards whatever the sampler writes.  A sampler that returns 0
  abandons the walk, and what it already wrote stays written.
- **Only `nInputs` slots of the sampler's input array are defined.**
  `cmsStageSampleCLut*` memsets its buffer first, but `cmsSliceSpace*`
  does not — so a sampler reading past the input count reads stack
  garbage. A probe that did so agreed on macOS and disagreed on Linux;
  the rule for probes is to read exactly what the API defines as
  written, never the width of the buffer.

### Transforms (20), Colorimetry (23), Formatters (2 + `TYPE_*` space), MLU (12), Named colors (8), Dictionaries (6), PSEQ (3), Intents (5), CHAD (5), Alarm codes (4), GBD (12), IT8/CGATS (37), PostScript (3), MD5 (3), IO handlers (5), Header access (26), Virtual profiles (24), CIECAM02 (4), Plugins (all kinds), Misc (3)

*(each section is filled in the phase that implements it; the section must
be complete for every family; the differential probes under Conformance/ are the
living record of what each one measures)*

## What the differential can and cannot see

Comparing two builds is only evidence when the question was answered.
Three ways it silently was not, each found the hard way and each now
closed in `scripts/run_conformance.sh`:

- **Both crashed.** Two probes killed by a signal print the same
  truncated output and compare equal. Any exit status at or above 128
  now fails outright.
- **`diff` went binary.** A probe printed a NUL byte, `diff` decided the
  files were binary, and binary mode emits no `+`/`-` lines — so nothing
  was extracted and nothing looked like agreement. `cmp` is now the
  authority and `--text` stops the case arising; bytes differing with
  nothing extracted is now itself a failure.
- **The probe was not deterministic.** Output that depends on the clock,
  uninitialized memory, an address or an iteration order passes or fails
  by luck, and the failure surfaces later on another machine looking
  like a real divergence. Each probe now runs twice, a second apart, and
  must answer identically both times. The wait is what makes a
  seconds-resolution clock a certain catch rather than a coin flip.

A related discipline for probes themselves: a lifetime test that frees
the caller's copy only at the end cannot tell a copy from a kept
pointer. Free first, then read.

### Formatters (`_cmsGetFormatter`, `cmsFormatterForColorspaceOfProfile`, …) — *specific-entry integer formatters implemented*

- A formatter is chosen by walking an ordered table and taking the first
  entry matching `(format & ~mask) == type`. **Order is behaviour.**
  Omitting an entry is safe only when no layout it would catch matches a
  later entry that is present — which holds between the float and
  integer halves, since no integer entry masks the float bit away.
- The table has two kinds of entry. A **specific** one names a layout and
  its function ignores the transform entirely. A **generic** one stands
  for a family and reads the layout out of `info->InputFormat`, so it
  cannot run without a live transform — passing null crashes the
  reference.
- **Everything left to port is generic.** `RGBA_8` and `KCMY_16` have no
  specific entry in the reference either; planar, byte-swapped words and
  the whole float half go through generic handlers. So the formatter
  layer resumes after the transform exists, not before: the remaining
  functions need something to ask about the format, and the transform is
  what holds it.
- A consequence for probes: which formatter is *selected* can be asked
  for any layout, but running one is only defined where the entry is
  specific. The two questions are asked separately.
- The reference is inconsistent about reversal order —
  `Pack1ByteReversed` reverses in 16 bits then narrows, `Pack4BytesReverse`
  narrows then reverses in 8 — and the two do not agree for every value.
  Neither is a mistake to tidy up; each is reproduced as it stands.

## Floating point: what "agreement" means

Swift's arithmetic is IEEE-strict: it never contracts `a*b + c*d` into a
fused multiply-add, and its results are the same on every target.  C
compilers contract by default, so the reference's own doubles depend on
whether the target has the instruction — arm64 does, baseline x86-64 does
not — and a stock build of the reference disagrees with itself across the
two platforms this library ships on.

So the standard is:

- **Exact**, for everything quantized or encoded: 16-bit codes, pixel
  bytes, 15.16 fields, profile bytes.  This is what reaches files and
  images, and it is what the differential suites assert.
- **Exact against a reference built with `-ffp-contract=off`**, for raw
  doubles.  `scripts/build_reference.sh` builds it that way and CI uses
  it, so a remaining difference is this library's rather than the
  compiler's.
- **Within one ulp of a stock distribution build**, for raw doubles, and
  unspecified which way — because that build's own answer is unspecified.

Verified: the vector and matrix primitives are bit-identical to the
reference's own `cmsmtrx.c` compiled without contraction.

**A NaN is a NaN.** IEEE 754 fixes neither the sign nor the payload of a
NaN produced by an invalid operation, and the platform libraries
disagree: `log()` of a negative number returns a NaN of one sign on
Darwin and the other under glibc.  So a conformance program compares
*that* a NaN appeared and where, never which NaN — the probes feed a
marker in its place.  The inverse sigmoid outside its domain is the case
that found this; anything reaching `log` or `sqrt` of a negative can hit
it.

## Layouts constrained by the upstream testbed

The reference's own `testbed/testcms2.c` is part of this project's
conformance contract (compiled unmodified, linked against us, and it has to
pass eventually).  It includes the reference's private `lcms2_internal.h`
and reaches through two otherwise-opaque layouts, on objects **we**
allocated — which makes their upstream field order contract even though no
installed header declares it, exactly as it does for the 18 CMSCHECKPOINT
symbols:

| Struct | What the testbed touches | Consequence |
|---|---|---|
| `_cms_curve_struct` | reads `InterpParams->ContextID`, indexes `Table16[]`; writes `Table16[]` and `Segments[0].Type` on `cmsBuildGamma`/`cmsBuildTabulatedToneCurve16` results | the engine's curve must carry upstream's field prefix (InterpParams, nSegments, Segments, SegInterp, Evals, nEntries, Table16); `swift_ctx` appends after it |
| `_cmstransform_struct` | stack-allocates at upstream `sizeof`, sets `InputFormat`/`OutputFormat` at upstream offsets, passes it to the formatters `_cmsGetFormatter` returns | the head of the transform struct through `OutputFormat` must match upstream offsets |

Tail extension is safe in both cases: the testbed only dereferences pointers
our allocator produced.

## The three variadics (permanent C)

`cmsPipelineCheckAndRetreiveStages` takes `n` stage-type signatures
followed by `n` `cmsStage**` out-pointers as **one** variadic list, read
in two passes over the same `va_list` — so the two groups cannot be
interleaved.  Nothing is written unless every type matches, which is what
lets a caller try several shapes in turn against the same pointers and
have only the fitting one fill them; the `mAB` writer uses exactly that
to decide which of its four layouts a pipeline has.  A null out-pointer
is skipped.  An empty pipeline matches only a count of zero.

Implementing it made the C floor stop being standalone: it now reaches
the pipeline through the exported accessors, which the Swift boundary
defines.  Anything linking `CLCMS2` must link `LCMS2ABI` too.


| Symbol | Declared | Notes |
|---|---|---|
| `cmsPipelineCheckAndRetreiveStages` | lcms2.h:1308 | `n` sig args then `n` `cmsStage**` out-args |
| `cmsSignalError` | lcms2_plugin.h:105 | printf-style, `vsnprintf` into fixed buffer |
| `_cmsIOPrintf` | lcms2_plugin.h:177 | printf-style into an iohandler, "2K at most" |

## Known semantic gaps (documented, not hidden)

- A `cmsPluginMemHandler` can observe every engine allocation that carries
  payload (tag blocks, tables, LUTs) but not Swift runtime allocations
  (class instances, `Array`/`String` backing stores).  The reference routes
  everything; we route everything whose pointer can escape.
- `wchar_t` APIs assume 4-byte `wchar_t` (Unix).  Windows (2-byte) is out of
  scope until a Windows artifact exists.
