# Third-party software

The Icecast Control app bundles these programs, built unmodified from their official source
releases by [`scripts/build-deps.sh`](scripts/build-deps.sh). They run as separate programs
inside the app.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| Icecast | 2.4.4 | GNU GPL v2 | https://downloads.xiph.org/releases/icecast/icecast-2.4.4.tar.gz |
| libogg (in Icecast) | 1.3.5 | BSD 3-clause | https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz |
| libvorbis (in Icecast) | 1.3.7 | BSD 3-clause | https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz |
| FFmpeg (audio-only build) | 7.1.1 | GNU LGPL v2.1+ | https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz |
| LAME (in FFmpeg) | 3.100 | GNU LGPL v2+ | https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz |

The exact build configuration is in `scripts/build-deps.sh`; running it reproduces the bundled
binaries. You may replace `Icecast Control.app/Contents/MacOS/icecast` or `ffmpeg` with your own
builds (re-sign the app afterwards with `codesign --force --sign - "Icecast Control.app"`).

Icecast is a trademark of the Xiph.Org Foundation. FFmpeg is a trademark of Fabrice Bellard.
This project is not affiliated with either.
