// =============================================================================
// vehicle_agent.asl — VehicleAgent (runnable, protocol-aligned)
// =============================================================================
// Owner : Danial
// Notes : Self-contained edge + ML + ECDSA simulation in AgentSpeak.
//         Jason ENVIRONMENT actions cannot bind result variables back into a
//         plan, so telemetry/ML values are simulated internally here. The
//         edge/ML/crypto env actions (deriveECDSAKey, signTelemetryRecord, ...)
//         are invoked only as success acknowledgements.
//
// CHANGE LOG (consolidation pass, Step 0 of SPE prep):
//   - The previous revision defined +!evaluate_maintenance_need FIVE times
//     with overlapping/contradictory contexts (Jason takes the FIRST matching
//     plan in source order, so several of those blocks were silently dead),
//     plus one block that called a misspelled, never-defined goal
//     (!evaluate_maintenance instead of !evaluate_maintenance_need). This
//     version keeps exactly ONE definition per context, ordered
//     most-specific-first, so plan selection is unambiguous.
//   - Kept the new service_finished handshake: this closes a real gap (the
//     vehicle previously never learned that its service had actually
//     completed) and is the one unambiguous improvement from the previous
//     revision. Dropped the redundant service_cycle_finished message/handler
//     that the previous revision also introduced for the same event.
//   - Kept stigmergic self-deferral under critical pressure
//     (booking_status -> deferred, auto-retried when pressure relaxes).
//   - Isolation Forest anomaly now also escalates urgency_level(high), since
//     a statistical outlier reading should not silently leave urgency at
//     whatever the threshold rule produced.
//
// Protocol (shared across all three agents):
//   Vehicle  -> Coordinator : book_request(Vehicle, Part, Urgency)
//   Coordinator -> Service   : booking_request(Vehicle, Part, Urgency)
//   Service  -> Vehicle      : booking_confirmed(Slot, Center)
//                              booking_deferred(AltSlot, Center)
//                              booking_declined(Reason)
//   Service  -> Coordinator  : booking_confirmed(Vehicle)
// =============================================================================

/* ---------------- Initial beliefs ---------------- */
vin("XYZ1234567890").
mileage(0).
current_temperature(25.0).
engine_status(ok).
battery_condition(good).
brake_condition(good).
reported_issues(0).

urgency_level(low).
is_registered(false).
booking_status(none).          // none | requested | confirmed | deferred
booking_pressure(low).         // updated by coordinator broadcasts (stigmergy)
service_part(oil_filter).      // part requested when booking (may switch)

/* ---------------- Initial goal ---------------- */
!initialize_agent.

/* ---------------- Startup & registration ---------------- */
+!initialize_agent
    <- .my_name(Me);
       .print("[VehicleAgent:", Me, "] Initializing internal components...");
       !register_on_blockchain.

// F1: Register the vehicle digital twin on the permissioned network
+!register_on_blockchain
    :  vin(VIN) & is_registered(false)
    <- .my_name(Me);
       .print("[VehicleAgent:", Me, "] Registering VIN ", VIN, " on Hyperledger Fabric...");
       registerVehicle(Me, VIN);
       -+is_registered(true);
       !collect_telemetry.

+!register_on_blockchain
    <- .print("[VehicleAgent] Registration skipped or malformed VIN.").

/* ---------------- Telemetry / ML / signing loop ---------------- */
+!collect_telemetry
    :  is_registered(true)
    <- !sense_edge;
       !classify_health;
       !sign_and_publish;
       !evaluate_maintenance_need;
       !calculate_sampling_delay(Delay);
       .wait(Delay);
       !collect_telemetry.

// Simulated DS18B20 temperature + OBD-II mileage acquisition
+!sense_edge
    <- .random(R);
       T = 25.0 + (R * 25.0);          // 25.0 .. 50.0 C
       -+current_temperature(T);
       ?mileage(M);
       NM = M + 100;
       -+mileage(NM).

// Mock Random Forest (maintenance need) + Isolation Forest (anomaly) decisions
+!classify_health
    :  current_temperature(T) & reported_issues(I)
    <- if (T >= 40.0 | I > 0) {
           -+urgency_level(high);
           .print("[VehicleAgent] ML: maintenance needed (T=", T, ", issues=", I, ").")
       } else {
           -+urgency_level(low)
       };
       if (T >= 45.0) {
           -+telemetry_anomaly(true);
           -+urgency_level(high);     // a statistical outlier always escalates urgency
           .print("[VehicleAgent] Isolation Forest: statistical outlier telemetry (T=", T, ").")
       }.

// F3: ECDSA signing + MQTT publish (env actions acknowledge success only)
+!sign_and_publish
    :  vin(VIN) & current_temperature(T) & mileage(M) & urgency_level(U)
    <- .my_name(Me);
       deriveECDSAKey(VIN, key);
       signTelemetryRecord(T, M, U, key, sig);
       .print("[VehicleAgent:", Me, "] Published signed telemetry (T=", T,
              ", mileage=", M, ", urgency=", U, ").").

