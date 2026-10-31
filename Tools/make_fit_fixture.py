#!/usr/bin/env python3
"""Generate Fixtures/sample_ride.fit, a synthetic cycling activity (Python 3 stdlib only).

Exercises: 14-byte header + header CRC, file CRC, little- and big-endian definitions,
compressed-timestamp records (with 5-bit rollover), a developer field, invalid values,
file_id / lap / session / activity messages.
Writes expected values to Fixtures/sample_ride.expected.json.
"""
import json, math, os, struct, sys

FIT_EPOCH = 631065600
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "Fixtures", "sample_ride.fit")

ENUM, SINT8, UINT8, SINT16, UINT16, SINT32, UINT32, STRING, UINT8Z, UINT32Z = (
    0x00, 0x01, 0x02, 0x83, 0x84, 0x85, 0x86, 0x07, 0x0A, 0x8C)
FMT = {ENUM: "B", SINT8: "b", UINT8: "B", SINT16: "h", UINT16: "H", SINT32: "i",
       UINT32: "I", UINT8Z: "B", UINT32Z: "I"}

_CRC_TABLE = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
              0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]

def crc16(data, crc=0):
    for byte in data:
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ _CRC_TABLE[byte & 0xF]
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ _CRC_TABLE[(byte >> 4) & 0xF]
    return crc

class Writer:
    def __init__(self):
        self.buf = bytearray()
        self.big = {}  # local type -> bool

    def define(self, local, global_num, fields, dev_fields=(), big=False):
        """fields: [(num, size, basetype)]; dev_fields: [(num, size, dev_data_index)]"""
        hdr = 0x40 | local | (0x20 if dev_fields else 0)
        e = ">" if big else "<"
        self.buf += bytes([hdr, 0, 1 if big else 0]) + struct.pack(e + "HB", global_num, len(fields))
        for n, s, t in fields:
            self.buf += bytes([n, s, t])
        if dev_fields:
            self.buf.append(len(dev_fields))
            for n, s, d in dev_fields:
                self.buf += bytes([n, s, d])
        self.big[local] = big

    def data(self, local, fields, values, header=None):
        """values aligned with fields; each is int/None (None -> invalid) or bytes (raw)."""
        e = ">" if self.big[local] else "<"
        self.buf.append(local if header is None else header)
        for (n, s, t), v in zip(fields, values):
            if isinstance(v, (bytes, bytearray)):
                self.buf += bytes(v).ljust(s, b"\0")[:s]
                continue
            if v is None:
                v = {ENUM: 0xFF, SINT8: 0x7F, UINT8: 0xFF, SINT16: 0x7FFF, UINT16: 0xFFFF,
                     SINT32: 0x7FFFFFFF, UINT32: 0xFFFFFFFF, UINT8Z: 0, UINT32Z: 0}[t]
            self.buf += struct.pack(e + FMT[t], v)

    def finish(self):
        body = bytes(self.buf)
        hdr = struct.pack("<BBHI4s", 14, 0x20, 2132, len(body), b".FIT")
        hdr += struct.pack("<H", crc16(hdr))
        full = hdr + body
        return full + struct.pack("<H", crc16(full))

def semi(deg):
    return int(round(deg * 2**31 / 180.0))

