# kaliSSR — Data Collection Notes
> **Note:** This is an informal Q&A reference. References to `Scenes*.txt` below are from an earlier lab version and no longer apply. Use `DATA_COLLECTION.md` for the current data collection guide.

---

Quick question what data i need to collect for the report

Based on the lab structure, here's what you should collect for each scenario you run:

1. Detection Report (most important)
- The final IDS summary — which rules fired, how many alerts, CRITICAL vs HIGH
- Already at the end of each Scenes*.txt

2. Auth Logs (evidence of the attacks)
podman exec victim1 cat /var/log/auth.log
podman exec victim3 cat /var/log/auth.log
podman exec victim4 cat /var/log/auth.log   # scenario 3 only

3. Honeypot Events
podman exec honeypot cat /var/log/lab/honeypot_events.jsonl

4. C2 Beacon Events
podman exec attacker cat /tmp/c2_events.jsonl
podman exec victim1  cat /tmp/relay_events.jsonl

5. Network Topology Evidence
podman exec victim1 ip addr    # shows dual-homed interfaces
podman exec victim2 ip addr    # scenario 3: shows extra_net interface

6. The Scenes.txt file itself* — it captures the entire run timeline end to end.

---
For the report analysis, you'll want to answer:
- What did each IDS rule detect and why does it indicate an attack?
- How did segmentation (scenario 1 vs 2 vs 3) affect what the attacker could reach?
- What would a defender do in response to each alert?
- Did any attack activity go undetected? Why?

The Scenes3.txt you have already contains most of this. Run scenarios 1, 2, and 4 as well and save each output — comparing them across scenarios is the core of the analysis.