#!/bin/bash
# Builds a self-contained wimlib-imagex for the machine's own architecture.
#
# ImageHub bundles this so splitting an oversized install.wim needs no Homebrew
# on the Mac that builds drives. Two properties matter and are both verified
# below:
#
#   1. It must link only against system libraries. A binary that references
#      /opt/homebrew works on the build machine and fails everywhere else.
#   2. libwim is linked statically (--disable-shared), so the result is one file.
#
# wimlib-imagex is GPLv3+ (only libwim can be LGPL). ImageHub invokes it as a
# separate process, so this is aggregation rather than linking — but the licence
# text and source version ship alongside it, which is what the licence requires.
#
# Usage: scripts/build_wimlib.sh <output-directory> [target-arch]
#
# With no target-arch it builds for the host. Passing a different one
# cross-compiles — that keeps everything on a single runner, because Intel macOS
# runners now sit queued indefinitely and a job that never starts blocks the app
# build behind it.
set -euo pipefail

WIMLIB_VERSION="1.14.5"
OUTPUT="${1:?usage: build_wimlib.sh <output-directory> [target-arch]}"
TARGET_ARCH="${2:-$(uname -m)}"
mkdir -p "${OUTPUT}"
OUTPUT="$(cd "${OUTPUT}" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}"

HOST_ARCH="$(uname -m)"
echo "Building wimlib ${WIMLIB_VERSION} for ${TARGET_ARCH} (host ${HOST_ARCH})"

# The release tarball on wimlib.net ships a generated ./configure; the GitHub tag
# archive does not, so autotools runs when needed.
TARBALL="wimlib-${WIMLIB_VERSION}.tar.gz"
if curl -fsSL --max-time 120 -o "${TARBALL}" \
    "https://wimlib.net/downloads/${TARBALL}"; then
  echo "Fetched the release tarball from wimlib.net"
  tar xf "${TARBALL}"
  cd "wimlib-${WIMLIB_VERSION}"
else
  echo "wimlib.net unavailable; falling back to the GitHub tag archive"
  curl -fsSL --max-time 120 -o wimlib.tar.gz \
    "https://github.com/ebiggers/wimlib/archive/refs/tags/v${WIMLIB_VERSION}.tar.gz"
  tar xf wimlib.tar.gz
  cd "wimlib-${WIMLIB_VERSION}"
  autoreconf -fiv
fi

# libxml2 comes from the SDK rather than Homebrew, so the binary stays portable.
SDK="$(xcrun --show-sdk-path)"

CONFIGURE_ARGS=(
  --disable-shared
  --enable-static
  --without-fuse
  --without-ntfs-3g
  --without-libcrypto
)
if [ "${TARGET_ARCH}" != "${HOST_ARCH}" ]; then
  # Autoconf switches to cross mode and stops trying to run test binaries.
  CONFIGURE_ARGS+=(--host="${TARGET_ARCH}-apple-darwin")
fi

./configure \
  "${CONFIGURE_ARGS[@]}" \
  CC="clang -arch ${TARGET_ARCH}" \
  CPPFLAGS="-I${SDK}/usr/include/libxml2" \
  LIBS="-lxml2" \
  >configure.log 2>&1 || { tail -40 configure.log; exit 1; }

make -j"$(sysctl -n hw.ncpu)" >build.log 2>&1 || { tail -40 build.log; exit 1; }

BINARY="./wimlib-imagex"
if [ ! -x "${BINARY}" ]; then
  # Some versions leave it under .libs when libtool wraps the link.
  BINARY="./.libs/wimlib-imagex"
fi
if [ ! -x "${BINARY}" ]; then
  echo "error: wimlib-imagex was not produced" >&2
  find . -name 'wimlib-imagex*' -maxdepth 3 >&2 || true
  exit 1
fi

# --- Portability check --------------------------------------------------------
# Anything outside /usr/lib and /System means this binary would only run on a
# machine set up like the builder.
echo "Linked libraries:"
otool -L "${BINARY}"
if otool -L "${BINARY}" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|/opt/local'; then
  echo "error: links against a non-system library — it would not run on a clean Mac." >&2
  exit 1
fi

# Confirm the binary really is the architecture that was asked for.
if ! lipo -archs "${BINARY}" | tr ' ' '\n' | grep -qx "${TARGET_ARCH}"; then
  echo "error: expected ${TARGET_ARCH} but got $(lipo -archs "${BINARY}")" >&2
  exit 1
fi

# Only runnable when it matches the host.
if [ "${TARGET_ARCH}" = "${HOST_ARCH}" ]; then
  "${BINARY}" --version
fi

cp "${BINARY}" "${OUTPUT}/wimlib-imagex-${TARGET_ARCH}"
cp COPYING "${OUTPUT}/COPYING" 2>/dev/null || true
echo "${WIMLIB_VERSION}" > "${OUTPUT}/VERSION"

echo "Wrote ${OUTPUT}/wimlib-imagex-${TARGET_ARCH}"
