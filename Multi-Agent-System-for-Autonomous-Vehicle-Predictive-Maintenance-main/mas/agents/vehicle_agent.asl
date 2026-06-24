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
booking_status(none).          // none | requested | confirmed
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
       !evaluate_maintenance_need;     // FIXED: Synchronously processed at the tail of telemetry stream processing
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
            -+urgency_level(high);     // FIXED: Enforce critical urgency tracking when Isolation Forest detects an outlier
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
// Guarded plan: if we have high urgency and a part is defined, book it immediately




// =============================================================================
// vehicle_agent.asl — Fix Deferred Booking Logic Suffixes
// =============================================================================

// 1. Rename the goal head to match the main telemetry evaluation cycle signature
+!evaluate_maintenance_need : booking_status(deferred) <-
    .print("[VehicleAgent] Maintenance evaluation paused. Request is deferred due to critical fleet load-shedding.");
    
    .wait(3000); 
    
    ?booking_pressure(CurrentPressure);
    if (CurrentPressure == low | CurrentPressure == medium) {
        .print("[VehicleAgent] Fleet backpressure relaxed. Re-enabling maintenance evaluation pathways.");
        -+booking_status(none);
    };
    !evaluate_maintenance_need. // Fixed suffix

// 2. Fix the suffix inside the reactive booking deferral handler
+booking_deferred(AlternativeSlot, Center) <- 
    .print("[VehicleAgent] Booking DEFERRED by ", Center, ". Capacity full. Retrying shortly...");
    -+booking_status(none); 
    
    .random(R);
    BackoffTime = 2000 + (R * 1500); 
    .wait(BackoffTime);
    !evaluate_maintenance_need. // Fixed suffix




// 1. Target Condition: High urgency and fully clear state -> Proceed with booking
+!evaluate_maintenance_need
    : urgency_level(high) & booking_status(none) & service_part(P)
    <- !request_fleet_booking.

// 2. Safe Guard Condition: If already requested or confirmed, DO NOT retry or recurse.
// Yield gracefully and wait for asynchronous callback updates from the service center.
+!evaluate_maintenance_need
    : urgency_level(high) & (booking_status(requested) | booking_status(confirmed))
    <- .print("[VehicleAgent] Maintenance pipeline active (", booking_status, "). Awaiting network handshake response...").

// 3. Recovery Plan: High urgency and explicitly stuck in a 'deferred' state
+!evaluate_maintenance_need
    : urgency_level(high) & booking_status(deferred)
    <- .print("[VehicleAgent] Retrying deferred request due to ongoing high urgency conditions.");
       -+booking_status(none); 
       !evaluate_maintenance_need. 

// 4. Fallback Plan: Urgency is high, clear state, but part was dropped due to race conditions
+!evaluate_maintenance_need
    : urgency_level(high) & booking_status(none)
    <- .print("[VehicleAgent] Urgency is high, but no target component found. Defaulting to oil_filter.");
       +service_part(oil_filter);
       !request_fleet_booking.

// Unify the deferred handler under the correct '!evaluate_maintenance_need' signature
+!evaluate_maintenance_need : booking_status(deferred) <-
    .print("[VehicleAgent] Maintenance evaluation paused. Request is deferred due to active fleet load-shedding.");
    .wait(4000); 
    
    ?booking_pressure(CurrentPressure);
    if (CurrentPressure == low | CurrentPressure == medium) {
        .print("[VehicleAgent] Fleet backpressure relaxed. Re-enabling evaluation pathways.");
        -+booking_status(none)
    } else {
        !evaluate_maintenance_need
    }.

// 5. Unconditional catch-all fallback to handle unmapped telemetry evaluation states (low urgency)
+!evaluate_maintenance_need : true <-
    ?urgency_level(Urgency);
    ?reported_issues(Issues);
    .wait(1000). // Smoothly yield to prevent execution lock spikes



    
// =============================================================================
// vehicle_agent.asl — Handling Stigmergy Deferral States
// =============================================================================

