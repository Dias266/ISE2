// =============================================================================
// fleet_coordinator_agent.asl — FleetCoordinatorAgent
// =============================================================================
// ISE Project: Multi-Agent System for Autonomous Vehicle Predictive Maintenance
// Owner     : Dias
// Course    : Intelligent Systems Engineering — Codice [ISE]
// Integrated: Distributed Systems layer (Codice 87474) + IoT layer (Codice 77780)
//
// Responsibilities:
//   1. Maintain shared fleet-level stigmergy belief: booking_pressure(Level)
//   2. Monitor IoT data stream for fleet-wide anomaly patterns
//   3. Broadcast collective alerts when multiple vehicles share the same anomaly
//   4. Prevent simultaneous overload of ServiceCenterAgent via load regulation
//   5. Self-organise without a central controller (swarm-inspired coordination)
// =============================================================================


// ---------------------------------------------------------------------------
// INITIAL BELIEFS
// ---------------------------------------------------------------------------

booking_pressure(low).
evaporation_rate(3).
evaporation_counter(0).
fleet_size(0).
anomaly_threshold(2).
monitoring_interval(5000).
overload_threshold(3).


// ---------------------------------------------------------------------------
// INITIAL GOALS
// ---------------------------------------------------------------------------

!start.


// ---------------------------------------------------------------------------
// PLANS: STARTUP & REGISTRATION
// ---------------------------------------------------------------------------

+!start
    <- .print("[FleetCoordinator] Booting up — stigmergy coordination active.");
       !register_with_environment;
       !broadcast_pressure;
       !monitor_fleet.

+!register_with_environment
    <- registerCoordinator;
       .print("[FleetCoordinator] Registered with MaintenanceDataBridge.").


// ---------------------------------------------------------------------------
// PLANS: STIGMERGY — BOOKING PRESSURE MANAGEMENT
// ---------------------------------------------------------------------------

+!broadcast_pressure
    :  booking_pressure(Level)
    <- .print("[FleetCoordinator] Broadcasting booking_pressure: ", Level);
       .broadcast(tell, booking_pressure(Level)).

// Vehicle -> Coordinator booking request. Apply load regulation (stigmergy)
// and forward the request to the ServiceCenterAgent for slot allocation.
+book_request(VehicleID, Part, Urgency)
    :  booking_pressure(Level)
    <- .print("[FleetCoordinator] book_request from ", VehicleID,
              " part=", Part, " urgency=", Urgency, " — forwarding to ServiceCenter.");
       !escalate_pressure(Level);
       .send(service_center_agent, tell, booking_request(VehicleID, Part, Urgency));
       !check_overload;
       // .abolish will completely remove the belief matching this pattern
       .abolish(book_request(VehicleID, Part, Urgency)).


+request_received(VehicleID, Urgency)
    :  booking_pressure(Level)
    <- .print("[FleetCoordinator] Request received from ", VehicleID,
              " urgency=", Urgency);
       !escalate_pressure(Level);
       !check_overload.

+booking_confirmed(VehicleID)
    <- .print("[FleetCoordinator] Booking confirmed for ", VehicleID,
              " — reducing pressure.");
       !decay_pressure.

// Multi-organisation endorsement: the coordinator's org co-signs a service
// record produced by a service centre (Byzantine-validated commitment).
+endorse_request(RecordId, VehicleID)[source(Center)]
    <- .print("[FleetCoordinator] Cross-org endorsement of record #", RecordId,
              " for ", VehicleID, " — APPROVE.");
       .send(Center, tell, endorsement(RecordId, approve)).

+!escalate_pressure(low)
    <- -+booking_pressure(medium);
       !broadcast_pressure.

+!escalate_pressure(medium)
    <- -+booking_pressure(high);
       !broadcast_pressure.

+!escalate_pressure(high)
    <- -+booking_pressure(critical);
       !broadcast_pressure.

+!escalate_pressure(critical)
    <- .print("[FleetCoordinator] WARNING — booking_pressure already at CRITICAL.");
       !broadcast_pressure.

+!decay_pressure
    :  booking_pressure(critical)
    <- -+booking_pressure(high);
       !broadcast_pressure.

+!decay_pressure
    :  booking_pressure(high)
    <- -+booking_pressure(medium);
       !broadcast_pressure.

+!decay_pressure
    :  booking_pressure(medium)
    <- -+booking_pressure(low);
       !broadcast_pressure.

+!decay_pressure
    :  booking_pressure(low)
    <- .print("[FleetCoordinator] Pressure already at minimum (low). No decay needed.").

+tick
    :  evaporation_counter(C) & evaporation_rate(R) & C >= R
    <- -+evaporation_counter(0);
       .print("[FleetCoordinator] Evaporation cycle — decaying pressure.");
       !decay_pressure.

+tick
    :  evaporation_counter(C) & evaporation_rate(R) & C < R
    <- NC = C + 1;
       -+evaporation_counter(NC).


// ---------------------------------------------------------------------------
// PLANS: OVERLOAD DETECTION
// ---------------------------------------------------------------------------

