# ffmpeg-bundle

Prebuilt, LGPL-only [FFmpeg](https://ffmpeg.org/) static archives and a thin
Rust FFI shim, so a Rust program can decode and encode media without requiring
FFmpeg to be installed on the machine it runs on.

**This project is packaging, not authorship.** Everything that does the actual
work here was written by the FFmpeg project and its contributors over more than
two decades. This repository fetches a pinned FFmpeg release, builds it with a
deliberately restricted configuration, and exposes the result to Cargo. The
credit belongs upstream; please direct thanks, bug reports about codec
behaviour, and any support you can offer to [the FFmpeg
project](https://ffmpeg.org/donations.html).

## Why this exists

Linking FFmpeg from Rust normally means one of two unhappy choices:

- **Depend on a system FFmpeg.** Then your program's behaviour depends on
  whichever version a distribution shipped, which codecs that build enabled,
  and whether the user has it at all. Reproducing a bug becomes a conversation
  about the user's package manager.
- **Vendor and build FFmpeg yourself.** Then every consumer of your crate
  inherits a C build: autotools, NASM, a working cross-compilation story, and
  a fifteen-minute compile in front of every `cargo build`.

This repository takes the second path once, in one place, with the build recipe
committed and the FFmpeg version pinned in `ffmpeg-version.txt`. Downstream
crates get a normal Cargo dependency, a fixed set of codecs, and a binary that
runs on a machine with no FFmpeg installed.

It is deliberately general: nothing here is specific to any particular
application.

## Licensing — please read this before distributing anything

FFmpeg is free software under the **GNU Lesser General Public License, version
2.1 or later**. This build is configured with `--disable-gpl` and no non-free
components, so the archives here are **LGPL-only**. That is a deliberate choice:
it keeps the licensing posture of anything that links them as simple as the LGPL
allows.

If you ship a binary that statically links these archives, the LGPL asks a few
things of you. In plain terms:

1. **Say so.** Give prominent notice that your program uses FFmpeg and that
   FFmpeg is covered by the LGPL-2.1-or-later, and include a copy of the
   licence. `sources/ffmpeg-n7.1/COPYING.LGPLv2.1` is the text.
2. **Provide the source.** The complete FFmpeg source this build came from is
   committed in `sources/`, at the exact revision used. Redistribute it, or make
   it available on the same terms you make your own binary available.
3. **Allow relinking.** A user must be able to replace the FFmpeg part with
   their own modified version. Shipping the static archives from `dist/lib`
   alongside your object files, or your build recipe, satisfies this — which is
   the reason the archives here are kept as `.a` files rather than folded into
   an opaque binary.

If you enable GPL components by changing the configure flags in
`scripts/build-ffmpeg.sh`, none of the above holds any more and your entire
program becomes subject to the GPL. The flags are the licence.

This summary is a pointer, not legal advice. The licence text governs, and if
you are distributing commercially it is worth an hour of a lawyer's time.

### What is in this repository, and whose it is

| Path | Contents | Copyright |
| --- | --- | --- |
| `sources/ffmpeg-*` | Unmodified FFmpeg release tarball and extracted tree | The FFmpeg authors — LGPL-2.1-or-later |
| `dist/lib`, `dist/include` | Static archives and headers built from that source | The FFmpeg authors — LGPL-2.1-or-later |
| `scripts/`, `build.rs`, `src/` | Build recipe and the Rust FFI shim | This repository's author, under the same licence |

FFmpeg's own `LICENSE.md` in `sources/` lists the licences of every component
it contains and is the authoritative statement.

## Using it

Add it as a Git dependency, pinned to a tag:

```toml
[dependencies.ffmpeg-bundle]
git = "https://github.com/jowharshamshiri/ffmpeg-bundle"
tag = "v1.24.76"
```

The build script publishes the include path and link flags, so a dependent
crate links the archives without any further configuration. `dist/link_flags.txt`
records the exact flags used, which is also the fastest way to see what a
consumer will actually link against.

To rebuild from source — after changing the pinned version, the configure
flags, or to verify what the committed archives contain:

```bash
scripts/build-ffmpeg.sh
```

It fetches the release named in `ffmpeg-version.txt`, configures it with the
restricted flag set, builds, and writes the archives into `dist/`.

## Changing what is enabled

`scripts/build-ffmpeg.sh` holds one `./configure` invocation, commented with the
reason for each decision. Enabling a codec means adding a flag there and
rebuilding; there is no hidden configuration elsewhere. Check the licence
implications of anything you add — some components are GPL, and a few are
non-free and cannot be redistributed at all.
