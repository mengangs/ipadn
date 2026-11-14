#!/usr/bin/env python3
"""Compile pinned Telegram trash and original iPadn share to native keyframes.

Not a general Lottie renderer: unsupported features fail explicitly. No packages.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'vendor/TelegramRevealAnimations'
OUTPUT = ROOT / 'iPadn/Resources/RevealAnimations'
COMMIT = '24638bc69bd083981b178dd1e7f921eebbf7fc46'


def scalar(v):
    return v[0] if isinstance(v, list) else v


def component(v, i):
    return v[min(i, len(v)-1)] if isinstance(v, list) else v


def cubic(a, b, c, d, t):
    u = 1-t
    return u*u*u*a + 3*u*u*t*b + 3*u*t*t*c + t*t*t*d


def eased(key, fraction, index=0):
    out, into = key.get('o', {}), key.get('i', {})
    x1, y1 = component(out.get('x', 0), index), component(out.get('y', 0), index)
    x2, y2 = component(into.get('x', 1), index), component(into.get('y', 1), index)
    lo, hi = 0.0, 1.0
    for _ in range(32):
        mid = (lo+hi)/2
        if cubic(0, x1, x2, 1, mid) < fraction:
            lo = mid
        else:
            hi = mid
    return cubic(0, y1, y2, 1, (lo+hi)/2)


def mix(a, b, amount):
    if isinstance(a, bool):
        assert a == b
        return a
    if isinstance(a, dict):
        assert set(a) == set(b)
        return {k: mix(a[k], b[k], amount) for k in a}
    if isinstance(a, list):
        assert len(a) == len(b), 'Incompatible path topology'
        return [mix(x, y, amount) for x, y in zip(a, b)]
    return a+(b-a)*amount


def value(prop, frame):
    if not prop.get('a', 0):
        return prop['k']
    keys = prop['k']
    for i, key in enumerate(keys):
        if i+1 == len(keys) or frame < keys[i+1]['t']:
            start = key.get('s', keys[max(0, i-1)].get('e'))
            if i+1 == len(keys) or key.get('h') == 1 or frame <= key['t']:
                return start
            end = key.get('e', keys[i+1].get('s'))
            assert start is not None and end is not None
            fraction = (frame-key['t'])/(keys[i+1]['t']-key['t'])
            if isinstance(start, list) and start and isinstance(start[0], (float, int)):
                if 'to' in key:
                    t = eased(key, fraction)
                    return [cubic(a, a+key['to'][j], b+key['ti'][j], b, t)
                            for j, (a, b) in enumerate(zip(start, end))]
                return [mix(a, b, eased(key, fraction, j)) for j, (a, b) in enumerate(zip(start, end))]
            return mix(start, end, eased(key, fraction))
    raise AssertionError('No property value')


def multiply(a, b):
    return [a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1],
            a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3],
            a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5]]


def transform(props, frame):
    assert scalar(value(props.get('sk', {'k': 0}), frame)) == 0, 'Skew unsupported'
    p, a, s = (value(props[k], frame) for k in ('p', 'a', 's'))
    r = math.radians(scalar(value(props['r'], frame)))
    co, si = math.cos(r), math.sin(r)
    m = [co*s[0]/100, si*s[0]/100, -si*s[1]/100, co*s[1]/100, p[0], p[1]]
    return multiply(m, [1, 0, 0, 1, -a[0], -a[1]])


def point(m, p):
    return [round(m[0]*p[0]+m[2]*p[1]+m[4], 5), round(m[1]*p[0]+m[3]*p[1]+m[5], 5)]


def contour(shape, matrix):
    v, incoming, outgoing = shape['v'], shape['i'], shape['o']
    n = len(v)
    assert len(incoming) == len(outgoing) == n and n > 1
    # Explicit cubic commands let Core Animation interpolate native CGPaths
    # between source frames, including on a 120 Hz screen, without SwiftUI ticks.
    commands = point(matrix, v[0])
    for j in range(n if shape['c'] else n-1):
        k = (j+1) % n
        commands += point(matrix, [v[j][q]+outgoing[j][q] for q in (0, 1)])
        commands += point(matrix, [v[k][q]+incoming[k][q] for q in (0, 1)])
        commands += point(matrix, v[k])
    return {'closed': shape['c'], 'points': commands}


def last_time(v):
    if isinstance(v, dict):
        if v.get('a') == 1:
            return max(k['t'] for k in v['k'])
        return max((last_time(x) for x in v.values()), default=0)
    if isinstance(v, list):
        return max((last_time(x) for x in v), default=0)
    return 0


def compile_asset(path):
    raw = path.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == '64158b35934cfedf33a6416da3c7a1bf2880a263c4a90dd416051d8741d22a8b', 'Pinned upstream artwork changed'
    data = json.loads(raw)
    assert not data.get('assets'), 'Precompositions/images unsupported'
    layers = {l['ind']: l for l in data['layers']}
    fps, start = data['fr'], data['ip']
    # Delete contains 155 static tail frames; keep all motion, drop that idle tail.
    last = min(data['op']-1, max(last_time(l) for l in data['layers']))
    times = list(range(int(start), int(math.ceil(last))+1))
    assert len(times) >= 2

    def layer_matrix(layer, frame, visiting=()):
        assert layer['ind'] not in visiting
        m = transform(layer['ks'], frame)
        if 'parent' in layer:
            m = multiply(layer_matrix(layers[layer['parent']], frame, visiting+(layer['ind'],)), m)
        return m

    tracks = []
    # Lottie is front-to-back; CAShapeLayers are added back-to-front.
    for layer in reversed(data['layers']):
        assert layer['ty'] == 4 and not layer.get('masksProperties') and not layer.get('ef')
        assert layer.get('sr', 1) == 1 and layer.get('bm', 0) == 0 and not layer.get('ddd', 0)
        for group in layer['shapes']:
            assert group['ty'] == 'gr' and not group.get('hd', False)
            items = group['it']
            assert all(s['ty'] in {'sh', 'fl', 'st', 'tr', 'mm'} for s in items)
            assert all(s.get('mm', 1) == 1 for s in items if s['ty'] == 'mm')
            shapes = [s for s in items if s['ty'] == 'sh']
            group_transform = next(s for s in items if s['ty'] == 'tr')
            for style in (s for s in items if s['ty'] in {'fl', 'st'}):
                assert value(style['c'], start) == [1, 1, 1, 1], 'Only white artwork supported'
                track = {'name': layer.get('nm', ''), 'stroke': style['ty'] == 'st',
                         'evenOdd': style.get('r', 1) == 2, 'lineCap': style.get('lc', 1),
                         'lineJoin': style.get('lj', 1), 'frames': []}
                for frame in times:
                    matrix = multiply(layer_matrix(layer, frame), transform(group_transform, frame))
                    opacity = scalar(value(layer['ks']['o'], frame))*scalar(value(group_transform['o'], frame))*scalar(value(style['o'], frame))/1_000_000
                    if not layer['ip'] <= frame < layer['op']:
                        opacity = 0
                    width = 0.0
                    if style['ty'] == 'st':
                        width = scalar(value(style['w'], frame))*math.sqrt(matrix[0]**2+matrix[1]**2)
                    paths = []
                    for shape in shapes:
                        v = value(shape['ks'], frame)
                        paths.append(contour(v[0] if isinstance(v, list) else v, matrix))
                    track['frames'].append({'opacity': round(opacity, 6), 'width': round(width, 5), 'contours': paths})
                tracks.append(track)
    def bounds(frames):
        points = [c['points'] for f in frames if f['opacity'] > 0 for c in f['contours']]
        xs = [x for p in points for x in p[0::2]]
        ys = [y for p in points for y in p[1::2]]
        return min(xs), min(ys), max(xs), max(ys)

    resting = bounds([t['frames'][-1] for t in tracks])
    extent = bounds([f for t in tracks for f in t['frames']])
    cx, cy = (resting[0]+resting[2])/2, (resting[1]+resting[3])/2
    scale = min(26/(resting[3]-resting[1]),
                24/max(cx-extent[0], extent[2]-cx),
                24/max(cy-extent[1], extent[3]-cy))
    # Same glyph height at rest; leave room for the entire original lid/arrow
    # motion inside a 52 pt action. Uniform normalization does not alter timing.
    for track in tracks:
        for f in track['frames']:
            f['width'] = round(f['width']*scale, 5)
            for c in f['contours']:
                c['points'] = [round((p-(cx if i % 2 == 0 else cy))*scale+26, 5)
                               for i, p in enumerate(c['points'])]
    return {'version': 1, 'canvas': [52, 52], 'originalCanvas': [data['w'], data['h']],
            'duration': (last-start)/fps, 'sourceSHA256': hashlib.sha256(raw).hexdigest(),
            'sourceCommit': COMMIT, 'tracks': tracks}



def compile_share():
    # Original iPadn share artwork: a complete lift/return/settle sequence.
    # Telegram's anim_forward morphs to a success checkmark, so do not use it
    # as an idle Share action. The trigger/reset mechanism remains the same.
    keys = {
        'arrowY': [(0, 0), (4, 1), (13, -5), (23, 0.7), (30, -0.6), (39, 0)],
        'arrowOpacity': [(0, 1), (39, 1)],
        'trayY': [(0, 0), (9, 0.8), (20, 0), (27, -0.4), (39, 0)]
    }

    def sample(name, frame):
        values = keys[name]
        for (t0, a), (t1, b) in zip(values, values[1:]):
            if frame <= t1:
                t = (frame-t0)/(t1-t0)
                # Smooth endpoints for anticipation, launch, return and settling.
                return a+(b-a)*(3*t*t-2*t*t*t)
        return values[-1][1]

    def line_path(points, y):
        points = [[11+x*30, 11+v*30+y] for x, v in points]
        data = points[0][:]
        for previous, following in zip(points, points[1:]):
            data += previous+following+following
        return {'closed': False, 'points': [round(p, 5) for p in data]}

    tracks = []
    for name, paths in [('tray', [[(.28, .40), (.18, .40), (.18, .88), (.82, .88), (.82, .40), (.72, .40)]]),
                        ('arrow', [[(.50, .65), (.50, .14)], [(.33, .31), (.50, .14), (.67, .31)]])]:
        track = {'name': name, 'stroke': True, 'evenOdd': False, 'lineCap': 2, 'lineJoin': 2, 'frames': []}
        for frame in range(40):
            y = sample('arrowY' if name == 'arrow' else 'trayY', frame)
            opacity = sample('arrowOpacity', frame) if name == 'arrow' else 1
            track['frames'].append({'opacity': round(opacity, 6), 'width': 1.9,
                                    'contours': [line_path(p, y) for p in paths]})
        tracks.append(track)
    return {'version': 1, 'canvas': [52, 52], 'duration': 39/60,
            'sourceSHA256': hashlib.sha256(json.dumps(keys, sort_keys=True).encode()).hexdigest(),
            'sourceCommit': 'iPadn-original', 'tracks': tracks}


def _cubic_circle(cx, cy, rx, ry, rot=0.0):
    """4-segment cubic Bezier ellipse rotated by `rot` radians around (cx, cy)."""
    k = 0.55228475
    raw = [
        (rx, 0.0), (rx, k * ry), (k * rx, ry), (0.0, ry),
        (-k * rx, ry), (-rx, k * ry), (-rx, 0.0),
        (-rx, -k * ry), (-k * rx, -ry), (0.0, -ry),
        (k * rx, -ry), (rx, -k * ry), (rx, 0.0),
    ]
    co, si = math.cos(rot), math.sin(rot)
    pts = []
    for x, y in raw:
        pts.extend([round(cx + x * co - y * si, 5), round(cy + x * si + y * co, 5)])
    return {'closed': True, 'points': pts}


def _rounded_polygon(verts, radii, closed=True):
    """Polygon converted to smooth rounded cubic corner arcs + straight cubic edges."""
    n = len(verts)
    assert n >= 3 and len(radii) == n
    k = 0.55228475
    corners = []
    for i in range(n):
        p_prev = verts[(i - 1) % n]
        p_curr = verts[i]
        p_next = verts[(i + 1) % n]
        r = radii[i]
        v1 = (p_prev[0] - p_curr[0], p_prev[1] - p_curr[1])
        v2 = (p_next[0] - p_curr[0], p_next[1] - p_curr[1])
        l1 = math.hypot(*v1) or 1.0
        l2 = math.hypot(*v2) or 1.0
        d1 = min(r, l1 * 0.42)
        d2 = min(r, l2 * 0.42)
        a = (p_curr[0] + v1[0] / l1 * d1, p_curr[1] + v1[1] / l1 * d1)
        b = (p_curr[0] + v2[0] / l2 * d2, p_curr[1] + v2[1] / l2 * d2)
        c1 = (a[0] + (p_curr[0] - a[0]) * k, a[1] + (p_curr[1] - a[1]) * k)
        c2 = (b[0] + (p_curr[0] - b[0]) * k, b[1] + (p_curr[1] - b[1]) * k)
        corners.append((a, c1, c2, b))
    pts = [round(corners[0][0][0], 5), round(corners[0][0][1], 5)]
    for i in range(n):
        a, c1, c2, b = corners[i]
        nxt = corners[(i + 1) % n][0]
        pts.extend([round(c1[0], 5), round(c1[1], 5),
                    round(c2[0], 5), round(c2[1], 5),
                    round(b[0], 5), round(b[1], 5)])
        l1 = (b[0] + (nxt[0] - b[0]) / 3.0, b[1] + (nxt[1] - b[1]) / 3.0)
        l2 = (b[0] + (nxt[0] - b[0]) * 2.0 / 3.0, b[1] + (nxt[1] - b[1]) * 2.0 / 3.0)
        pts.extend([round(l1[0], 5), round(l1[1], 5),
                    round(l2[0], 5), round(l2[1], 5),
                    round(nxt[0], 5), round(nxt[1], 5)])
    return {'closed': closed, 'points': pts}


def _interp_keys(keys, frame):
    if frame <= keys[0][0]:
        return keys[0][1]
    for (t0, a), (t1, b) in zip(keys, keys[1:]):
        if frame <= t1:
            t = (frame - t0) / (t1 - t0)
            s = t * t * (3.0 - 2.0 * t)
            return a + (b - a) * s
    return keys[-1][1]


def _cubic_segment(p0, c1, c2, p1):
    return [round(p0[0], 5), round(p0[1], 5),
            round(c1[0], 5), round(c1[1], 5),
            round(c2[0], 5), round(c2[1], 5),
            round(p1[0], 5), round(p1[1], 5)]


def compile_tab_search():
    """Original iPadn Tab Search icon: loupe tilt + whip handle + inner glint sweep."""
    frames_count = 31
    angle_keys = [(0, 0.0), (5, -14.0), (14, 16.0), (22, -5.0), (27, 1.5), (30, 0.0)]
    handle_lag_keys = [(0, 0.0), (6, -10.0), (15, 21.0), (23, -7.0), (28, 2.0), (30, 0.0)]
    scale_keys = [(0, 1.0), (5, 0.94), (14, 1.06), (22, 0.985), (30, 1.0)]
    dx_keys = [(0, 0.0), (5, -1.3), (14, 1.6), (22, -0.5), (30, 0.0)]
    dy_keys = [(0, 0.0), (5, 0.7), (14, -1.4), (22, 0.4), (30, 0.0)]
    glint_alpha_keys = [(0, 0.0), (6, 0.0), (12, 0.78), (20, 0.55), (27, 0.0), (30, 0.0)]
    glint_sweep_keys = [(0, -2.55), (6, -2.55), (17, -1.85), (27, -1.35), (30, -1.35)]

    rest_cx, rest_cy, rest_r = 22.0, 22.0, 13.8
    lens_frames, handle_frames, glint_frames = [], [], []
    for f in range(frames_count):
        a = math.radians(_interp_keys(angle_keys, f))
        hl = math.radians(_interp_keys(handle_lag_keys, f))
        sc = _interp_keys(scale_keys, f)
        cx = rest_cx + _interp_keys(dx_keys, f)
        cy = rest_cy + _interp_keys(dy_keys, f)
        r = rest_r * sc
        lens_frames.append({
            'opacity': 1.0,
            'width': 3.8,
            'contours': [_cubic_circle(cx, cy, r, r, rot=a)],
        })
        h_angle = math.radians(45.0) + a * 0.5 + (hl - a) * 0.45
        p0 = (cx + r * math.cos(h_angle), cy + r * math.sin(h_angle))
        p_mid = (cx + (r + 5.6) * math.cos(h_angle + (hl - a) * 0.25),
                 cy + (r + 5.6) * math.sin(h_angle + (hl - a) * 0.25))
        p1 = (cx + (r + 12.2) * math.cos(h_angle + (hl - a) * 0.55),
              cy + (r + 12.2) * math.sin(h_angle + (hl - a) * 0.55))
        handle_frames.append({
            'opacity': 1.0,
            'width': 3.9,
            'contours': [{'closed': False, 'points': _cubic_segment(p0, p_mid, p_mid, p1)}],
        })
        g_start = _interp_keys(glint_sweep_keys, f) + a * 0.4
        g_end = g_start + 0.85
        gr = r - 4.4
        k_arc = (4.0 / 3.0) * math.tan((g_end - g_start) / 4.0)
        ga0 = (cx + gr * math.cos(g_start), cy + gr * math.sin(g_start))
        ga1 = (cx + gr * math.cos(g_end), cy + gr * math.sin(g_end))
        gc1 = (ga0[0] - k_arc * gr * math.sin(g_start), ga0[1] + k_arc * gr * math.cos(g_start))
        gc2 = (ga1[0] + k_arc * gr * math.sin(g_end), ga1[1] - k_arc * gr * math.cos(g_end))
        glint_frames.append({
            'opacity': round(_interp_keys(glint_alpha_keys, f), 6),
            'width': 2.5,
            'contours': [{'closed': False, 'points': _cubic_segment(ga0, gc1, gc2, ga1)}],
        })

    return {
        'version': 1,
        'canvas': [52, 52],
        'duration': (frames_count - 1) / 60.0,
        'sourceSHA256': hashlib.sha256(b'iPadn-original-tab-search-v1').hexdigest(),
        'sourceCommit': 'iPadn-original',
        'tracks': [
            {'name': 'lens', 'stroke': True, 'evenOdd': False, 'lineCap': 2, 'lineJoin': 2, 'frames': lens_frames},
            {'name': 'handle', 'stroke': True, 'evenOdd': False, 'lineCap': 2, 'lineJoin': 2, 'frames': handle_frames},
            {'name': 'glint', 'stroke': True, 'evenOdd': False, 'lineCap': 2, 'lineJoin': 2, 'frames': glint_frames},
        ],
    }


def compile_tab_downloads():
    """Original iPadn Tab Downloads icon: cushioned badge circle + continuous conveyor arrow drop."""
    frames_count = 32
    circle_dy_keys = [(0, 0.0), (5, -0.8), (15, 1.6), (22, 0.9), (27, -0.35), (31, 0.0)]
    circle_ry_keys = [(0, 20.5), (5, 21.1), (15, 19.6), (22, 20.0), (27, 20.8), (31, 20.5)]
    out_y_keys = [(0, 0.0), (5, -2.0), (14, 12.8), (31, 12.8)]
    out_sy_keys = [(0, 1.0), (5, 0.96), (9, 1.10), (14, 0.002), (31, 0.002)]
    out_sx_keys = [(0, 1.0), (5, 1.04), (9, 0.88), (14, 0.35), (31, 0.35)]
    in_y_keys = [(0, -12.8), (13, -12.8), (22, 1.6), (27, -0.6), (31, 0.0)]
    in_sy_keys = [(0, 0.002), (13, 0.002), (19, 1.08), (24, 0.95), (31, 1.0)]
    in_sx_keys = [(0, 0.35), (13, 0.35), (19, 0.92), (24, 1.05), (31, 1.0)]

    # Crisp symmetric downward chevron-shaft arrow (9 vertices, rounded softly at corners)
    base_arrow = [
        (-2.15, -9.2), (2.15, -9.2), (2.15, 1.2), (6.5, -3.1),
        (9.1, -0.5), (0.0, 8.8), (-9.1, -0.5), (-6.5, -3.1), (-2.15, 1.2),
    ]
    base_radii = [1.0, 1.0, 0.4, 0.9, 0.9, 1.1, 0.9, 0.9, 0.4]

    def arrow_contour(cy, sx, sy):
        verts = [(26.0 + x * sx, cy + y * sy) for x, y in base_arrow]
        rads = [r * min(sx, sy) for r in base_radii]
        return _rounded_polygon(verts, rads)

    frames = []
    for f in range(frames_count):
        cdy = _interp_keys(circle_dy_keys, f)
        cry = _interp_keys(circle_ry_keys, f)
        crx = (20.5 * 20.5) / cry
        c_outer = _cubic_circle(26.0, 26.0 + cdy, crx, cry)
        c_out = arrow_contour(26.0 + cdy + _interp_keys(out_y_keys, f),
                              _interp_keys(out_sx_keys, f),
                              _interp_keys(out_sy_keys, f))
        c_in = arrow_contour(26.0 + cdy + _interp_keys(in_y_keys, f),
                             _interp_keys(in_sx_keys, f),
                             _interp_keys(in_sy_keys, f))
        frames.append({'opacity': 1.0, 'width': 0.0, 'contours': [c_outer, c_out, c_in]})

    return {
        'version': 1,
        'canvas': [52, 52],
        'duration': (frames_count - 1) / 60.0,
        'sourceSHA256': hashlib.sha256(b'iPadn-original-tab-downloads-v1').hexdigest(),
        'sourceCommit': 'iPadn-original',
        'tracks': [
            {'name': 'badge', 'stroke': False, 'evenOdd': True, 'lineCap': 1, 'lineJoin': 1, 'frames': frames},
        ],
    }


def compile_tab_purchased():
    """Original iPadn Tab Purchased icon: weighted bag pendulum swing + elastic handle."""
    frames_count = 33
    swing_keys = [(0, 0.0), (5, -7.5), (12, 11.5), (20, -6.0), (26, 2.5), (30, -0.7), (32, 0.0)]
    lift_keys = [(0, 0.0), (5, -1.8), (12, 0.4), (20, -0.5), (27, 0.2), (32, 0.0)]
    shear_keys = [(0, 0.0), (5, 1.1), (12, -1.7), (20, 0.9), (26, -0.35), (32, 0.0)]

    pivot = (26.0, 19.0)
    bag_verts = [(-14.2, 0.0), (14.2, 0.0), (16.2, 25.0), (-16.2, 25.0)]
    bag_radii = [3.2, 3.2, 5.2, 5.2]

    handle_frames, bag_frames = [], []
    for f in range(frames_count):
        ang = math.radians(_interp_keys(swing_keys, f))
        dy = _interp_keys(lift_keys, f)
        sh = _interp_keys(shear_keys, f)
        co, si = math.cos(ang), math.sin(ang)

        transformed = []
        for idx, (vx, vy) in enumerate(bag_verts):
            lx = vx + (sh if idx >= 2 else 0.0)
            ly = vy
            rx = pivot[0] + lx * co - ly * si
            ry = pivot[1] + dy + lx * si + ly * co
            transformed.append((rx, ry))
        bag_frames.append({
            'opacity': 1.0,
            'width': 0.0,
            'contours': [_rounded_polygon(transformed, bag_radii)],
        })

        ha = ang * 0.35
        hco, hsi = math.cos(ha), math.sin(ha)
        arch_lift = -dy * 0.45
        p0_local = (-6.8, 0.5)
        p1_local = (6.8, 0.5)
        c1_local = (-6.8, -11.5 - arch_lift)
        c2_local = (6.8, -11.5 - arch_lift)

        def rot_h(pt):
            return (pivot[0] + pt[0] * hco - pt[1] * hsi,
                    pivot[1] + dy + pt[0] * hsi + pt[1] * hco)

        handle_frames.append({
            'opacity': 1.0,
            'width': 3.4,
            'contours': [{'closed': False, 'points': _cubic_segment(rot_h(p0_local), rot_h(c1_local), rot_h(c2_local), rot_h(p1_local))}],
        })

    return {
        'version': 1,
        'canvas': [52, 52],
        'duration': (frames_count - 1) / 60.0,
        'sourceSHA256': hashlib.sha256(b'iPadn-original-tab-purchased-v1').hexdigest(),
        'sourceCommit': 'iPadn-original',
        'tracks': [
            {'name': 'handle', 'stroke': True, 'evenOdd': False, 'lineCap': 2, 'lineJoin': 2, 'frames': handle_frames},
            {'name': 'bag', 'stroke': False, 'evenOdd': False, 'lineCap': 1, 'lineJoin': 1, 'frames': bag_frames},
        ],
    }


def compile_tab_account():
    """Original iPadn Tab Account icon: outer badge + expressive head & lagged shoulder motion."""
    frames_count = 33
    head_dx_keys = [(0, 0.0), (5, -2.0), (13, 2.2), (21, -0.8), (28, 0.25), (32, 0.0)]
    head_dy_keys = [(0, 0.0), (5, 0.7), (13, -0.6), (21, 0.25), (32, 0.0)]
    sh_dx_keys = [(0, 0.0), (7, -1.4), (15, 1.5), (23, -0.5), (29, 0.15), (32, 0.0)]
    sh_dy_keys = [(0, 0.0), (7, -0.4), (15, 0.5), (23, -0.2), (32, 0.0)]
    sh_rot_keys = [(0, 0.0), (7, -6.0), (15, 6.0), (23, -2.0), (32, 0.0)]
    ring_ry_keys = [(0, 20.5), (5, 20.1), (13, 20.8), (22, 20.3), (32, 20.5)]

    def shoulder_contour(dx, dy, rot_deg):
        """Smooth shoulder crescent kept strictly inside r=16.5 concentric to (26, 26)."""
        rot = math.radians(rot_deg)
        co, si = math.cos(rot), math.sin(rot)
        cx, cy = 26.0, 26.0

        def clamp_point(x, y):
            vx, vy = (x * co - y * si) + dx, (x * si + y * co) + dy
            dist = math.hypot(vx, vy)
            max_r = 16.4
            if dist > max_r:
                s = max_r / dist
                vx, vy = vx * s, vy * s
            return (cx + vx, cy + vy)

        # Sample smooth 8-point rounded shoulder crescent in local coords relative to (26, 26)
        local_pts = [
            (-11.2, 9.2), (-8.8, 3.8), (-4.0, 2.3), (0.0, 2.2),
            (4.0, 2.3), (8.8, 3.8), (11.2, 9.2), (6.5, 14.0),
            (0.0, 15.6), (-6.5, 14.0),
        ]
        verts = [clamp_point(px, py) for px, py in local_pts]
        rads = [1.8, 2.2, 1.6, 1.4, 1.6, 2.2, 1.8, 2.0, 2.0, 2.0]
        return _rounded_polygon(verts, rads)

    frames = []
    for f in range(frames_count):
        ry = _interp_keys(ring_ry_keys, f)
        rx = (20.5 * 20.5) / ry
        c_ring = _cubic_circle(26.0, 26.0, rx, ry)
        c_head = _cubic_circle(26.0 + _interp_keys(head_dx_keys, f),
                               19.6 + _interp_keys(head_dy_keys, f),
                               5.6, 5.6)
        c_shoulders = shoulder_contour(_interp_keys(sh_dx_keys, f),
                                       _interp_keys(sh_dy_keys, f),
                                       _interp_keys(sh_rot_keys, f))
        frames.append({'opacity': 1.0, 'width': 0.0, 'contours': [c_ring, c_head, c_shoulders]})

    return {
        'version': 1,
        'canvas': [52, 52],
        'duration': (frames_count - 1) / 60.0,
        'sourceSHA256': hashlib.sha256(b'iPadn-original-tab-account-v1').hexdigest(),
        'sourceCommit': 'iPadn-original',
        'tracks': [
            {'name': 'account', 'stroke': False, 'evenOdd': True, 'lineCap': 1, 'lineJoin': 1, 'frames': frames},
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        OUTPUT.mkdir(parents=True, exist_ok=True)
    generators = [
        ('trash.json', lambda: compile_asset(SOURCE / 'anim_delete.json')),
        ('share.json', compile_share),
        ('tab_search.json', compile_tab_search),
        ('tab_downloads.json', compile_tab_downloads),
        ('tab_purchased.json', compile_tab_purchased),
        ('tab_account.json', compile_tab_account),
    ]
    for target, build in generators:
        asset = build()
        encoded = json.dumps(asset, separators=(',', ':'), ensure_ascii=False)+'\n'
        destination = OUTPUT/target
        if args.check:
            assert destination.read_text(encoding='utf-8') == encoded, f'Stale asset: {target}'
        else:
            destination.write_text(encoded, encoding='utf-8')
        print(f'{target}: {len(asset["tracks"])} tracks, {len(asset["tracks"][0]["frames"])} frames, {asset["duration"]:.3f}s, {len(encoded):,} bytes')


if __name__ == '__main__':
    main()
