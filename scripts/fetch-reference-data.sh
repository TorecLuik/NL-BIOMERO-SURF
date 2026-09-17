#!/usr/bin/env bash
# Re-download the public reference datasets used to exercise BIOMERO workflows.
#
# Source: RIKEN SSBD (https://ssbd.riken.jp/), served as OME-Zarr v0.4.
# Writes into $OMERO_DATA_PATH/L-Drive/reference-data/, which OMERO sees as
# /data/reference-data. L-Drive lives on the attached storage volume; see
# deployment_docs/storage-architecture.md.
#
# Fetches the Zarr, regenerates the .ome.tiff files from it, then verifies
# everything against SHA256SUMS. Safe to re-run.
#
# See deployment_docs/reference-data.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# L-Drive moved onto the attached storage volume, so resolve it the same way
# docker-compose.yml does rather than assuming the old in-repo path.
DATA_PATH="$(grep -hE '^OMERO_DATA_PATH=' "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
if [ -z "$DATA_PATH" ]; then
  echo "OMERO_DATA_PATH is not set in .env" >&2
  exit 1
fi
if [ ! -d "$DATA_PATH/L-Drive" ]; then
  echo "$DATA_PATH/L-Drive does not exist; is the storage volume attached?" >&2
  exit 1
fi
DEST="$DATA_PATH/L-Drive/reference-data"
BASE="https://dmss3gw.riken.jp/globias/zarr/v0.4"
# zarr and tifffile live in the worker venv, not the container default python
PYBIN="/opt/omero/server/venv-3.11/bin/python"

# Fetch every resolution level the .zattrs declares. The downsampled levels are
# not optional: OMERO's NGFF pixel buffer reads the multiscales list and opens
# every path in it, so a pyramid missing a level fails with
# "'.zarray' expected but is not readable or missing in store" and the image
# registers with no readable pixels and no thumbnail.
#
# The level count and chunk grid differ per dataset -- fig7 has 3 levels, the RGB
# one has 6 -- so both are read from the served metadata rather than assumed.
fetch_zarr() {
  local name="$1"
  local url="$BASE/${name}.zarr/0"
  local out="$DEST/$name/${name}.zarr"
  echo "==> $name"
  mkdir -p "$out"
  curl -fsS -m 30 "$url/.zattrs" -o "$out/.zattrs"
  curl -fsS -m 30 "$url/.zgroup" -o "$out/.zgroup"

  local lvl
  for lvl in $(python3 -c "
import json
d=json.load(open('$out/.zattrs'))
print(' '.join(x['path'] for x in d['multiscales'][0]['datasets']))"); do
    mkdir -p "$out/$lvl"
    curl -fsS -m 30 "$url/$lvl/.zarray" -o "$out/$lvl/.zarray"
    # chunk grid per axis, from this level's own shape and chunk size
    local grid
    grid=$(python3 -c "
import json,math
d=json.load(open('$out/$lvl/.zarray'))
print(' '.join(str(math.ceil(s/c)) for s,c in zip(d['shape'], d['chunks'])))")
    local nt nc nz ny nx
    read -r nt nc nz ny nx <<<"$grid"
    local t c z y x
    for ((t=0; t<nt; t++)); do
      for ((c=0; c<nc; c++)); do
        for ((z=0; z<nz; z++)); do
          for ((y=0; y<ny; y++)); do
            mkdir -p "$out/$lvl/$t/$c/$z/$y"
            for ((x=0; x<nx; x++)); do
              curl -fsS -m 60 "$url/$lvl/$t/$c/$z/$y/$x" \
                   -o "$out/$lvl/$t/$c/$z/$y/$x"
            done
          done
        done
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
a = zarr.open(d + '.zarr/0', mode='r')   # level 0
vol = np.asarray(a[0, :, 0])
# The path must end .ome.tiff: tifffile decides whether to emit OME metadata
# from the filename, and without it the file carries no SizeC. Bio-Formats then
# reads 2 channels as 1 and the ZARR export dies with 'Invalid C index: 1/1'.
tifffile.imwrite(d + '.ome.tiff', vol, photometric='minisblack',
                 metadata={'axes': 'CYX'})
print(vol.shape, vol.dtype)
"
}

fetch_zarr fig7_RSAdetection_16w
fetch_zarr 6E3rd4hrSTFBGlc-1_Render_SeriesRGB

if sudo docker ps --format '{{.Names}}' | grep -qx nl-biomero-biomeroworker-1; then
  make_tiff fig7_RSAdetection_16w
  make_tiff 6E3rd4hrSTFBGlc-1_Render_SeriesRGB
else
  echo "NOTE: biomeroworker is not running; skipped .ome.tiff regeneration."
  echo "      Start the stack and re-run, or convert by hand -- see"
  echo "      deployment_docs/reference-data.md."
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
