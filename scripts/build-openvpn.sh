#!/usr/bin/env bash
# Builds a statically-linked, universal (arm64 + x86_64) `openvpn` binary
# and vendors it at Helper/Resources/openvpn, for embedding in the app
# bundle (see AGENTS.md's "openvpn bundling" notes). Same
# approach Tunnelblick/Viscosity use: static-link OpenSSL/lzo/lz4 so
# there's exactly one Mach-O to sign, rather than a dylib tree that needs
# install_name_tool rewrites and its own signing order.
#
# NOTE: this script has not been executed end-to-end yet -- it was written
# against known-good configure/build flags for these libraries but the
# actual build (especially cross-arch static linking) needs to be run and
# debugged on a real dev machine with build tools installed. Treat it as a
# strong starting point, not a verified pipeline.
#
# Prerequisites (dev machine only, none of this ships in the app):
#   brew install autoconf automake libtool pkg-config
#
# Usage:
#   ./scripts/build-openvpn.sh
#
# Produces: Helper/Resources/openvpn (universal2 Mach-O, statically linked)

set -euo pipefail

OPENVPN_VERSION="2.6.21"
OPENSSL_VERSION="3.4.0"
LZO_VERSION="2.10"
LZ4_VERSION="1.10.0"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/build/openvpn-static}"
OUT_BINARY="$ROOT_DIR/Helper/Resources/openvpn"
MACOS_MIN="11.0"

ARCHES=(arm64 x86_64)

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$(dirname "$OUT_BINARY")"
cd "$WORK_DIR"

echo "==> Fetching sources"
curl -fsSL -o openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
curl -fsSL -o lzo.tar.gz "https://www.oberhumer.com/opensource/lzo/download/lzo-${LZO_VERSION}.tar.gz"
curl -fsSL -o lz4.tar.gz "https://github.com/lz4/lz4/archive/refs/tags/v${LZ4_VERSION}.tar.gz"
curl -fsSL -o openvpn.tar.gz "https://github.com/OpenVPN/openvpn/archive/refs/tags/v${OPENVPN_VERSION}.tar.gz"

for arch in "${ARCHES[@]}"; do
  echo "==> Building dependencies for $arch"
  arch_dir="$WORK_DIR/$arch"
  prefix="$arch_dir/prefix"
  mkdir -p "$arch_dir" "$prefix"

  case "$arch" in
    arm64)   openssl_target="darwin64-arm64-cc" ;;
    x86_64)  openssl_target="darwin64-x86_64-cc" ;;
  esac
  host_triple="$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)"
  cflags="-arch $arch -mmacosx-version-min=$MACOS_MIN"

  # --- OpenSSL (static, no shared libs) ---
  tar -xzf openssl.tar.gz -C "$arch_dir"
  (
    cd "$arch_dir/openssl-${OPENSSL_VERSION}"
    ./Configure "$openssl_target" no-shared no-tests --prefix="$prefix" -mmacosx-version-min=$MACOS_MIN
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
  )

  # --- lzo (static) ---
  tar -xzf lzo.tar.gz -C "$arch_dir"
  (
    cd "$arch_dir/lzo-${LZO_VERSION}"
    CFLAGS="$cflags" ./configure --host="$host_triple" --prefix="$prefix" --disable-shared --enable-static
    make -j"$(sysctl -n hw.ncpu)"
    make install
  )

  # --- lz4 (static; plain Makefile, no autotools) ---
  tar -xzf lz4.tar.gz -C "$arch_dir"
  (
    cd "$arch_dir"/lz4-*
    make -j"$(sysctl -n hw.ncpu)" BUILD_SHARED=no CFLAGS="$cflags" PREFIX="$prefix" install
  )

  # --- openvpn itself, statically linked against the above ---
  tar -xzf openvpn.tar.gz -C "$arch_dir"
  (
    cd "$arch_dir"/openvpn-*
    autoreconf -ivf
    OPENSSL_CFLAGS="-I$prefix/include" \
    OPENSSL_LIBS="-L$prefix/lib -lssl -lcrypto" \
    LZO_CFLAGS="-I$prefix/include" \
    LZO_LIBS="-L$prefix/lib -llzo2" \
    LZ4_CFLAGS="-I$prefix/include" \
    LZ4_LIBS="-L$prefix/lib -llz4" \
    CFLAGS="$cflags" \
    LDFLAGS="-L$prefix/lib" \
    ./configure \
      --host="$host_triple" \
      --disable-shared \
      --disable-plugins \
      --disable-debug \
      --enable-static
    make -j"$(sysctl -n hw.ncpu)"
  )

  cp "$arch_dir"/openvpn-*/src/openvpn/openvpn "$arch_dir/openvpn-$arch"
done

echo "==> Creating universal binary"
lipo -create -output "$OUT_BINARY" "$WORK_DIR/arm64/openvpn-arm64" "$WORK_DIR/x86_64/openvpn-x86_64"
chmod +x "$OUT_BINARY"

echo "==> Verifying"
lipo -info "$OUT_BINARY"
otool -L "$OUT_BINARY" || true   # should show only /usr/lib/libSystem.B.dylib and similar system libs

echo "==> Done: $OUT_BINARY"
echo "    Ship its license: OpenVPN is GPLv2 -- copy $WORK_DIR/*/openvpn-*/COPYING"
echo "    alongside the binary (e.g. Helper/Resources/openvpn-LICENSE.txt) and note"
echo "    the exact upstream version ($OPENVPN_VERSION) in the README."
