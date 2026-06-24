// =============================================================================
// shared_beliefs.asl — Shared Ontology (reference vocabulary)
// =============================================================================
// This file is the canonical, jointly-maintained vocabulary for the project:
// belief names, urgency ordering, pressure levels, component and agent names.
// It documents the common terms the three agents reason over.
//
// NOTE: it is NOT auto-loaded by maintenance.mas2j. The agents currently embed
// the terms they need directly. To load this ontology into an agent, add an
// include directive at the top of that agent's .asl file, e.g.:
//     { include("mas/common/shared_beliefs.asl") }
// (verify the path against your Jason version before relying on it).
//
// All three team members maintain this file jointly.
// =============================================================================
 
// ---------------------------------------------------------------------------
// Agent name constants (used in .send/broadcast targets)
// ---------------------------------------------------------------------------
agent_name(fleet_coordinator, fleet_coordinator_agent).
agent_name(service_center,    service_center_agent).
// VehicleAgents are addressed dynamically by their registered ID
 
// ---------------------------------------------------------------------------
// Urgency level ordering (low < medium < high < critical)
// Used by all agents for comparison in context conditions
// ---------------------------------------------------------------------------
urgency_order(low,      1).
urgency_order(medium,   2).
urgency_order(high,     3).
urgency_order(critical, 4).
 
// ---------------------------------------------------------------------------
// Booking pressure levels (mirrors fleet_coordinator_agent.asl)
// ---------------------------------------------------------------------------
pressure_level(low).
pressure_level(medium).
pressure_level(high).
pressure_level(critical).
 
// ---------------------------------------------------------------------------
// Component identifiers (canonical names from the IoT/ML layers)
// ---------------------------------------------------------------------------
component(engine).
component(brakes).
component(battery).
component(oil_pressure).
component(transmission).
component(tyre_pressure).
 
// ---------------------------------------------------------------------------
// Severity thresholds for urgency classification
// (ML health score → urgency: used by VehicleAgent)
// ---------------------------------------------------------------------------
urgency_threshold(critical, 0.90).   // score >= 0.90 → critical
urgency_threshold(high,     0.70).   // score >= 0.70 → high
urgency_threshold(medium,   0.40).   // score >= 0.40 → medium
// below 0.40 → low
