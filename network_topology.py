#!/usr/bin/env python3
"""
SSH Botnet Lab — Network Topology Diagrams
Light theme, horizontal flow per network band.

Usage:
    python3 network_topology.py [--save]
"""
import argparse
from pathlib import Path
import matplotlib
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.lines import Line2D
import matplotlib.patches as mpatches

OUT_DIR = Path('defense_charts')

# ── Palette ────────────────────────────────────────────────────────────────────
BG  = '#f8fafc'
TXT = '#1e293b'
DIM = '#64748b'

NET = {
    '172.21': dict(fill='#dbeafe', border='#3b82f6', text='#1e40af'),
    '10.10':  dict(fill='#dcfce7', border='#16a34a', text='#14532d'),
    '10.20':  dict(fill='#ffedd5', border='#ea580c', text='#9a3412'),
    '10.30':  dict(fill='#ede9fe', border='#7c3aed', text='#4c1d95'),
}
NET_NAME   = {'172.21': 'attack_net',   '10.10': 'internal_net',
              '10.20':  'extra_net',    '10.30': 'deep_net'}
NET_SUBNET = {'172.21': '172.21.0.0/24', '10.10': '10.10.0.0/24',
              '10.20':  '10.20.0.0/24',  '10.30': '10.30.0.0/24'}

ROLE = {
    'attacker': dict(fill='#fee2e2', border='#ef4444'),
    'victim':   dict(fill='#ffffff', border='#94a3b8'),
    'pivot':    dict(fill='#fff7ed', border='#f97316'),
    'honeypot': dict(fill='#faf5ff', border='#a855f7'),
    'monitor':  dict(fill='#f0fdf4', border='#16a34a'),
}

# ── Layout constants (data units = inches) ─────────────────────────────────────
FW    = 10.0   # figure width
ML    = 0.40   # left/right margin
MT    = 0.65   # top margin (title area)
MB    = 0.30   # bottom margin
BP    = 0.22   # band inner padding
LH    = 0.38   # label row height inside band
BH    = 0.78   # host box height
BW    = 1.40   # host box width
BGAP  = 0.22   # gap between host boxes
BAND_H = BP + LH + BH + BP   # total band height = 1.60
INTER  = 0.48  # vertical gap between bands (arrow space)

# ── Scenario data ──────────────────────────────────────────────────────────────
# rows: list of row-specs.
#   Each row-spec is a list of band dicts (for side-by-side, len>1).
#   band dict keys:
#     net    – prefix key ('172.21', '10.10', ...)
#     hosts  – list of (ip, role, bold_name, dim_line)
#     dashed – True for downstream/isolated nets
#     note   – str appended to label row (or None)
#     w_frac – fraction of available width (default 1.0, use 0.5 for side-by-side)
#
# intra_arrows – arrows within a band: (src_ip, dst_ip, label, style)
#   style 'direct' → solid red arrow
# inter_arrows – arrows between bands: (src_ip, dst_net, label)
#   drawn as dashed orange arrow going downward

