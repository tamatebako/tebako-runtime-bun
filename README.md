# tebako-runtime-bun

Bun (oven-sh prebuilt distributions) as a tebako **runtime** — the
hermetic `bun` engine: the release ships the pair per platform, the
tebako-owned wrapper exe (`tebako-runtime-launcher`, the process entry
point) plus the env image (`.tfs`, mounted — never extracted).

Bun's env image is the simplest in the ecosystem — one self-contained
binary, no stdlib tree — and **TypeScript is the headline**: bun
transpiles TS/TSX in-process, so a payload's entry is its `.ts` file
directly, with no press-compile step.

- **kind:** runtime (`engine: bun`, `implementation: bun`)
- **upstream:** Bun 1.4.2 (oven-sh/bun), repacked — no compilation. The
  x64 legs ship the **baseline** builds (no AVX requirement) for
  universal reach. There is no linux-musl leg YET: upstream ships musl
  builds (`bun-linux-x64-musl-baseline`, `bun-linux-aarch64-musl`) and
  the tebako product ships the full musl toolchain at v2.8.22 — the two
  legs are tracked in issue #2 and will land as declared recipe rows,
  never discovered at run time.
  Bun rolls weekly on 1.x — this factory pins exact versions, never
  `latest`.
- **artifacts:** `tebako-runtime-<tebako-line>-<implementation>-<version>-<platform>[.exe]`
  + `.tfs` + `.sha256` sidecars + `<stem>.manifest.json` release shards
  (+ a detached `.asc` per served name on signing-enabled lines), and
  this registry (`tpkg-registry.yaml`) on the repo's default branch
- **visibility:** the locked default order — preload on POSIX (with the
  link-unit preload shim granted), the exec cache on windows (the
  payload root is declared `home`, so the whole tree materializes there)

The artifact name carries the distribution segment
([tebako#716](https://github.com/tamatebako/tebako/issues/716)): new
publishes spell
`tebako-runtime-<tebako-line>-<implementation>-<version>-<platform>`,
where `<implementation>` is the flavor's identity (`bun` today — the
recipe ships one implementation, oven-sh's build; a future distribution
variant slots its own segment in through its flavor block). Releases
already published keep the segment-less spelling
(`tebako-runtime-<tebako-line>-<version>-<platform>`) forever: they are
immutable and sha256-pinned in this registry, and re-running an old tag
composes that ref's own names, self-consistently. Tooling that reads
artifact names (the registry mirror, the release gem) accepts both
spellings.

Consumers' app payloads declare
`runtime_requirement: {engine: bun, constraint: ">= 1.4"}` on their
entrypoints; the dispatcher resolves the newest compatible cached
runtime (or downloads + verifies it from this repo's release index).
Payloads with native addons pin the ABI line per the support matrix —
bun speaks NAPI (node-addon-api interop) with its own coverage, so a
wrong-line resolution is a named error, never a segfault.

> The dispatch surface for a runtime's OWN entries
> (`tebako run bun:bun`, shimmed `bun`) is PLANNED product-side.
> Until it lands the binary and its `bunx` alias are declared in the
> runtime manifest's additive entrypoints list (the registry carries no
> entrypoints on kind: runtime) and the interpreter answers the spec 17
> wire directly (`--tebako-entry bun …` on the wrapper exe).

Platform coverage follows the tebako launcher's: macOS (arm64, x86_64),
linux (gnu, x86_64 + arm64), windows (x86_64). The aarch64-windows leg
lands when the product ships `tebako-runtime-launcher` for
windows-ucrt-arm64 — upstream's windows-arm64 build is native since
v1.3.10, so only the wrapper is missing. Note for that leg when it
arrives: `bun:ffi` is disabled on windows-arm64 upstream, so payloads
needing ffi exclude the triplet.

## Release shape

On a tag, each build leg **publishes and signs in-leg**: the leg that
built a pair uploads only the write-once names it owns (the wrapper exe,
the `.tfs` env image, both `.sha256` sidecars, the
`<stem>.manifest.json` shard) and — when `TEBAKO_RELEASE_SIGNING_ENABLED`
is armed — signs every one of those served names itself (no-fold rule:
nothing is ever "covered by" another artifact's signature; the shard
declares each artifact's `{keyid, asc}` block from the
`TEBAKO_RELEASE_SIGNING_KEYID` repo variable). No shared mutable file
exists, so all legs publish concurrently with zero rendezvous.

There is **no monolithic `manifest.json` / `SHA256SUMS.txt` release
asset**: both are derivable conveniences, computed consumer-side from
the shards + the asset listing (`tebako-pkg release-index`). The release
notes are written once at release creation (by whichever leg wins the
create race) and never rewritten. Every asset name is write-once: a
re-run skips digest-matching names and loudly keeps differing ones — a
bad published artifact is remedied by `status: withdrawn` in the
registry plus the next patch line, never by delete-and-replace.

The single `release` job then keeps only the two whole-matrix duties:

1. **Audit** (`tools/audit_release.rb`, read-only) — the expected
   (flavor × platform) matrix, derived from the workflow's own build
   matrix × `Tebakofile`'s pins, must be a subset of the release
   listing; on signing-enabled lines every served name's `.asc` is
   required, and the retired monoliths are refused.
2. **Registry** (`tools/registry_update.rb`) — renders
   `tpkg-registry.yaml` from the release's shards (never from
   templates) and lands it on `main` by bot PR. The merge preserves
   existing versions' rows and any `status: withdrawn` marks;
   `default:` tracks the newest non-withdrawn version.

Tooling specs live in `spec/` and run in the lint workflow. The release
sign pass is the tebako-release gem's (tamatebako/tebako-release-tooling,
pinned at Tebakofile's `tools.release_tooling`) — its coverage lives
with the gem.
