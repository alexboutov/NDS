"""
Generate HTML and PDF reports with embedded matplotlib charts for TTP Trend Candles3.3.
Reads trade data from a JSON file passed as argv[1], outputs HTML to argv[2].
PDF is auto-generated alongside the HTML (same name, .pdf extension).
"""
import sys
import json
import base64
import io
import os
from collections import defaultdict, OrderedDict
from datetime import datetime

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
from matplotlib.backends.backend_pdf import PdfPages

# --- Dark theme for all charts ---
COLORS = {
    'bg': '#0f1117', 'card': '#1a1d27', 'border': '#2a2d37',
    'text': '#cccccc', 'green': '#66bb6a', 'red': '#ef5350',
    'blue': '#4fc3f7', 'amber': '#ffa726', 'gold': '#ffd54f',
    'cyan': '#80deea', 'purple': '#ce93d8',
}
INSTR_COLORS = {
    'CL': COLORS['amber'], 'GC': COLORS['gold'], 'NQ': COLORS['blue'],
    'MNQ': COLORS['cyan'], 'ES': COLORS['purple'], 'MES': '#a5d6a7',
}

plt.rcParams.update({
    'figure.facecolor': COLORS['card'], 'axes.facecolor': COLORS['card'],
    'axes.edgecolor': COLORS['border'], 'axes.labelcolor': COLORS['text'],
    'text.color': COLORS['text'], 'xtick.color': COLORS['text'],
    'ytick.color': COLORS['text'], 'grid.color': '#2a2d37', 'grid.alpha': 0.5,
    'legend.facecolor': COLORS['card'], 'legend.edgecolor': COLORS['border'],
    'legend.labelcolor': COLORS['text'],
})


def fig_to_base64(fig, dpi=110):
    buf = io.BytesIO()
    fig.savefig(buf, format='png', dpi=dpi, bbox_inches='tight',
                facecolor=fig.get_facecolor(), edgecolor='none')
    buf.seek(0)
    return base64.b64encode(buf.read()).decode('ascii')


def root_symbol(instrument):
    return instrument.split()[0] if ' ' in instrument else instrument


def make_equity_chart(trades):
    cum = []
    total = 0.0
    for t in trades:
        total += t['PnL_Dollars']
        cum.append(total)
    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(range(len(cum)), cum, color=COLORS['blue'], linewidth=1.2)
    ax.fill_between(range(len(cum)), cum, alpha=0.15, color=COLORS['blue'])
    ax.axhline(0, color='#555', linewidth=0.5)
    ax.set_title('Equity Curve (Cumulative PnL)', fontsize=12, fontweight='bold')
    ax.set_xlabel('Trade #')
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax.grid(True, alpha=0.3)
    return fig


def make_instrument_equity_chart(trades):
    by_instr = defaultdict(list)
    for t in trades:
        by_instr[root_symbol(t['Instrument'])].append(t)
    fig, ax = plt.subplots(figsize=(12, 4))
    for sym, trs in sorted(by_instr.items()):
        cum = []
        total = 0.0
        for t in trs:
            total += t['PnL_Dollars']
            cum.append(total)
        color = INSTR_COLORS.get(sym, '#ccc')
        ax.plot(range(len(cum)), cum, color=color, linewidth=1.2, label=sym)
    ax.axhline(0, color='#555', linewidth=0.5)
    ax.set_title('Per-Instrument Equity Curves', fontsize=12, fontweight='bold')
    ax.set_xlabel('Trade # (per instrument)')
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    return fig


def make_daily_pnl_chart(trades):
    by_date = defaultdict(float)
    for t in trades:
        by_date[t['EntryTime'][:10]] += t['PnL_Dollars']
    dates = sorted(by_date.keys())
    pnls = [by_date[d] for d in dates]
    colors = [COLORS['green'] if p >= 0 else COLORS['red'] for p in pnls]
    labels = [d[5:] for d in dates]
    fig, ax = plt.subplots(figsize=(12, 3.5))
    ax.bar(range(len(dates)), pnls, color=colors, width=0.7)
    ax.set_xticks(range(len(dates)))
    ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=7)
    ax.axhline(0, color='#555', linewidth=0.5)
    ax.set_title('Daily PnL', fontsize=12, fontweight='bold')
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax.grid(True, axis='y', alpha=0.3)
    return fig