SCENARIOS = {
    1: dict(
        title='Scenario 1 — Single Network',
        subtitle='./start.sh 1  ·  No segmentation, all machines visible to attacker',
        rows=[
            [dict(net='172.21', dashed=False, note=None, w_frac=1.0, hosts=[
                ('172.21.0.10',  'attacker', 'ATTACKER\n172.21.0.10', 'Kali Linux'),
                ('172.21.0.20',  'victim',   'Victim 1',              '172.21.0.20'),
                ('172.21.0.21',  'victim',   'Victim 2',              '172.21.0.21'),
                ('172.21.0.22',  'victim',   'Victim 3',              '172.21.0.22'),
                ('172.21.0.100', 'monitor',  'Monitor',               '172.21.0.100 · IDS'),
            ])],
        ],
        intra_arrows=[
            ('172.21.0.10', '172.21.0.20', 'SSH brute-force', 'direct'),
            ('172.21.0.10', '172.21.0.21', None,              'direct'),
            ('172.21.0.10', '172.21.0.22', None,              'direct'),
        ],
        inter_arrows=[],
    ),
    2: dict(
        title='Scenario 2 — Two Networks (standard lab)',
        subtitle='./start.sh 2  ·  Attacker must pivot through victim1 to reach internal_net',
        rows=[
            [dict(net='172.21', dashed=False, note=None, w_frac=1.0, hosts=[
                ('172.21.0.10',  'attacker', 'ATTACKER\n172.21.0.10', 'Kali Linux'),
                ('172.21.0.20',  'pivot',    'Victim 1',              '172.21.0.20\npivot · dual-homed'),
                ('172.21.0.21',  'victim',   'Victim 2',              '172.21.0.21'),
                ('172.21.0.100', 'monitor',  'Monitor',               '172.21.0.100'),
            ])],
            [dict(net='10.10', dashed=True, note='only reachable via pivot', w_frac=1.0, hosts=[
                ('10.10.0.10', 'victim',   'Victim 3', '10.10.0.10'),
                ('10.10.0.50', 'honeypot', 'Honeypot', '10.10.0.50'),
            ])],
        ],
        intra_arrows=[
            ('172.21.0.10', '172.21.0.20', 'brute-force', 'direct'),
            ('172.21.0.10', '172.21.0.21', None,          'direct'),
        ],
        inter_arrows=[
            ('172.21.0.20', '10.10', 'pivot', 'pivot'),
        ],
    ),
    3: dict(
        title='Scenario 3 — Three Networks, Two Pivots',
        subtitle='./start.sh 3  ·  victim1 → internal_net   victim2 → extra_net',
        rows=[
            [dict(net='172.21', dashed=False, note=None, w_frac=1.0, hosts=[
                ('172.21.0.10',  'attacker', 'ATTACKER\n172.21.0.10', 'Kali Linux'),
                ('172.21.0.20',  'pivot',    'Victim 1',              '172.21.0.20\npivot 1'),
                ('172.21.0.21',  'pivot',    'Victim 2',              '172.21.0.21\npivot 2'),
                ('172.21.0.100', 'monitor',  'Monitor',               '172.21.0.100'),
            ])],
            [
                dict(net='10.10', dashed=True, note='only via pivot 1', w_frac=0.50, hosts=[
                    ('10.10.0.10', 'victim',   'Victim 3', '10.10.0.10'),
                    ('10.10.0.50', 'honeypot', 'Honeypot', '10.10.0.50'),
                ]),
                dict(net='10.20', dashed=True, note='only via pivot 2', w_frac=0.50, hosts=[
                    ('10.20.0.10', 'victim', 'Victim 4', '10.20.0.10'),
                    ('10.20.0.11', 'victim', 'Victim 5', '10.20.0.11'),
                ]),
            ],
        ],
        intra_arrows=[
            ('172.21.0.10', '172.21.0.20', 'brute-force both', 'direct'),
            ('172.21.0.10', '172.21.0.21', None,               'direct'),
        ],
        inter_arrows=[
            ('172.21.0.20', '10.10', 'pivot 1', 'pivot'),
            ('172.21.0.21', '10.20', 'pivot 2', 'pivot'),
        ],
    ),
    4: dict(
        title='Scenario 4 — Deep Chain (3 hops)',
        subtitle='./start.sh 4  ·  attacker → victim1 → victim3 → deep_net',
        rows=[
            [dict(net='172.21', dashed=False, note=None, w_frac=1.0, hosts=[
                ('172.21.0.10',  'attacker', 'ATTACKER\n172.21.0.10', 'Kali Linux'),
                ('172.21.0.20',  'pivot',    'Victim 1',              '172.21.0.20\nhop 1 · pivot'),
                ('172.21.0.21',  'victim',   'Victim 2',              '172.21.0.21'),
                ('172.21.0.100', 'monitor',  'Monitor',               '172.21.0.100'),
            ])],
            [dict(net='10.10', dashed=True, note=None, w_frac=1.0, hosts=[
                ('10.10.0.10', 'pivot',    'Victim 3', '10.10.0.10\nhop 2 · pivot'),
                ('10.10.0.50', 'honeypot', 'Honeypot', '10.10.0.50'),
            ])],
            [dict(net='10.30', dashed=True, note='deep_net  ·  only reachable from victim3', w_frac=1.0, hosts=[
                ('10.30.0.10', 'victim', 'victim4', '10.30.0.10'),
                ('10.30.0.11', 'victim', 'victim5', '10.30.0.11'),
            ])],
        ],
        intra_arrows=[
            ('172.21.0.10', '172.21.0.20', 'brute-force', 'direct'),
            ('172.21.0.10', '172.21.0.21', None,          'direct'),
        ],
        inter_arrows=[
            ('172.21.0.20', '10.10', 'hop 1', 'pivot'),
            ('10.10.0.10',  '10.30', 'hop 2', 'pivot'),
        ],
    ),
}