// Adaptive sampling cadence mapped from the Layer-1 ESP32 FSM
+!calculate_sampling_delay(5000) : current_temperature(T) & T < 30.0.
+!calculate_sampling_delay(2000) : current_temperature(T) & T >= 30.0 & T < 40.0.
+!calculate_sampling_delay(1000) : current_temperature(T) & T >= 40.0.
+!calculate_sampling_delay(5000).      // safe fallback

/* ---------------- Stigmergy-aware booking ---------------- */
// Plans are ordered most-specific-context-first; Jason takes the first match.

// 1. Already mid-flight (requested or confirmed) — do nothing, await callback.
+!evaluate_maintenance_need
    :  booking_status(requested) | booking_status(confirmed)
    <- true.

// 2. Deferred under prior critical backpressure — recheck whether pressure
//    has relaxed enough to retry; otherwise stay deferred this cycle.
+!evaluate_maintenance_need
    :  booking_status(deferred)
    <- ?booking_pressure(Level);
       if (Level == low | Level == medium) {
           .print("[VehicleAgent] Fleet backpressure relaxed. Resuming evaluation.");
           -+booking_status(none);
           !evaluate_maintenance_need
       } else {
           .print("[VehicleAgent] Still deferred — fleet pressure remains ", Level, ".")
       }.

// 3. Healthy and idle — nothing to do this cycle.
+!evaluate_maintenance_need
    :  urgency_level(low) & booking_status(none)
    <- true.

// 4. Urgent and idle — request a booking.
+!evaluate_maintenance_need
    :  urgency_level(high) & booking_status(none)
    <- !request_fleet_booking.

// 5. Catch-all fallback (should not normally be reached).
+!evaluate_maintenance_need
    <- true.

// Defer autonomously under critical backpressure (load shedding)
+!request_fleet_booking
    :  booking_pressure(critical) & not urgency_level(critical)
    <- .print("[VehicleAgent] Critical backpressure — deferring request to reduce congestion.");
       -+booking_status(deferred).

// Otherwise send a booking request to the FleetCoordinator
+!request_fleet_booking
    :  service_part(P)
    <- .my_name(Me);
       .print("[VehicleAgent:", Me, "] Sending book_request to FleetCoordinator (part=", P, ").");
       -+booking_status(requested);
       .send(fleet_coordinator_agent, tell, book_request(Me, P, high)).

/* ---------------- Reactive coordination plans ---------------- */

// Stigmergy signal: fleet booking pressure changed. If we are mid-request and
// the fleet just escalated to critical, shed our own load proactively instead
// of waiting for the service center to defer us.
+booking_pressure(Level)
    <- .print("[VehicleAgent] Stigmergy signal: booking pressure = ", Level);
       if (Level == critical & booking_status(requested) & not urgency_level(critical)) {
           .print("[VehicleAgent] Shedding load — relinquishing active request.");
           -+booking_status(deferred)
       }.

// Fleet-wide brake_wear pattern -> prioritise brake service
+fleet_anomaly_alert(brake_wear, Count)
    <- .print("[VehicleAgent] Fleet brake_wear pattern across ", Count,
              " units. Prioritising brake service.");
       -+service_part(brake_pad);
       ?reported_issues(I);
       -+reported_issues(I + 1).

// Fleet-wide oil_pressure pattern -> prioritise oil service
+fleet_anomaly_alert(oil_pressure, Count)
    <- .print("[VehicleAgent] Fleet oil_pressure pattern across ", Count,
              " units. Prioritising oil service.");
       -+service_part(oil_filter);
       ?reported_issues(I);
       -+reported_issues(I + 1).

// Any other fleet-wide anomaly pattern
+fleet_anomaly_alert(AnomalyType, Count)
    <- .print("[VehicleAgent] Fleet alert: ", AnomalyType, " across ", Count, " units.");
       ?reported_issues(I);
       -+reported_issues(I + 1).

// Booking outcomes from the ServiceCenter
+booking_confirmed(Slot, Center)
    <- .print("[VehicleAgent] Booking CONFIRMED at ", Center, " slot ", Slot, ".");
       -+booking_status(confirmed).

+booking_deferred(AltSlot, Center)
    <- .print("[VehicleAgent] Booking deferred by ", Center,
              " — alternative slot ", AltSlot, " accepted.");
       -+booking_status(confirmed).

+booking_declined(Reason)
    <- .print("[VehicleAgent] Booking declined: ", Reason, ". Will retry on next cycle.");
       -+booking_status(none).

// Service Center confirms the physical service work is complete: reset state
// so the vehicle can be evaluated and re-booked on a future cycle.
+service_finished
    <- .print("[VehicleAgent] Service cycle finished. Resetting booking status.");
       -+booking_status(none);
       -+urgency_level(low);
       -+reported_issues(0);
       -+service_part(oil_filter).

/* ---------------- Failure fallback ---------------- */
-!X
    <- .print("[VehicleAgent] Plan failure on: ", X).