def make_drawdown_chart(trades):
    cum = []
    total = 0.0
    for t in trades:
        total += t['PnL_Dollars']
        cum.append(total)
    peak = 0.0
    dd = []
    for c in cum:
        if c > peak: peak = c
        dd.append(-(peak - c))
    fig, ax = plt.subplots(figsize=(12, 3))
    ax.plot(range(len(dd)), dd, color=COLORS['red'], linewidth=1)
    ax.fill_between(range(len(dd)), dd, alpha=0.2, color=COLORS['red'])
    ax.set_title('Drawdown', fontsize=12, fontweight='bold')
    ax.set_xlabel('Trade #')
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax.grid(True, alpha=0.3)
    return fig


def make_instrument_bars(trades):
    by_instr = defaultdict(lambda: {'pnl': 0, 'wins': 0, 'total': 0})
    for t in trades:
        sym = root_symbol(t['Instrument'])
        by_instr[sym]['pnl'] += t['PnL_Dollars']
        by_instr[sym]['total'] += 1
        if t['Win']: by_instr[sym]['wins'] += 1
    syms = sorted(by_instr.keys())
    pnls = [by_instr[s]['pnl'] for s in syms]
    wps = [100 * by_instr[s]['wins'] / max(by_instr[s]['total'], 1) for s in syms]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 3.5))
    ax1.bar(syms, pnls, color=[COLORS['green'] if p >= 0 else COLORS['red'] for p in pnls], width=0.5)
    ax1.axhline(0, color='#555', linewidth=0.5)
    ax1.set_title('PnL by Instrument', fontsize=11, fontweight='bold')
    ax1.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax1.grid(True, axis='y', alpha=0.3)
    ax2.bar(syms, wps, color=COLORS['blue'], width=0.5)
    ax2.set_title('Win Rate by Instrument', fontsize=11, fontweight='bold')
    ax2.set_ylim(0, 100)
    ax2.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'{v:.0f}%'))
    ax2.grid(True, axis='y', alpha=0.3)
    fig.tight_layout(pad=2)
    return fig


def make_tod_charts(trades):
    by_hour = defaultdict(lambda: {'pnl': 0, 'wins': 0, 'total': 0})
    for t in trades:
        hr = int(t['EntryTime'][11:13])
        by_hour[hr]['pnl'] += t['PnL_Dollars']
        by_hour[hr]['total'] += 1
        if t['Win']: by_hour[hr]['wins'] += 1
    hours = sorted(by_hour.keys())
    labels = [f'{h:02d}:00' for h in hours]
    pnls = [by_hour[h]['pnl'] for h in hours]
    wps = [100 * by_hour[h]['wins'] / max(by_hour[h]['total'], 1) for h in hours]
    counts = [by_hour[h]['total'] for h in hours]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 3.5))
    ax1.bar(range(len(hours)), pnls, color=[COLORS['green'] if p >= 0 else COLORS['red'] for p in pnls], width=0.6)
    ax1.set_xticks(range(len(hours)))
    ax1.set_xticklabels(labels, rotation=45, ha='right', fontsize=7)
    ax1.axhline(0, color='#555', linewidth=0.5)
    ax1.set_title('PnL by Hour', fontsize=11, fontweight='bold')
    ax1.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax1.grid(True, axis='y', alpha=0.3)
    ax2.bar(range(len(hours)), wps, color=COLORS['blue'], width=0.6, label='Win%')
    ax2_twin = ax2.twinx()
    ax2_twin.bar(range(len(hours)), counts, color='white', alpha=0.1, width=0.6, label='Trades')
    ax2.set_xticks(range(len(hours)))
    ax2.set_xticklabels(labels, rotation=45, ha='right', fontsize=7)
    ax2.set_ylim(0, 100)
    ax2.set_title('Win Rate & Volume by Hour', fontsize=11, fontweight='bold')
    ax2.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'{v:.0f}%'))
    ax2_twin.set_ylabel('Trade Count', fontsize=8)
    ax2_twin.tick_params(axis='y', labelcolor='#666', labelsize=7)
    ax2.grid(True, axis='y', alpha=0.3)
    fig.tight_layout(pad=2)
    return fig


