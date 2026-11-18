#!/usr/bin/env python3
"""Fetch an offline raster tile set for a board's map (the SenseCAP's
bundled LittleFS image, or a copy to push from the Mac app).

The area is a circle around a centre, zooms 12-15, planned the way the
firmware plans it (firmware/common/tile_plan.h): a tile counts if any part
of it is inside the circle, the estimate is 12 KB a tile on flash, 1 MB of
the partition stays free, and a plan that does not fit shrinks the zoom-15
radius first, then zoom 14, in 250 m steps. The plan is printed before
anything is fetched; after fetching, the real sizes are checked again.

    tools/fetch_tiles.py [--lat 37.7749 --lon -122.4194] [--radius-km 3]
                         [--fs-mb 5.875] [--out firmware/orecchino_sensecap/data]

Basemap: Esri World Dark Gray Canvas (JPEG, no API key; attribution "Esri,
HERE, Garmin, © OpenStreetMap contributors"; Esri's terms apply: free for
basemap use, an ArcGIS account may be required for production use). CARTO
dark_all now needs a key and answers placeholders without one.
Output tree: <out>/tiles/{z}/{x}/{y}.jpg — packed into LittleFS by pack_fs.sh.
Esri's URLs are z/y/x (row before column); the stored tree is z/x/y.
"""
import argparse
import math
import os
import time
import urllib.request

ZMIN, ZMAX = 12, 15
RESERVE = 1024 * 1024          # TILE_PLAN_RESERVE
DEFAULT_BYTES = 12288          # TILE_PLAN_DEFAULT_BYTES
STEP_M = 250.0                 # TILE_PLAN_STEP_M
EARTH_R = 6371000.0
BLOCK = 4096                   # LittleFS block: a file takes whole blocks
SENSECAP_FS = 0x5E0000         # orecchino_sensecap/partitions.csv littlefs

URL = ("https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/"
       "World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}")   # note: z/y/x
UA = "orecchino-esp32/0.7.0 (personal offline device map; one-time fetch; <= 3 tiles/s)"   # FW_VERSION (rx_core.h)
DELAY = 0.35                   # seconds between requests: under 4 a second, as the boards


def is_jpeg(data):
    """A real tile starts FF D8 FF; an error page or a placeholder does not."""
    return data[:3] == b"\xff\xd8\xff"


def tile_lon(x, z):
    return x / 2 ** z * 360.0 - 180.0


def tile_lat(y, z):
    n = math.pi * (1.0 - 2.0 * y / 2 ** z)
    return math.degrees(math.atan(math.sinh(n)))


def tile_of(lat, lon, z):
    n = 2 ** z
    rad = math.radians(lat)
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2.0 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def dist_m(lat1, lon1, lat2, lon2):
    dlon = lon2 - lon1
    if dlon > 180:
        dlon -= 360
    elif dlon < -180:
        dlon += 360
    dx = math.radians(dlon) * math.cos(math.radians((lat1 + lat2) / 2)) * EARTH_R
    dy = math.radians(lat2 - lat1) * EARTH_R
    return math.hypot(dx, dy)


def in_circle(lat, lon, r, z, x, y):
    """tile_in_circle: the tile's nearest point to the centre is within r."""
    if r < 0:
        return False
    w, e = tile_lon(x, z), tile_lon(x + 1, z)
    n, s = tile_lat(y, z), tile_lat(y + 1, z)
    # The centre in the tile's frame: across the antimeridian its nearest
    # edge is the one 360 degrees away in raw longitude.
    mid = (w + e) / 2
    if lon - mid > 180:
        lon -= 360
    elif mid - lon > 180:
        lon += 360
    plat = min(max(lat, s), n)
    plon = min(max(lon, w), e)
    return dist_m(lat, lon, plat, plon) <= r


