#!/usr/bin/env python3
"""
SSH Botnet Lab — Defense Data Visualizer
One figure per scenario showing all defenses side-by-side.

Usage:
    python3 visualize_defense_data.py            # interactive
    python3 visualize_defense_data.py --save     # save PNGs to defense_charts/
    python3 visualize_defense_data.py --data-dir /path/to/Data --save
"""

import re
import json
import sys
import argparse
from pathlib import Path

import matplotlib
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.gridspec as gridspec
import matplotlib.ticker as mticker
import numpy as np

# ── Config ────────────────────────────────────────────────────────────────────

BASE_DIR = Path(__file__).parent / 'Data'
OUT_DIR  = Path(__file__).parent / 'defense_charts'

TESTS = [
    '0_baseline',
    '1_fail2ban',
    '2_block_ip',
    '3_rate_limit',
    '4_disable_password',
    '5_fail2ban+rate_limit',
    '6_all_defenses',
]

LABELS = {
    '0_baseline':           'Baseline',
    '1_fail2ban':           'fail2ban',
    '2_block_ip':           'Block IP',
    '3_rate_limit':         'Rate Limit',
    '4_disable_password':   'Disable\nPwd',
    '5_fail2ban+rate_limit':'f2b +\nRate',
    '6_all_defenses':       'All\nDefenses',
}

SHORT = [LABELS[t] for t in TESTS]

SCENARIO_COLORS = {1: '#22c55e', 2: '#3b82f6', 3: '#f97316', 4: '#a855f7'}

STYLE = {
    'bg':       '#1e1e2e',
    'panel':    '#242438',
    'panel2':   '#2a2a42',
    'text':     '#cdd6f4',
    'subtext':  '#7c7f9e',
    'grid':     '#383858',
    'failed':   '#ef4444',
    'accepted': '#50fa7b',
    'comp':     '#ffb86c',
    'net':      '#14b8a6',
    'pivot_y':  '#ef4444',
    'pivot_n':  '#2a3050',
    'table_hd': '#383858',
    'table_ok': '#1a3328',
    'table_base':'#2d2d46',
}

# ── Data loading ──────────────────────────────────────────────────────────────

def find_scenarios(base):
    scenes = {}
    for d in sorted(base.glob('Scenes*Data')):
        m = re.match(r'Scenes(\d+)Data', d.name)
        if m:
            scenes[int(m.group(1))] = d
    return scenes


def parse_comparison(scene_dir):
    path = scene_dir / 'comparison.txt'
    if not path.exists():
        return {}
    rows = {}
    for line in path.read_text().splitlines():
        if '─' in line or line.strip().startswith('Test'):
            continue
        m = re.match(r'^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(YES|NO)', line.strip())
        if m:
            rows[m.group(1)] = {
                'test':        m.group(1),
                'v1_failed':   int(m.group(2)),
                'v1_accepted': int(m.group(3)),
                'compromised': int(m.group(4)),
                'pivoted':     m.group(5) == 'YES',
            }
    return rows


def load_scenario(scene_dir):
    data = parse_comparison(scene_dir)
    for test in TESTS:
        if test not in data:
            data[test] = {'test': test, 'v1_failed': 0, 'v1_accepted': 0,
                          'compromised': 0, 'pivoted': False, 'nets': 0, 'hosts': []}
        path = scene_dir / test / 'gui_report.json'
        if path.exists():
            try:
                rep = json.loads(path.read_text())
                data[test]['nets']  = rep['stats'].get('nets', 0)
                data[test]['hosts'] = rep.get('hosts', [])
            except Exception:
                data[test].setdefault('nets', 0)
                data[test].setdefault('hosts', [])
        else:
            data[test].setdefault('nets', 0)
            data[test].setdefault('hosts', [])

        # per-victim auth counts from auth logs
        victims = {}
        for log in sorted((scene_dir / test).glob('*_auth.log')) if (scene_dir / test).exists() else []:
            name = log.stem  # e.g. victim1
            txt = log.read_text(errors='ignore').splitlines()
            victims[name] = {
                'failed':   sum(1 for l in txt if 'Failed password'   in l),
                'accepted': sum(1 for l in txt if 'Accepted password' in l),
            }
        data[test]['victims'] = victims
    return data