def make_streak_chart(trades):
    streaks = []
    cur_type = None
    cur_len = 0
    for t in trades:
        typ = 'W' if t['Win'] else 'L'
        if typ == cur_type:
            cur_len += 1
        else:
            if cur_type: streaks.append((cur_type, cur_len))
            cur_type = typ
            cur_len = 1
    if cur_type: streaks.append((cur_type, cur_len))
    win_dist = defaultdict(int)
    loss_dist = defaultdict(int)
    for typ, ln in streaks:
        (win_dist if typ == 'W' else loss_dist)[ln] += 1
    max_len = max(max(win_dist.keys(), default=0), max(loss_dist.keys(), default=0))
    lens = list(range(1, max_len + 1))
    fig, ax = plt.subplots(figsize=(10, 3.5))
    w = 0.35
    ax.bar([x - w/2 for x in range(len(lens))], [win_dist.get(l, 0) for l in lens],
           width=w, color=COLORS['green'], label='Win Streaks')
    ax.bar([x + w/2 for x in range(len(lens))], [loss_dist.get(l, 0) for l in lens],
           width=w, color=COLORS['red'], label='Loss Streaks')
    ax.set_xticks(range(len(lens)))
    ax.set_xticklabels(lens)
    ax.set_xlabel('Streak Length')
    ax.set_ylabel('Count')
    ax.set_title('Streak Length Distribution', fontsize=12, fontweight='bold')
    ax.legend(fontsize=9)
    ax.grid(True, axis='y', alpha=0.3)
    return fig


def make_daily_cumulative_chart(trades):
    by_date = OrderedDict()
    for t in trades:
        dt = t['EntryTime'][:10]
        if dt not in by_date: by_date[dt] = 0
        by_date[dt] += t['PnL_Dollars']
    dates = list(by_date.keys())
    cum = []
    total = 0
    for d in dates:
        total += by_date[d]
        cum.append(total)
    labels = [d[5:] for d in dates]
    fig, ax = plt.subplots(figsize=(12, 3.5))
    ax.plot(range(len(cum)), cum, color=COLORS['blue'], linewidth=1.5, marker='o', markersize=4)
    ax.fill_between(range(len(cum)), cum, alpha=0.1, color=COLORS['blue'])
    ax.axhline(0, color='#555', linewidth=0.5)
    ax.set_xticks(range(len(dates)))
    ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=7)
    ax.set_title('Daily Cumulative Equity', fontsize=12, fontweight='bold')
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _: f'${v:,.0f}'))
    ax.grid(True, alpha=0.3)
    return fig


