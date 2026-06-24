// =============================================================================
// service_center_agent.asl — ServiceCenterAgent (capacity-focused)
// =============================================================================
// Owner : Mary
// ISE Project: Multi-Agent System for Autonomous Vehicle Predictive Maintenance
//
// Responsibilities (aligned with the project report, Section 6):
//   1. Resource management   — technician capacity, parts inventory, slot calendar
//   2. Request handling       — accept / defer / decline booking requests
//   3. Service execution      — log immutable service record, publish completion
//   4. Consensus participation— multi-org endorsement of service records
//
// Shared protocol:
//   Coordinator -> Service : booking_request(Vehicle, Part, Urgency)
//   Service  -> Vehicle    : booking_confirmed(Slot, Center)
//                            booking_deferred(AltSlot, Center)
//                            booking_declined(Reason)
//   Service  -> Coordinator: booking_confirmed(Vehicle)        (decays pressure)
//                            endorse_request(RecordId, Vehicle) (cross-org sign)
//   Coordinator -> Service : endorsement(RecordId, approve|reject)
// =============================================================================

// ---------------------------------------------------------------------------
// INITIAL BELIEFS — resource model
// ---------------------------------------------------------------------------

// Technician capacity (free technician-slots right now)
current_capacity(3).

// Service-slot calendar
available_slot(slot1, available).
available_slot(slot2, available).
available_slot(slot3, available).

// Parts inventory (per-part stock levels)
parts_inventory(brake_pad, 10).
parts_inventory(oil_filter, 10).

// Pricing (used when logging the service record)
parts_cost(brake_pad, 80).
parts_cost(oil_filter, 25).
service_cost(labour_hour, 60).

// Technicians and their qualifications
technician(tech_a).
technician(tech_b).
qualified(tech_a, brake_pad).
qualified(tech_a, oil_filter).
qualified(tech_b, oil_filter).

// Bookkeeping
record_counter(0).        // monotonic service-record id (preserves ordering)
is_overloaded(false).

// ---------------------------------------------------------------------------
// RULES
// ---------------------------------------------------------------------------

// A record is valid for endorsement if we hold it in our local ledger view.
record_valid(RID) :- service_record(RID, _, _, _, _).

// ---------------------------------------------------------------------------
// INITIAL GOALS
// ---------------------------------------------------------------------------

!start.

// ---------------------------------------------------------------------------
// PLANS: STARTUP
// ---------------------------------------------------------------------------

+!start
    <- .print("[ServiceCenterAgent] Operational. Ready for maintenance requests.");
       !advertise_capacity.

// Publish current free capacity to the fleet (stigmergy / MQTT analog)
+!advertise_capacity
    :  current_capacity(C)
    <- .send(fleet_coordinator_agent, tell, service_center_capacity(C));
       .print("[ServiceCenterAgent] Advertising free capacity: ", C).

// ---------------------------------------------------------------------------
// PLANS: HANDLING REQUESTS
// ---------------------------------------------------------------------------

// Booking request forwarded by the FleetCoordinator. Carries the required Part.
// =============================================================================
// service_center_agent.asl — Strict Param Validation Fix
// =============================================================================

// Handle booking request - pass variables cleanly down
+booking_request(VehicleID, TargetPart, Urgency) <- 
    .print("[ServiceCenterAgent] Processing incoming request from ", VehicleID, " for part: ", TargetPart);
    !evaluate_request(VehicleID, TargetPart, Urgency).

// Atomic Resource Check matching specific TargetPart requested
+!evaluate_request(VehicleID, TargetPart, Urgency) 
    : available_slot(SlotID, available) & 
      parts_inventory(TargetPart, Qty) & Qty > 0 & 
      current_capacity(C) & C > 0 & 
      qualified(Tech, TargetPart) <- 
    
    // Explicitly lock slot status immediately to protect from race conditions
    -+available_slot(SlotID, occupied);
    .print("[ServiceCenterAgent] Slot secured. Allocating ", SlotID, " to ", VehicleID, " for ", TargetPart);
    !perform_booking(VehicleID, SlotID, TargetPart, Tech).

// Fallback for no parts available for that specific target component
+!evaluate_request(VehicleID, TargetPart, Urgency) : parts_inventory(TargetPart, 0) <- 
    .send(VehicleID, tell, booking_declined(parts_shortage(TargetPart))).