# ── Style helpers ─────────────────────────────────────────────────────────────

def style_ax(ax):
    ax.set_facecolor(STYLE['panel'])
    ax.tick_params(colors=STYLE['text'], labelsize=8)
    ax.xaxis.label.set_color(STYLE['text'])
    ax.yaxis.label.set_color(STYLE['text'])
    ax.title.set_color(STYLE['text'])
    for sp in ax.spines.values():
        sp.set_edgecolor(STYLE['grid'])
    ax.grid(axis='y', color=STYLE['grid'], linewidth=0.5, linestyle='--', zorder=0)
    ax.set_axisbelow(True)


def bar_val(ax, bars, color=None):
    for b in bars:
        h = b.get_height()
        if h > 0:
            ax.text(b.get_x() + b.get_width() / 2, h + 0.05,
                    f'{int(h)}', ha='center', va='bottom',
                    fontsize=7.5, color=color or STYLE['text'], fontweight='bold')

# ── Per-scenario individual charts ───────────────────────────────────────────

def _title(fig, snum, color, subtitle):
    fig.suptitle(
        f'Scenario {snum} — {subtitle}',
        color=color, fontsize=13, fontweight='bold',
    )


def chart_compromised(snum, data, color, save):
    fig, ax = plt.subplots(figsize=(10, 5), facecolor=STYLE['bg'])
    _title(fig, snum, color, 'Compromised Hosts per Defense')
    style_ax(ax)
    x = np.arange(len(TESTS))
    vals = [data[t]['compromised'] for t in TESTS]
    bars = ax.bar(x, vals, color=color, alpha=0.85,
                  edgecolor='#00000044', linewidth=0.6, zorder=3)
    bars[0].set_color('#888aab')
    bar_val(ax, bars, STYLE['text'])
    ax.set_xticks(x); ax.set_xticklabels(SHORT, fontsize=9)
    ax.set_ylabel('Hosts Compromised', color=STYLE['text'])
    ax.yaxis.set_major_locator(mticker.MaxNLocator(integer=True))
    ax.set_ylim(0, max(vals) * 1.3 + 0.5)
    fig.tight_layout()
    _save(fig, f'scenario_{snum}_compromised.png', save)


def chart_auth(snum, data, color, save):
    fig, ax = plt.subplots(figsize=(10, 5), facecolor=STYLE['bg'])
    _title(fig, snum, color, 'Victim1 — Failed vs Accepted Logins')
    style_ax(ax)
    x = np.arange(len(TESTS))
    failed   = [data[t]['v1_failed']   for t in TESTS]
    accepted = [data[t]['v1_accepted'] for t in TESTS]
    w = 0.36
    b1 = ax.bar(x - w/2, failed,   w, label='Failed',
                color=STYLE['failed'],   edgecolor='#00000044', linewidth=0.6, zorder=3)
    b2 = ax.bar(x + w/2, accepted, w, label='Accepted',
                color=STYLE['accepted'], edgecolor='#00000044', linewidth=0.6, zorder=3)
    bar_val(ax, b1, STYLE['failed'])
    bar_val(ax, b2, STYLE['accepted'])
    ax.set_xticks(x); ax.set_xticklabels(SHORT, fontsize=9)
    ax.set_ylabel('SSH Auth Attempts (victim1)', color=STYLE['text'])
    ax.legend(facecolor=STYLE['panel2'], edgecolor=STYLE['grid'],
              labelcolor=STYLE['text'], fontsize=9, loc='upper right')
    ax.set_ylim(0, max(max(failed), max(accepted), 1) * 1.3)
    fig.tight_layout()
    _save(fig, f'scenario_{snum}_auth.png', save)


