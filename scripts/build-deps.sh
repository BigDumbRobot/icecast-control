#!/bin/bash
# Builds the programs bundled inside Icecast Control, from source, for macOS 14.2+:
#   vendor/icecast        Icecast server (libogg/libvorbis linked in statically)
#   vendor/icecast-share  Icecast's web + admin pages
#   vendor/ffmpeg         A tiny ffmpeg: raw audio in → limiter → MP3 (LAME, static) → Icecast
# Only macOS's own libraries (libxml2, libxslt, curl) are used at runtime. No Homebrew needed.
#
# Needs (build machine only): Xcode command line tools. Takes a few minutes the first time.
# Usage: scripts/build-deps.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."

LAME_VERSION="3.100"
OGG_VERSION="1.3.5"
VORBIS_VERSION="1.3.7"
ICECAST_VERSION="2.4.4"
FFMPEG_VERSION="7.1.1"
export MACOSX_DEPLOYMENT_TARGET="14.2"

ROOT="$PWD"
WORK="$ROOT/vendor/.build"
PREFIX="$WORK/prefix"
JOBS="$(sysctl -n hw.ncpu)"
export CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export LDFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

if [[ -x vendor/icecast && -x vendor/ffmpeg && -d vendor/icecast-share && "${1:-}" != "--force" ]]; then
    echo "Bundled programs already built (vendor/). Use --force to rebuild."
    exit 0
fi
mkdir -p "$WORK" "$PREFIX"

fetch() { # url folder
    if [[ ! -d "$WORK/$2" ]]; then
        echo "Downloading $2..."
        curl -fsSL "$1" | tar -xz -C "$WORK" 2>/dev/null || curl -fsSL "$1" | tar -xJ -C "$WORK"
    fi
}

# --- LAME (MP3 encoder), static -------------------------------------------------------
if [[ ! -f "$PREFIX/lib/libmp3lame.a" ]]; then
    fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "lame-$LAME_VERSION"
    (cd "$WORK/lame-$LAME_VERSION"
     # LAME 3.100 lists a symbol that no longer exists; drop it so linking works.
     sed -i '' '/lame_init_old/d' include/libmp3lame.sym
     ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend --disable-dependency-tracking -q
     make -j"$JOBS" -s && make install -s)
fi

# --- libogg + libvorbis (needed by Icecast), static ------------------------------------
if [[ ! -f "$PREFIX/lib/libogg.a" ]]; then
    fetch "https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.gz" "libogg-$OGG_VERSION"
    (cd "$WORK/libogg-$OGG_VERSION"
     ./configure --prefix="$PREFIX" --disable-shared --enable-static -q
     make -j"$JOBS" -s && make install -s)
fi
if [[ ! -f "$PREFIX/lib/libvorbis.a" ]]; then
    fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.gz" "libvorbis-$VORBIS_VERSION"
    (cd "$WORK/libvorbis-$VORBIS_VERSION"
     # Old configure passes a flag modern clang rejects.
     sed -i '' 's/-force_cpusubtype_ALL//g' configure
     ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-ogg="$PREFIX" -q
     make -j"$JOBS" -s && make install -s)
fi

# --- Icecast ------------------------------------------------------------------------
fetch "https://downloads.xiph.org/releases/icecast/icecast-$ICECAST_VERSION.tar.gz" "icecast-$ICECAST_VERSION"
(cd "$WORK/icecast-$ICECAST_VERSION"
 PKG_CONFIG=false ./configure --prefix="$PREFIX/icecast" \
     --with-ogg="$PREFIX" --with-vorbis="$PREFIX" \
     --without-theora --without-speex --without-openssl \
     --with-curl --with-xslt-config=/usr/bin/xslt-config -q
 make -j"$JOBS" -s)
cp "$WORK/icecast-$ICECAST_VERSION/src/icecast" vendor/icecast
strip vendor/icecast
rm -rf vendor/icecast-share && mkdir -p vendor/icecast-share
cp -R "$WORK/icecast-$ICECAST_VERSION/web" "$WORK/icecast-$ICECAST_VERSION/admin" vendor/icecast-share/
find vendor/icecast-share -name 'Makefile*' -delete

# --- ffmpeg (audio only) ------------------------------------------------------------------
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION"
(cd "$WORK/ffmpeg-$FFMPEG_VERSION"
 ./configure \
     --prefix="$PREFIX/ffmpeg" \
     --disable-everything --disable-autodetect --disable-doc --disable-debug \
     --disable-ffplay --disable-ffprobe --disable-avdevice --disable-swscale --disable-postproc \
     --enable-static --disable-shared --enable-small \
     --enable-avfilter --enable-swresample --enable-network \
     --enable-libmp3lame \
     --enable-protocol=pipe,file,tcp,http,icecast \
     --enable-demuxer=pcm_f32le,wav \
     --enable-decoder=pcm_f32le,pcm_s16le \
     --enable-encoder=libmp3lame \
     --enable-muxer=mp3 \
     --enable-filter=alimiter,aresample,aformat,anull,abuffer,abuffersink,volume \
     --extra-cflags="-I$PREFIX/include $CFLAGS" \
     --extra-ldflags="-L$PREFIX/lib $LDFLAGS" >/dev/null
 make -j"$JOBS" ffmpeg >/dev/null)
cp "$WORK/ffmpeg-$FFMPEG_VERSION/ffmpeg" vendor/ffmpeg
strip vendor/ffmpeg

echo
echo "Done. Bundled programs and the libraries they use:"
for program in vendor/icecast vendor/ffmpeg; do
    echo "  $program ($(du -h "$program" | cut -f1)):"
    otool -L "$program" | tail -n +2 | awk '{print "      " $1}'
done