# ── Drawing helpers ────────────────────────────────────────────────────────────

def draw_host_box(ax, bx, by, ip, role, bold_name, dim_line):
    """Draw a single host box; return center-x, center-y, left-x, right-x."""
    sty = ROLE[role]
    rect = FancyBboxPatch((bx, by), BW, BH,
                          boxstyle='round,pad=0.05',
                          facecolor=sty['fill'], edgecolor=sty['border'],
                          linewidth=1.8, zorder=3)
    ax.add_patch(rect)
    cx = bx + BW / 2
    # Bold name (split on \n — two lines handled with offset)
    name_lines = bold_name.split('\n')
    if len(name_lines) == 1:
        ny = by + BH * 0.60
        ax.text(cx, ny, name_lines[0], ha='center', va='center',
                fontsize=9, fontweight='bold', color=TXT, zorder=4)
    else:
        ax.text(cx, by + BH * 0.74, name_lines[0], ha='center', va='center',
                fontsize=8, fontweight='bold', color=TXT, zorder=4)
        ax.text(cx, by + BH * 0.54, name_lines[1], ha='center', va='center',
                fontsize=7.5, fontweight='bold', color=sty['border'], zorder=4)
    # Dim sublabel
    dim_lines = dim_line.split('\n') if dim_line else []
    if len(dim_lines) == 1:
        ax.text(cx, by + BH * 0.22, dim_lines[0], ha='center', va='center',
                fontsize=7, color=DIM, fontfamily='monospace', zorder=4)
    elif len(dim_lines) == 2:
        ax.text(cx, by + BH * 0.30, dim_lines[0], ha='center', va='center',
                fontsize=7, color=DIM, fontfamily='monospace', zorder=4)
        ax.text(cx, by + BH * 0.10, dim_lines[1], ha='center', va='center',
                fontsize=6.5, color=sty['border'], fontfamily='monospace', zorder=4)
    return cx, by + BH / 2, bx, bx + BW