def chart_networks(snum, data, color, save):
    fig, ax = plt.subplots(figsize=(10, 5), facecolor=STYLE['bg'])
    _title(fig, snum, color, 'Network Reach (Pivot Depth)')
    style_ax(ax)
    x = np.arange(len(TESTS))
    nets = [data[t]['nets'] for t in TESTS]
    bn = ax.bar(x, nets, color=STYLE['net'], alpha=0.85,
                edgecolor='#00000044', linewidth=0.6, zorder=3)
    bn[0].set_color('#888aab')
    bar_val(ax, bn, STYLE['net'])
    ax.set_xticks(x); ax.set_xticklabels(SHORT, fontsize=9)
    ax.set_ylabel('Networks Discovered', color=STYLE['text'])
    ax.yaxis.set_major_locator(mticker.MaxNLocator(integer=True))
    ax.set_ylim(0, max(nets) * 1.3 + 0.5)
    fig.tight_layout()
    _save(fig, f'scenario_{snum}_networks.png', save)


def chart_pivot(snum, data, color, save):
    fig, ax = plt.subplots(figsize=(10, 5), facecolor=STYLE['bg'])
    _title(fig, snum, color, 'Pivot / Lateral Movement Detected')
    style_ax(ax)
    x = np.arange(len(TESTS))
    pv = [1 if data[t]['pivoted'] else 0 for t in TESTS]
    ax.bar(x, pv,
           color=[STYLE['pivot_y'] if v else STYLE['pivot_n'] for v in pv],
           edgecolor='#00000044', linewidth=0.6, zorder=3)
    ax.set_xticks(x); ax.set_xticklabels(SHORT, fontsize=9)
    ax.set_yticks([0, 1]); ax.set_yticklabels(['No', 'Yes'], fontsize=10)
    ax.set_ylabel('Lateral Movement', color=STYLE['text'])
    ax.set_ylim(-0.1, 1.5)
    for i, v in enumerate(pv):
        ax.text(i, v + 0.08, '✓' if v else '✗',
                ha='center', fontsize=13,
                color=STYLE['pivot_y'] if v else '#50fa7b',
                fontweight='bold')
    fig.tight_layout()
    _save(fig, f'scenario_{snum}_pivot.png', save)


def chart_heatmap(snum, data, color, save):
    all_victims = sorted({v for t in TESTS for v in data[t]['victims']})
    if not all_victims:
        return
    n_v, n_t = len(all_victims), len(TESTS)
    mat_f = np.zeros((n_v, n_t))
    mat_a = np.zeros((n_v, n_t))
    for j, test in enumerate(TESTS):
        for i, vic in enumerate(all_victims):
            d = data[test]['victims'].get(vic, {})
            mat_f[i, j] = d.get('failed',   0)
            mat_a[i, j] = d.get('accepted', 0)

    fig, ax = plt.subplots(figsize=(13, max(4, n_v * 1.1)), facecolor=STYLE['bg'])
    _title(fig, snum, color, 'Per-Victim Auth Log Heatmap  (cell = failed / accepted)')
    ax.set_facecolor(STYLE['panel'])

    max_f = max(mat_f.max(), 1)
    for i in range(n_v):
        for j in range(n_t):
            f = mat_f[i, j]; a = mat_a[i, j]
            intensity = f / max_f
            cell_color = (
                0.12 + 0.60 * intensity,
                0.12 - 0.05 * intensity,
                0.22 - 0.10 * intensity,
            )
            rect = plt.Rectangle([j - 0.5, i - 0.5], 1, 1,
                                  facecolor=cell_color, edgecolor=STYLE['bg'],
                                  linewidth=1.2)
            ax.add_patch(rect)
            txt_color = '#ffffff' if intensity > 0.3 else STYLE['subtext']
            ax.text(j, i, f'{int(f)}\n/{int(a)}', ha='center', va='center',
                    fontsize=8, color=txt_color, fontweight='bold')

    ax.set_xlim(-0.5, n_t - 0.5)
    ax.set_ylim(-0.5, n_v - 0.5)
    ax.set_xticks(range(n_t)); ax.set_xticklabels(SHORT, fontsize=9, color=STYLE['text'])
    ax.set_yticks(range(n_v)); ax.set_yticklabels(all_victims, fontsize=9, color=STYLE['text'])
    ax.tick_params(length=0)
    for sp in ax.spines.values():
        sp.set_visible(False)
    legend_el = [
        mpatches.Patch(facecolor='#2d0808', label='Low failed'),
        mpatches.Patch(facecolor='#8b1010', label='High failed'),
        mpatches.Patch(facecolor=STYLE['panel2'], label='Cell: failed / accepted'),
    ]
    ax.legend(handles=legend_el, loc='lower right',
              facecolor=STYLE['panel2'], edgecolor=STYLE['grid'],
              labelcolor=STYLE['text'], fontsize=8)
    fig.tight_layout()
    _save(fig, f'scenario_{snum}_heatmap.png', save)


