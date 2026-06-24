# Agent Design

Multi-Agent System for Autonomous Vehicle Predictive Maintenance
University of Bologna — MSc Computer Science (Intelligent Embedded Systems)
Courses: 95631 (ML & Data Mining), 87474 (Distributed Systems), 77780 (Embedded & IoT)

This document describes the Belief–Desire–Intention (BDI) design of the three agents and the
Java environment bridge, as actually implemented in `mas/agents/*.asl` and
`env/FleetMASEnvironment.java`. It is the design counterpart to `message_protocol.md`, which
specifies the inter-agent messages.

---

## 1. Overview

The MAS coordinates three roles so that a fleet of vehicles can autonomously detect maintenance
needs, negotiate service, and record the result on a (mock or real) blockchain — without a central
scheduler. Coordination is *stigmergic*: agents react to a shared `booking_pressure` signal rather
than negotiating point-to-point.

```
   VehicleAgent (x3) ──book_request──▶ FleetCoordinatorAgent ──booking_request──▶ ServiceCenterAgent
        ▲  ▲                                   │   ▲                                    │   │
        │  └──────booking_pressure (broadcast)─┘   └────booking_confirmed───────────────┘   │
        └──────────booking_confirmed / booking_deferred / booking_declined──────────────────┘
                                            (+ endorse_request / endorsement, Service ⇄ Coordinator)
```

The runtime (`maintenance.mas2j`) launches one `fleet_coordinator_agent`, three `vehicle_agent`
instances (`vehicle_agent1..3`), and one `service_center_agent`, all sharing the
`env.FleetMASEnvironment` environment.

---

## 2. VehicleAgent (`vehicle_agent.asl`) — owner: Danial

The VehicleAgent represents a single vehicle. Because Jason *environment* actions cannot bind
result variables back into a plan, the edge-sensing, ML inference and ECDSA signing are simulated
*inside* the agent; the corresponding environment actions are invoked only as success
acknowledgements.

### Beliefs (B)
| Belief | Meaning |
|---|---|
| `vin(V)` | Vehicle identification number (basis for the digital twin / ECDSA key) |
| `current_temperature(T)` | Latest simulated DS18B20 reading |
| `mileage(M)` | Simulated OBD-II odometer |
| `engine_status / battery_condition / brake_condition` | Component condition (ML features) |
| `reported_issues(I)` | Count of reported issues (top ML predictor) |
| `urgency_level(U)` | `low` or `high`, set by the mock Random Forest |
| `booking_status(S)` | `none` → `requested` → `confirmed` |
| `booking_pressure(P)` | Last stigmergy signal received from the coordinator |
| `service_part(P)` | Part to request when booking (`oil_filter`, or `brake_pad` after a brake alert) |
| `is_registered(B)` | Whether the vehicle twin is registered |

### Desires (D)
Minimise maintenance need, maintain data integrity (authenticated telemetry), register itself on
the blockchain, and obtain a service booking when the ML flags a problem — while respecting
fleet-wide congestion.

### Intentions / key plans (I)
- `!initialize_agent` → `!register_on_blockchain` (calls `registerVehicle`) → `!collect_telemetry`.
- `!collect_telemetry` loop: `!sense_edge` (random temperature 25–50 °C, +100 mi) →
  `!classify_health` (mock Random Forest + Isolation Forest) → `!sign_and_publish`
  (`deriveECDSAKey`, `signTelemetryRecord`) → `!evaluate_maintenance_need` →
  `!calculate_sampling_delay` (5 s / 2 s / 1 s by FSM state) → wait → repeat.
- `!request_fleet_booking`: defers autonomously under `booking_pressure(critical)`; otherwise
  sends `book_request(Me, Part, high)` to the coordinator.
- Reactive: `+booking_pressure`, `+fleet_anomaly_alert` (raises `reported_issues`, switches the
  requested part to `brake_pad` on a brake-wear pattern), and the booking outcomes
  `+booking_confirmed/2`, `+booking_deferred/2`, `+booking_declined/1`.

### Adaptive sampling (Layer-1 FSM mirror)
`T < 30 °C → 5 s`, `30 ≤ T < 40 → 2 s`, `T ≥ 40 → 1 s`.

---

## 3. FleetCoordinatorAgent (`fleet_coordinator_agent.asl`) — owner: Dias

The coordinator is the swarm-level regulator. It never schedules directly; it broadcasts a
`booking_pressure` signal, forwards booking requests to the service centre, detects fleet-wide
anomaly patterns from the IoT stream, and co-signs (endorses) service records.

### Beliefs (B)
| Belief | Meaning |
|---|---|
| `booking_pressure(L)` | Current stigmergy level: `low/medium/high/critical` |
| `fleet_size(N)` | Number of registered vehicles |
| `anomaly_count(Type, N)` | Running count per anomaly type |
| `anomaly_threshold(T)` | Vehicles sharing an anomaly before a collective alert (default 2) |
| `evaporation_rate / evaporation_counter` | Pheromone-style decay of pressure over ticks |
| `overload_threshold(T)` | Threshold for overload escalation |

### Desires (D)
Optimise fleet health, prevent cascading failures, and keep the service centre from being
overloaded, while maintaining a consistent shared state.

### Intentions / key plans (I)
- `!start` → register with the environment → `!broadcast_pressure` → `!monitor_fleet`.
- `!monitor_fleet` loop: `pollIoTAnomalyStream` (env injects `anomaly_detected/3`), wait 5 s, repeat.
- `+anomaly_detected` → `!update_anomaly_count` → `!check_pattern_alert`; at threshold it
  `!broadcast_collective_alert` (`fleet_anomaly_alert`) and `!notify_blockchain_anomaly`
  (`logFleetAnomalyToBlockchain`).
