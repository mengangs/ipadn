#!/usr/bin/env python3
"""Chunky solid parcel with true 3D isometric unboxing & spring pendulum motion:
120Hz (69 frames, 0.5667s), C1-smooth raised-sine envelopes, true hinged flap
foreshortening around outer box rims, 3D isometric yaw turn, and damped settle.
"""
import hashlib
import json
import math
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "iPadn-iOS/iPadn/Resources/RevealAnimations/tab_packages.json"
FRAMES = 69  # 68 intervals at 120Hz = 0.566667s (silky ProMotion cadence)
DURATION = 68 / 120


def bell(t, start, end, power=2.0, skew=1.0):
    """C1-smooth raised-sine envelope on [start, end] with optional fast-attack skew."""
    if t <= start or t >= end:
        return 0.0
    u = (t - start) / (end - start)
    s = u ** skew
    return math.sin(math.pi * s) ** power


def rounded_poly_radii(points, radii):
    """Filleted polygon with softer outer corners and crisp inner Y-junction seams."""
    incoming, outgoing = [], []
    n = len(points)
    for i, p in enumerate(points):
        r = radii[i]

        def tangent(q):
            dx, dy = q[0] - p[0], q[1] - p[1]
            length = math.hypot(dx, dy)
            amount = min(r, length / 2.4) / length
            return p[0] + dx * amount, p[1] + dy * amount

        incoming.append(tangent(points[(i - 1) % n]))
        outgoing.append(tangent(points[(i + 1) % n]))
    values = list(incoming[0])
    for i, p in enumerate(points):
        a, b = incoming[i], outgoing[i]
        values += [
            a[0] + (p[0] - a[0]) * 2 / 3,
            a[1] + (p[1] - a[1]) * 2 / 3,
            b[0] + (p[0] - b[0]) * 2 / 3,
            b[1] + (p[1] - b[1]) * 2 / 3,
            *b,
        ]
        end = incoming[(i + 1) % n]
        values += [*b, *end, *end]
    return {"closed": True, "points": [round(v, 4) for v in values]}


def xform(pts, cx, cy, sx=1.0, sy=1.0, angle_deg=0.0, dx=0.0, dy=0.0):
    rad = math.radians(angle_deg)
    ca, sa = math.cos(rad), math.sin(rad)
    out = []
    for x, y in pts:
        vx, vy = (x - cx) * sx, (y - cy) * sy
        rx = vx * ca - vy * sa
        ry = vx * sa + vy * ca
        out.append((cx + rx + dx, cy + ry + dy))
    return out


def yaw_deform_base(left_pts, right_pts, yaw):
    """Isometric 3D yaw turn: shifts central vertical ridge and foreshortens walls."""
    spine_dx = yaw
    wall_dx = yaw * 0.25
    l0 = (left_pts[0][0] + wall_dx, left_pts[0][1] - yaw * 0.22)
    l1 = (left_pts[1][0] + spine_dx, left_pts[1][1] + abs(yaw) * 0.06)
    l2 = (left_pts[2][0] + spine_dx, left_pts[2][1] + abs(yaw) * 0.06)
    l3 = (left_pts[3][0] + wall_dx, left_pts[3][1] - yaw * 0.22)

    r0 = (right_pts[0][0] + spine_dx, right_pts[0][1] + abs(yaw) * 0.06)
    r1 = (right_pts[1][0] + wall_dx, right_pts[1][1] + yaw * 0.22)
    r2 = (right_pts[2][0] + wall_dx, right_pts[2][1] + yaw * 0.22)
    r3 = (right_pts[3][0] + spine_dx, right_pts[3][1] + abs(yaw) * 0.06)
    return [l0, l1, l2, l3], [r0, r1, r2, r3]


def yaw_deform_lid(tl_pts, tr_pts, yaw):
    """Apply matching isometric 3D yaw shear/depth to hinged top flaps."""
    tl = [
        (tl_pts[0][0] - yaw * 0.55, tl_pts[0][1] + abs(yaw) * 0.05),
        (tl_pts[1][0] - yaw * 0.15, tl_pts[1][1] + yaw * 0.10),
        (tl_pts[2][0] + yaw * 0.42, tl_pts[2][1] - yaw * 0.10),
        (tl_pts[3][0] + yaw * 0.25, tl_pts[3][1] - yaw * 0.22),
    ]
    tr = [
        (tr_pts[0][0] - yaw * 0.12, tr_pts[0][1] + yaw * 0.10),
        (tr_pts[1][0] + yaw * 0.25, tr_pts[1][1] + yaw * 0.22),
        (tr_pts[2][0] + yaw * 0.80, tr_pts[2][1] + abs(yaw) * 0.06),
        (tr_pts[3][0] + yaw * 0.45, tr_pts[3][1] - yaw * 0.10),
    ]
    return tl, tr


