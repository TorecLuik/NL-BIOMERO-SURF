#!/usr/bin/env bash
# Re-download the public reference datasets used to exercise BIOMERO workflows.
#
# Source: RIKEN SSBD (https://ssbd.riken.jp/), served as OME-Zarr v0.4.
# Writes into web/L-Drive/reference-data/, which OMERO sees as /data/reference-data.
#
# Fetches the Zarr, regenerates the .ome.tiff files from it, then verifies
# everything against SHA256SUMS. Safe to re-run.
#
# See setup_docs/reference-data.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/web/L-Drive/reference-data"
BASE="https://dmss3gw.riken.jp/globias/zarr/v0.4"
# zarr and tifffile live in the worker venv, not the container default python
PYBIN="/opt/omero/server/venv-3.11/bin/python"

# name : chunk grid (channels, y-chunks, x-chunks) at level 0
fetch_zarr() {
  local name="$1" nc="$2" ny="$3" nx="$4"
  local url="$BASE/${name}.zarr/0"
  local out="$DEST/$name/${name}.zarr"
  echo "==> $name"
  mkdir -p "$out/0"
  curl -fsS -m 30 "$url/.zattrs"   -o "$out/.zattrs"
  curl -fsS -m 30 "$url/.zgroup"   -o "$out/.zgroup"
  curl -fsS -m 30 "$url/0/.zarray" -o "$out/0/.zarray"
  # chunk layout follows the t/c/z/y/x axis order declared in .zattrs
  for ((c=0; c<nc; c++)); do
    for ((y=0; y<ny; y++)); do
      mkdir -p "$out/0/0/$c/0/$y"
      for ((x=0; x<nx; x++)); do
        curl -fsS -m 60 "$url/0/0/$c/0/$y/$x" -o "$out/0/0/$c/0/$y/$x"
      done
    done
  done
}

# Convert level 0 to a CYX OME-TIFF, sliced at t=0,z=0. Runs inside
# biomeroworker, which already has zarr and tifffile; /data is the same volume.
make_tiff() {
  local name="$1"
  echo "==> $name.ome.tiff"
  sudo docker exec nl-biomero-biomeroworker-1 "$PYBIN" -c "
import zarr, numpy as np, tifffile
d = '/data/reference-data/$name/$name'
a = zarr.open(d + '.zarr/0', mode='r')
vol = np.asarray(a[0, :, 0])
# No 'Name' in the OME metadata: Bio-Formats registers the OME Image name as a
# second, pixel-less OMERO image on import, which shows as 'No preview' and
# fails any workflow it reaches. See setup_docs/reference-data.md.
tifffile.imwrite(d + '.ome.tiff', vol, photometric='minisblack',
                 metadata={'axes': 'CYX'})
print(vol.shape, vol.dtype)
"
}

fetch_zarr fig7_RSAdetection_16w              2 1 1
fetch_zarr 6E3rd4hrSTFBGlc-1_Render_SeriesRGB 3 2 2

if sudo docker ps --format '{{.Names}}' | grep -qx nl-biomero-biomeroworker-1; then
  make_tiff fig7_RSAdetection_16w
  make_tiff 6E3rd4hrSTFBGlc-1_Render_SeriesRGB
else
  echo "NOTE: biomeroworker is not running; skipped .ome.tiff regeneration."
  echo "      Start the stack and re-run, or convert by hand -- see"
  echo "      setup_docs/reference-data.md."
fi

echo
echo "Reference data in $DEST"

# The .ome.tiff files are NOT byte-reproducible: tifffile embeds a fresh UUID and
# timestamp on every write, so their pixels are stable but their bytes are not.
# SHA256SUMS therefore covers the Zarr only, and the TIFFs are checked on pixels.
if [ -f "$DEST/SHA256SUMS" ]; then
  echo "Verifying Zarr against recorded checksums..."
  ( cd "$DEST" && sha256sum -c SHA256SUMS --quiet ) \
    && echo "OK: Zarr matches" \
    || echo "NOTE: mismatch -- upstream may have changed; see reference-data.md"
else
  echo "No SHA256SUMS present; recording one now."
  ( cd "$DEST" && find . -type f -path "*.zarr/*" -print0 \
      | sort -z | xargs -0 sha256sum > SHA256SUMS )
fi

if sudo docker ps --format '{{.Names}}' | grep -qx nl-biomero-biomeroworker-1; then
  echo "Verifying .ome.tiff pixels against the Zarr..."
  sudo docker exec nl-biomero-biomeroworker-1 "$PYBIN" -c "
import zarr, numpy as np, tifffile, sys
ok = True
for name in ['fig7_RSAdetection_16w', '6E3rd4hrSTFBGlc-1_Render_SeriesRGB']:
    d = '/data/reference-data/%s/%s' % (name, name)
    want = np.asarray(zarr.open(d + '.zarr/0', mode='r')[0, :, 0])
    got = tifffile.imread(d + '.ome.tiff')
    same = np.array_equal(want, got)
    ok = ok and same
    print('  %-38s %s %s' % (name, got.shape, 'OK' if same else 'PIXEL MISMATCH'))
sys.exit(0 if ok else 1)
"
fi