- `+book_request(V, Part, Urg)` → `!escalate_pressure` → forward `booking_request` to the service
  centre → `!check_overload`.
- `+booking_confirmed(V)` → `!decay_pressure`.
- `+endorse_request(RID, V)` → reply `endorsement(RID, approve)` (multi-org co-signing).
- `+tick` → pheromone evaporation (periodic `!decay_pressure`).

---

## 4. ServiceCenterAgent (`service_center_agent.asl`) — owner: Mary

A **capacity-focused** resource manager. Its job is to keep an accurate model of finite resources
(technicians, parts, slot calendar) and allocate them well, log an immutable service record, and
participate in endorsement.

### Beliefs (B)
| Belief | Meaning |
|---|---|
| `current_capacity(C)` | Free technician slots right now |
| `available_slot(S, available/occupied)` | Service-slot calendar |
| `parts_inventory(Part, Qty)` | Per-part stock levels |
| `parts_cost(Part, C)` / `service_cost(labour_hour, C)` | Pricing for the service record |
| `technician(T)` / `qualified(T, Part)` | Technician pool and qualifications |
| `record_counter(N)` | Monotonic service-record id (preserves ordering) |
| `service_record(RID, Vehicle, Part, Tech, Cost)` | Local ledger view |
| `is_overloaded(B)` | Set when the coordinator warns of high pressure |

### Desires (D)
Maximise throughput, minimise wait time (offer the earliest viable slot), and never accept work it
cannot complete to standard (no part, no qualified technician).

### Intentions / key plans (I)
- `!start` → `!advertise_capacity` (publishes free capacity to the coordinator).
- `+booking_request(V, Part, Urg)` → `!evaluate_request`, which selects exactly one outcome:
  1. **Accept** — free slot + part in stock + capacity + qualified technician → `!perform_booking`.
  2. **Decline (parts)** — `parts_inventory(Part,0)` → `booking_declined(parts_shortage(Part))`.
  3. **Decline (skills)** — `not qualified(_,Part)` → `booking_declined(no_qualified_technician(Part))`.
  4. **Defer (capacity)** — `current_capacity ≤ 0` → `booking_deferred(next_available, ...)`.
  5. **Defer (slots)** — no free slot → `booking_deferred(next_available, ...)`.
  6. **Fallback** — `booking_declined(unavailable)`.
- `!perform_booking`: reserve slot + decrement capacity + decrement the part; compute
  `Cost = parts_cost + labour_hour`; create `service_record(RID,...)`; `writeServiceRecord` to the
  blockchain; request endorsement (`endorse_request`); confirm to the vehicle and the coordinator;
  `!complete_service` (publish `service_completed`); after 2 s `!release_slot` (restores slot +
  capacity, re-advertises).
- Consensus participation: `+endorsement(RID, approve|reject)` commits or places an integrity hold;
  `+endorse_request(RID, Orig)` validates another peer's record via the `record_valid` rule
  (Byzantine validation) and replies `approve`/`reject`.

### Rule
```
record_valid(RID) :- service_record(RID, _, _, _, _).
```

---

## 5. Environment bridge (`FleetMASEnvironment.java`)

The environment exposes the three course layers to the agents and injects percepts.

| Action (called by) | Effect |
|---|---|
| `registerCoordinator` (Coordinator) | Acknowledge coordinator registration |
| `registerVehicle(Me, VIN)` (Vehicle) | Inject `vehicle_registered(Me)` to the coordinator |
| `pollIoTAnomalyStream` (Coordinator) | Inject `anomaly_detected(V,Type,Sev)` from the IoT mock |
| `logFleetAnomalyToBlockchain(Type,Count)` (Coordinator) | Log a fleet anomaly (mock/real) |
| `writeServiceRecord(Vehicle, Details)` (Service) | Write a service record; inject `booking_confirmed(Vehicle)` to the coordinator |
| `fetchEdgeSensors`, `evaluateRandomForest`, `evaluateIsolationForest`, `deriveECDSAKey`, `signTelemetryRecord` | Edge/ML/crypto **acknowledgement** stubs (values are simulated in-agent) |
| `tick` (injected every 2 s) | Drives pheromone evaporation in the coordinator |

`USE_REAL_INTEGRATIONS = false` (default) runs the whole MAS standalone with mock adapters. Setting
it `true` points `writeServiceRecord` / `logFleetAnomaly` at a Hyperledger-Fabric-backed DS backend
at `http://localhost:3000`.

### Why ML/crypto values are simulated in the agent
A Jason `Environment.executeAction` returns only `true`/`false` and may `addPercept`; it **cannot
unify result variables** in the calling plan (e.g. `evaluateRandomForest(...,Prediction)` cannot
bind `Prediction`). To keep the MAS runnable end-to-end without an external ML service, the
VehicleAgent simulates these values internally and uses the env actions purely as success hooks. To
use a real ML pipeline, convert them to percept-injecting actions (the environment `addPercept`s the
result and the agent reacts to it) or to user-defined *internal* actions with a library prefix.

---

## 6. Design rationale (summary)

- **Stigmergy over central scheduling** — coordination cost grows with the number of signals, not
  the number of agent pairs, so the fleet scales.
- **Capacity-focused service centre** — one agent doing one job well (modelling and allocating
  finite capacity) composes cleanly into the larger system.
- **Endorsement before commitment** — multi-organisation co-signing mirrors the Byzantine-validated
  commitment of the Distributed Systems layer.
- **Mock-first environment** — the system demonstrates all behaviours without external IoT/ML/chain
  services, while leaving clean seams to plug them in.
