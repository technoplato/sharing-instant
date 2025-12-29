/**
 * Log current state to debug endpoint
 */

var DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";

var step = STEP || "unknown";
var message = MESSAGE || "State logged";

var payload = {
  location: "maestro/log-state.js",
  message: message,
  data: {
    step: step,
    platform: maestro.platform,
    timestamp: Date.now()
  },
  timestamp: Date.now(),
  sessionId: "maestro-test",
  hypothesisId: "MAESTRO"
};

try {
  http.post(DEBUG_ENDPOINT, {
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  output.logged = true;
} catch (e) {
  output.logged = false;
  output.error = e.message;
}