// General capacity fallback
+!evaluate_request(VehicleID, TargetPart, Urgency) <- 
    .send(VehicleID, tell, booking_deferred(next_available, service_center_agent)).


// =============================================================================
// service_center_agent.asl — Fixed Async Trigger Syntax
// =============================================================================

+!perform_booking(VehicleID, SlotID, TargetPart, Tech) <- 
    ?current_capacity(C); -+current_capacity(C - 1);
    ?parts_inventory(TargetPart, Qty); -+parts_inventory(TargetPart, Qty - 1);
    
    .time(H, M, S);
    RecordID = S; 
    
    // Write clean data to Blockchain mock interface
    writeServiceRecord(VehicleID, TargetPart, Tech, "scheduled");
    
    // Notify corresponding coordination channels
    .send(VehicleID, tell, booking_confirmed(SlotID, service_center_agent));
    .send(fleet_coordinator_agent, tell, booking_confirmed(VehicleID));
    
    .print("[ServiceCenterAgent] Booking successfully verified for ", VehicleID, " with item: ", TargetPart);
    
    // FIX: Removed the leading dot. Triggering a standard AgentSpeak sub-goal.
    !!background_service_cycle(VehicleID, TargetPart, Tech, RecordID, SlotID).

// FIX: Updated matching operator pattern to standard achievement goal format (+!)
+!background_service_cycle(VehicleID, TargetPart, Tech, RecordID, SlotID) <-
    .wait(2500); // Safely pauses this sub-goal's execution thread without blocking the agent's main belief queue
    .print("[ServiceCenterAgent] Technician ", Tech, " finished repairing ", VehicleID, " (", TargetPart, ")");
    !complete_service(VehicleID, TargetPart, Tech, RecordID, SlotID).

+!complete_service(VehicleID, Part, Tech, RID, SlotID) <- 
    .send(fleet_coordinator_agent, tell, service_completed(VehicleID, RID));
    .send(VehicleID, tell, service_cycle_finished);
    !release_slot(SlotID).

+!release_slot(SlotID) <-
    -+available_slot(SlotID, available);
    ?current_capacity(C); -+current_capacity(C + 1);
    .print("[ServiceCenterAgent] Slot ", SlotID, " is now free. Capacity restored.").

// 1. Success: free slot AND part in stock AND capacity AND a qualified technician.
//    Marked [atomic] so the whole reservation (slot, capacity, part, record id)
//    runs without interleaving. This removes the concurrency race in which a
//    concurrent booking could transiently empty a belief while many vehicles
//    book at once. NOTE: there is no .wait inside this plan; the timed service
//    and the slot release are handled by the non-atomic pending_release plan.
@sc_accept[atomic]
+!evaluate_request(VehicleID, Part, Urgency)
    :  available_slot(SlotID, available)
     & parts_inventory(Part, Qty) & Qty > 0
     & current_capacity(C) & C > 0
     & qualified(Tech, Part)
    <- .print("[ServiceCenterAgent] Resources found. Allocating ", SlotID,
              " to ", VehicleID, " (tech=", Tech, ")");
       // Reserve slot, technician and one part using the context-bound values
       -available_slot(SlotID, available); +available_slot(SlotID, occupied);
       -current_capacity(C);               +current_capacity(C - 1);
       -parts_inventory(Part, Qty);        +parts_inventory(Part, Qty - 1);
       // Build the immutable, monotonically-ordered service record
       ?parts_cost(Part, PC); ?service_cost(labour_hour, LC); Cost = PC + LC;
       ?record_counter(RC); RID = RC + 1;
       -record_counter(RC); +record_counter(RID);
       +service_record(RID, VehicleID, Part, Tech, Cost);
       // Log to the blockchain (Codice 87474) and request cross-org endorsement
       writeServiceRecord(VehicleID, scheduled_maintenance);
       .send(fleet_coordinator_agent, tell, endorse_request(RID, VehicleID));
       // Confirm to the vehicle and notify the coordinator (decays pressure)
       .send(VehicleID, tell, booking_confirmed(SlotID, service_center_agent));
       .send(fleet_coordinator_agent, tell, booking_confirmed(VehicleID));
       .print("[ServiceCenterAgent] Logged record #", RID, " — vehicle=", VehicleID,
              " part=", Part, " tech=", Tech, " cost=", Cost);
       // Hand off the timed service + release to a non-atomic intention
       +pending_release(SlotID, VehicleID, Tech, RID).

