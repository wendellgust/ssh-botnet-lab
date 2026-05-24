#!/usr/bin/env python3
"""
SSH Botnet Lab — Real-Time GUI
Run on Kali host: python3 gui.py
Open browser: http://localhost:5000
"""

import http.server
import threading
import subprocess
import queue
import json
import re
import time
import sys
import os
from urllib.parse import urlparse, parse_qs

# ── Global state ──────────────────────────────────────────────────────────────
state = {
    'events':   [],      # all events (for replay on reconnect)
    'hosts':    {},      # ip -> {state, user, pwd, via, cx, cy}
    'zones':    set(),   # network prefixes seen
    'running':  False,
    'done':     False,
    'stats':    {'found': 0, 'compromised': 0, 'nets': 0},
}
_pending_via = {}        # ip -> via (set on attack_start, used on compromised)
_clients = []
_clients_lock = threading.Lock()
_proc = None             # running subprocess
_proc_lock = threading.Lock()
defense_status = {}      # container_name -> set of applied defense ids

# ── Event broadcasting ────────────────────────────────────────────────────────
def broadcast(ev_type, data):
    ts = time.strftime('%H:%M:%S')
    ev = {'type': ev_type, 'data': data, 'ts': ts}
    state['events'].append(ev)
    msg = ('data: ' + json.dumps(ev) + '\n\n').encode()
    with _clients_lock:
        dead = []
        for q in _clients:
            try:
                q.put_nowait(msg)
            except queue.Full:
                dead.append(q)
        for q in dead:
            _clients.remove(q)

# ── Log line parser ───────────────────────────────────────────────────────────
def parse_line(line):
    # OPEN ssh://ip:22
    m = re.search(r'OPEN ssh://(\d+\.\d+\.\d+\.\d+):22', line)
    if m:
        ip = m.group(1)
        if ip not in state['hosts']:
            state['hosts'][ip] = {'state': 'open', 'via': None}
            state['stats']['found'] += 1
            broadcast('host_open', {'ip': ip})
        return

    # Brute-forcing ip (via X)
    m = re.search(r'Brute-forcing (\d+\.\d+\.\d+\.\d+) \(via ([^\)]+)\)', line)
    if m:
        ip, via = m.group(1), m.group(2)
        _pending_via[ip] = via
        if ip in state['hosts']:
            state['hosts'][ip]['state'] = 'attacking'
        broadcast('attack_start', {'ip': ip, 'via': via})
        return

    # CREDENTIAL FOUND: user:pass @ ip
    m = re.search(r'CREDENTIAL FOUND: (\S+):(\S+) @ (\d+\.\d+\.\d+\.\d+)', line)
    if m:
        user, pwd, ip = m.group(1), m.group(2), m.group(3)
        via = _pending_via.get(ip, 'direct')
        if ip not in state['hosts']:
            state['hosts'][ip] = {'state': 'compromised'}
            state['stats']['found'] += 1
        state['hosts'][ip].update({'state': 'compromised', 'user': user, 'pwd': pwd, 'via': via})
        state['stats']['compromised'] += 1
        broadcast('compromised', {'ip': ip, 'user': user, 'pwd': pwd, 'via': via})
        return

    # New network discovered: prefix.0/24 (via ip)
    m = re.search(r'New network discovered: (\d+\.\d+\.\d+)\.0/24 \(via ([^\)]+)\)', line)
    if m:
        net, via = m.group(1) + '.', m.group(2)
        if net not in state['zones']:
            state['zones'].add(net)
            state['stats']['nets'] += 1
            broadcast('net_discovered', {'net': net, 'via': via})
        return

    # Scanning net/24
    m = re.search(r'Scanning (\d+\.\d+\.\d+)\.0/24', line)
    if m:
        net = m.group(1) + '.'
        if net not in state['zones']:
            state['zones'].add(net)
            state['stats']['nets'] += 1
        broadcast('scanning', {'net': net})
        return

    # Brute-force failed
    m = re.search(r'Brute-force failed on (\d+\.\d+\.\d+\.\d+)', line)
    if m:
        ip = m.group(1)
        if ip in state['hosts']:
            state['hosts'][ip]['state'] = 'failed'
        broadcast('attack_fail', {'ip': ip})
        return

    # Fall-through: raw log line
    if line.strip():
        broadcast('log', {'line': line})

# ── Botnet runner ─────────────────────────────────────────────────────────────
def run_botnet(delay='0.5'):
    global _proc
    if state['running']:
        return

    # Reset state
    state['events'].clear()
    state['hosts'].clear()
    state['zones'].clear()
    _pending_via.clear()
    state['done'] = False
    state['running'] = True
    state['stats'] = {'found': 0, 'compromised': 0, 'nets': 0}
    broadcast('start', {'msg': 'Botnet started', 'delay': delay})

    cmd = ['podman', 'exec', 'attacker', 'python3', '/lab/botnet.py', '--delay', delay]
    try:
        with _proc_lock:
            _proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
            )
        for raw in _proc.stdout:
            line = raw.rstrip('\n')
            parse_line(line)
        _proc.wait()
        rc = _proc.returncode
    except FileNotFoundError:
        broadcast('error', {'msg': 'podman not found. Is the container running?'})
        rc = -1
    except Exception as e:
        broadcast('error', {'msg': str(e)})
        rc = -1
    finally:
        state['running'] = False
        state['done'] = True
        broadcast('done', {
            'returncode': rc,
            'compromised': state['stats']['compromised'],
            'found': state['stats']['found'],
        })
        with _proc_lock:
            _proc = None

def stop_botnet():
    global _proc
    with _proc_lock:
        if _proc:
            _proc.terminate()