+!check_overload
    :  booking_pressure(critical)
    <- .print("[FleetCoordinator] OVERLOAD DETECTED — notifying ServiceCenterAgent.");
       .send(service_center_agent, tell, fleet_overload_warning(critical)).

+!check_overload
    :  booking_pressure(high)
    <- .print("[FleetCoordinator] High pressure — advising ServiceCenterAgent.");
       .send(service_center_agent, tell, fleet_overload_warning(high)).

+!check_overload
    <- true.


// ---------------------------------------------------------------------------
// PLANS: FLEET-WIDE ANOMALY MONITORING (IoT Layer Integration)
// ---------------------------------------------------------------------------

+!monitor_fleet
    <- .print("[FleetCoordinator] Monitoring IoT stream for fleet-wide anomaly patterns.");
       pollIoTAnomalyStream;
       .wait(5000);
       !monitor_fleet.

+anomaly_detected(VehicleID, AnomalyType, Severity)
    <- .print("[FleetCoordinator] Anomaly from ", VehicleID,
              " type=", AnomalyType, " severity=", Severity);
       !update_anomaly_count(AnomalyType);
       !check_pattern_alert(AnomalyType).

+!update_anomaly_count(AnomalyType)
    :  anomaly_count(AnomalyType, Count)
    <- NC = Count + 1;
       -+anomaly_count(AnomalyType, NC).

+!update_anomaly_count(AnomalyType)
    <- +anomaly_count(AnomalyType, 1).

+!check_pattern_alert(AnomalyType)
    :  anomaly_count(AnomalyType, Count) & anomaly_threshold(T) & Count >= T
    <- .print("[FleetCoordinator] COLLECTIVE ALERT — anomaly pattern detected: ",
              AnomalyType, " across ", Count, " vehicles.");
       !broadcast_collective_alert(AnomalyType, Count);
       !notify_blockchain_anomaly(AnomalyType, Count);
       -+anomaly_count(AnomalyType, 0).

+!check_pattern_alert(_)
    <- true.

+!broadcast_collective_alert(AnomalyType, Count)
    <- .broadcast(tell, fleet_anomaly_alert(AnomalyType, Count));
       .print("[FleetCoordinator] Broadcast sent: fleet_anomaly_alert(",
              AnomalyType, ",", Count, ").").

+!notify_blockchain_anomaly(AnomalyType, Count)
    <- logFleetAnomalyToBlockchain(AnomalyType, Count);
       .print("[FleetCoordinator] Fleet anomaly logged to blockchain: ",
              AnomalyType, " count=", Count).


// ---------------------------------------------------------------------------
// PLANS: FLEET SIZE TRACKING
// ---------------------------------------------------------------------------

+vehicle_registered(VehicleID)
    :  fleet_size(N)
    <- NN = N + 1;
       -+fleet_size(NN);
       .print("[FleetCoordinator] Vehicle registered: ", VehicleID,
              " — fleet size now ", NN).

+vehicle_deregistered(VehicleID)
    :  fleet_size(N) & N > 0
    <- NN = N - 1;
       -+fleet_size(NN);
       .print("[FleetCoordinator] Vehicle deregistered: ", VehicleID,
              " — fleet size now ", NN).


// ---------------------------------------------------------------------------
// PLANS: FLEET STATUS REPORTING
// ---------------------------------------------------------------------------

+!report_fleet_status
    :  booking_pressure(Level) & fleet_size(N)
    <- .print("[FleetCoordinator] Fleet status — size=", N,
              " booking_pressure=", Level);
       .send(service_center_agent, tell, fleet_status(N, Level)).



// ---------------------------------------------------------------------------
// PLANS: SERVICE COMPLETION HANDLING
// ---------------------------------------------------------------------------
+service_completed(VehicleID, RID)[source(Center)]
    <- .print("[FleetCoordinator] Processing service completion for ", VehicleID, 
              " from center: ", Center);
       
       // Optional: Log final status or settlement to blockchain 
       // (adjust custom action name to match your environment wrapper if needed)
       // logServiceSettlementToBlockchain(VehicleID, RID);
       
       // --- FIXED: Notify the vehicle that service is complete so it resets its status ---
       .send(VehicleID, tell, service_finished);
       
       // Request an updated status report to confirm fleet health
       !report_fleet_status;
       
       // Housekeeping: Remove the belief so it doesn't clutter the belief base
       -service_completed(VehicleID, RID)[source(Center)].


// ---------------------------------------------------------------------------
// PLANS: FAILURE HANDLING
// ---------------------------------------------------------------------------

-!monitor_fleet
    <- .print("[FleetCoordinator] ERROR — IoT monitoring failed. Retrying...");
       .wait(10000);
       !monitor_fleet.

-!notify_blockchain_anomaly(AnomalyType, Count)
    <- .print("[FleetCoordinator] WARNING — Blockchain log failed for: ",
              AnomalyType, ". Recording locally.");
       +local_anomaly_log(AnomalyType, Count).

-!X
    <- .print("[FleetCoordinator] Plan failed: ", X, " — continuing.").


// ---------------------------------------------------------------------------
// END OF fleet_coordinator_agent.asl
// ---------------------------------------------------------------------------