// 2. Parts shortage: requested part out of stock -> decline with reason
+!evaluate_request(VehicleID, Part, Urgency)
    :  parts_inventory(Part, 0)
    <- .print("[ServiceCenterAgent] DECLINED: out of stock for ", Part);
       .send(VehicleID, tell, booking_declined(parts_shortage(Part))).

// 3. No qualified technician for this part -> decline with reason
+!evaluate_request(VehicleID, Part, Urgency)
    :  not qualified(_, Part)
    <- .print("[ServiceCenterAgent] DECLINED: no qualified technician for ", Part);
       .send(VehicleID, tell, booking_declined(no_qualified_technician(Part))).

// 4. Capacity exhausted -> counter-offer the next available slot (defer)
+!evaluate_request(VehicleID, Part, Urgency)
    :  current_capacity(C) & C <= 0
    <- .print("[ServiceCenterAgent] FULL (no free technicians) — deferring ", VehicleID);
       .send(VehicleID, tell, booking_deferred(next_available, service_center_agent)).

// 5. No free slots -> counter-offer the next available slot (defer)
+!evaluate_request(VehicleID, Part, Urgency)
    :  not available_slot(_, available)
    <- .print("[ServiceCenterAgent] FULL (no free slots) — deferring ", VehicleID);
       .send(VehicleID, tell, booking_deferred(next_available, service_center_agent)).

// 6. Fallback: anything else we cannot serve right now
+!evaluate_request(VehicleID, Part, Urgency)
    <- .print("[ServiceCenterAgent] Unable to serve ", VehicleID, " at this time.");
       .send(VehicleID, tell, booking_declined(unavailable)).

// ---------------------------------------------------------------------------
// PLANS: SERVICE COMPLETION & TIMED RELEASE (non-atomic — may .wait)
// ---------------------------------------------------------------------------

// Triggered by the reservation above. Runs the (simulated 2 s) service, then
// frees the slot. This runs as its own non-atomic intention, so the .wait does
// not block other bookings.
+pending_release(SlotID, VehicleID, Tech, RID)
    <- .send(fleet_coordinator_agent, tell, service_completed(VehicleID, RID));
       .print("[ServiceCenterAgent] Service completed for ", VehicleID,
              " by ", Tech, " (record #", RID, ").");
       .wait(2000);
       -pending_release(SlotID, VehicleID, Tech, RID);
       !release_slot(SlotID).


// ---------------------------------------------------------------------------
// PLANS: CONSENSUS PARTICIPATION (endorsement)
// ---------------------------------------------------------------------------

// Endorsement reply for one of OUR records (from the FleetCoordinator's org)
+endorsement(RID, approve)
    <- .print("[ServiceCenterAgent] Record #", RID,
              " ENDORSED (approve) — committed to ledger.").

+endorsement(RID, reject)
    <- .print("[ServiceCenterAgent] Record #", RID,
              " endorsement REJECTED — placing integrity hold.");
       -service_record(RID, _, _, _, _).

// Validate a service record proposed by another peer (Byzantine validation)
+endorse_request(RID, Originator)[source(Peer)]
    :  record_valid(RID)
    <- .print("[ServiceCenterAgent] Peer record #", RID, " from ", Originator, " — APPROVE.");
       .send(Peer, tell, endorsement(RID, approve)).

+endorse_request(RID, Originator)[source(Peer)]
    :  not record_valid(RID)
    <- .print("[ServiceCenterAgent] Peer record #", RID, " from ", Originator,
              " — REJECT (unknown record).");
       .send(Peer, tell, endorsement(RID, reject)).

// ---------------------------------------------------------------------------
// PLANS: COORDINATION & OVERLOAD
// ---------------------------------------------------------------------------

// Reacting to the FleetCoordinator's overload warning
+fleet_overload_warning(Level)
    <- -+is_overloaded(true);
       .print("[ServiceCenterAgent] High fleet pressure alert: ", Level,
              ". Prioritising urgent jobs.").

+fleet_status(Size, Pressure)
    <- .print("[ServiceCenterAgent] Fleet Status Report — Vehicles: ", Size,
              " System Pressure: ", Pressure).

// ---------------------------------------------------------------------------
// PLANS: FAILURE FALLBACK
// ---------------------------------------------------------------------------

-!X
    <- .print("[ServiceCenterAgent] Plan failed: ", X).
