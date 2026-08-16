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
- Custom `cmsIOHANDLER` (public layout, lcms2_plugin.h:118): profile takes
  ownership of the handler iff opened via `cmsOpenProfileFromIOhandler2THR`
  with... *(verify exact close policy against cmsio0.c in Phase 3)*.

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
- **errors**: `L` on alloc; `B` on eval (void).
- `cmsStageData` returns the **live** stage payload (`_cmsStage*Data`,
  public layouts lcms2_plugin.h:516–542); clients read and, via the
  sampling idiom, observe mutation.  `_cmsStageCLutData.Params` points to
  the live `cmsInterpParams` (public layout, lcms2_plugin.h:290).

### Transforms (20), Colorimetry (23), Formatters (2 + `TYPE_*` space), MLU (12), Named colors (8), Dictionaries (6), PSEQ (3), Intents (5), CHAD (5), Alarm codes (4), GBD (12, stubbed), IT8/CGATS (37, stubbed), PostScript (3, stubbed), MD5 (3), IO handlers (5), Header access (26), Virtual profiles (24), Misc (3)

*(each section is filled in the phase that implements it; the section must
be complete before the family's stubs are retired)*

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