def compute_stats(trades):
    total = len(trades)
    winners = [t for t in trades if t['Win']]
    losers = [t for t in trades if not t['Win']]
    total_pnl = sum(t['PnL_Dollars'] for t in trades)
    win_pct = round(100 * len(winners) / max(total, 1), 1)
    avg_win = round(sum(t['PnL_Dollars'] for t in winners) / max(len(winners), 1), 2)
    avg_loss = round(sum(t['PnL_Dollars'] for t in losers) / max(len(losers), 1), 2)

    cum = 0; peak = 0; max_dd = 0; max_dd_peak = 0; max_dd_trough = 0
    max_dd_peak_time = ''; max_dd_trough_time = ''; cur_peak_time = ''
    for t in trades:
        cum += t['PnL_Dollars']
        if cum > peak: peak = cum; cur_peak_time = t['EntryTime']
        dd = peak - cum
        if dd > max_dd:
            max_dd = dd; max_dd_peak = peak; max_dd_trough = cum
            max_dd_peak_time = cur_peak_time; max_dd_trough_time = t['EntryTime']

    recovery = 'Not yet recovered'
    past_trough = False; cum2 = 0
    for t in trades:
        cum2 += t['PnL_Dollars']
        if t['EntryTime'] == max_dd_trough_time: past_trough = True
        if past_trough and cum2 >= max_dd_peak: recovery = t['EntryTime']; break

    dd_trades = len([t for t in trades if max_dd_peak_time <= t['EntryTime'] <= max_dd_trough_time])
    return_maxdd = round(total_pnl / max(max_dd, 1), 2)

    by_instr = defaultdict(lambda: {'pnl': 0, 'wins': 0, 'losses': 0, 'total': 0, 'maxdd': 0})
    instr_cum = defaultdict(float); instr_peak = defaultdict(float)
    for t in trades:
        sym = root_symbol(t['Instrument'])
        by_instr[sym]['pnl'] += t['PnL_Dollars']
        by_instr[sym]['total'] += 1
        if t['Win']: by_instr[sym]['wins'] += 1
        else: by_instr[sym]['losses'] += 1
        instr_cum[sym] += t['PnL_Dollars']
        if instr_cum[sym] > instr_peak[sym]: instr_peak[sym] = instr_cum[sym]
        idd = instr_peak[sym] - instr_cum[sym]
        if idd > by_instr[sym]['maxdd']: by_instr[sym]['maxdd'] = idd

    by_hour = defaultdict(lambda: {'pnl': 0, 'wins': 0, 'losses': 0, 'total': 0})
    for t in trades:
        hr = int(t['EntryTime'][11:13])
        by_hour[hr]['pnl'] += t['PnL_Dollars']
        by_hour[hr]['total'] += 1
        if t['Win']: by_hour[hr]['wins'] += 1
        else: by_hour[hr]['losses'] += 1

    streaks = []
    cur_type = None; cur_len = 0; cur_pnl = 0; cur_start = ''; cur_end = ''
    for t in trades:
        typ = 'W' if t['Win'] else 'L'
        if typ == cur_type:
            cur_len += 1; cur_pnl += t['PnL_Dollars']; cur_end = t['EntryTime']
        else:
            if cur_type:
                streaks.append({'type': cur_type, 'len': cur_len, 'pnl': round(cur_pnl, 2), 'start': cur_start, 'end': cur_end})
            cur_type = typ; cur_len = 1; cur_pnl = t['PnL_Dollars']
            cur_start = t['EntryTime']; cur_end = t['EntryTime']
    if cur_type:
        streaks.append({'type': cur_type, 'len': cur_len, 'pnl': round(cur_pnl, 2), 'start': cur_start, 'end': cur_end})

    win_streaks = sorted([s for s in streaks if s['type'] == 'W'], key=lambda s: -s['len'])
    loss_streaks = sorted([s for s in streaks if s['type'] == 'L'], key=lambda s: -s['len'])
    avg_win_streak = round(sum(s['len'] for s in win_streaks) / max(len(win_streaks), 1), 1)
    avg_loss_streak = round(sum(s['len'] for s in loss_streaks) / max(len(loss_streaks), 1), 1)

    by_date = OrderedDict()
    for t in trades:
        dt = t['EntryTime'][:10]
        if dt not in by_date: by_date[dt] = {'pnl': 0, 'wins': 0, 'total': 0}
        by_date[dt]['pnl'] += t['PnL_Dollars']
        by_date[dt]['total'] += 1
        if t['Win']: by_date[dt]['wins'] += 1

    return {
        'total': total, 'winners': len(winners), 'losers': len(losers),
        'total_pnl': round(total_pnl, 2), 'win_pct': win_pct,
        'avg_win': avg_win, 'avg_loss': avg_loss,
        'max_dd': round(max_dd, 2), 'max_dd_peak': round(max_dd_peak, 2),
        'max_dd_trough': round(max_dd_trough, 2),
        'max_dd_peak_time': max_dd_peak_time, 'max_dd_trough_time': max_dd_trough_time,
        'dd_trades': dd_trades, 'recovery': recovery, 'return_maxdd': return_maxdd,
        'final_equity': round(total_pnl, 2),
        'by_instr': dict(by_instr), 'by_hour': dict(by_hour),
        'win_streaks': win_streaks[:5], 'loss_streaks': loss_streaks[:5],
        'max_win_streak': win_streaks[0] if win_streaks else {'len':0,'pnl':0},
        'max_loss_streak': loss_streaks[0] if loss_streaks else {'len':0,'pnl':0},
        'avg_win_streak': avg_win_streak, 'avg_loss_streak': avg_loss_streak,
        'by_date': by_date,
    }


