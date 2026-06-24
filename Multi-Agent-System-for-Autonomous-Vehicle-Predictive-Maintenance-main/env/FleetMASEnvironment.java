package env;

import jason.asSyntax.*;
import jason.environment.Environment;
import java.util.*;
import java.util.logging.Logger;
import java.net.http.*;
import java.net.URI;
import java.net.http.HttpRequest.BodyPublishers;
import java.net.http.HttpResponse.BodyHandlers;

/**
 * FleetMASEnvironment
 *
 * Bridges Jason MAS to the three integrated course layers:
 *   - IoT layer       (Codice 77780) — MQTT broker at localhost:1883
 *   - ML layer        (Codice 95631) — Flask API at localhost:5000
 *   - Blockchain      (Codice 87474) — DS backend at localhost:3000
 *
 * Toggle USE_REAL_INTEGRATIONS to switch between mock and real.
 */
public class FleetMASEnvironment extends Environment {

    private static final Logger logger = Logger.getLogger(FleetMASEnvironment.class.getName());

    // -------------------------------------------------------------------------
    // SET true  → connects to real DS backend at localhost:3000
    // SET false → uses mock data (standalone simulation)
    // Default is false so the MAS runs end-to-end with no external backends.
    // -------------------------------------------------------------------------
    private static final boolean USE_REAL_INTEGRATIONS = false;

    // DS project endpoints (from start-all.sh output)
    private static final String DS_BACKEND_URL  = "http://localhost:3000";
    private static final String ML_BACKEND_URL  = "http://localhost:5000";

    private IoTStreamAdapter    iotAdapter;
    private MLPipelineAdapter   mlAdapter;
    private BlockchainAdapter   blockchainAdapter;

    private Thread tickThread;
    private volatile boolean running = true;

    private final HttpClient httpClient = HttpClient.newHttpClient();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    @Override
    public void init(String[] args) {
        logger.info("[ENV] FleetMASEnvironment initialising...");

        if (USE_REAL_INTEGRATIONS) {
            logger.info("[ENV] Mode: REAL — connecting to DS backend at " + DS_BACKEND_URL);
            iotAdapter        = new MockIoTStream();          // IoT mock (ESP32 not connected)
            mlAdapter         = new MockMLPipeline();         // ML mock (Flask not running)
            blockchainAdapter = new RealBlockchainClient();   // REAL DS backend
        } else {
            logger.info("[ENV] Mode: MOCK — using simulated data");
            iotAdapter        = new MockIoTStream();
            mlAdapter         = new MockMLPipeline();
            blockchainAdapter = new MockBlockchainClient();
        }

        startTickThread();
        logger.info("[ENV] FleetMASEnvironment ready.");
    }

    @Override
    public void stop() {
        running = false;
        if (tickThread != null) tickThread.interrupt();
        super.stop();
    }

    // -------------------------------------------------------------------------
    // Action Dispatcher
    // -------------------------------------------------------------------------

    @Override
    public boolean executeAction(String agentName, Structure action) {
        String functor = action.getFunctor();
        logger.info("[ENV] Action from " + agentName + ": " + functor);

        switch (functor) {

            case "registerCoordinator":
                logger.info("[ENV] FleetCoordinator registered.");
                return true;

            case "pollIoTAnomalyStream":
                return handlePollIoT(agentName);

            case "logFleetAnomalyToBlockchain":
                String anomalyType = action.getTerm(0).toString();
                String countStr    = action.getTerm(1).toString();
                return blockchainAdapter.logFleetAnomaly(anomalyType, Integer.parseInt(countStr));

            case "registerVehicle":
                String vin = action.getTerm(0).toString();
                addPercept("fleet_coordinator_agent",
                        ASSyntax.createLiteral("vehicle_registered",
                                ASSyntax.createAtom(vin)));
                return true;
 
            // -----------------------------------------------------------------
            // Edge / ML / crypto simulation hooks.
            // Jason environment actions cannot bind result variables back into a
            // plan, so the VehicleAgent simulates the actual values internally
            // and these actions simply acknowledge success. Implemented here so
            // that any agent invoking them never hits the "Unknown action" path.
            // -----------------------------------------------------------------
            case "fetchEdgeSensors":
            case "evaluateRandomForest":
            case "evaluateIsolationForest":
            case "deriveECDSAKey":
            case "signTelemetryRecord":
                logger.fine("[ENV] Simulated edge/ML/crypto action: " + functor);
                return true;

            case "fetchMLHealthInsights":
                return handleFetchMLInsights(agentName);

            case "readDigitalTwin":
                return handleReadDigitalTwin(agentName, action.getTerm(0).toString());

            case "writeServiceRecord":
                String vehicleId = action.getTerm(0).toString();
                String details   = action.getTerm(1).toString();
                boolean ok = blockchainAdapter.writeServiceRecord(vehicleId, details);
                if (ok) {
                    addPercept("fleet_coordinator_agent",
                            ASSyntax.createLiteral("booking_confirmed",
                                    ASSyntax.createAtom(vehicleId)));
                }
                return ok;

            default:
                logger.warning("[ENV] Unknown action: " + functor);
                return false;
        }
    }