def circle_tiles(lat, lon, r, z):
    if r < 0:
        return []
    dlat = math.degrees(r / EARTH_R)
    dlon = math.degrees(r / (EARTH_R * max(math.cos(math.radians(lat)), 0.02)))
    # Across the antimeridian the west/east edges wrap round (x0 > x1: x0..n-1
    # then 0..x1), as tile_circle_box does; the tiles on both sides are in.
    w, e = lon - dlon, lon + dlon
    if w < -180.0:
        w += 360.0
    if e > 180.0:
        e -= 360.0
    n = 2 ** z
    x0, y0 = tile_of(min(lat + dlat, 85.0), w, z)
    x1, y1 = tile_of(max(lat - dlat, -85.0), e, z)
    if dlon >= 180.0:
        x0, x1 = 0, n - 1
    cols = x1 - x0 + 1 if x0 <= x1 else n - x0 + x1 + 1
    return [(z, x, y) for x in ((x0 + i) % n for i in range(cols)) for y in range(y0, y1 + 1)
            if in_circle(lat, lon, r, z, x, y)]


def plan(lat, lon, want_m, fs_bytes, avg_bytes=DEFAULT_BYTES):
    """tile_plan_make for an empty filesystem: per-zoom radii that fit."""
    capacity = max(fs_bytes - RESERVE, 0)
    radius = {z: want_m for z in range(ZMIN, ZMAX + 1)}

    def tiles():
        return [t for z in range(ZMIN, ZMAX + 1) for t in circle_tiles(lat, lon, radius[z], z)]

    shrunk = False
    for z in range(ZMAX, ZMIN - 1, -1):          # zoom 15 first, then 14, ...
        while len(tiles()) * avg_bytes > capacity and radius[z] >= 0:
            radius[z] = radius[z] - STEP_M if radius[z] > STEP_M else (0 if radius[z] > 0 else -1)
            shrunk = True
        if len(tiles()) * avg_bytes <= capacity:
            break
    return radius, tiles(), capacity, shrunk


def describe(radius):
    parts, z = [], ZMIN
    while z <= ZMAX:
        z1 = z
        while z1 + 1 <= ZMAX and radius[z1 + 1] == radius[z]:
            z1 += 1
        if radius[z] >= 0:
            zs = f"z{z}" if z == z1 else f"z{z}-{z1}"
            parts.append(f"{radius[z] / 1000:g} km {zs}")
        z = z1 + 1
    return ", ".join(parts) or "nothing"


def on_flash(size):
    return (size + BLOCK - 1) // BLOCK * BLOCK


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--lat", type=float, default=37.7749)
    ap.add_argument("--lon", type=float, default=-122.4194)
    ap.add_argument("--radius-km", type=float, default=3.0)
    ap.add_argument("--fs-mb", type=float, default=SENSECAP_FS / 1048576,
                    help="LittleFS partition size (default: the SenseCAP's)")
    ap.add_argument("--out", default="firmware/orecchino_sensecap/data")
    ap.add_argument("--dry-run", action="store_true", help="print the plan only")
    a = ap.parse_args()

    fs_bytes = int(a.fs_mb * 1048576)
    radius, tiles, capacity, shrunk = plan(a.lat, a.lon, a.radius_km * 1000, fs_bytes)
    est = len(tiles) * DEFAULT_BYTES
    print(f"Map: {describe(radius)}; {len(tiles)} tiles, about {est / 1e6:.1f} MB "
          f"of {capacity / 1e6:.1f} MB usable"
          + (" (shrunk to fit)" if shrunk else ""))
    if a.dry_run:
        return

    size = flash = fetched = 0
    for i, (z, x, y) in enumerate(tiles):
        path = os.path.join(a.out, "tiles", str(z), str(x), f"{y}.jpg")
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            req = urllib.request.Request(URL.format(z=z, x=x, y=y), headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read()
            if not is_jpeg(data):
                raise SystemExit(f"z{z} x{x} y{y}: not a JPEG tile ({len(data)} bytes); stopping")
            tmp = path + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
            fetched += 1
            time.sleep(DELAY)
        n = os.path.getsize(path)
        size += n
        flash += on_flash(n)
        if fetched and fetched % 25 == 0:
            print(f"  {i + 1}/{len(tiles)} checked, {fetched} fetched, {size / 1e6:.1f} MB")
    print(f"tiles: {len(tiles)} ({fetched} newly fetched), {size / 1e6:.2f} MB, "
          f"about {flash / 1e6:.2f} MB on flash of {capacity / 1e6:.1f} MB usable")
    if flash > capacity:
        raise SystemExit("too big for the partition: use a smaller --radius-km")


if __name__ == "__main__":
    main()