# ============================================================
# PDF REPORT
# ============================================================
def make_summary_page(stats, accounts, report_date):
    """Create a text-based summary page as a matplotlib figure."""
    fig, ax = plt.subplots(figsize=(11, 8.5))
    ax.axis('off')

    lines = [
        ('TTP Trend Candles3.3 — Analysis Report', 16, 'bold', COLORS['blue']),
        (f'{report_date}  |  {accounts}', 10, 'normal', '#888888'),
        ('', 8, 'normal', COLORS['text']),
        ('OVERALL SUMMARY', 13, 'bold', COLORS['green']),
        (f"Total Trades:  {stats['total']}     |     Winners:  {stats['winners']} ({stats['win_pct']}%)     |     Losers:  {stats['losers']}", 10, 'normal', COLORS['text']),
        (f"Total PnL:  ${stats['total_pnl']:,.0f}     |     Avg Win:  ${stats['avg_win']:,.0f}     |     Avg Loss:  ${stats['avg_loss']:,.0f}", 10, 'normal', COLORS['text']),
        ('', 8, 'normal', COLORS['text']),
        ('DRAWDOWN', 13, 'bold', COLORS['green']),
        (f"Max Drawdown:  ${stats['max_dd']:,.0f}     |     Return/MaxDD:  {stats['return_maxdd']}", 10, 'normal', COLORS['text']),
        (f"Peak:  ${stats['max_dd_peak']:,.0f}  ({stats['max_dd_peak_time'][:10]})     |     Trough:  ${stats['max_dd_trough']:,.0f}  ({stats['max_dd_trough_time'][:10]})", 10, 'normal', COLORS['text']),
        (f"Trades in DD:  {stats['dd_trades']}     |     Recovery:  {stats['recovery'][:10] if 'Not' not in stats['recovery'] else 'Pending'}", 10, 'normal', COLORS['text']),
        ('', 8, 'normal', COLORS['text']),
        ('PER-INSTRUMENT', 13, 'bold', COLORS['green']),
    ]
    for sym in sorted(stats['by_instr'].keys()):
        d = stats['by_instr'][sym]
        wp = round(100 * d['wins'] / max(d['total'], 1), 1)
        lines.append((f"  {sym}:  {d['total']} trades  |  W: {d['wins']} ({wp}%)  L: {d['losses']}  |  PnL: ${d['pnl']:,.0f}  |  MaxDD: ${d['maxdd']:,.0f}", 9, 'normal', COLORS['text']))

    lines.append(('', 8, 'normal', COLORS['text']))
    lines.append(('STREAKS', 13, 'bold', COLORS['green']))
    ms = stats['max_win_streak']
    ml = stats['max_loss_streak']
    lines.append((f"Max Win Streak: {ms['len']} trades (${ms['pnl']:,.0f})     |     Avg: {stats['avg_win_streak']}", 10, 'normal', COLORS['text']))
    lines.append((f"Max Loss Streak: {ml['len']} trades (${ml['pnl']:,.0f})     |     Avg: {stats['avg_loss_streak']}", 10, 'normal', COLORS['text']))

    y = 0.95
    for text, size, weight, color in lines:
        if text == '':
            y -= 0.02
            continue
        ax.text(0.05, y, text, transform=ax.transAxes, fontsize=size,
                fontweight=weight, color=color, verticalalignment='top',
                fontfamily='monospace' if size <= 10 else 'sans-serif')
        y -= 0.04 if size <= 10 else 0.05

    return fig


