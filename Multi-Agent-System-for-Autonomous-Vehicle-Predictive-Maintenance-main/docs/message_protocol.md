# Message Protocol

Multi-Agent System for Autonomous Vehicle Predictive Maintenance

This document is the authoritative specification of the inter-agent messages (the Agent
Communication Language, ACL) and the environment actions. All three agents are implemented against
this single protocol; `agent_design.md` describes the agents' internal reasoning.

All inter-agent messages use the Jason `tell` performative (assert a belief in the receiver).
Agent names at runtime: `fleet_coordinator_agent`, `vehicle_agent1`, `vehicle_agent2`,
`vehicle_agent3`, `service_center_agent`.

---

## 1. Message catalogue

| # | Message | From → To | Performative | Arguments |
|---|---|---|---|---|
| 1 | `book_request(Vehicle, Part, Urgency)` | Vehicle → Coordinator | tell | requesting vehicle, part needed, urgency |
| 2 | `booking_request(Vehicle, Part, Urgency)` | Coordinator → Service | tell | forwarded request |
| 3 | `booking_confirmed(Slot, Center)` | Service → Vehicle | tell | allocated slot, service centre |
| 4 | `booking_deferred(AltSlot, Center)` | Service → Vehicle | tell | counter-offered slot |
| 5 | `booking_declined(Reason)` | Service → Vehicle | tell | `parts_shortage(P)` / `no_qualified_technician(P)` / `unavailable` |
| 6 | `booking_confirmed(Vehicle)` | Service → Coordinator | tell | confirmation (triggers pressure decay) |
| 7 | `endorse_request(RecordId, Vehicle)` | Service → Coordinator | tell | request cross-org endorsement |
| 8 | `endorsement(RecordId, approve\|reject)` | Coordinator → Service | tell | endorsement decision |
| 9 | `booking_pressure(Level)` | Coordinator → all (broadcast) | tell | stigmergy load signal |
| 10 | `fleet_anomaly_alert(Type, Count)` | Coordinator → all (broadcast) | tell | collective anomaly pattern |
| 11 | `fleet_overload_warning(Level)` | Coordinator → Service | tell | overload advisory |
| 12 | `fleet_status(Size, Pressure)` | Coordinator → Service | tell | periodic status report |
| 13 | `service_center_capacity(C)` | Service → Coordinator | tell | advertised free capacity |
| 14 | `service_completed(Vehicle, RecordId)` | Service → Coordinator | tell | service completion event |

> Note the deliberate **arity split** on `booking_confirmed`: the vehicle receives the 2-argument
> form `booking_confirmed(Slot, Center)`; the coordinator receives the 1-argument form
> `booking_confirmed(Vehicle)`. They are distinct messages to distinct recipients and never
> collide.

---

## 2. Primary sequence — successful booking

```
IoT mock ──anomaly_detected(v1,brake_wear,high)──▶ Coordinator
IoT mock ──anomaly_detected(v2,brake_wear,med)───▶ Coordinator
Coordinator: anomaly_count(brake_wear) reaches threshold (2)
Coordinator ──fleet_anomaly_alert(brake_wear,2)──▶ (broadcast) Vehicles
Vehicle vN: reported_issues++ , service_part:=brake_pad , urgency:=high
Vehicle vN ──book_request(vN, brake_pad, high)──▶ Coordinator
Coordinator: escalate_pressure ; ──booking_request(vN, brake_pad, high)──▶ Service
Service: accept (slot free, part in stock, capacity>0, qualified tech)
Service: reserve slot+capacity+part ; create service_record(RID,...) ; writeServiceRecord
Service ──endorse_request(RID, vN)──▶ Coordinator
Coordinator ──endorsement(RID, approve)──▶ Service        (commit)
Service ──booking_confirmed(slotK, service_center_agent)──▶ Vehicle vN
Service ──booking_confirmed(vN)──▶ Coordinator            (decay pressure)
Service ──service_completed(vN, RID)──▶ Coordinator
Service: after 2 s, release slot + restore capacity + advertise_capacity
```

## 3. Alternative outcomes

| Condition at Service | Reply to Vehicle |
|---|---|
| Free slot + part in stock + capacity + qualified tech | `booking_confirmed(Slot, Center)` |
| Requested part out of stock | `booking_declined(parts_shortage(Part))` |
| No technician qualified for the part | `booking_declined(no_qualified_technician(Part))` |
| No free technician capacity | `booking_deferred(next_available, Center)` |
| No free slot | `booking_deferred(next_available, Center)` |
| Anything else | `booking_declined(unavailable)` |

On `booking_declined`, the vehicle resets `booking_status` to `none` and may retry on a later
telemetry cycle. On `booking_deferred`, the vehicle accepts the alternative (`booking_status:=confirmed`).

## 4. Stigmergy (load regulation)

`booking_pressure` is a shared environmental signal, not a directed negotiation:

```
low ──escalate──▶ medium ──escalate──▶ high ──escalate──▶ critical
   ◀──decay/evaporation──────────────────────────────────
```

- Each forwarded `book_request` escalates pressure one level.
- Each `booking_confirmed(Vehicle)` decays it one level.
- Every environment `tick` (2 s) drives pheromone-style evaporation toward `low`.
- A vehicle perceiving `booking_pressure(critical)` while not itself `critical` **defers its own
  request** — emergent load shedding with no central command.

## 5. Endorsement (consensus participation)

```
Service ──endorse_request(RID, Vehicle)──▶ Coordinator   (propose record for co-signing)
Coordinator: validate → ──endorsement(RID, approve)──▶ Service
Service: approve → committed ; reject → integrity hold (retract local record)
```

The ServiceCenter also implements the **reverse** capability — validating a record proposed by
another peer via `record_valid(RID)` and replying `endorsement(RID, approve|reject)` — so the role
generalises to a multi-service-centre network (Byzantine validation).

---

## 6. Environment actions (agent → environment)

| Action | Caller | Returns / effect |
|---|---|---|
| `registerCoordinator` | Coordinator | true |
| `registerVehicle(Me, VIN)` | Vehicle | true; injects `vehicle_registered(Me)` to Coordinator |
| `pollIoTAnomalyStream` | Coordinator | true; injects `anomaly_detected/3` |
| `logFleetAnomalyToBlockchain(Type, Count)` | Coordinator | true (mock) / HTTP 200/201 (real) |
| `writeServiceRecord(Vehicle, Details)` | Service | true; injects `booking_confirmed(Vehicle)` to Coordinator |
| `fetchEdgeSensors`, `evaluateRandomForest`, `evaluateIsolationForest`, `deriveECDSAKey`, `signTelemetryRecord` | Vehicle | true (acknowledgement; values simulated in-agent) |

See `agent_design.md` §5 for why the ML/crypto actions are acknowledgements rather than
value-returning calls (Jason environment actions cannot unify result variables).

---

## 7. Design invariants (regression checklist)

When changing any message, keep these true (they are what makes the MAS run end-to-end):

1. Every message sent has exactly one receiver with a matching plan head (same functor **and**
   arity).
2. The vehicle's `book_request/3` is answered only after the coordinator forwards
   `booking_request/3` to the service centre — vehicles never message the service centre directly.
3. `booking_confirmed` is 2-arity to the vehicle and 1-arity to the coordinator.
4. Each service booking produces a unique `RecordId` (monotonic `record_counter`) so endorsement
   beliefs always re-trigger.
5. No agent calls an environment action that is not implemented in `FleetMASEnvironment.executeAction`.