def hinge_flap_3d(pts, hinge_indices, free_indices, theta_rad, lift_z):
    """True 3D isometric hinged rotation of a rectangular flap around its outer edge.
    Each free vertex rotates upward by theta_rad perpendicular to the hinge, pulling
    inward by (1 - cos theta) toward its hinge counterpart and rising vertically by W * sin(theta).
    """
    out = list(pts)
    for hi, fi in zip(hinge_indices, free_indices):
        hx, hy = pts[hi]
        fx, fy = pts[fi]
        vx, vy = fx - hx, fy - hy
        span = math.hypot(vx, vy)
        c, s = math.cos(theta_rad), math.sin(theta_rad)
        # In isometric view, folding the flap up by theta foreshortens (vx, vy) by cos(theta)
        # and raises the free edge in -Y by span * 0.50 * sin(theta)
        nx = hx + vx * c
        ny = hy + vy * c - span * 0.50 * s - lift_z
        out[fi] = (nx, ny)
        out[hi] = (hx, hy - lift_z)
    return out


def build():
    cx, cy = 26.0, 26.0
    left_base = [(6.5, 17.6), (24.95, 26.8), (24.95, 45.9), (6.5, 36.4)]
    left_radii = [2.2, 0.9, 1.8, 2.6]
    right_base = [(27.05, 26.8), (45.5, 17.6), (45.5, 36.4), (27.05, 45.9)]
    right_radii = [0.9, 2.2, 2.6, 1.8]

    # top_left : back(0), seam-back(1), seam-front(2), left(3)
    # top_right: seam-back(0), right(1), front(2), seam-front(3)
    top_left = [(26.0, 6.0), (34.4, 10.3), (15.6, 19.9), (7.2, 15.6)]
    tl_radii = [2.6, 1.0, 1.0, 2.2]
    top_right = [(36.4, 11.3), (44.8, 15.6), (26.0, 25.2), (17.6, 20.9)]
    tr_radii = [1.0, 2.2, 1.1, 1.0]

    base_frames = []
    lid_frames = []
    for i in range(FRAMES):
        t = i / (FRAMES - 1)

        # C1-smooth layered spring curves (elastic attack, fluid swing, plush settle)
        anti = bell(t, 0.0, 0.19, power=2.0, skew=0.86)
        leap = bell(t, 0.07, 0.63, power=2.0, skew=0.70)
        land = bell(t, 0.49, 0.87, power=2.0, skew=0.80)
        micro = bell(t, 0.74, 1.00, power=2.2, skew=0.84)

        squash = 0.064 * anti + 0.040 * land - 0.044 * leap - 0.014 * micro
        base_sx = 1.0 + squash
        base_sy = 1.0 - squash * 1.16
        base_dy = 1.60 * anti - 2.55 * leap + 1.15 * land - 0.38 * micro

        # 3D isometric yaw pendulum: swings right, sweeps across left, settles cleanly
        yaw = (
            2.75 * bell(t, 0.05, 0.44, power=2.0, skew=0.76)
            - 2.25 * bell(t, 0.30, 0.74, power=2.0, skew=0.82)
            + 0.65 * bell(t, 0.62, 0.95, power=2.2, skew=0.85)
        )
        base_tilt = (
            -2.4 * anti
            + 4.4 * bell(t, 0.07, 0.45, power=2.0, skew=0.76)
            - 3.1 * bell(t, 0.33, 0.76, power=2.0, skew=0.82)
            + 0.9 * bell(t, 0.64, 0.96, power=2.2, skew=0.85)
        )

        # True 3D hinged twin flaps with ~18ms aerodynamic stagger + elastic rebound
        open_l = bell(t, 0.09, 0.72, power=2.0, skew=0.70)
        open_r = bell(t, 0.12, 0.76, power=2.0, skew=0.70)
        rebound_l = bell(t, 0.66, 0.96, power=2.2, skew=0.80)
        rebound_r = bell(t, 0.69, 0.98, power=2.2, skew=0.80)

        theta_l = math.radians(42.0) * open_l + math.radians(7.0) * rebound_l
        theta_r = math.radians(40.0) * open_r + math.radians(6.5) * rebound_r

        hover_l = 0.50 * bell(t, 0.10, 0.68, power=2.0, skew=0.74) - 0.25 * anti
        hover_r = 0.40 * bell(t, 0.13, 0.71, power=2.0, skew=0.74) - 0.25 * anti

        tl_hinged = hinge_flap_3d(top_left, hinge_indices=(0, 3), free_indices=(1, 2), theta_rad=theta_l, lift_z=hover_l)
        tr_hinged = hinge_flap_3d(top_right, hinge_indices=(1, 2), free_indices=(0, 3), theta_rad=theta_r, lift_z=hover_r)

        lb_yaw, rb_yaw = yaw_deform_base(left_base, right_base, yaw)
        tl_yaw, tr_yaw = yaw_deform_lid(tl_hinged, tr_hinged, yaw * 0.92)

        lb_x = xform(lb_yaw, cx, cy, sx=base_sx, sy=base_sy, angle_deg=base_tilt, dy=base_dy)
        rb_x = xform(rb_yaw, cx, cy, sx=base_sx, sy=base_sy, angle_deg=base_tilt, dy=base_dy)

        # Flaps follow box body motion smoothly with slight elastic lag
        l_dy = 1.35 * anti - 2.30 * bell(t, 0.09, 0.66, power=2.0, skew=0.72) + 0.95 * land - 0.30 * micro
        r_dy = 1.35 * anti - 2.30 * bell(t, 0.11, 0.68, power=2.0, skew=0.72) + 0.95 * land - 0.30 * micro

        tl_x = xform(tl_yaw, cx, cy, sx=base_sx, sy=base_sy, angle_deg=base_tilt * 0.90, dy=l_dy)
        tr_x = xform(tr_yaw, cx, cy, sx=base_sx, sy=base_sy, angle_deg=base_tilt * 0.90, dy=r_dy)

        base_frames.append({
            "opacity": 1.0,
            "width": 0.0,
            "contours": [
                rounded_poly_radii(lb_x, left_radii),
                rounded_poly_radii(rb_x, right_radii),
            ],
        })
        lid_frames.append({
            "opacity": 1.0,
            "width": 0.0,
            "contours": [
                rounded_poly_radii(tl_x, tl_radii),
                rounded_poly_radii(tr_x, tr_radii),
            ],
        })

    asset = {
        "version": 1,
        "canvas": [52, 52],
        "duration": round(DURATION, 6),
        "tracks": [
            {"name": "base", "stroke": False, "evenOdd": False, "lineCap": 2, "lineJoin": 2, "frames": base_frames},
            {"name": "lid", "stroke": False, "evenOdd": False, "lineCap": 2, "lineJoin": 2, "frames": lid_frames},
        ],
    }
    asset["sourceSHA256"] = hashlib.sha256(json.dumps(asset, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    asset["sourceCommit"] = "ipadn-chunky-parcel-v3-silky"
    return asset


def validate(asset):
    assert len(asset["tracks"]) <= 8
    for track in asset["tracks"]:
        frames = track["frames"]
        assert len(frames) == FRAMES and frames[0] == frames[-1]
        for f in frames:
            assert 0 <= f["opacity"] <= 1 and 0 <= f["width"] <= 20
            for c, initial in zip(f["contours"], frames[0]["contours"]):
                assert c["closed"] == initial["closed"] and len(c["points"]) == len(initial["points"])
                assert 8 <= len(c["points"]) <= 2048 and (len(c["points"]) - 2) % 6 == 0
                assert all(math.isfinite(v) and 0 <= v <= 52 for v in c["points"]), f"out of bounds: {c['points']}"


if __name__ == "__main__":
    asset = build()
    validate(asset)
    OUT.write_text(json.dumps(asset, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"PASS: chunky parcel v3, 2 tracks, {FRAMES} frames, {round(DURATION, 4)}s, identical start/end")