    // -------------------------------------------------------------------------
    // Internal Handlers
    // -------------------------------------------------------------------------

    private boolean handlePollIoT(String agentName) {
        List<IoTAnomaly> anomalies = iotAdapter.getLatestAnomalies();
        for (IoTAnomaly a : anomalies) {
            Literal percept = ASSyntax.createLiteral("anomaly_detected",
                    ASSyntax.createAtom(a.vehicleId),
                    ASSyntax.createAtom(a.anomalyType),
                    ASSyntax.createAtom(a.severity));
            addPercept("fleet_coordinator_agent", percept);
            logger.info("[ENV] Injected anomaly_detected(" +
                    a.vehicleId + "," + a.anomalyType + "," + a.severity + ")");
        }
        return true;
    }

    private boolean handleFetchMLInsights(String agentName) {
        MLInsight insight = mlAdapter.getInsight(agentName);
        if (insight == null) return false;
        addPercept(agentName, ASSyntax.createLiteral("health_status",
                ASSyntax.createAtom(insight.componentId),
                ASSyntax.createNumber(insight.score)));
        addPercept(agentName, ASSyntax.createLiteral("urgency_level",
                ASSyntax.createAtom(insight.urgency)));
        return true;
    }

    private boolean handleReadDigitalTwin(String agentName, String vin) {
        String history = blockchainAdapter.readDigitalTwin(vin);
        addPercept(agentName, ASSyntax.createLiteral("maintenance_history",
                ASSyntax.createAtom(vin),
                ASSyntax.createAtom(history)));
        return true;
    }

    // -------------------------------------------------------------------------
    // Tick Thread
    // -------------------------------------------------------------------------