def draw_band(ax, band_x, band_y, band_w, band_def):
    """Draw one network band. Returns dict ip→(cx, cy, lx, rx, by, top_y)."""
    net    = band_def['net']
    hosts  = band_def['hosts']
    dashed = band_def['dashed']
    note   = band_def['note']
    ns     = NET[net]

    # Band background
    ls = (5, 4) if dashed else None
    rect = FancyBboxPatch((band_x, band_y), band_w, BAND_H,
                          boxstyle='round,pad=0.06',
                          facecolor=ns['fill'], edgecolor=ns['border'],
                          linewidth=1.6 if not dashed else 1.2,
                          linestyle='--' if dashed else '-',
                          zorder=0)
    ax.add_patch(rect)

    # Label row
    lbl_y = band_y + BAND_H - BP - LH / 2
    label = f"{NET_NAME[net]}  ·  {NET_SUBNET[net]}"
    ax.text(band_x + BP, lbl_y, label,
            ha='left', va='center',
            fontsize=8.5, color=ns['text'], fontweight='bold', zorder=2)
    if note:
        ax.text(band_x + band_w - BP, lbl_y, note,
                ha='right', va='center',
                fontsize=7.5, color=ns['border'], style='italic', zorder=2)

    # Host boxes
    host_y = band_y + BP
    host_x = band_x + BP
    positions = {}
    for ip, role, bold, dim in hosts:
        cx, cy, lx, rx = draw_host_box(ax, host_x, host_y, ip, role, bold, dim)
        positions[ip] = dict(cx=cx, cy=cy, lx=lx, rx=rx,
                             top=host_y + BH, bot=host_y,
                             band_top=band_y + BAND_H, band_bot=band_y)
        host_x += BW + BGAP

    return positions


def arrow(ax, x1, y1, x2, y2, color, lw=1.5, dashed=False, label=None, rad=0.0,
          label_t=0.25):
    style = dict(arrowstyle='->', color=color, lw=lw,
                 connectionstyle=f'arc3,rad={rad}')
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=style, zorder=5)
    if label:
        # Place label near the source end to avoid covering intermediate hosts
        lx = x1 + (x2 - x1) * label_t
        ly = y1 + (y2 - y1) * label_t
        # Shift down for downward-arcing arrows, up for upward
        vy = -0.10 - abs(rad) * 0.18 if rad <= 0 else 0.06 + abs(rad) * 0.18
        ax.text(lx, ly + vy, label, fontsize=7, color=color,
                ha='center', va='top' if rad <= 0 else 'bottom',
                style='italic', zorder=6)


def draw_intra_arrows(ax, arrows, positions):
    for src_ip, dst_ip, label, style in arrows:
        if src_ip not in positions or dst_ip not in positions:
            continue
        sp = positions[src_ip]
        dp = positions[dst_ip]
        color = '#ef4444' if style == 'direct' else '#f97316'
        # Dynamic curvature: farther targets arc more → fan-out from attacker
        dx = dp['cx'] - sp['cx']
        n_hops = dx / (BW + BGAP)
        rad = -(0.13 * n_hops) if sp['rx'] < dp['lx'] else (0.13 * abs(n_hops))
        arrow(ax, sp['rx'], sp['cy'], dp['lx'], dp['cy'],
              color=color, lw=1.6, label=label, rad=rad)


def draw_inter_arrows(ax, inter_arrows, all_positions, band_tops):
    """inter_arrows: list of (src_ip, dst_net, label, style)"""
    for src_ip, dst_net, label, style in inter_arrows:
        if src_ip not in all_positions:
            continue
        sp = all_positions[src_ip]
        dst_top = band_tops.get(dst_net)
        if dst_top is None:
            continue
        # Arrow from bottom of src host box down to top of destination band
        arrow(ax, sp['cx'], sp['bot'], sp['cx'], dst_top,
              color='#f97316', lw=1.5, dashed=True, label=label, rad=0.0)