def generate_report():
    hosts_list = []
    for ip, h in state['hosts'].items():
        hosts_list.append({
            'ip':  ip,
            'state': h.get('state', 'unknown'),
            'user':  h.get('user', ''),
            'pwd':   h.get('pwd', ''),
            'via':   h.get('via', 'direct'),
            'net':   h.get('prefix', ''),
        })
    # Count brute-force attempts per target for IDS simulation
    attack_counts = {}
    for ev in state['events']:
        if ev['type'] == 'attack_start':
            ip = ev['data'].get('ip', '')
            attack_counts[ip] = attack_counts.get(ip, 0) + 1
    ids_alerts = []
    for ip, cnt in attack_counts.items():
        if cnt >= 3:
            ids_alerts.append(f"BRUTE_FORCE: {cnt} attempts against {ip} from 172.21.0.10")
    pivot_hosts = {h['via'] for h in hosts_list if h['state'] == 'compromised' and h['via'] not in ('direct', '')}
    for ph in pivot_hosts:
        ids_alerts.append(f"PIVOT_DETECTED: lateral movement through {ph}")
    return {
        'stats':   state['stats'],
        'hosts':   hosts_list,
        'alerts':  ids_alerts,
        'running': state['running'],
        'done':    state['done'],
    }

def apply_defense(action: str, target: str):
    allowed_targets = {'victim1', 'victim2', 'victim3', 'victim4', 'victim5', 'honeypot'}
    if target not in allowed_targets:
        return False, f"Unknown target: {target}"
    exe = 'podman' if os.path.exists('/usr/bin/podman') else 'docker'
    cmds = {
        'fail2ban': [
            'bash', '-c',
            'apt-get install -y fail2ban -q 2>/dev/null; '
            'mkdir -p /etc/fail2ban && '
            'printf "[sshd]\\nenabled=true\\nmaxretry=5\\nfindtime=60\\nbantime=300\\n"'
            ' > /etc/fail2ban/jail.local && '
            'service fail2ban start 2>/dev/null || fail2ban-client start 2>/dev/null; echo done'
        ],
        'block_ip': [
            'bash', '-c',
            'iptables -C INPUT -s 172.21.0.10 -j DROP 2>/dev/null || '
            'iptables -A INPUT -s 172.21.0.10 -j DROP; echo done'
        ],
        'rate_limit': [
            'bash', '-c',
            'iptables -C INPUT -p tcp --dport 22 -m state --state NEW -m recent '
            '--update --seconds 60 --hitcount 10 -j DROP 2>/dev/null || ('
            'iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set; '
            'iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent '
            '--update --seconds 60 --hitcount 10 -j DROP); echo done'
        ],
        'disable_password': [
            'bash', '-c',
            'sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config && '
            'kill -HUP $(cat /var/run/sshd.pid 2>/dev/null || pgrep sshd | head -1) 2>/dev/null; echo done'
        ],
    }
    if action not in cmds:
        return False, f"Unknown action: {action}"
    try:
        result = subprocess.run(
            [exe, 'exec', target] + cmds[action],
            capture_output=True, text=True, timeout=30
        )
        ok = result.returncode == 0
        msg = (result.stdout.strip() or result.stderr.strip() or ('ok' if ok else 'failed'))[:120]
        if ok:
            if target not in defense_status:
                defense_status[target] = set()
            defense_status[target].add(action)
        return ok, msg
    except Exception as e:
        return False, str(e)[:120]

# ── SSE client handler ────────────────────────────────────────────────────────
def sse_stream(wfile):
    q = queue.Queue(maxsize=500)
    with _clients_lock:
        _clients.append(q)
    try:
        # Replay existing events to catch up
        for ev in list(state['events']):
            msg = ('data: ' + json.dumps(ev) + '\n\n').encode()
            wfile.write(msg)
        wfile.flush()
        # Stream live events — never close; keepalive pings prevent reconnect loops
        while True:
            try:
                msg = q.get(timeout=15)
                wfile.write(msg)
                wfile.flush()
            except queue.Empty:
                wfile.write(b': keepalive\n\n')
                wfile.flush()
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    finally:
        with _clients_lock:
            if q in _clients:
                _clients.remove(q)

