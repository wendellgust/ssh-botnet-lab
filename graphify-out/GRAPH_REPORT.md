# Graph Report - .  (2026-05-23)

## Corpus Check
- Corpus is ~22,416 words - fits in a single context window. You may not need a graph.

## Summary
- 191 nodes · 356 edges · 16 communities (13 shown, 3 thin omitted)
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 35 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Docker Lab Infrastructure|Docker Lab Infrastructure]]
- [[_COMMUNITY_IDS Analyzer & Alerting|IDS Analyzer & Alerting]]
- [[_COMMUNITY_Botnet Propagation Engine|Botnet Propagation Engine]]
- [[_COMMUNITY_Lab Orchestration Runner|Lab Orchestration Runner]]
- [[_COMMUNITY_Victim Host Setup & Logging|Victim Host Setup & Logging]]
- [[_COMMUNITY_Lateral Movement Simulator|Lateral Movement Simulator]]
- [[_COMMUNITY_C2 Beacon Simulator|C2 Beacon Simulator]]
- [[_COMMUNITY_Port Scan Simulator|Port Scan Simulator]]
- [[_COMMUNITY_Infected Host Simulator|Infected Host Simulator]]
- [[_COMMUNITY_SSH Brute-Force Simulator|SSH Brute-Force Simulator]]
- [[_COMMUNITY_Lab Setup Script|Lab Setup Script]]
- [[_COMMUNITY_Dependency Installer|Dependency Installer]]
- [[_COMMUNITY_Scenario Documentation|Scenario Documentation]]
- [[_COMMUNITY_Monitor Entrypoint|Monitor Entrypoint]]
- [[_COMMUNITY_Scenario Launcher|Scenario Launcher]]
- [[_COMMUNITY_Attacker Entrypoint|Attacker Entrypoint]]

## God Nodes (most connected - your core abstractions)
1. `auto_run.sh script` - 13 edges
2. `log()` - 12 edges
3. `run_analysis()` - 12 edges
4. `Docker Compose Lab Definition` - 12 edges
5. `ok()` - 11 edges
6. `banner()` - 11 edges
7. `PortScanSimulator` - 10 edges
8. `C2HeartbeatSimulator` - 10 edges
9. `Alert` - 10 edges
10. `propagate()` - 9 edges

## Surprising Connections (you probably didn't know these)
- `setup.sh — Lab Setup Script` --semantically_similar_to--> `auto_run.sh — Fully Automatic Scenario Runner`  [INFERRED] [semantically similar]
  setup.sh → auto_run.sh
- `Scenario 2: Two Segmented Networks with Pivot` --semantically_similar_to--> `Docker Compose Lab Definition`  [INFERRED] [semantically similar]
  scenarios/scenario2.yml → docker-compose.yml
- `Attack Phase Animations (Recon, Brute-force, Lateral, C2, Full)` --conceptually_related_to--> `Attack Chain: Brute-force → Lateral Movement → C2 Beaconing`  [INFERRED]
  docs/attack_visualizer.html → README.md
- `Scenarios Network Topology Diagram (All 4 Scenarios)` --references--> `Scenario 1: Single Network (No Segmentation)`  [EXTRACTED]
  docs/scenarios_diagram.svg → scenarios/scenario1.yml
- `Scenarios Network Topology Diagram (All 4 Scenarios)` --references--> `Scenario 2: Two Segmented Networks with Pivot`  [EXTRACTED]
  docs/scenarios_diagram.svg → scenarios/scenario2.yml

## Hyperedges (group relationships)
- **Attack-Detect Feedback Loop: Simulator/Botnet generate auth.log entries consumed by Analyzer detection rules** — attacker_simulator_sshbruteforcesimulator, concept_auth_log, monitor_analyzer_rule_ssh_brute_force [INFERRED 0.95]
- **Honeypot Event Pipeline: victim-b sshd writes auth.log, honeypot_logger reads it and emits JSONL, analyzer ingests JSONL for HONEYPOT-001 and C2-001 rules** — victim_b_entrypoint_sh, victim_b_honeypot_logger_emit_event, concept_honeypot_events_jsonl, monitor_analyzer_parse_honeypot_log, monitor_analyzer_rule_honeypot_hit [EXTRACTED 0.95]
- **Autonomous Botnet Propagation Loop: scan → brute-force → compromise → discover new networks → scan** — attacker_botnet_scan_network, attacker_botnet_brute_force, attacker_botnet_get_networks_from_host, attacker_botnet_propagate [EXTRACTED 1.00]
- **Full Attack Chain: Recon → Brute-force → Lateral Movement → C2 Beaconing** — docs_lab_guide_phase1_recon, docs_lab_guide_phase2_bruteforce, docs_lab_guide_phase4_lateral, docs_lab_guide_phase5_c2 [EXTRACTED 1.00]
- **Scenario Network Topology Progression (1→2→3→4 increasing complexity)** — scenarios_scenario1_single_network, scenarios_scenario2_two_networks, scenarios_scenario3_three_networks, scenarios_scenario4_deep_chain [INFERRED 0.95]
- **Lab Documentation Corpus (README, LAB_GUIDE, explainSSR)** — readme_project_overview, docs_lab_guide_ssh_botnet_attack, docs_explainssr_full_explanation [INFERRED 0.85]

## Communities (16 total, 3 thin omitted)

