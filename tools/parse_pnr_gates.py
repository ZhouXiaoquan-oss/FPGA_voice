#!/usr/bin/env python3
"""parse_pnr_gates.py -- parse Gowin V1.9.11 PnR outputs for d2_screen_pnr gate checks.

This script only READS build outputs and never touches src/ or the board.

Usage:
  python parse_pnr_gates.py --root <tree> --proj d2_screen_pnr \
      [--baseline <baseline tree>] [--out <impl/pnr/gates_summary.json>]

Inputs (produced by ONE gw_sh run: "run syn; run pnr"):
  impl/pnr/<proj>.rpt.txt          resource usage + PnR messages
  impl/pnr/<proj>_tr_content.html  Fmax / TNS / Setup-Hold-Recovery-Removal path tables
  impl/pnr/<proj>.timing_paths     machine-readable worst paths (cross-check)
  impl/pnr/<proj>.fs               bitstream identity header (CheckSum/UserCode)
  impl/pnr/device.cfg              vccx
  build_screen_pnr_*.log           gw_sh console log (exit code / unrouted)
  src/d2.cst, src/d2.sdc           constraint retention checks
Output: JSON summary (UTF-8 no BOM); a compact key=value dump to stdout.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import sys

PROJ_DEFAULT = 'd2_screen_pnr'


def read_text(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


def strip_tags(s):
    s = re.sub(r'<[^>]+>', ' ', s)
    for a, b in (('&nbsp;', ' '), ('&amp;', '&'), ('&lt;', '<'), ('&gt;', '>'), ('&quot;', '"')):
        s = s.replace(a, b)
    return re.sub(r'\s+', ' ', s).strip()


def anchor_slice(text, name, max_bytes=12000000):
    start = '<a name="%s">' % name
    i = text.find(start)
    if i < 0:
        return ''
    nxt = text.find('<a name="', i + len(start))
    end = nxt if nxt >= 0 else len(text)
    if end - i > max_bytes:
        end = i + max_bytes
    return text[i:end]


def table_rows(section):
    out = []
    for rm in re.finditer(r'<tr[^>]*>(.*?)</tr>', section, re.S | re.I):
        cells = [strip_tags(c) for c in re.findall(r'<td[^>]*>(.*?)</td>', rm.group(1), re.S | re.I)]
        if cells:
            out.append(cells)
    return out


def to_float(s):
    if s is None:
        return None
    try:
        return float(s)
    except Exception:
        m = re.search(r'-?\d+(?:\.\d+)?', str(s))
        return float(m.group(0)) if m else None


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def parse_resources(rpt):
    i = rpt.find('3. Resource Usage Summary')
    j = rpt.find('4. I/O Bank Usage Summary')
    if i < 0:
        return {}
    sec = rpt[i:j if j > i else i + 20000]
    rows = {}
    for line in sec.splitlines():
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 3:
            continue
        name, usage, util = parts[0], parts[1], parts[2]
        if not name or name.startswith('---') or name.lower().startswith('resources'):
            continue
        m = re.match(r'^(\d+)\s*/\s*(\d+)$', usage)
        if m:
            rows[name] = {'used': int(m.group(1)), 'total': int(m.group(2)), 'util': util}
            continue
        m = re.match(r'^(\d+)$', usage)
        if m:
            rows[name] = {'used': int(m.group(1)), 'total': None, 'util': util}
            continue
        m = re.match(r'^(\d+)\((.*)\)$', usage)
        if m:
            rows[name] = {'used': int(m.group(1)), 'total': None, 'util': util, 'detail': m.group(2)}
    return rows


def parse_timing_html(tr):
    out = {}
    # ---- Max Frequency Summary -------------------------------------------------
    sec = anchor_slice(tr, 'Max_Frequency_Report')
    fmax = []
    for r in table_rows(sec):
        if len(r) >= 4:
            m1 = re.match(r'^([\d.]+)\s*\(MHz\)$', r[2].replace(' ', ''))
            m2 = re.match(r'^([\d.]+)', r[3])
            if m1 and m2:
                fmax.append({
                    'clock': r[1],
                    'constraint_mhz': float(m1.group(1)),
                    'fmax_mhz': float(m2.group(1)),
                    'logic_level': r[4] if len(r) > 4 else None,
                })
    out['fmax_table'] = fmax
    # ---- Total Negative Slack Summary (Setup/Hold only in Gowin STA) -----------
    sec = anchor_slice(tr, 'Total_Negative_Slack_Report')
    tns = []
    for r in table_rows(sec):
        if len(r) >= 4 and r[1] in ('Setup', 'Hold', 'Recovery', 'Removal'):
            tns.append({'clock': r[0], 'type': r[1], 'tns_ns': to_float(r[2]),
                        'endpoints': int(re.sub(r'[^0-9]', '', r[3]) or 0)})
    out['tns_table'] = tns
    # ---- per-class worst-path tables ------------------------------------------
    details = {}
    for typ, anchor in (('Setup', 'Setup_Slack_Table'), ('Hold', 'Hold_Slack_Table'),
                        ('Recovery', 'Recovery_Slack_Table'), ('Removal', 'Removal_Slack_Table')):
        sec = anchor_slice(tr, anchor)
        paths = []
        for r in table_rows(sec):
            if len(r) >= 9 and re.match(r'^\d+$', r[0]):
                paths.append({
                    'n': int(r[0]), 'slack': to_float(r[1]),
                    'from_node': r[2], 'to_node': r[3],
                    'from_clock': r[4], 'to_clock': r[5],
                    'relation': r[6], 'clock_skew': to_float(r[7]),
                    'data_delay': to_float(r[8]),
                })
        info = {'count': len(paths)}
        if paths:
            worst = min(paths, key=lambda p: p['slack'])
            info.update({
                'min_slack_ns': worst['slack'],
                'violated_paths': sum(1 for p in paths if p['slack'] is not None and p['slack'] < 0),
                'worst_path': worst,
            })
        details[typ] = info
    out['paths'] = details
    return out


def parse_timing_paths(path):
    blocks = {}
    if not os.path.isfile(path):
        return blocks
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if line.strip() != '=====' or i + 2 >= len(lines):
            continue
        typ = lines[i + 1].strip()
        slack = to_float(lines[i + 2])
        if slack is None:
            continue
        b = blocks.setdefault(typ, {'count': 0, 'min_slack_ns': None, 'violated': 0})
        b['count'] += 1
        if b['min_slack_ns'] is None or slack < b['min_slack_ns']:
            b['min_slack_ns'] = slack
        if slack < 0:
            b['violated'] += 1
    return blocks


def newest_log(root):
    cands = sorted(glob.glob(os.path.join(root, 'build_screen_pnr_*.log')), key=os.path.getmtime)
    return cands[-1] if cands else None


def parse_log(log_path):
    info = {}
    if not log_path or not os.path.isfile(log_path):
        return info
    txt = read_text(log_path)
    info['path'] = log_path
    info['bytes'] = os.path.getsize(log_path)
    m = re.search(r'exit_code\s*:\s*(\d+)', txt)
    info['exit_code'] = int(m.group(1)) if m else None
    m = re.search(r'start\s*:\s*([0-9:\- ]+)', txt)
    info['start'] = m.group(1).strip() if m else None
    m = re.search(r'end\s*:\s*([0-9:\- ]+)', txt)
    info['end'] = m.group(1).strip() if m else None
    m = re.search(r'elapsed_s\s*:\s*([0-9.]+)', txt)
    info['elapsed_s'] = float(m.group(1)) if m else None
    info['pr0004_unrouted_marks'] = len(re.findall(r'PR0004', txt))
    # Gowin prints "ERROR (PR0004) : There are total N unrouted nets"; N=0 can still occur on
    # an aborted routing pass, so the gate also requires timing+bitstream to have completed.
    # A run that finishes normally simply has no PR0004 line at all => 0 unrouted nets.
    m = re.search(r'There are total (\d+) unrouted nets', txt)
    info['unrouted_nets_reported'] = int(m.group(1)) if m else 0
    info['pr0004_present'] = bool(m)
    info['warn_count'] = len(re.findall(r'(?m)^WARN', txt))
    info['error_count'] = len(re.findall(r'(?m)^ERROR', txt))
    info['pr1014_generic_clock'] = 'PR1014' in txt
    info['routing_phases'] = re.findall(r'\[(\d+%)\] Routing Phase \d+ completed', txt)
    info['pnr_completed'] = 'Placement and routing completed' in txt
    info['timing_analysis_completed'] = 'Timing analysis completed' in txt
    info['bitstream_completed'] = 'Bitstream generation completed' in txt
    info['unrouted_word'] = len(re.findall(r'(?i)unrouted', txt))
    return info


def parse_fs(path):
    info = {'path': path}
    if not os.path.isfile(path):
        return info
    info['bytes'] = os.path.getsize(path)
    info['sha256'] = sha256(path)
    with open(path, 'rb') as f:
        head = f.read(8192)
    txt = head.decode('ascii', 'replace')
    for key, rx in (('checksum', r'//CheckSum:\s*(\S+)'),
                    ('usercode', r'//UserCode:\s*(\S+)'),
                    ('tool_version', r'//Tool Version:\s*(.+)'),
                    ('device', r'//Device:\s*(\S+)'),
                    ('part_number', r'//Part Number:\s*(\S+)'),
                    ('compress', r'//Compress:\s*(\S+)')):
        m = re.search(rx, txt)
        info[key] = m.group(1).strip() if m else None
    return info


def constraint_checks(cst, sdc):
    c = {}
    c['cst_insloc_ddr_rsti_reg_2_s0_R53C57'] = (
        'INS_LOC "u_ddr3/gw3_top/u_ddr_phy_top/ddr_rsti_reg_2_s0" R53C57[0][B];' in cst)
    c['sdc_s1_false_path_ddrst_s_0_s0_D'] = bool(
        re.search(r'set_false_path[^\n]*\{u_ddr3_ui/ddrst_s_0_s0/D\}', sdc))
    c['sdc_hold_only_ev_toerr'] = bool(
        re.search(r'set_false_path[^\n]*ev_toerr_s0/D\}[^\n]*-hold', sdc))
    c['sdc_hold_only_dll_step_base'] = bool(
        re.search(r'set_false_path[^\n]*dll_step_base_\*_s0/D\}[^\n]*-hold', sdc))
    c['sdc_hold_only_req_star'] = bool(
        re.search(r'set_false_path[^\n]*req_\*_s\*/Q\}[^\n]*-hold', sdc))
    c['sdc_hold_only_tap_pw_data'] = bool(
        re.search(r'set_false_path[^\n]*pw_data\*_s0/D[^\n]*-hold', sdc))
    c['sdc_set_min_delay_0p5'] = bool(re.search(r'set_min_delay[^\n]*\b0\.5\b', sdc))
    c['sdc_report_timing_max_paths_2000_count'] = len(
        re.findall(r'report_timing[^\n]*-max_paths\s+2000', sdc))
    c['sdc_report_timing_recovery_present'] = bool(re.search(r'report_timing\s+-recovery', sdc))
    c['sdc_report_timing_removal_present'] = bool(re.search(r'report_timing\s+-removal', sdc))
    return c


def parse_device_cfg(path):
    info = {'path': path}
    if not os.path.isfile(path):
        return info
    txt = read_text(path)
    m = re.search(r'set\s+vccx\s*=\s*([0-9.]+)', txt)
    info['vccx'] = m.group(1) if m else None
    m = re.search(r'set\s+vcc\s*=\s*([0-9.]+)', txt)
    info['vcc'] = m.group(1) if m else None
    return info


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--proj', default=PROJ_DEFAULT)
    ap.add_argument('--baseline', default=None)
    ap.add_argument('--out', default=None)
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root)
    proj = a.proj
    pnr = os.path.join(root, 'impl', 'pnr')
    out = a.out or os.path.join(pnr, 'gates_summary.json')

    rpt_p = os.path.join(pnr, proj + '.rpt.txt')
    tr_p = os.path.join(pnr, proj + '_tr_content.html')
    tp_p = os.path.join(pnr, proj + '.timing_paths')
    fs_p = os.path.join(pnr, proj + '.fs')
    dev_p = os.path.join(pnr, 'device.cfg')
    cmd_p = os.path.join(pnr, 'cmd.do')
    cst_p = os.path.join(root, 'src', 'd2.cst')
    sdc_p = os.path.join(root, 'src', 'd2.sdc')
    log_p = newest_log(root)

    summary = {}
    rpt = read_text(rpt_p) if os.path.isfile(rpt_p) else ''
    summary['rpt_present'] = bool(rpt)
    m = re.search(r'<\s*Tool Version\s*>\s*:\s*(.+)', rpt)
    summary['tool_version'] = m.group(1).strip() if m else None
    m = re.search(r'<\s*Part Number\s*>\s*:\s*(.+)', rpt)
    summary['part_number'] = m.group(1).strip() if m else None
    m = re.search(r'<\s*Created Time\s*>\s*:\s*(.+)', rpt)
    summary['created_time'] = m.group(1).strip() if m else None

    summary['resources'] = parse_resources(rpt)
    # flat view: primary counters, plus LUT/ALU/ROM16/FF split out of composite rows
    res0 = summary['resources']
    flat = {}
    for key, short in (('Logic', 'logic'), ('Register', 'register'), ('CLS', 'cls'),
                       ('BSRAM', 'bsram'), ('DSP', 'dsp'), ('I/O Port', 'io_port'),
                       ('IOLOGIC', 'iologic'), ('--SSRAM(RAM16)', 'ssram')):
        d = res0.get(key)
        if d:
            flat[short] = {'used': d.get('used'), 'total': d.get('total')}
    det = (res0.get('--LUT,ALU,ROM16', {}) or {}).get('detail') or ''
    for short, pat in (('lut', r'(\d+)\s*LUT'), ('alu', r'(\d+)\s*ALU'), ('rom16', r'(\d+)\s*ROM16')):
        m = re.search(pat, det)
        if m:
            flat[short] = {'used': int(m.group(1))}
    ffrow = res0.get('--Logic Register as FF') or {}
    if ffrow:
        flat['ff'] = {'used': ffrow.get('used'), 'total': ffrow.get('total')}
    summary['resources_flat'] = flat

    tr = read_text(tr_p) if os.path.isfile(tr_p) else ''
    summary['tr_content_present'] = bool(tr)
    html = parse_timing_html(tr) if tr else {'fmax_table': [], 'tns_table': [], 'paths': {}}
    summary['fmax_table'] = html['fmax_table']
    summary['tns_table'] = html['tns_table']
    summary['path_tables'] = html['paths']
    summary['timing_paths_file'] = parse_timing_paths(tp_p)

    summary['build_log'] = parse_log(log_p)
    summary['bitstream'] = parse_fs(fs_p)
    summary['device_cfg'] = parse_device_cfg(dev_p)
    summary['cmd_do_present'] = os.path.isfile(cmd_p)

    cst = read_text(cst_p) if os.path.isfile(cst_p) else ''
    sdc = read_text(sdc_p) if os.path.isfile(sdc_p) else ''
    summary['constraints'] = constraint_checks(cst, sdc)
    summary['src_hashes'] = {}
    for p in (cst_p, sdc_p):
        if os.path.isfile(p):
            summary['src_hashes'][os.path.basename(p)] = {'sha256': sha256(p).upper(),
                                                          'bytes': os.path.getsize(p)}
    if a.baseline:
        base = os.path.abspath(a.baseline)
        summary['baseline_compare'] = {}
        for f in ('d2.cst', 'd2.sdc'):
            bp = os.path.join(base, 'src', f)
            np_ = os.path.join(root, 'src', f)
            if os.path.isfile(bp) and os.path.isfile(np_):
                summary['baseline_compare'][f] = (sha256(bp).upper() == sha256(np_).upper())
        brp = os.path.join(base, 'impl', 'pnr')
        cands = sorted(glob.glob(os.path.join(brp, '*.rpt.txt')))
        summary['baseline_resources'] = parse_resources(read_text(cands[0])) if cands else {}

    # ---------------- gates ------------------------------------------------------
    res = summary['resources']
    fmax_clk = None
    for row in summary['fmax_table']:
        if row['clock'] == 'clk':
            fmax_clk = row['fmax_mhz']
    setup_ep = sum(r['endpoints'] for r in summary['tns_table'] if r['type'] == 'Setup')
    hold_ep = sum(r['endpoints'] for r in summary['tns_table'] if r['type'] == 'Hold')
    rec = summary['path_tables'].get('Recovery', {})
    rem = summary['path_tables'].get('Removal', {})
    cls = res.get('CLS', {}).get('used')
    cls_total = res.get('CLS', {}).get('total')
    log = summary['build_log']

    def g(ok, **kw):
        d = {'pass': bool(ok)}
        d.update(kw)
        return d

    gates = {}
    gates['clk_fmax_ge_50MHz'] = g(fmax_clk is not None and fmax_clk >= 50.0,
                                   actual_mhz=fmax_clk, goal_mhz=50.0, baseline_mhz=52.787)
    gates['global_setup_violated_endpoints_zero'] = g(setup_ep == 0, violated_endpoints=setup_ep)
    gates['global_hold_violated_endpoints_zero'] = g(hold_ep == 0, violated_endpoints=hold_ep)
    gates['recovery_all_slacks_ge_0'] = g(
        rec.get('count', 0) > 0 and rec.get('violated_paths', 1) == 0,
        paths=rec.get('count'), min_slack_ns=rec.get('min_slack_ns'),
        baseline_min_ns=0.422, baseline_paths=2000)
    gates['removal_all_slacks_ge_0'] = g(
        rem.get('count', 0) > 0 and rem.get('violated_paths', 1) == 0,
        paths=rem.get('count'), min_slack_ns=rem.get('min_slack_ns'),
        baseline_min_ns=0.004, baseline_paths=2056)
    gates['no_unrouted'] = g(
        log.get('unrouted_nets_reported') == 0 and log.get('pnr_completed', False)
        and log.get('timing_analysis_completed', False) and log.get('bitstream_completed', False),
        unrouted_nets_reported=log.get('unrouted_nets_reported'),
        pr0004_marks=log.get('pr0004_unrouted_marks'),
        pnr_completed=log.get('pnr_completed'),
        timing_analysis_completed=log.get('timing_analysis_completed'),
        bitstream_completed=log.get('bitstream_completed'))
    gates['cls_within_29952'] = g(cls is not None and cls_total is not None and cls <= cls_total,
                                  used=cls, total=cls_total, baseline_used=25658,
                                  tolerance_over_baseline=None)
    cons = summary['constraints']
    cons_ok = all([cons['cst_insloc_ddr_rsti_reg_2_s0_R53C57'],
                   cons['sdc_s1_false_path_ddrst_s_0_s0_D'],
                   cons['sdc_hold_only_ev_toerr'], cons['sdc_hold_only_dll_step_base'],
                   cons['sdc_hold_only_req_star'], cons['sdc_hold_only_tap_pw_data'],
                   cons['sdc_set_min_delay_0p5'],
                   cons['sdc_report_timing_max_paths_2000_count'] == 4,
                   cons['sdc_report_timing_recovery_present'],
                   cons['sdc_report_timing_removal_present']])
    gates['constraints_retained'] = g(cons_ok)
    gates['build_exit_zero'] = g(log.get('exit_code') == 0, exit_code=log.get('exit_code'))
    summary['gates'] = gates

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(summary, f, indent=1, ensure_ascii=True)
        f.write('\n')

    def fnum(v):
        return 'None' if v is None else str(v)

    print('SUMMARY_JSON ' + out)
    print('tool_version=%s part=%s created=%s' % (summary['tool_version'], summary['part_number'],
                                                  summary['created_time']))
    print('resources: ' + ', '.join('%s=%s/%s' % (k, v.get('used'), v.get('total'))
                                    for k, v in res.items() if k in
                                    ('Logic', 'Register', 'CLS', 'BSRAM', 'DSP', 'I/O Port', 'IOLOGIC')))
    print('resources_flat: ' + ', '.join('%s=%s' % (k, v.get('used'))
                                         for k, v in summary['resources_flat'].items()))
    print('fmax: ' + ', '.join('%s=%s MHz (constr %s)' % (r['clock'], r['fmax_mhz'], r['constraint_mhz'])
                               for r in summary['fmax_table']))
    print('tns: ' + ', '.join('%s/%s tns=%s ep=%s' % (r['clock'], r['type'], r['tns_ns'], r['endpoints'])
                              for r in summary['tns_table']))
    for typ in ('Setup', 'Hold', 'Recovery', 'Removal'):
        i = summary['path_tables'].get(typ, {})
        w = i.get('worst_path') or {}
        print('%s: paths=%s min_slack=%s violated=%s worst_to=%s' %
              (typ, i.get('count'), fnum(i.get('min_slack_ns')), i.get('violated_paths'),
               w.get('to_node')))
    print('timing_paths_file: ' + ', '.join('%s count=%s min=%s neg=%s' %
          (k, v['count'], v['min_slack_ns'], v['violated']) for k, v in
          summary['timing_paths_file'].items()))
    print('log: exit_code=%s elapsed_s=%s pr0004=%s warns=%s errors=%s pnr=%s bit=%s' %
          (log.get('exit_code'), log.get('elapsed_s'), log.get('pr0004_unrouted_marks'),
           log.get('warn_count'), log.get('error_count'), log.get('pnr_completed'),
           log.get('bitstream_completed')))
    b = summary['bitstream']
    print('fs: bytes=%s sha256=%s usercode=%s checksum=%s' %
          (b.get('bytes'), b.get('sha256'), b.get('usercode'), b.get('checksum')))
    print('constraints_ok=%s' % cons_ok)
    print('GATES: ' + ', '.join('%s=%s' % (k, 'PASS' if v['pass'] else 'FAIL') for k, v in gates.items()))
    allpass = all(v['pass'] for v in gates.values())
    print('ALL_GATES_PASS=%s' % allpass)
    return 0


if __name__ == '__main__':
    sys.exit(main())