# ── HTML page ─────────────────────────────────────────────────────────────────
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SSH Botnet Lab — Live Monitor</title>
<style>
html,body{height:100%;margin:0;padding:0;overflow:hidden}
*{box-sizing:border-box}
body{background:#080d1a;color:#cdd6f4;font-family:'Courier New',monospace;display:flex;flex-direction:column}
/* Header */
.hdr{background:linear-gradient(90deg,#0a0a1e,#080d1a);border-bottom:1px solid #1e2235;padding:10px 20px;display:flex;align-items:center;gap:14px;flex-shrink:0}
.hdr-title{font-size:16px;color:#f8f8f2;letter-spacing:2px}
.hdr-sub{font-size:10px;color:#6272a4;margin-top:2px}
.stat-bar{display:flex;gap:18px;margin-left:auto;align-items:center}
.stat{font-size:11px;color:#44475a}
.stat span{color:#cdd6f4;font-weight:bold}
.pulse{width:8px;height:8px;border-radius:50%;background:#44475a;display:inline-block;margin-right:6px}
.pulse.running{background:#50fa7b;animation:blink 1s infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}
/* Controls */
.controls{background:#0a0f1e;border-bottom:1px solid #1e2235;padding:8px 20px;display:flex;gap:8px;align-items:center;flex-shrink:0}
.btn{background:#1a1f2e;border:1px solid #2a3050;color:#cdd6f4;padding:5px 14px;border-radius:4px;cursor:pointer;font-family:'Courier New',monospace;font-size:12px;transition:all .15s}
.btn:hover{background:#252a3e;border-color:#6272a4}
.btn.run{border-color:#50fa7b;color:#50fa7b}
.btn.run:hover{background:#0a200a}
.btn.stop{border-color:#ff5555;color:#ff5555}
.btn.stop:hover{background:#200a0a}
.btn:disabled{opacity:.4;cursor:default}
.speed-label{font-size:11px;color:#44475a;margin-left:8px}
select{background:#1a1f2e;border:1px solid #2a3050;color:#cdd6f4;padding:4px 8px;border-radius:4px;font-family:'Courier New',monospace;font-size:11px}
/* Main layout */
.main{flex:1;display:flex;min-height:0}
/* SVG panel */
.svg-panel{flex:1;padding:14px;display:flex;flex-direction:column;gap:10px;min-width:0;overflow:hidden}
.svg-wrap{flex:1;background:#0d1117;border:1px solid #1e2235;border-radius:6px;overflow:hidden;display:flex;align-items:center;justify-content:center}
#diagram{width:100%;height:100%}
/* Status bar under SVG */
.phase-bar{background:#0d1117;border:1px solid #1e2235;border-radius:6px;padding:8px 14px;flex-shrink:0}
.phase-name{font-size:13px;color:#f8f8f2;margin-bottom:2px}
.phase-desc{font-size:11px;color:#6272a4}
/* Log panel */
.log-panel{width:360px;background:#0a0f1e;border-left:1px solid #1e2235;display:flex;flex-direction:column;flex-shrink:0}
.log-title{font-size:10px;color:#44475a;letter-spacing:2px;text-transform:uppercase;padding:10px 14px 6px;border-bottom:1px solid #1e2235}
.log-feed{flex:1;overflow-y:auto;padding:8px 12px;display:flex;flex-direction:column;gap:3px}
.log-entry{font-size:10px;line-height:1.5;display:flex;gap:6px}
.log-ts{color:#44475a;flex-shrink:0}
.log-msg{word-break:break-all}
.log-ok{color:#50fa7b}.log-attack{color:#f97316}.log-pwned{color:#ffb86c}.log-pivot{color:#a855f7}
.log-warn{color:#ff5555}.log-info{color:#6272a4}.log-done{color:#50fa7b;font-weight:bold}
/* Report panel */
.report-panel{border-top:1px solid #1e2235;padding:10px 14px;max-height:160px;overflow-y:auto}
.report-title{font-size:10px;color:#44475a;letter-spacing:2px;text-transform:uppercase;margin-bottom:8px}
.host-entry{font-size:10px;padding:4px 8px;border-radius:3px;border-left:3px solid #1e2235;margin-bottom:3px;color:#44475a}
.host-entry.compromised{border-left-color:#ffb86c;color:#cdd6f4}
.host-entry.open{border-left-color:#3b82f6}
.host-entry.attacking{border-left-color:#f97316}
.host-entry.failed{border-left-color:#44475a}
/* Modal system */
.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.78);z-index:100;align-items:center;justify-content:center}
.modal-overlay.open{display:flex}
.modal{background:#0d1117;border:1px solid #2a3050;border-radius:8px;width:710px;max-width:95vw;max-height:87vh;display:flex;flex-direction:column;overflow:hidden}
.modal-hdr{background:#0a0f1e;padding:13px 18px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #1e2235;flex-shrink:0}
.modal-hdr h2{margin:0;font-size:12px;color:#f8f8f2;letter-spacing:2px}
.modal-close{background:none;border:none;color:#6272a4;font-size:18px;cursor:pointer;line-height:1}
.modal-body{padding:16px 18px;overflow-y:auto;flex:1}
.modal-section{margin-bottom:16px}
.modal-section h3{font-size:10px;color:#44475a;letter-spacing:2px;text-transform:uppercase;margin:0 0 8px}
/* Report stat grid */
.report-stat-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:4px}
.r-stat{background:#1a1f2e;border-radius:4px;padding:10px 12px;text-align:center}
.r-stat .val{font-size:22px;font-weight:bold;color:#f8f8f2}
.r-stat .lbl{font-size:9px;color:#44475a;margin-top:2px;text-transform:uppercase;letter-spacing:1px}
/* Hosts table */
table.host-tbl{width:100%;border-collapse:collapse;font-size:10px}
table.host-tbl th{color:#44475a;text-align:left;padding:4px 8px;border-bottom:1px solid #1e2235;font-size:9px;letter-spacing:1px;text-transform:uppercase}
table.host-tbl td{padding:5px 8px;border-bottom:1px solid #0a0f1e}
table.host-tbl tr.comp td{color:#ffb86c}
table.host-tbl tr.open td{color:#3b82f6}
table.host-tbl tr.fail td{color:#44475a}
/* Infection chain */
.chain-row{margin-bottom:8px}
.chain-node{display:inline-block;background:#1a1f2e;border:1px solid #2a3050;padding:3px 9px;border-radius:12px;font-size:10px}
.chain-arrow{color:#50fa7b;margin:0 5px;font-size:12px}
/* IDS alerts */
.alert-item{font-size:10px;padding:5px 8px;background:#1a0808;border-left:3px solid #ff5555;border-radius:2px;margin-bottom:4px;color:#ff8080}
/* Defenses grid */
.def-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.def-card{background:#1a1f2e;border:1px solid #2a3050;border-radius:6px;padding:12px}
.def-card h4{margin:0 0 4px;font-size:11px}
.def-card p{margin:0 0 10px;font-size:10px;color:#6272a4;line-height:1.5}
.def-targets{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px}
.def-target{background:#0d1117;border:1px solid #2a3050;color:#6272a4;font-size:10px;padding:3px 8px;border-radius:3px;cursor:pointer;font-family:'Courier New',monospace;transition:all .15s}
.def-target:hover{border-color:#6272a4;color:#cdd6f4}
.def-target.applied{border-color:#50fa7b !important;color:#50fa7b}
.def-status{font-size:9px;color:#44475a;min-height:14px;word-break:break-all}
/* Extra control buttons */
.btn.report-btn{border-color:#bd93f9;color:#bd93f9}
.btn.report-btn:hover{background:#1a0a2e}
.btn.defend-btn{border-color:#14b8a6;color:#14b8a6}
.btn.defend-btn:hover{background:#0a1e1e}
</style>
</head>
<body>

<div class="hdr">
  <div>
    <div class="hdr-title">SSH BOTNET LAB</div>
    <div class="hdr-sub">FEUP SSR — Real-Time Propagation Monitor</div>
  </div>
  <div class="stat-bar">
    <div class="stat"><span class="pulse" id="pulse"></span><span id="status-text">Idle</span></div>
    <div class="stat">Hosts: <span id="stat-found">0</span> found</div>
    <div class="stat">Compromised: <span id="stat-comp">0</span></div>
    <div class="stat">Networks: <span id="stat-nets">0</span></div>
  </div>
</div>

<div class="controls">
  <button class="btn run" id="btn-run" onclick="startRun()">▶ Run Botnet</button>
  <button class="btn stop" id="btn-stop" onclick="stopRun()" disabled>■ Stop</button>
  <button class="btn" onclick="resetView()">&#8635; Reset View</button>
  <button class="btn report-btn" onclick="openReport()">&#128203; Report</button>
  <button class="btn defend-btn" onclick="openDefend()">&#128737; Defenses</button>
  <span class="speed-label">Delay:</span>
  <select id="delay-sel">
    <option value="0.2">Fast (0.2s)</option>
    <option value="0.5" selected>Normal (0.5s)</option>
    <option value="1.0">Slow (1.0s)</option>
  </select>
</div>

<div class="main">
  <div class="svg-panel">
    <div class="svg-wrap">
      <svg id="diagram" viewBox="0 0 820 460" xmlns="http://www.w3.org/2000/svg">
        <defs>
          <filter id="glow-r"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
          <filter id="glow-o"><feGaussianBlur stdDeviation="5" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
          <filter id="glow-g"><feGaussianBlur stdDeviation="4" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
          <marker id="arr" markerWidth="7" markerHeight="7" refX="5" refY="3.5" orient="auto">
            <path d="M0,0 L7,3.5 L0,7 Z" fill="#50fa7b" fill-opacity=".7"/>
          </marker>
        </defs>
        <!-- edges go under everything -->
        <g id="edges"></g>
        <!-- Dynamic zones and nodes -->
        <g id="zones"></g>
        <g id="nodes"></g>
        <!-- Attacker node drawn last so it always renders on top -->
        <g id="node-atk">
          <circle cx="110" cy="380" r="32" fill="#180808" stroke="#ef4444" stroke-width="2.5" filter="url(#glow-r)"/>
          <text x="110" y="375" text-anchor="middle" fill="#ef4444" font-family="monospace" font-size="11" font-weight="bold">ATK</text>
          <text x="110" y="425" text-anchor="middle" fill="#ef4444" font-family="monospace" font-size="10">ATTACKER</text>
          <text x="110" y="439" text-anchor="middle" fill="#44475a" font-family="monospace" font-size="9">172.21.0.10</text>
        </g>
        <!-- Packets layer (animated dots) -->
        <g id="packets"></g>
      </svg>
    </div>
    <div class="phase-bar">
      <div class="phase-name" id="phase-name">Ready</div>
      <div class="phase-desc" id="phase-desc">Click "Run Botnet" to start autonomous propagation. Ensure containers are up first.</div>
    </div>
  </div>

  <div class="log-panel">
    <div class="log-title">Live Output</div>
    <div class="log-feed" id="log-feed"></div>
    <div class="report-panel">
      <div class="report-title">Host Report</div>
      <div id="host-report"></div>
    </div>
  </div>
</div>

<!-- ── Report Modal ─────────────────────────────────────────────── -->
<div class="modal-overlay" id="modal-report" onclick="if(event.target===this)closeModal('modal-report')">
  <div class="modal">
    <div class="modal-hdr">
      <h2>&#128203; ATTACK REPORT</h2>
      <button class="modal-close" onclick="closeModal('modal-report')">&#x2715;</button>
    </div>
    <div class="modal-body" id="report-body">
      <div style="color:#6272a4;font-size:12px;text-align:center;padding:40px 0">Loading&#8230;</div>
    </div>
  </div>
</div>

<!-- ── Defenses Modal ────────────────────────────────────────────── -->
<div class="modal-overlay" id="modal-defend" onclick="if(event.target===this)closeModal('modal-defend')">
  <div class="modal">
    <div class="modal-hdr">
      <h2>&#128737; DEFENSIVE COUNTERMEASURES</h2>
      <button class="modal-close" onclick="closeModal('modal-defend')">&#x2715;</button>
    </div>
    <div class="modal-body">
      <div class="modal-section">
        <h3>Apply per-container defenses</h3>
        <p style="font-size:10px;color:#6272a4;margin:0 0 14px">Select a defense then click a victim container to apply it live. Effects immediately influence whether the botnet can compromise that host.</p>
      </div>
      <div class="def-grid" id="def-grid"></div>
    </div>
  </div>
</div>

<script>
/* ── Zone layout ──────────────────────────────────────────────────── */
const ZONE_DEFS = {
  '172.21.': {x:10,  y:20, w:210, h:420, color:'#ef4444', label:'ATTACK_NET · 172.21.0.0/24',  zone:0},
  '10.10.':  {x:250, y:20, w:210, h:205, color:'#3b82f6', label:'INTERNAL_NET · 10.10.0.0/24', zone:1},
  '10.20.':  {x:250, y:235,w:210, h:205, color:'#a855f7', label:'EXTRA_NET · 10.20.0.0/24',    zone:2},
  '10.30.':  {x:490, y:20, w:210, h:420, color:'#14b8a6', label:'DEEP_NET · 10.30.0.0/24',     zone:3},
};

/* zone -> slot index for node positioning */
const zoneSlots = {'172.21.':0,'10.10.':0,'10.20.':0,'10.30.':0};
const nodesData  = {}; /* ip -> {cx,cy,prefix,state} */
const zonesDrawn = new Set();

const NS  = 'http://www.w3.org/2000/svg';
const svg = document.getElementById('diagram');
const edgesG  = document.getElementById('edges');
const nodesG  = document.getElementById('nodes');
const zonesG  = document.getElementById('zones');
const pktsG   = document.getElementById('packets');

/* attacker fixed at bottom of attack_net zone */
nodesData['172.21.0.10'] = {cx:110, cy:380, prefix:'172.21.'};
nodesData['direct']       = {cx:110, cy:380, prefix:'172.21.'};

function getPrefix(ip) {
  for (const p of Object.keys(ZONE_DEFS)) {
    if (ip.startsWith(p)) return p;
  }
  return null;
}

function ensureZone(prefix) {
  if (zonesDrawn.has(prefix)) return;
  zonesDrawn.add(prefix);
  const d = ZONE_DEFS[prefix];
  if (!d) return;

  const rect = document.createElementNS(NS,'rect');
  rect.setAttribute('x',d.x); rect.setAttribute('y',d.y);
  rect.setAttribute('width',d.w); rect.setAttribute('height',d.h);
  rect.setAttribute('rx','8');
  rect.setAttribute('fill',d.color); rect.setAttribute('fill-opacity','.04');
  rect.setAttribute('stroke',d.color); rect.setAttribute('stroke-opacity','.3');
  rect.setAttribute('stroke-width','1.5');
  zonesG.appendChild(rect);

  const txt = document.createElementNS(NS,'text');
  txt.setAttribute('x', d.x+14); txt.setAttribute('y', d.y+18);
  txt.setAttribute('fill',d.color); txt.setAttribute('fill-opacity','.55');
  txt.setAttribute('font-family','monospace'); txt.setAttribute('font-size','10');
  txt.setAttribute('font-weight','bold');
  txt.textContent = d.label;
  zonesG.appendChild(txt);
}

function allocPos(prefix) {
  const d = ZONE_DEFS[prefix];
  const idx = zoneSlots[prefix] !== undefined ? zoneSlots[prefix] : 0;
  zoneSlots[prefix] = idx + 1;
  const cx = d.x + d.w/2;
  const cy = d.y + 55 + idx * 115;
  return {cx, cy};
}

function addNode(ip, initState='open') {
  if (nodesData[ip]) { setNodeState(ip, initState); return; }
  const prefix = getPrefix(ip);
  if (!prefix) return;
  ensureZone(prefix);
  const {cx,cy} = allocPos(prefix);
  nodesData[ip] = {cx, cy, prefix, state: initState};

  const isPivot = initState === 'pivot';
  const colors = {open:'#3b82f6', compromised:'#ffb86c', attacking:'#f97316', failed:'#44475a', pivot:'#a855f7'};
  const stroke = colors[initState] || '#3b82f6';

  const g = document.createElementNS(NS,'g');
  g.id = 'nd-' + ip.replace(/\./g,'_');

  const c = document.createElementNS(NS,'circle');
  c.setAttribute('cx',cx); c.setAttribute('cy',cy); c.setAttribute('r','26');
  c.setAttribute('fill','#0a1020');
  c.setAttribute('stroke', stroke); c.setAttribute('stroke-width','2');
  g.appendChild(c);

  const lbl = document.createElementNS(NS,'text');
  lbl.setAttribute('x',cx); lbl.setAttribute('y',cy-5);
  lbl.setAttribute('text-anchor','middle');
  lbl.setAttribute('fill',stroke);
  lbl.setAttribute('font-family','monospace'); lbl.setAttribute('font-size','9');
  lbl.setAttribute('font-weight','bold');
  lbl.textContent = 'HOST';
  g.appendChild(lbl);

  const ipTxt = document.createElementNS(NS,'text');
  ipTxt.setAttribute('x',cx); ipTxt.setAttribute('y',cy+7);
  ipTxt.setAttribute('text-anchor','middle');
  ipTxt.setAttribute('fill','#8be9fd');
  ipTxt.setAttribute('font-family','monospace'); ipTxt.setAttribute('font-size','8');
  ipTxt.textContent = ip;
  g.appendChild(ipTxt);

  nodesG.appendChild(g);
}

function setNodeState(ip, newState) {
  const nd = nodesData[ip];
  if (!nd) return;
  nd.state = newState;
  const g = document.getElementById('nd-' + ip.replace(/\./g,'_'));
  if (!g) return;
  const c = g.querySelector('circle');
  const lbl = g.querySelector('text');
  if (!c) return;
  const map = {open:'#3b82f6', attacking:'#f97316', compromised:'#ffb86c', failed:'#44475a', pivot:'#a855f7'};
  const col = map[newState] || '#3b82f6';
  c.setAttribute('stroke', col);
  c.setAttribute('stroke-width', newState==='compromised' ? '3' : '2');
  c.style.filter = newState==='compromised' ? 'drop-shadow(0 0 10px #ffb86c)' : '';
  if (lbl) lbl.setAttribute('fill', col);
}

function addEdge(fromIp, toIp, color='#2a3050', dashed=true) {
  const from = nodesData[fromIp] || nodesData['direct'];
  const to   = nodesData[toIp];
  if (!from || !to) { setTimeout(()=>addEdge(fromIp,toIp,color,dashed),600); return; }

  const line = document.createElementNS(NS,'line');
  line.setAttribute('x1',from.cx); line.setAttribute('y1',from.cy);
  line.setAttribute('x2',to.cx);   line.setAttribute('y2',to.cy);
  line.setAttribute('stroke',color); line.setAttribute('stroke-width','1.5');
  if (dashed) line.setAttribute('stroke-dasharray','5,4');
  else        line.setAttribute('marker-end','url(#arr)');
  edgesG.appendChild(line);
}

function animatePacket(fromIp, toIp, color) {
  const from = nodesData[fromIp] || nodesData['direct'];
  const to   = nodesData[toIp];
  if (!from || !to) return;
  const c = document.createElementNS(NS,'circle');
  c.setAttribute('r','5'); c.setAttribute('fill',color); c.setAttribute('opacity','0');
  pktsG.appendChild(c);
  const dur=700, start=performance.now();
  function step(now){
    const t=Math.min((now-start)/dur,1);
    const e=t<.5?2*t*t:-1+(4-2*t)*t;
    c.setAttribute('cx',from.cx+(to.cx-from.cx)*e);
    c.setAttribute('cy',from.cy+(to.cy-from.cy)*e);
    c.setAttribute('opacity',t<.1?t*10:t>.85?(1-t)/.15:1);
    if(t<1)requestAnimationFrame(step);
    else pktsG.removeChild(c);
  }
  requestAnimationFrame(step);
}

/* ── Log feed ─────────────────────────────────────────────────────── */
const logFeed = document.getElementById('log-feed');

function addLog(ts, msg, cls='log-info') {
  const row = document.createElement('div');
  row.className = 'log-entry';
  row.innerHTML = `<span class="log-ts">${ts}</span><span class="log-msg ${cls}">${msg}</span>`;
  logFeed.appendChild(row);
  logFeed.scrollTop = logFeed.scrollHeight;
  // Trim to 400 lines
  while (logFeed.children.length > 400) logFeed.removeChild(logFeed.firstChild);
}

/* ── Stats ────────────────────────────────────────────────────────── */
function updateStats(data) {
  if (data.found      !== undefined) document.getElementById('stat-found').textContent = data.found;
  if (data.compromised!== undefined) document.getElementById('stat-comp').textContent  = data.compromised;
  if (data.nets       !== undefined) document.getElementById('stat-nets').textContent  = data.nets;
}

/* ── Host report panel ────────────────────────────────────────────── */
function updateReport() {
  const el = document.getElementById('host-report');
  el.innerHTML = Object.entries(hostStates).map(([ip,h])=>`
    <div class="host-entry ${h.state}">
      ${h.state==='compromised'?'★':h.state==='attacking'?'→':'·'} ${ip}
      ${h.user ? `<span style="color:#6272a4"> ${h.user}:${h.pwd}</span>` : ''}
      ${h.via ? `<span style="color:#44475a"> via ${h.via}</span>` : ''}
    </div>
  `).join('');
}
const hostStates = {};

/* ── Event handler ────────────────────────────────────────────────── */
function handleEvent(ev) {
  const {type, data, ts} = ev;

  if (type === 'start') {
    document.getElementById('pulse').classList.add('running');
    document.getElementById('status-text').textContent = 'Running';
    document.getElementById('phase-name').textContent = 'Phase 1 — Network Discovery';
    document.getElementById('phase-desc').textContent = 'Scanning local interfaces…';
    document.getElementById('btn-run').disabled = true;
    document.getElementById('btn-stop').disabled = false;
    addLog(ts, '▶ Botnet started', 'log-ok');
  }
  else if (type === 'scanning') {
    ensureZone(data.net.slice(0,-1).split('.').slice(0,2).join('.')+'.'); // try to pre-draw zone
    ensureZone(data.net);
    document.getElementById('phase-name').textContent = 'Scanning ' + data.net + '0/24';
    document.getElementById('phase-desc').textContent = 'Probing hosts for open SSH port 22…';
    addLog(ts, `· Scanning ${data.net}0/24`, 'log-info');
  }
  else if (type === 'host_open') {
    addNode(data.ip, 'open');
    addEdge('direct', data.ip, '#2a3050', true);
    hostStates[data.ip] = {state:'open'};
    updateReport();
    addLog(ts, `✓ OPEN ${data.ip}`, 'log-ok');
  }
  else if (type === 'attack_start') {
    addNode(data.ip, 'attacking');
    setNodeState(data.ip, 'attacking');
    hostStates[data.ip] = {...(hostStates[data.ip]||{}), state:'attacking', via:data.via};
    updateReport();
    animatePacket(data.via==='direct'?'172.21.0.10':data.via, data.ip, '#ff5555');
    document.getElementById('phase-name').textContent = 'Brute-forcing ' + data.ip;
    document.getElementById('phase-desc').textContent = `Via ${data.via} — trying credential combinations…`;
    addLog(ts, `→ Attacking ${data.ip} via ${data.via}`, 'log-attack');
  }
  else if (type === 'compromised') {
    addNode(data.ip, 'compromised');
    setNodeState(data.ip, 'compromised');
    // Draw solid success edge
    const fromIp = data.via === 'direct' ? '172.21.0.10' : data.via;
    addEdge(fromIp, data.ip, '#50fa7b', false);
    animatePacket(fromIp, data.ip, '#50fa7b');
    hostStates[data.ip] = {state:'compromised', user:data.user, pwd:data.pwd, via:data.via};
    updateReport();
    addLog(ts, `★ COMPROMISED ${data.ip}  ${data.user}:${data.pwd}`, 'log-pwned');
  }
  else if (type === 'attack_fail') {
    setNodeState(data.ip, 'failed');
    hostStates[data.ip] = {...(hostStates[data.ip]||{}), state:'failed'};
    updateReport();
    addLog(ts, `✗ Brute-force failed on ${data.ip}`, 'log-warn');
  }
  else if (type === 'net_discovered') {
    ensureZone(data.net);
    addLog(ts, `⤷ Network discovered: ${data.net}0/24 via ${data.via}`, 'log-pivot');
    document.getElementById('phase-desc').textContent = `Pivoting into ${data.net}0/24 via ${data.via}`;
  }
  else if (type === 'log') {
    const l = data.line;
    const cls = l.includes('★')?'log-pwned':l.includes('✓')?'log-ok':l.includes('→')?'log-attack':l.includes('⤷')?'log-pivot':l.includes('!')?'log-warn':'log-info';
    addLog(ts, l, cls);
  }
  else if (type === 'error') {
    addLog(ts, '! ' + data.msg, 'log-warn');
    document.getElementById('phase-name').textContent = 'Error';
    document.getElementById('phase-desc').textContent = data.msg;
  }
  else if (type === 'done') {
    document.getElementById('pulse').classList.remove('running');
    document.getElementById('status-text').textContent = 'Done';
    document.getElementById('btn-run').disabled = false;
    document.getElementById('btn-stop').disabled = true;
    document.getElementById('phase-name').textContent = '✓ Propagation Complete';
    document.getElementById('phase-desc').textContent =
      `${data.compromised} host(s) compromised out of ${data.found} found.`;
    addLog(ts, `■ Done — ${data.compromised} compromised / ${data.found} found`, 'log-done');
  }

  // Update stat bar
  fetch('/state').then(r=>r.json()).then(s=>updateStats(s.stats)).catch(()=>{});
}

/* ── SSE connection ───────────────────────────────────────────────── */
let evtSource;
function connect() {
  evtSource = new EventSource('/stream');
  evtSource.onmessage = e => { try { handleEvent(JSON.parse(e.data)); } catch(_){} };
  evtSource.onerror = () => { evtSource.close(); setTimeout(connect, 3000); };
}
connect();

/* ── Controls ─────────────────────────────────────────────────────── */
function startRun() {
  const delay = document.getElementById('delay-sel').value;
  fetch('/run?delay=' + delay);
}
function stopRun() {
  fetch('/stop');
}
function resetView() {
  fetch('/reset').then(() => location.reload());
}

/* ── Modal helpers ────────────────────────────────────────────── */
function closeModal(id) {
  document.getElementById(id).classList.remove('open');
}

/* ── Report Modal ─────────────────────────────────────────────── */
function openReport() {
  document.getElementById('modal-report').classList.add('open');
  document.getElementById('report-body').innerHTML =
    '<div style="color:#6272a4;font-size:12px;text-align:center;padding:40px 0">Loading…</div>';
  fetch('/report')
    .then(r => r.json())
    .then(data => renderReport(data))
    .catch(() => {
      document.getElementById('report-body').innerHTML =
        '<div style="color:#ff5555;font-size:11px">Failed to load report.</div>';
    });
}

function renderReport(d) {
  const s = d.stats || {};
  const hosts = d.hosts || [];
  const alerts = d.alerts || [];

  let html = `<div class="modal-section">
    <h3>Summary</h3>
    <div class="report-stat-grid">
      <div class="r-stat"><div class="val" style="color:#f97316">${s.found||0}</div><div class="lbl">Hosts Found</div></div>
      <div class="r-stat"><div class="val" style="color:#ffb86c">${s.compromised||0}</div><div class="lbl">Compromised</div></div>
      <div class="r-stat"><div class="val" style="color:#3b82f6">${s.nets||0}</div><div class="lbl">Networks</div></div>
    </div>
  </div>`;

  // Host table
  html += `<div class="modal-section"><h3>Host Details</h3>
  <table class="host-tbl"><tr><th>IP</th><th>Network</th><th>Status</th><th>Credentials</th><th>Via</th></tr>`;
  for (const h of hosts) {
    const cls = h.state==='compromised'?'comp':h.state==='open'?'open':'fail';
    const cred = h.user ? `${h.user} / ${h.pwd}` : '—';
    const via = h.via && h.via !== 'direct' ? h.via : 'direct';
    html += `<tr class="${cls}"><td>${h.ip}</td><td>${h.net||'?'}</td><td>${h.state}</td><td style="font-family:monospace">${cred}</td><td>${via}</td></tr>`;
  }
  html += `</table></div>`;

  // Infection chains
  const comped = hosts.filter(h => h.state === 'compromised');
  if (comped.length) {
    html += `<div class="modal-section"><h3>Infection Chain</h3>`;
    for (const chain of buildChains(comped)) {
      html += `<div class="chain-row">` +
        chain.map(n => `<span class="chain-node">${n}</span>`).join(`<span class="chain-arrow">→</span>`) +
        `</div>`;
    }
    html += `</div>`;
  }

  // IDS alerts
  if (alerts.length) {
    html += `<div class="modal-section"><h3>Simulated IDS Alerts</h3>`;
    for (const a of alerts)
      html += `<div class="alert-item">⚠ ${a}</div>`;
    html += `</div>`;
  } else {
    html += `<div class="modal-section"><h3>Simulated IDS Alerts</h3>
      <div style="font-size:10px;color:#44475a">No alerts triggered yet — run the botnet first.</div></div>`;
  }

  document.getElementById('report-body').innerHTML = html;
}

function buildChains(hosts) {
  const viaMap = {};
  for (const h of hosts) viaMap[h.ip] = (h.via && h.via !== 'direct') ? h.via : null;
  const seenKeys = new Set();
  const chains = [];
  for (const h of hosts) {
    const path = [];
    let cur = h.ip;
    const seen = new Set();
    while (cur && !seen.has(cur)) {
      seen.add(cur);
      path.unshift(cur);
      cur = viaMap[cur] || null;
    }
    const chain = ['ATTACKER'].concat(path);
    const key = chain.join('>');
    if (!seenKeys.has(key)) { seenKeys.add(key); chains.push(chain); }
  }
  return chains;
}

/* ── Defenses Modal ───────────────────────────────────────────── */
const DEFENSE_DEFS = [
  { id:'fail2ban',         name:'fail2ban',            color:'#50fa7b',
    desc:'Installs fail2ban and configures SSH jail: ban after 5 failed attempts within 60 s for 5 min.' },
  { id:'block_ip',         name:'Block Attacker IP',   color:'#ff5555',
    desc:'iptables DROP rule for all packets from 172.21.0.10 (attacker). Botnet connections immediately refused.' },
  { id:'rate_limit',       name:'SSH Rate Limit',      color:'#f97316',
    desc:'iptables conntrack: drops connections exceeding 10 new SSH conns per 60 s from a single source.' },
  { id:'disable_password', name:'Disable Password Auth', color:'#bd93f9',
    desc:'Sets PasswordAuthentication no in sshd_config and reloads sshd. Forces key-only authentication.' },
];
const VICTIMS = ['victim1','victim2','victim3','victim4','victim5'];
const defenseApplied = {};  // target -> Set<action id>

function openDefend() {
  document.getElementById('modal-defend').classList.add('open');
  renderDefenseGrid();
}

function renderDefenseGrid() {
  const grid = document.getElementById('def-grid');
  grid.innerHTML = DEFENSE_DEFS.map(def => {
    const btns = VICTIMS.map(v => {
      const applied = (defenseApplied[v] || new Set()).has(def.id);
      return `<button class="def-target ${applied?'applied':''}" id="def-${def.id}-${v}"
        style="${applied?'border-color:'+def.color+';color:'+def.color:''}"
        onclick="applyDefense('${def.id}','${v}')">${v}</button>`;
    }).join('');
    return `<div class="def-card">
      <h4 style="color:${def.color}">${def.name}</h4>
      <p>${def.desc}</p>
      <div class="def-targets">${btns}</div>
      <div class="def-status" id="def-status-${def.id}"></div>
    </div>`;
  }).join('');
}

function applyDefense(action, target) {
  const btn = document.getElementById(`def-${action}-${target}`);
  const statusEl = document.getElementById(`def-status-${action}`);
  if (btn) { btn.disabled = true; btn.textContent = target + '…'; }
  if (statusEl) statusEl.textContent = `Applying ${action} to ${target}…`;
  fetch(`/defend?action=${encodeURIComponent(action)}&target=${encodeURIComponent(target)}`)
    .then(r => r.json())
    .then(data => {
      if (!defenseApplied[target]) defenseApplied[target] = new Set();
      const def = DEFENSE_DEFS.find(d => d.id === action) || {};
      if (data.ok) {
        defenseApplied[target].add(action);
        if (btn) {
          btn.classList.add('applied');
          btn.style.borderColor = def.color || '#50fa7b';
          btn.style.color = def.color || '#50fa7b';
          btn.disabled = false;
          btn.textContent = target;
        }
        if (statusEl) statusEl.textContent = `✓ ${target}: ${data.msg}`;
      } else {
        if (btn) { btn.disabled = false; btn.textContent = target; }
        if (statusEl) statusEl.textContent = `✗ ${target}: ${data.msg}`;
      }
    })
    .catch(err => {
      if (btn) { btn.disabled = false; btn.textContent = target; }
      if (statusEl) statusEl.textContent = `Error: ${err}`;
    });
}
</script>
</body>
</html>"""

# ── HTTP request handler ──────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        params = parse_qs(parsed.query)

        if path == '/':
            body = HTML.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif path == '/stream':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            sse_stream(self.wfile)

        elif path == '/run':
            delay = params.get('delay', ['0.5'])[0]
            if not state['running']:
                t = threading.Thread(target=run_botnet, args=(delay,), daemon=True)
                t.start()
            self.send_response(204)
            self.end_headers()

        elif path == '/stop':
            stop_botnet()
            self.send_response(204)
            self.end_headers()

        elif path == '/reset':
            if not state['running']:
                state['events'].clear()
                state['hosts'].clear()
                state['zones'].clear()
                _pending_via.clear()
                state['done'] = False
                state['stats'] = {'found': 0, 'compromised': 0, 'nets': 0}
            self.send_response(204)
            self.end_headers()

        elif path == '/state':
            body = json.dumps({
                'stats': state['stats'],
                'hosts': {ip: {k:v for k,v in h.items() if k not in ('cx','cy')}
                          for ip,h in state['hosts'].items()},
                'running': state['running'],
                'done':    state['done'],
            }).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif path == '/report':
            body = json.dumps(generate_report()).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif path == '/defend':
            action = params.get('action', [''])[0]
            target = params.get('target', [''])[0]
            ok, msg = apply_defense(action, target)
            body = json.dumps({'ok': ok, 'msg': msg}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_):
        pass  # suppress server access logs

class ThreadedServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
    server = ThreadedServer(('0.0.0.0', port), Handler)
    print(f"""
╔══════════════════════════════════════════════════════════╗
║  SSH Botnet Lab — Live GUI                               ║
╚══════════════════════════════════════════════════════════╝
  Open: http://localhost:{port}

  Requirements:
  - Podman/Docker containers must be running
  - Run the appropriate scenario first:
      podman-compose -f scenarios/scenario2.yml up -d

  Press Ctrl+C to stop.
""")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n[GUI] Shutting down.')