def draw_scenario(snum, sc, save):
    rows   = sc['rows']
    title  = sc['title']
    sub    = sc['subtitle']

    # Compute figure height
    n_bands = sum(1 for row in rows for _ in row)
    n_rows  = len(rows)
    fig_h = MT + n_rows * BAND_H + (n_rows - 1) * INTER + MB

    fig, ax = plt.subplots(figsize=(FW, fig_h), facecolor=BG)
    ax.set_facecolor(BG)
    ax.set_xlim(0, FW)
    ax.set_ylim(0, fig_h)   # y upward
    ax.axis('off')

    # Title
    ax.text(FW / 2, fig_h - 0.12, title,
            ha='center', va='top', fontsize=13, fontweight='bold',
            color=TXT, fontfamily='sans-serif')
    ax.text(FW / 2, fig_h - 0.42, sub,
            ha='center', va='top', fontsize=8.5, color=DIM,
            fontfamily='monospace')

    # Draw bands top-to-bottom (in data coords y increases upward)
    avail_w = FW - ML - ML
    all_positions = {}   # ip → pos dict
    band_tops     = {}   # net → y of band's top edge

    cur_y = fig_h - MT - BAND_H  # top band starts here

    for row_idx, row in enumerate(rows):
        # row can have 1 or 2 bands (side-by-side)
        x_cursor = ML
        for band_def in row:
            w_frac = band_def.get('w_frac', 1.0)
            bw = avail_w * w_frac - (0.15 if len(row) > 1 else 0)
            positions = draw_band(ax, x_cursor, cur_y, bw, band_def)
            all_positions.update(positions)
            band_tops[band_def['net']] = cur_y + BAND_H   # top y
            # Store band bot for inter-arrow destination
            band_tops[band_def['net'] + '_bot'] = cur_y
            x_cursor += bw + 0.15

        if row_idx < len(rows) - 1:
            cur_y -= INTER + BAND_H
        else:
            cur_y -= BAND_H

    # Intra-band arrows
    draw_intra_arrows(ax, sc['intra_arrows'], all_positions)

    # Inter-band arrows (top of lower band)
    real_inter = []
    for src_ip, dst_net, label, style in sc['inter_arrows']:
        real_inter.append((src_ip, dst_net, label, style))

    # Re-map band_tops to use band BOTTOM (where arrow should land)
    band_bot_map = {net: band_tops[net + '_bot'] + BAND_H
                    for net in NET_NAME if net in {b['net'] for row in rows for b in row}}
    # We want arrows to land on TOP of the destination band
    dst_band_top = {}
    for row in rows:
        for b in row:
            dst_band_top[b['net']] = band_tops[b['net']]  # top of this band

    for src_ip, dst_net, label, _ in real_inter:
        if src_ip not in all_positions:
            continue
        sp  = all_positions[src_ip]
        top = dst_band_top.get(dst_net)
        if top is None:
            continue
        arrow(ax, sp['cx'], sp['bot'], sp['cx'], top,
              color='#f97316', lw=1.5, label=label, rad=0.0)

    # Legend
    legend_items = [
        mpatches.Patch(facecolor=v['fill'], edgecolor=v['border'], linewidth=1.5, label=k.upper())
        for k, v in ROLE.items()
    ] + [
        Line2D([0],[0], color='#ef4444', lw=1.6, label='Direct Attack'),
        Line2D([0],[0], color='#f97316', lw=1.5, linestyle='--', label='Pivot / Hop'),
    ]
    ax.legend(handles=legend_items, loc='lower right', ncol=2,
              facecolor='#ffffff', edgecolor='#cbd5e1',
              labelcolor=TXT, fontsize=7.5, handlelength=1.4)

    plt.tight_layout(pad=0.2)

    if save:
        OUT_DIR.mkdir(exist_ok=True)
        out = OUT_DIR / f'topology_scenario_{snum}.png'
        fig.savefig(out, dpi=150, bbox_inches='tight', facecolor=BG)
        print(f'  saved → {out}')
        plt.close(fig)
    else:
        plt.show()
        plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--save', action='store_true')
    ap.add_argument('--scenario', type=int, choices=[1, 2, 3, 4])
    args = ap.parse_args()
    if args.save:
        matplotlib.use('Agg')
    snums = [args.scenario] if args.scenario else [1, 2, 3, 4]
    for snum in snums:
        print(f'Scenario {snum}...')
        draw_scenario(snum, SCENARIOS[snum], args.save)
    if args.save:
        print('Done.')


if __name__ == '__main__':
    main()