### Community 0 - "Docker Lab Infrastructure"
Cohesion: 0.08
Nodes (42): attack_net Network (172.21.0.0/24), Attacker Container Service, Honeypot Container Service (prod-server-01), internal_net Network (10.10.0.0/24), Docker Compose Lab Definition, Monitor Container Service (Dual-homed IDS), Victim1 Container Service (Dual-homed Pivot), Victim2 Container Service (+34 more)

### Community 1 - "IDS Analyzer & Alerting"
Cohesion: 0.12
Nodes (24): Concept: /var/log/lab/honeypot_events.jsonl — Structured Honeypot Event Log, Alert, list_rules(), live_monitor(), main(), parse_auth_log(), parse_honeypot_log(), print_report() (+16 more)

### Community 2 - "Botnet Propagation Engine"
Cohesion: 0.23
Nodes (18): brute_force(), botnet.py — compromised{} — Global Infection State Dict, get_local_networks(), get_networks_from_host(), is_safe_target(), log(), main(), print_report() (+10 more)

### Community 3 - "Lab Orchestration Runner"
Cohesion: 0.40
Nodes (17): auto_run.sh script, banner(), fail(), log(), ok(), phase_bruteforce(), phase_c2(), phase_detect() (+9 more)

### Community 4 - "Victim Host Setup & Logging"
Cohesion: 0.20
Nodes (9): Concept: /var/log/auth.log — Shared SSH Log Artifact, entrypoint.sh script, entrypoint.sh script, entrypoint.sh script, firewall_setup.sh script, emit_event(), main(), Yield new lines from a log file as they appear. (+1 more)

### Community 5 - "Lateral Movement Simulator"
Cohesion: 0.21
Nodes (7): LateralMovementSimulator, Verify target is within allowed lab networks., Simulates an attacker using a compromised pivot machine to reach     machines in, Attempt SSH connection to an internal target., Simulate lateral movement from pivot to internal targets., safety_check(), setup_logging()

### Community 6 - "C2 Beacon Simulator"
Cohesion: 0.28
Nodes (6): C2HeartbeatSimulator, Simulates a botnet C2 (Command and Control) beacon protocol.     Bots periodical, Build a realistic beacon payload., Send a single beacon to the C2 server via raw TCP., Send beacons with jitter at regular intervals., Concept: C2 Beaconing / Heartbeat Protocol

### Community 7 - "Port Scan Simulator"
Cohesion: 0.28
Nodes (5): PortScanSimulator, Simulates network reconnaissance by probing TCP ports.     Uses real TCP connect, Try a TCP connection to host:port. Returns True if open., Scan common ports on a single host., Scan a range of hosts in the lab network.

### Community 8 - "Infected Host Simulator"
Cohesion: 0.33
Nodes (4): InfectedHostSimulator, Simulates behaviors of a machine that has already been compromised     and is ru, Build and log a status report (as if sending to C2)., Run the infected host simulation for a set duration.

### Community 9 - "SSH Brute-Force Simulator"
Cohesion: 0.33
Nodes (4): Simulates an SSH brute-force attack by attempting real SSH connections     with, Try a single SSH login. Returns True if successful., Run the brute-force simulation., SSHBruteforceSimulator

### Community 10 - "Lab Setup Script"
Cohesion: 0.52
Nodes (6): setup.sh script, fail(), info(), ok(), step(), warn()

### Community 11 - "Dependency Installer"
Cohesion: 0.52
Nodes (6): install.sh script, fail(), info(), ok(), step(), warn()

### Community 12 - "Scenario Documentation"
Cohesion: 0.50
Nodes (5): main(), auto_run.sh — Fully Automatic Scenario Runner, install.sh — Full Dependency Installer, setup.sh — Lab Setup Script, start.sh — Scenario Launcher

## Knowledge Gaps
- **11 isolated node(s):** `start.sh script`, `entrypoint.sh script`, `entrypoint.sh script`, `entrypoint.sh script`, `firewall_setup.sh script` (+6 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `auto_run.sh — Fully Automatic Scenario Runner` connect `Scenario Documentation` to `IDS Analyzer & Alerting`, `Victim Host Setup & Logging`?**
  _High betweenness centrality (0.105) - this node is a cross-community bridge._
- **Why does `main()` connect `Scenario Documentation` to `Lateral Movement Simulator`, `C2 Beacon Simulator`, `Port Scan Simulator`, `Infected Host Simulator`, `SSH Brute-Force Simulator`?**
  _High betweenness centrality (0.103) - this node is a cross-community bridge._
- **Why does `run_analysis()` connect `IDS Analyzer & Alerting` to `Scenario Documentation`?**
  _High betweenness centrality (0.070) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Docker Compose Lab Definition` (e.g. with `Scenario 1: Single Network (No Segmentation)` and `Scenario 2: Two Segmented Networks with Pivot`) actually correct?**
  _`Docker Compose Lab Definition` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `start.sh script`, `Return all /24 network prefixes visible from this machine.`, `SSH to a compromised host and discover its network interfaces.` to the rest of the system?**
  _46 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Docker Lab Infrastructure` be split into smaller, more focused modules?**
  _Cohesion score 0.08246225319396051 - nodes in this community are weakly interconnected._
- **Should `IDS Analyzer & Alerting` be split into smaller, more focused modules?**
  _Cohesion score 0.12169312169312169 - nodes in this community are weakly interconnected._