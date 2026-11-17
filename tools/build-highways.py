#!/usr/bin/env python3
"""Builds RadarGlance/Resources/highways.bin from US Census TIGER/Line primary roads.

Primary roads (MTFCC S1100) are interstates and other limited-access highways. TIGER/Line is
public domain. Download and unzip it into its own directory, then pass the .shp path:

    curl -o /tmp/tiger-dl/primaryroads.zip \\
        https://www2.census.gov/geo/tiger/TIGER2024/PRIMARYROADS/tl_2024_us_primaryroads.zip
    unzip /tmp/tiger-dl/primaryroads.zip -d /tmp/tiger
    python3 -I tools/build-highways.py /tmp/tiger/tl_2024_us_primaryroads.shp \\
        RadarGlance/Resources/highways.bin

Only lines inside the CONUS radar box are kept. Each line is simplified (Douglas-Peucker) to
TOLERANCE_M meters and stored as 1e-5 degree integers. Format (little-endian), read by
Shared/HighwayData.swift:

    "RGHW", UInt8 version (1), UInt32 line count, then per line:
    UInt8 class (0 interstate, 1 other freeway), UInt32 point count,
    Int32 latitude e5 + Int32 longitude e5 for the first point,
    then Int16 deltas (lat, lon) for the rest. A delta that doesn't fit in Int16 is written as
    the escape value -32768 followed by Int32 deltas (lat, lon).
"""
import math
import struct
import sys

TOLERANCE_M = 25.0
CONUS = (-130.0, 20.0, -60.0, 55.0)  # west, south, east, north; matches RadarRegion.conus
ESCAPE = -32768


def read_dbf(path):
    with open(path, "rb") as f:
        header = f.read(32)
        count = struct.unpack("<I", header[4:8])[0]
        header_len, record_len = struct.unpack("<HH", header[8:12])
        fields = []
        while True:
            descriptor = f.read(32)
            if descriptor[0] == 0x0D:
                break
            name = descriptor[:11].split(b"\0")[0].decode()
            fields.append((name, descriptor[16]))
        f.seek(header_len)
        rows = []
        for _ in range(count):
            record = f.read(record_len)
            row, offset = {}, 1  # first byte is the deletion flag
            for name, length in fields:
                row[name] = record[offset:offset + length].decode("latin-1").strip()
                offset += length
            rows.append(row)
        return rows


def read_polylines(path):
    """Yields each record's parts as lists of (lon, lat)."""
    with open(path, "rb") as f:
        f.seek(100)
        while True:
            header = f.read(8)
            if len(header) < 8:
                return
            length = struct.unpack(">I", header[4:8])[0] * 2
            content = f.read(length)
            shape_type = struct.unpack("<i", content[:4])[0]
            if shape_type != 3:
                yield []
                continue
            num_parts, num_points = struct.unpack("<ii", content[36:44])
            parts = list(struct.unpack(f"<{num_parts}i", content[44:44 + 4 * num_parts]))
            start = 44 + 4 * num_parts
            coords = struct.unpack(f"<{2 * num_points}d", content[start:start + 16 * num_points])
            points = list(zip(coords[0::2], coords[1::2]))
            parts.append(num_points)
            yield [points[parts[i]:parts[i + 1]] for i in range(num_parts)]


def simplify(points, tolerance):
    """Douglas-Peucker in local meters (equirectangular around the line's first point)."""
    if len(points) < 3:
        return points
    lat0 = math.radians(points[0][1])
    kx = 111_320 * math.cos(lat0)
    ky = 110_540
    xy = [(lon * kx, lat * ky) for lon, lat in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        (x1, y1), (x2, y2) = xy[first], xy[last]
        dx, dy = x2 - x1, y2 - y1
        norm = math.hypot(dx, dy)
        worst, index = 0.0, None
        for i in range(first + 1, last):
            px, py = xy[i]
            if norm == 0:
                d = math.hypot(px - x1, py - y1)
            else:
                d = abs(dy * px - dx * py + x2 * y1 - y2 * x1) / norm
            if d > worst:
                worst, index = d, i
        if index is not None and worst > tolerance:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def in_conus(points):
    west, south, east, north = CONUS
    return any(west <= lon <= east and south <= lat <= north for lon, lat in points)


def encode(line_class, points):
    ints = [(round(lat * 1e5), round(lon * 1e5)) for lon, lat in points]
    # Rounding can make neighbors identical; drop repeats.
    deduped = [ints[0]] + [p for prev, p in zip(ints, ints[1:]) if p != prev]
    out = bytearray(struct.pack("<BI", line_class, len(deduped)))
    out += struct.pack("<ii", *deduped[0])
    for (lat0, lon0), (lat1, lon1) in zip(deduped, deduped[1:]):
        dlat, dlon = lat1 - lat0, lon1 - lon0
        if -32767 <= dlat <= 32767 and -32767 <= dlon <= 32767:
            out += struct.pack("<hh", dlat, dlon)
        else:
            out += struct.pack("<hii", ESCAPE, dlat, dlon)
    return bytes(out)


def main(shp_path, out_path):
    rows = read_dbf(shp_path[:-4] + ".dbf")
    lines = []
    points_in = points_out = 0
    for row, parts in zip(rows, read_polylines(shp_path)):
        line_class = 0 if row.get("RTTYP") == "I" else 1
        for part in parts:
            if len(part) < 2 or not in_conus(part):
                continue
            simplified = simplify(part, TOLERANCE_M)
            points_in += len(part)
            points_out += len(simplified)
            lines.append(encode(line_class, simplified))
    with open(out_path, "wb") as f:
        f.write(b"RGHW" + struct.pack("<BI", 1, len(lines)))
        for line in lines:
            f.write(line)
    print(f"{len(lines)} lines, {points_in} -> {points_out} points, wrote {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