def main():
    w = Writer()
    start = 1_800_000_000 - FIT_EPOCH + 0  # arbitrary ride start (FIT time)
    start -= start % 64  # make rollover points predictable
    N = 600

    # file_id (local 0)
    FID = [(0, 1, ENUM), (1, 2, UINT16), (2, 2, UINT16), (3, 4, UINT32Z), (4, 4, UINT32)]
    w.define(0, 0, FID)
    w.data(0, FID, [4, 255, 1, 123456, start])

    # developer_data_id (207) + field_description (206), local 4
    DDI = [(3, 1, UINT8)]
    w.define(4, 207, DDI)
    w.data(4, DDI, [0])
    FD = [(0, 1, UINT8), (1, 1, UINT8), (2, 1, UINT8), (3, 16, STRING), (8, 8, STRING)]
    w.define(4, 206, FD)
    w.data(4, FD, [0, 0, UINT16, b"core_temp", b"C"])

    # record definitions
    # local 1: full timestamp; local 2: no timestamp (compressed headers); local 3: dev field
    body = [(0, 4, SINT32), (1, 4, SINT32), (2, 2, UINT16), (3, 1, UINT8), (4, 1, UINT8),
            (5, 4, UINT32), (6, 2, UINT16), (7, 2, UINT16), (73, 4, UINT32), (78, 4, UINT32)]
    REC_TS = [(253, 4, UINT32)] + body
    w.define(1, 20, REC_TS)
    w.define(2, 20, body)
    w.define(3, 20, REC_TS, dev_fields=[(0, 2, 0)])

    lat, lon = 33.45, -112.07
    dist = 0.0
    rows = []
    hdg = math.radians(40)
    for i in range(N):
        ts = start + i
        speed = 8.0 + 2.0 * math.sin(i / 40.0)
        dist += speed
        hdg += 0.002 * math.sin(i / 90.0)
        lat += speed * math.cos(hdg) / 111320.0
        lon += speed * math.sin(hdg) / (111320.0 * math.cos(math.radians(33.45)))
        alt = 335.0 + 12.0 * math.sin(i / 70.0)
        hr = int(120 + 40 * (1 - math.exp(-i / 120.0)) + 5 * math.sin(i / 15.0))
        cad = int(85 + 8 * math.sin(i / 25.0))
        pwr = int(180 + 60 * math.sin(i / 30.0))
        # invalid values: HR dropout i in 200..209, power dropout every 50th
        if 200 <= i < 210: hr = None
        if i % 50 == 49: pwr = None
        if 300 <= i < 305: lat_v = lon_v = None  # GPS loss
        else: lat_v, lon_v = semi(lat), semi(lon)
        dist_v = int(round(dist * 100))
        spd_v = int(round(speed * 1000))
        alt_v = int(round((alt + 500) * 5))
        rows.append(dict(ts=ts, lat=lat_v, lon=lon_v, alt=alt_v, hr=hr, cad=cad, pwr=pwr,
                         dist=dist_v, spd=spd_v))
        vals = [lat_v, lon_v, alt_v, hr, cad, dist_v, spd_v, pwr, spd_v, alt_v]
        dev = (i % 100 == 0)
        compressed = (i % 2 == 1) and not dev and i > 0
        if dev:
            w.data(3, REC_TS, [ts] + vals, header=3)
            w.buf += struct.pack("<H", 36 + (i // 100))  # developer field bytes
        elif compressed:
            w.data(2, body, vals, header=0x80 | (2 << 5) | (ts & 0x1F))
        else:
            w.data(1, REC_TS, [ts] + vals)

    end = start + N
    total_ms = N * 1000
    dist_cm = rows[-1]["dist"]
    kcal = 412

    # lap (big-endian definition, local 5)
    LAP = [(253, 4, UINT32), (2, 4, UINT32), (7, 4, UINT32), (8, 4, UINT32), (9, 4, UINT32)]
    w.define(5, 19, LAP, big=True)
    w.data(5, LAP, [end, start, total_ms, total_ms, dist_cm])

    # session (local 6)
    SES = [(253, 4, UINT32), (254, 2, UINT16), (2, 4, UINT32), (5, 1, ENUM), (6, 1, ENUM),
           (7, 4, UINT32), (8, 4, UINT32), (9, 4, UINT32), (11, 2, UINT16)]
    w.define(6, 18, SES)
    w.data(6, SES, [end, 0, start, 2, 7, total_ms, total_ms - 5000, dist_cm, kcal])

    # activity (local 7)
    ACT = [(253, 4, UINT32), (0, 4, UINT32), (1, 2, UINT16), (2, 1, ENUM), (3, 1, ENUM), (4, 1, ENUM)]
    w.define(7, 34, ACT)
    w.data(7, ACT, [end, total_ms, 1, 0, 26, 1])

    blob = w.finish()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(blob)

    exp = dict(
        file_bytes=len(blob), records=N, sessions=1, sport=2, sub_sport=7,
        start_unix=start + FIT_EPOCH, total_elapsed_s=N, total_timer_s=N - 5,
        total_distance_m=dist_cm / 100, total_calories=kcal,
        with_gps=sum(1 for r in rows if r["lat"] is not None),
        with_hr=sum(1 for r in rows if r["hr"] is not None),
        with_power=sum(1 for r in rows if r["pwr"] is not None),
        compressed_records=sum(1 for i in range(1, N) if i % 2 == 1 and i % 100 != 0),
        first=dict(unix=rows[0]["ts"] + FIT_EPOCH, lat=rows[0]["lat"] * 180 / 2**31,
                   lon=rows[0]["lon"] * 180 / 2**31, alt=rows[0]["alt"] / 5 - 500,
                   hr=rows[0]["hr"], cad=rows[0]["cad"], pwr=rows[0]["pwr"],
                   spd=rows[0]["spd"] / 1000, dist=rows[0]["dist"] / 100),
        last=dict(unix=rows[-1]["ts"] + FIT_EPOCH, lat=rows[-1]["lat"] * 180 / 2**31,
                  lon=rows[-1]["lon"] * 180 / 2**31, alt=rows[-1]["alt"] / 5 - 500,
                  hr=rows[-1]["hr"], cad=rows[-1]["cad"], pwr=rows[-1]["pwr"],
                  spd=rows[-1]["spd"] / 1000, dist=rows[-1]["dist"] / 100),
    )
    with open(os.path.join(ROOT, "Fixtures", "sample_ride.expected.json"), "w") as f:
        json.dump(exp, f, indent=2)
    print(json.dumps(exp, indent=2))

if __name__ == "__main__":
    main()