// Plan: Handle localized maintenance evaluation when load-shed by high backpressure
+!evaluate_maintenance : booking_status(deferred) <-
    .print("[VehicleAgent] Maintenance evaluation paused. Request is deferred due to critical fleet load-shedding.");
    
    // Cool down for a cycle to allow the Service Center to clear slots
    .wait(3000); 
    
    // Check if system pressure dropped, enabling a re-evaluation attempt
    ?booking_pressure(CurrentPressure);
    if (CurrentPressure == low | CurrentPressure == medium) {
        .print("[VehicleAgent] Fleet backpressure relaxed. Re-enabling maintenance evaluation pathways.");
        -+booking_status(none);
    }
    !evaluate_maintenance.

// Defer autonomously under critical backpressure (load shedding)
+!request_fleet_booking
    :  booking_pressure(critical) & not urgency_level(critical)
    <- .print("[VehicleAgent] Critical backpressure — deferring request to reduce congestion.").

// Otherwise send a booking request to the FleetCoordinator
+!request_fleet_booking
    :  service_part(P)
    <- .my_name(Me);
       .print("[VehicleAgent:", Me, "] Sending book_request to FleetCoordinator (part=", P, ").");
       -+booking_status(requested);
       .send(fleet_coordinator_agent, tell, book_request(Me, P, high)).

/* ---------------- Reactive coordination plans ---------------- */
// Stigmergy signal: fleet booking pressure changed
// Reactive Plan: React to environmental booking pressure shifts (Stigmergy)
+booking_pressure(Level) <- 
    .print("[VehicleAgent] Stigmergy Signal: Fleet booking pressure changed to: ", Level); 
    if (Level == critical & booking_status(requested) & not urgency_level(critical)) { 
        .print("[VehicleAgent] Shedding load. Relinquishing active request slot."); 
        -+booking_status(deferred); 
    }.

// Fleet-wide brake_wear pattern -> prioritise brake service
+fleet_anomaly_alert(brake_wear, Count)
    <- .print("[VehicleAgent] Fleet brake_wear pattern across ", Count,
              " units. Prioritising brake service.");
       -+service_part(brake_pad);
       ?reported_issues(I);
       -+reported_issues(I + 1).

// Reactive Plan: Fleet-wide pattern notifications from coordinator
+fleet_anomaly_alert(AnomalyType, Count) <- 
    .print("[VehicleAgent] Fleet alert received: ", AnomalyType, " tracking across ", Count, " units.");
    
    // Increment the issue tracking count
    if (reported_issues(I)) { 
        -+reported_issues(I + 1); 
    };
    
    // FIX: Dynamically deduce and bind the correct service part based on the fleet anomaly type
    if (AnomalyType == oil_pressure) {
        -+service_part(oil_filter);
        .print("[VehicleAgent] Fleet oil_pressure pattern detected. Prioritising oil service.");
    };
    if (AnomalyType == brake_wear) {
        -+service_part(brake_pad);
        .print("[VehicleAgent] Fleet brake_wear pattern detected. Prioritising brake service.");
    }.

// Reactive Plan: Reset booking state once the Coordinator confirms service completion
+service_finished[source(fleet_coordinator_agent)]
    <- .print("[VehicleAgent] Service cycle finished. Resetting booking status to none.");
       -+booking_status(none);
       -+urgency_level(low);          
       -+reported_issues(0);          // Flush the issue tracking counter
       -+service_part(oil_filter);    // Reset back to default part
       -service_finished[source(fleet_coordinator_agent)].

// Add this inside vehicle_agent.asl to clear its state lock
+service_cycle_finished <-
    .print("[VehicleAgent] Service cycle finished received. Resetting status to none.");
    -+booking_status(none);
    !collect_telemetry. // Resume standard monitoring loop
       
// Booking outcomes from the ServiceCenter
+booking_confirmed(Slot, Center)
    <- .print("[VehicleAgent] Booking CONFIRMED at ", Center, " slot ", Slot, ".");
       -+booking_status(confirmed).

// =============================================================================
// vehicle_agent.asl — Fix Deferred Booking Logic
// =============================================================================

+booking_declined(Reason)
    <- .print("[VehicleAgent] Booking declined: ", Reason, ". Will retry on next cycle.");
       -+booking_status(none).

/* ---------------- Failure fallback ---------------- */
-!X
    <- .print("[VehicleAgent] Plan failure on: ", X).