def chart_table(snum, data, color, save):
    fig, ax = plt.subplots(figsize=(12, 4), facecolor=STYLE['bg'])
    _title(fig, snum, color, 'Summary Table')
    ax.axis('off'); ax.set_facecolor(STYLE['bg'])

    col_hdrs = ['Defense', 'v1 Failed', 'v1 Accepted', 'Compromised', 'Networks', 'Pivoted']
    rows, row_colors = [], []
    for test in TESTS:
        d = data[test]
        piv = d['pivoted']; comp = d['compromised']
        rows.append([
            LABELS[test].replace('\n', ' '),
            str(d['v1_failed']), str(d['v1_accepted']),
            str(comp), str(d['nets']),
            'YES' if piv else 'NO',
        ])
        if test == '0_baseline':
            bg = STYLE['table_base']
        elif comp == 0 and not piv:
            bg = STYLE['table_ok']
        else:
            bg = STYLE['panel2']
        row_colors.append([bg] * len(col_hdrs))

    tbl = ax.table(cellText=rows, colLabels=col_hdrs, cellLoc='center',
                   loc='center', cellColours=row_colors, bbox=[0, 0, 1, 1])
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(10)
    tbl.scale(1, 2.0)

    for (r, c), cell in tbl.get_celld().items():
        cell.set_edgecolor(STYLE['grid'])
        if r == 0:
            cell.set_facecolor(STYLE['table_hd'])
            cell.set_text_props(color=STYLE['text'], fontweight='bold')
        else:
            txt = cell.get_text().get_text()
            if c == 5:
                cell.set_text_props(
                    color=STYLE['pivot_y'] if txt == 'YES' else '#50fa7b',
                    fontweight='bold')
            elif c == 3 and txt != '0':
                cell.set_text_props(color=STYLE['comp'], fontweight='bold')
            else:
                cell.set_text_props(color=STYLE['text'])

    fig.tight_layout()
    _save(fig, f'scenario_{snum}_table.png', save)


def make_scenario_charts(snum, data, color, save):
    chart_compromised(snum, data, color, save)
    chart_auth(snum, data, color, save)
    chart_networks(snum, data, color, save)
    chart_pivot(snum, data, color, save)
    chart_heatmap(snum, data, color, save)
    chart_table(snum, data, color, save)

# ── Output ────────────────────────────────────────────────────────────────────

def _save(fig, name, save):
    if save:
        OUT_DIR.mkdir(exist_ok=True)
        path = OUT_DIR / name
        fig.savefig(path, dpi=150, bbox_inches='tight', facecolor=STYLE['bg'])
        print(f'  saved → {path}')
        plt.close(fig)
    else:
        plt.show()
        plt.close(fig)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--save', action='store_true',
                        help='Save PNGs to defense_charts/')
    parser.add_argument('--data-dir', default=str(BASE_DIR),
                        help='Path to Data/ folder')
    args = parser.parse_args()

    if args.save:
        plt.switch_backend('Agg')

    base   = Path(args.data_dir)
    scenes = find_scenarios(base)
    if not scenes:
        print(f'No Scenes*Data folders found in {base}')
        sys.exit(1)

    print(f'Found scenarios: {sorted(scenes.keys())}')
    all_data = {}
    for snum, sdir in scenes.items():
        all_data[snum] = load_scenario(sdir)

    print('Generating per-scenario charts...')
    for snum, sdir in sorted(scenes.items()):
        color = SCENARIO_COLORS.get(snum, '#888aab')
        print(f'  Scenario {snum}...')
        make_scenario_charts(snum, all_data[snum], color, args.save)

    if args.save:
        print(f'\nAll charts saved to {OUT_DIR}/')

if __name__ == '__main__':
    main()
