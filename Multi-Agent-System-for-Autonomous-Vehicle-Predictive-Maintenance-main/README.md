# Multi-Agent System for Autonomous Vehicle Predictive Maintenance

A Jason (AgentSpeak) multi-agent system in which vehicles, a fleet coordinator, and a service
centre autonomously negotiate predictive maintenance. It is the integration layer of a three-course
project at the University of Bologna (MSc Computer Science, Intelligent Embedded Systems):

- **Codice 95631** — Machine Learning & Data Mining (maintenance prediction, anomaly detection)
- **Codice 87474** — Distributed Systems (blockchain, Byzantine validation, endorsement)
- **Codice 77780** — Embedded Systems & IoT (ESP32 telematics, ECDSA, MQTT)

Coordination is **stigmergic**: agents react to a shared `booking_pressure` signal instead of
negotiating point-to-point. The system runs standalone with mock IoT/ML/blockchain adapters, and
can be pointed at a real Hyperledger Fabric backend by a single flag.

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Java JDK | 21 | `sourceCompatibility = 21` in `build.gradle` |
| Gradle | 7+ | Or use the `gradlew` wrapper |

> Jason is pulled automatically from Maven Central
> (`io.github.jason-lang:jason-interpreter:3.3.0`). **No manual jar download is needed.**

---

## Project structure

```
.
├── mas/
│   ├── maintenance.mas2j               # MAS entry point (run this)
│   ├── agents/
│   │   ├── fleet_coordinator_agent.asl # Dias
│   │   ├── vehicle_agent.asl           # Danial
│   │   └── service_center_agent.asl    # Mary
│   └── common/
│       └── shared_beliefs.asl          # Shared ontology (reference vocabulary)
├── env/
│   └── FleetMASEnvironment.java        # Java bridge (IoT + ML + Blockchain)
├── data/
│   └── scenarios/                      # scenario_normal / high_urgency / parts_shortage
├── docs/
│   ├── agent_design.md                 # BDI design of all agents + environment
│   ├── message_protocol.md             # Authoritative inter-agent protocol (ACL)
│   └── report/                         # Final report PDF goes here
├── tests/
│   └── results/                        # Captured / expected run transcripts per scenario
├── build.gradle
├── settings.gradle
└── README.md
```

See `docs/agent_design.md` and `docs/message_protocol.md` for the full design.

---

## Run

```bash
gradle run
```

This compiles `env/FleetMASEnvironment.java` and launches `mas/maintenance.mas2j` (1 fleet
coordinator, 3 vehicles, 1 service centre) on the local Jason infrastructure.

Capture a scenario transcript:

```bash
gradle run > tests/results/scenario_normal_results.txt 2>&1
```

---

## What you should see

A successful booking flows end-to-end through all three agents:

```
[FleetCoordinator] Booting up — stigmergy coordination active.
[ServiceCenterAgent] Operational. Ready for maintenance requests.
[ServiceCenterAgent] Advertising free capacity: 3
[FleetCoordinator] Vehicle registered: vehicle_agent1 — fleet size now 1
[FleetCoordinator] COLLECTIVE ALERT — anomaly pattern detected: brake_wear across 2 vehicles.
[FleetCoordinator] Broadcast sent: fleet_anomaly_alert(brake_wear,2).
[VehicleAgent:vehicle_agent1] Sending book_request to FleetCoordinator (part=brake_pad).
[FleetCoordinator] book_request from vehicle_agent1 ... — forwarding to ServiceCenter.
[ServiceCenterAgent] Resources found. Allocating slot1 to vehicle_agent1 (tech=tech_a)
[ServiceCenterAgent] Logged record #1 — vehicle=vehicle_agent1 part=brake_pad tech=tech_a cost=140
[FleetCoordinator] Cross-org endorsement of record #1 for vehicle_agent1 — APPROVE.
[ServiceCenterAgent] Record #1 ENDORSED (approve) — committed to ledger.
[VehicleAgent] Booking CONFIRMED at service_center_agent slot slot1.
```

---

## Message protocol (summary)

```
Vehicle  --book_request(V, Part, Urg)-->  Coordinator
Coordinator --booking_request(V, Part, Urg)--> Service
Service  --booking_confirmed(Slot, Center) | booking_deferred(Alt, Center) | booking_declined(Reason)--> Vehicle
Service  --booking_confirmed(V) | endorse_request(RID, V)--> Coordinator
Coordinator --endorsement(RID, approve|reject)--> Service
Coordinator --booking_pressure(L) | fleet_anomaly_alert(Type, N)--> (broadcast)
```

Full catalogue, sequence diagrams and invariants: `docs/message_protocol.md`.

---

## Real vs mock integrations

`env/FleetMASEnvironment.java` runs with mock adapters by default
(`USE_REAL_INTEGRATIONS = false`). Set it to `true` to point `writeServiceRecord` /
`logFleetAnomaly` at a Hyperledger-Fabric-backed Distributed Systems backend at
`http://localhost:3000`.

> The ML/crypto edge actions (`evaluateRandomForest`, `deriveECDSAKey`, …) are **acknowledgement
> hooks**: Jason environment actions cannot bind result variables back into a plan, so the
> VehicleAgent simulates these values internally. To use a real ML pipeline, convert them to
> percept-injecting actions or to prefixed internal actions. See `docs/agent_design.md` §5.

---

## Scenarios

| File | Demonstrates |
|------|--------------|
| `data/scenarios/scenario_normal.json` | All requests confirmed; records logged and endorsed |
| `data/scenarios/scenario_high_urgency.json` | Pressure escalates to critical; stigmergy load-shedding (defer) |
| `data/scenarios/scenario_parts_shortage.json` | Out-of-stock part is declined with reason |

> Scenario JSON files are not yet auto-loaded by the environment. To exercise the parts-shortage
> path, set `parts_inventory(brake_pad, 0)` in `service_center_agent.asl`, or extend
> `FleetMASEnvironment.init(args)` to read a scenario file and inject the initial beliefs.

---

## Team

| Agent | Owner | File |
|-------|-------|------|
| FleetCoordinatorAgent | Dias | `mas/agents/fleet_coordinator_agent.asl` |
| VehicleAgent | Danial | `mas/agents/vehicle_agent.asl` |
| ServiceCenterAgent | Mary | `mas/agents/service_center_agent.asl` |
| Java environment bridge | All | `env/FleetMASEnvironment.java` |