def generate_pdf(pdf_path, figures, stats, accounts, report_date):
    """Write all figures to a multi-page PDF."""
    with PdfPages(pdf_path) as pdf:
        # Summary page
        summary_fig = make_summary_page(stats, accounts, report_date)
        pdf.savefig(summary_fig, facecolor=summary_fig.get_facecolor())
        plt.close(summary_fig)

        # Chart pages
        for fig in figures:
            pdf.savefig(fig, facecolor=fig.get_facecolor(), bbox_inches='tight')

    print(f"PDF report saved: {pdf_path}")


# ============================================================
# HTML REPORT
# ============================================================
def build_html(trades, stats, chart_images, accounts, report_date):
    def pnl_class(v): return 'positive' if v >= 0 else 'negative'
    def fmt_pnl(v): return f'${v:,.0f}' if abs(v) >= 1 else f'${v:.2f}'

    instr_rows = ''
    for sym in sorted(stats['by_instr'].keys()):
        d = stats['by_instr'][sym]
        wp = round(100 * d['wins'] / max(d['total'], 1), 1)
        instr_rows += f"<tr><td>{sym}</td><td>{d['total']}</td><td>{d['wins']}</td><td>{d['losses']}</td><td>{wp}%</td><td class='{pnl_class(d['pnl'])}'>${d['pnl']:,.0f}</td><td class='negative'>${d['maxdd']:,.0f}</td></tr>\n"

    tod_rows = ''
    for hr in sorted(stats['by_hour'].keys()):
        d = stats['by_hour'][hr]
        wp = round(100 * d['wins'] / max(d['total'], 1), 1)
        aw = round(sum(t['PnL_Dollars'] for t in trades if int(t['EntryTime'][11:13]) == hr and t['Win']) / max(d['wins'], 1), 0)
        al = round(sum(t['PnL_Dollars'] for t in trades if int(t['EntryTime'][11:13]) == hr and not t['Win']) / max(d['losses'], 1), 0)
        tod_rows += f"<tr><td>{hr:02d}:00</td><td>{d['total']}</td><td>{d['wins']}</td><td>{d['losses']}</td><td>{wp}%</td><td class='{pnl_class(d['pnl'])}'>${d['pnl']:,.0f}</td><td class='positive'>${aw:,.0f}</td><td class='negative'>${al:,.0f}</td></tr>\n"

    daily_rows = ''
    cum = 0
    for dt, d in stats['by_date'].items():
        cum += d['pnl']
        wp = round(100 * d['wins'] / max(d['total'], 1), 1)
        daily_rows += f"<tr><td>{dt}</td><td>{d['total']}</td><td>{d['wins']}</td><td>{wp}%</td><td class='{pnl_class(d['pnl'])}'>${d['pnl']:,.0f}</td><td class='{pnl_class(cum)}'>${cum:,.0f}</td></tr>\n"

    win_streak_items = '\n'.join(
        f"<div class='streak-item'>{s['len']} wins | ${s['pnl']:,.0f} | {s['start'][:10]} to {s['end'][:10]}</div>"
        for s in stats['win_streaks'])
    loss_streak_items = '\n'.join(
        f"<div class='streak-item'>{s['len']} losses | ${s['pnl']:,.0f} | {s['start'][:10]} to {s['end'][:10]}</div>"
        for s in stats['loss_streaks'])

    recovery_display = 'Pending' if 'Not yet' in stats['recovery'] else stats['recovery'][:10]

    html = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TTP Trend Candles3.3 - {report_date}</title>
