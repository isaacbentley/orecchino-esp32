#!/usr/bin/env python3
"""Fetch a small offline raster tile set for the SenseCAP Indicator's map.

Default coverage: City of San Francisco + 1 mile buffer, zooms 11-14,
CARTO dark_all basemap (© OpenStreetMap contributors, © CARTO).
Output tree: <out>/tiles/{z}/{x}/{y}.png — packed into LittleFS by pack_fs.sh.
"""
import math
import os
import sys
import time
import urllib.request

# SF city limits + ~1 mile buffer
BBOX = (37.690, -122.527, 37.836, -122.343)  # south, west, north, east
# Zooms overridable: fetch_tiles.py [out_dir] [zmin] [zmax]
ZOOMS = (range(int(sys.argv[2]), int(sys.argv[3]) + 1)
         if len(sys.argv) > 3 else range(11, 15))
URL = "https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
UA = "orecchino-esp32/0.3 (personal offline device map; one-time fetch)"
OUT = sys.argv[1] if len(sys.argv) > 1 else "firmware/orecchino_sensecap/data"
DELAY = 0.35  # seconds between requests — be polite to the free tile CDN


def deg2tile(lat, lon, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    rad = math.radians(lat)
    y = int((1.0 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2.0 * n)
    return x, y


def tile_list():
    out = []
    for z in ZOOMS:
        x0, y0 = deg2tile(BBOX[2], BBOX[1], z)  # north-west corner
        x1, y1 = deg2tile(BBOX[0], BBOX[3], z)  # south-east corner
        for x in range(min(x0, x1), max(x0, x1) + 1):
            for y in range(min(y0, y1), max(y0, y1) + 1):
                out.append((z, x, y))
    return out


def main():
    tiles = tile_list()
    print(f"{len(tiles)} tiles for z{ZOOMS[0]}-{ZOOMS[-1]}; worst-case fetch "
          f"~{len(tiles) * DELAY / 60:.0f} min at the polite rate limit")
    fetched = 0
    size = 0
    for i, (z, x, y) in enumerate(tiles):
        path = os.path.join(OUT, "tiles", str(z), str(x), f"{y}.png")
        if os.path.exists(path):
            size += os.path.getsize(path)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        req = urllib.request.Request(
            URL.format(z=z, x=x, y=y), headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read()
        with open(path, "wb") as f:
            f.write(data)
        fetched += 1
        size += len(data)
        if fetched % 25 == 0:
            print(f"  {i + 1}/{len(tiles)} checked, {fetched} fetched, "
                  f"{size/1e6:.1f} MB")
        time.sleep(DELAY)
    print(f"tiles: {len(tiles)} ({fetched} newly fetched), {size/1e6:.2f} MB")


if __name__ == "__main__":
    main()