    private void startTickThread() {
        tickThread = new Thread(() -> {
            while (running) {
                try {
                    Thread.sleep(2000);
                    addPercept("fleet_coordinator_agent",
                            ASSyntax.createLiteral("tick"));
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        tickThread.setDaemon(true);
        tickThread.start();
    }

    // -------------------------------------------------------------------------
    // Data classes
    // -------------------------------------------------------------------------

    static class IoTAnomaly {
        String vehicleId, anomalyType, severity;
        IoTAnomaly(String v, String t, String s) {
            vehicleId = v; anomalyType = t; severity = s;
        }
    }

    static class MLInsight {
        String componentId, urgency;
        double score;
        MLInsight(String c, double sc, String u) {
            componentId = c; score = sc; urgency = u;
        }
    }

    // -------------------------------------------------------------------------
    // Adapter interfaces
    // -------------------------------------------------------------------------

    interface IoTStreamAdapter    { List<IoTAnomaly> getLatestAnomalies(); }
    interface MLPipelineAdapter   { MLInsight getInsight(String agentName); }
    interface BlockchainAdapter   {
        boolean logFleetAnomaly(String anomalyType, int count);
        boolean writeServiceRecord(String vehicleId, String details);
        String  readDigitalTwin(String vin);
    }

    // =========================================================================
    // REAL BLOCKCHAIN CLIENT — calls DS backend at localhost:3000
    // Endpoints from DS project (start-all.sh output):
    //   POST /api/telemetry/store        — store fleet anomaly event
    //   POST /api/vehicle/:vin/service   — write service record
    //   GET  /api/vehicle/:vin           — read digital twin history
    // =========================================================================

    class RealBlockchainClient implements BlockchainAdapter {

        @Override
        public boolean logFleetAnomaly(String anomalyType, int count) {
            try {
                String payload = String.format(
                        "{\"type\":\"fleet_anomaly\",\"anomalyType\":\"%s\",\"count\":%d,\"source\":\"MAS-FleetCoordinator\",\"timestamp\":%d}",
                        anomalyType, count, System.currentTimeMillis());

                HttpRequest req = HttpRequest.newBuilder()
                        .uri(URI.create(DS_BACKEND_URL + "/api/telemetry/store"))
                        .header("Content-Type", "application/json")
                        .POST(BodyPublishers.ofString(payload))
                        .build();

                HttpResponse<String> resp = httpClient.send(req, BodyHandlers.ofString());
                System.out.println("[BLOCKCHAIN-REAL] Fleet anomaly logged: "
                        + anomalyType + " x" + count + " → HTTP " + resp.statusCode());
                return resp.statusCode() == 200 || resp.statusCode() == 201;

            } catch (Exception e) {
                logger.warning("[ENV] Blockchain log failed: " + e.getMessage());
                System.out.println("[BLOCKCHAIN-REAL] FAILED — falling back to local log");
                return false;
            }
        }

        @Override
        public boolean writeServiceRecord(String vehicleId, String details) {
            try {
                String payload = String.format(
                        "{\"service\":\"%s\",\"timestamp\":%d,\"source\":\"MAS-ServiceCenterAgent\"}",
                        details, System.currentTimeMillis());

                HttpRequest req = HttpRequest.newBuilder()
                        .uri(URI.create(DS_BACKEND_URL + "/api/vehicle/" + vehicleId + "/service"))
                        .header("Content-Type", "application/json")
                        .POST(BodyPublishers.ofString(payload))
                        .build();

                HttpResponse<String> resp = httpClient.send(req, BodyHandlers.ofString());
                System.out.println("[BLOCKCHAIN-REAL] Service record written for "
                        + vehicleId + " → HTTP " + resp.statusCode());
                return resp.statusCode() == 200 || resp.statusCode() == 201;

            } catch (Exception e) {
                logger.warning("[ENV] Service record write failed: " + e.getMessage());
                return false;
            }
        }

        @Override
        public String readDigitalTwin(String vin) {
            try {
                HttpRequest req = HttpRequest.newBuilder()
                        .uri(URI.create(DS_BACKEND_URL + "/api/vehicle/" + vin))
                        .GET()
                        .build();

                HttpResponse<String> resp = httpClient.send(req, BodyHandlers.ofString());
                if (resp.statusCode() == 200) {
                    System.out.println("[BLOCKCHAIN-REAL] Digital twin read for " + vin);
                    return resp.body();
                }
            } catch (Exception e) {
                logger.warning("[ENV] Digital twin read failed: " + e.getMessage());
            }
            return "last_service:unknown,status:unknown";
        }
    }

    // =========================================================================
    // MOCK ADAPTERS — used when USE_REAL_INTEGRATIONS = false
    // =========================================================================

    static class MockIoTStream implements IoTStreamAdapter {
        private final String[][] data = {
                {"vehicle_agent1", "brake_wear",   "high"},
                {"vehicle_agent2", "brake_wear",   "medium"},
                {"vehicle_agent3", "oil_pressure", "low"},
                {"vehicle_agent1", "oil_pressure", "high"},
                {"vehicle_agent2", "oil_pressure", "critical"},
        };
        private int cursor = 0;

        @Override
        public List<IoTAnomaly> getLatestAnomalies() {
            List<IoTAnomaly> result = new ArrayList<>();
            int batch = Math.min(2, data.length - cursor);
            for (int i = 0; i < batch; i++) {
                String[] row = data[(cursor + i) % data.length];
                result.add(new IoTAnomaly(row[0], row[1], row[2]));
            }
            cursor = (cursor + batch) % data.length;
            return result;
        }
    }

    static class MockMLPipeline implements MLPipelineAdapter {
        private final Map<String, MLInsight> insights = new HashMap<>();
        MockMLPipeline() {
            insights.put("vehicle_agent1", new MLInsight("engine",  0.82, "high"));
            insights.put("vehicle_agent2", new MLInsight("brakes",  0.45, "medium"));
            insights.put("vehicle_agent3", new MLInsight("battery", 0.91, "low"));
        }
        @Override
        public MLInsight getInsight(String agentName) {
            return insights.getOrDefault(agentName, new MLInsight("unknown", 0.5, "low"));
        }
    }

    static class MockBlockchainClient implements BlockchainAdapter {
        @Override
        public boolean logFleetAnomaly(String anomalyType, int count) {
            System.out.println("[BLOCKCHAIN-MOCK] Fleet anomaly logged: " + anomalyType + " x" + count);
            return true;
        }
        @Override
        public boolean writeServiceRecord(String vehicleId, String details) {
            System.out.println("[BLOCKCHAIN-MOCK] Service record written for: " + vehicleId + " — " + details);
            return true;
        }
        @Override
        public String readDigitalTwin(String vin) {
            return "last_service:2024-11-01,mileage:45200,status:ok";
        }
    }
}