<style>
  *{{box-sizing:border-box;margin:0;padding:0}}
  body{{font-family:'Segoe UI',system-ui,sans-serif;background:{COLORS['bg']};color:#e0e0e0;padding:20px;max-width:1200px;margin:0 auto}}
  h1{{color:{COLORS['blue']};margin-bottom:4px;font-size:1.6em}}
  h2{{color:{COLORS['green']};margin:30px 0 12px;font-size:1.2em;border-bottom:1px solid #333;padding-bottom:6px}}
  .subtitle{{color:#888;font-size:0.9em;margin-bottom:20px}}
  .summary-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:16px 0}}
  .stat-card{{background:{COLORS['card']};border-radius:8px;padding:14px;border:1px solid {COLORS['border']}}}
  .stat-card .label{{font-size:0.75em;color:#888;text-transform:uppercase;letter-spacing:0.5px}}
  .stat-card .value{{font-size:1.5em;font-weight:700;margin-top:4px}}
  .positive{{color:{COLORS['green']}}} .negative{{color:{COLORS['red']}}} .neutral{{color:#e0e0e0}}
  .chart-img{{width:100%;margin:12px 0;border-radius:8px}}
  table{{width:100%;border-collapse:collapse;margin:10px 0;font-size:0.85em}}
  th{{background:#1e2130;color:#90caf9;padding:8px 10px;text-align:right;border-bottom:2px solid #333}}
  td{{padding:6px 10px;text-align:right;border-bottom:1px solid #222}}
  th:first-child,td:first-child{{text-align:left}} tr:hover td{{background:#1e2130}}
  .streak-section{{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:12px 0}}
  @media(max-width:700px){{.streak-section{{grid-template-columns:1fr}}}}
  .streak-list{{background:{COLORS['card']};border-radius:8px;padding:14px;border:1px solid {COLORS['border']}}}
  .streak-list h3{{font-size:0.95em;color:#aaa;margin-bottom:8px}}
  .streak-item{{font-size:0.82em;padding:3px 0;color:#ccc}}
</style></head><body>
<h1>TTP Trend Candles3.3 Analysis</h1>
<div class="subtitle">{report_date} &mdash; {accounts}</div>
<h2>Overall Summary</h2>
<div class="summary-grid">
  <div class="stat-card"><div class="label">Total Trades</div><div class="value neutral">{stats['total']}</div></div>
  <div class="stat-card"><div class="label">Win Rate</div><div class="value {pnl_class(stats['win_pct']-50)}">{stats['win_pct']}%</div></div>
  <div class="stat-card"><div class="label">Total PnL</div><div class="value {pnl_class(stats['total_pnl'])}">{fmt_pnl(stats['total_pnl'])}</div></div>
  <div class="stat-card"><div class="label">Avg Win</div><div class="value positive">${stats['avg_win']:,.0f}</div></div>
  <div class="stat-card"><div class="label">Avg Loss</div><div class="value negative">${stats['avg_loss']:,.0f}</div></div>
  <div class="stat-card"><div class="label">Max Drawdown</div><div class="value negative">{fmt_pnl(stats['max_dd'])}</div></div>
  <div class="stat-card"><div class="label">Return / MaxDD</div><div class="value neutral">{stats['return_maxdd']}</div></div>
  <div class="stat-card"><div class="label">Recovery</div><div class="value neutral">{recovery_display}</div></div>
</div>
<h2>Equity Curve</h2><img class="chart-img" src="data:image/png;base64,{chart_images['equity']}">
<h2>Per-Instrument Equity</h2><img class="chart-img" src="data:image/png;base64,{chart_images['instr_equity']}">
<h2>Daily PnL</h2><img class="chart-img" src="data:image/png;base64,{chart_images['daily_pnl']}">
<h2>Daily Cumulative</h2><img class="chart-img" src="data:image/png;base64,{chart_images['daily_cum']}">
<h2>Drawdown</h2><img class="chart-img" src="data:image/png;base64,{chart_images['drawdown']}">
<div class="summary-grid">
  <div class="stat-card"><div class="label">Peak Equity</div><div class="value positive">{fmt_pnl(stats['max_dd_peak'])} <span style="font-size:0.5em;color:#888">{stats['max_dd_peak_time'][:10]}</span></div></div>
  <div class="stat-card"><div class="label">Trough Equity</div><div class="value negative">{fmt_pnl(stats['max_dd_trough'])} <span style="font-size:0.5em;color:#888">{stats['max_dd_trough_time'][:10]}</span></div></div>
  <div class="stat-card"><div class="label">Trades in Max DD</div><div class="value neutral">{stats['dd_trades']}</div></div>
</div>
<h2>Per-Instrument Breakdown</h2><img class="chart-img" src="data:image/png;base64,{chart_images['instr_bars']}">
<table><tr><th>Symbol</th><th>Trades</th><th>Wins</th><th>Losses</th><th>Win%</th><th>PnL</th><th>MaxDD</th></tr>{instr_rows}</table>
<h2>Time of Day</h2><img class="chart-img" src="data:image/png;base64,{chart_images['tod']}">
<table><tr><th>Hour</th><th>Trades</th><th>Wins</th><th>Losses</th><th>Win%</th><th>PnL</th><th>Avg Win</th><th>Avg Loss</th></tr>{tod_rows}</table>
<h2>Win/Loss Streaks</h2><img class="chart-img" src="data:image/png;base64,{chart_images['streaks']}">
<div class="summary-grid">
  <div class="stat-card"><div class="label">Max Win Streak</div><div class="value positive">{stats['max_win_streak']['len']} trades (${stats['max_win_streak']['pnl']:,.0f})</div></div>
  <div class="stat-card"><div class="label">Avg Win Streak</div><div class="value neutral">{stats['avg_win_streak']}</div></div>
  <div class="stat-card"><div class="label">Max Loss Streak</div><div class="value negative">{stats['max_loss_streak']['len']} trades (${stats['max_loss_streak']['pnl']:,.0f})</div></div>
  <div class="stat-card"><div class="label">Avg Loss Streak</div><div class="value neutral">{stats['avg_loss_streak']}</div></div>
</div>
<div class="streak-section">
  <div class="streak-list"><h3>Top 5 Win Streaks</h3>{win_streak_items}</div>
  <div class="streak-list"><h3>Top 5 Loss Streaks</h3>{loss_streak_items}</div>
</div>
<h2>Daily Breakdown</h2>
<table><tr><th>Date</th><th>Trades</th><th>Wins</th><th>Win%</th><th>Day PnL</th><th>Cumulative</th></tr>{daily_rows}</table>
</body></html>"""
    return html


def main():
    if len(sys.argv) < 3:
        print("Usage: python ttp_charts.py <input.json> <output.html>")
        sys.exit(1)

    json_path = sys.argv[1]
    html_path = sys.argv[2]
    pdf_path = os.path.splitext(html_path)[0] + '.pdf'

    with open(json_path, 'r', encoding='utf-8-sig') as f:
        data = json.load(f)

    trades = data['trades']
    accounts = data.get('accounts', '')
    report_date = data.get('report_date', datetime.now().strftime('%B %d, %Y'))
    trades.sort(key=lambda t: t['EntryTime'])

    print(f"Generating charts for {len(trades)} trades...")

    # Generate all figures (kept open for PDF)
    chart_figs = OrderedDict([
        ('equity',        make_equity_chart(trades)),
        ('instr_equity',  make_instrument_equity_chart(trades)),
        ('daily_pnl',     make_daily_pnl_chart(trades)),
        ('daily_cum',     make_daily_cumulative_chart(trades)),
        ('drawdown',      make_drawdown_chart(trades)),
        ('instr_bars',    make_instrument_bars(trades)),
        ('tod',           make_tod_charts(trades)),
        ('streaks',       make_streak_chart(trades)),
    ])

    # Convert to base64 for HTML (don't close yet)
    chart_images = {name: fig_to_base64(fig) for name, fig in chart_figs.items()}

    stats = compute_stats(trades)

    # Generate PDF (uses the still-open figures)
    generate_pdf(pdf_path, list(chart_figs.values()), stats, accounts, report_date)

    # Now close all figures
    for fig in chart_figs.values():
        plt.close(fig)

    # Generate HTML
    html = build_html(trades, stats, chart_images, accounts, report_date)
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f"HTML report saved: {html_path}")


if __name__ == '__main__':
    main()
