# Reference Data

*Created 2026-09-16 · last updated 2026-09-17*

Public example images for exercising BIOMERO workflows end to end. Used by
[pipeline-tests.md](pipeline-tests.md).

## What is stored

Under `web/L-Drive/reference-data/`, which OMERO sees as `/data/reference-data`:

```text
fig7_RSAdetection_16w/
  fig7_RSAdetection_16w.ome.tiff      2 x 512 x 512   uint8
  fig7_RSAdetection_16w.zarr/         OME-Zarr v0.4, level 0
6E3rd4hrSTFBGlc-1_Render_SeriesRGB/
  6E3rd4hrSTFBGlc-1_Render_SeriesRGB.ome.tiff   3 x 1114 x 1757  uint8
  6E3rd4hrSTFBGlc-1_Render_SeriesRGB.zarr/      OME-Zarr v0.4, level 0
SHA256SUMS                            covers the Zarr files
```

Both are 2D (`sizeZ=1`, `sizeT=1`). Most workflows registered here are 2D-only,
so this is deliberate — see the dimensionality warning in
[pipeline-tests.md](pipeline-tests.md). Only full-resolution level 0 is kept;
upstream also serves downsampled levels 1 and 2, which nothing here needs.

Both datasets come from RIKEN SSBD, a public OMERO instance, and were suggested
by the BIOMERO developers as representative of their workshop material.

### fig7_RSAdetection_16w

iPS-RPE cells incubated with serum from the TLHM6 monkey.

```text
channels   C0 = DNA (blue)   <- segment nuclei on this one
           C1 = RSA, RPE-specific antibody (green)
shape      (1, 2, 1, 512, 512)  as t,c,z,y,x
paper      Sugita et al. (2017) Stem Cell Reports 9, 1501-1515, figure 7
project    https://ssbd.riken.jp/database/project/108-Sugita-RPEiPSCell/
dataset    https://ssbd.riken.jp/database/dataset/4432/
preview    https://hms-dbmi.github.io/vizarr/?source=https://dmss3gw.riken.jp/globias/zarr/v0.4/fig7_RSAdetection_16w.zarr/0
```

Being 2-channel, this image suits `cellpose` but is a poor fit for `stardist`,
which branches on 1-channel grey vs 3-channel RGB and has no 2-channel path.
Use the RGB dataset below for StarDist.

### 6E3rd4hrSTFBGlc-1_Render_SeriesRGB

Glycogen in *Drosophila* fat body / body wall muscle, immunostained.

```text
channels   C0 = glycogen (red)
           C1 = F-actin (green)
           C2 = DNA (blue)   <- segment nuclei on this one
shape      (1, 3, 1, 1114, 1757)  as t,c,z,y,x
paper      Yamada et al. (2018) Development 145, dev158865, figure 2
project    https://ssbd.riken.jp/database/project/116-Yamada-Glycogen/
dataset    https://ssbd.riken.jp/database/dataset/4680
omero      https://ssbd.riken.jp/omero/webclient/img_detail/119527/
preview    https://hms-dbmi.github.io/vizarr/?source=https://dmss3gw.riken.jp/globias/zarr/v0.4/6E3rd4hrSTFBGlc-1_Render_SeriesRGB.zarr/0
```

At 1114x1757 this exceeds the 1024 px tile size, so it is the only dataset here
that exercises tiling.

## Importing into OMERO

Import **as copies, not by reference**. Importing with `--transfer=ln_s` leaves
the managed repository holding symlinks into `/data`; if that path is later
removed the images become permanently unreadable and the volume backup does not
cover them. This deployment has lost images that way. Plain import copies the
pixels into the `/OMERO` volume, which the backup does cover.

The `.ome.tiff` files are the ones to import. BIOMERO hands BIAFLOWS workflows
TIFF, so the Zarr copies are kept as the verifiable upstream original, not as
workflow input.

Through the UI, either route works:

```text
BIOMERO tab -> Importer   browse to /data/reference-data, select, import
OMERO.insight             File > Import, standard import dialog
```

## Restoring

```bash
scripts/fetch-reference-data.sh
```

Re-downloads both datasets from RIKEN, regenerates the `.ome.tiff` files from
the Zarr, and verifies both. Safe to re-run. Source, served as OME-Zarr:

```text
v0.4  https://dmss3gw.riken.jp/globias/zarr/v0.4/<name>.zarr/0
v0.5  https://dmss3gw.riken.jp/globias/zarr/v0.5/<name>.zarr/0
```

Both were reachable on 2026-09-16 and the v0.4 copies verified byte-for-byte.
If upstream disappears, the same images are downloadable from the SSBD dataset
pages above in their original formats.

The two artefacts are verified differently, because `tifffile` embeds a fresh
UUID and timestamp on every write: the TIFFs have stable *pixels* but unstable
*bytes*. So `SHA256SUMS` covers the Zarr, and the TIFFs are checked by comparing
their pixels against it. Checksumming the TIFFs would fail after every restore.

The conversion runs inside `biomeroworker` — `zarr` and `tifffile` are in
`/opt/omero/server/venv-3.11/bin/python`, not the container's default python. It
slices `(t,c,z,y,x)` at `t=0,z=0` and writes `CYX`:

```python
import zarr, numpy as np, tifffile
a = zarr.open('<name>.zarr/0', mode='r')
vol = np.asarray(a[0, :, 0])          # (c, y, x)
tifffile.imwrite('<name>.ome.tiff', vol, photometric='minisblack',
                 metadata={'axes': 'CYX', 'Name': '<name>'})
```

## Gaps

These two images cannot exercise everything registered in
`biomeroworker/slurm-config.ini`:

```text
no Z-stack or time series   stardist5d is the only 5D-capable workflow here and
                            its reason for existing is Z/T looping; both images
                            are sizeZ=1, sizeT=1
no punctate channel         spotcounting and aggregates_measurements both
                            consume an "aggregate" mask, and no registered
                            workflow produces one from these channels
```

Closing the first needs one public 3D or time-lapse dataset; SSBD serves both.
Closing the second needs an image with a spot-like channel plus a way to segment
it. Until then those three workflows stay untested — noted in
[open-items.md](open-items.md).
