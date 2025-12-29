/**
 * Setup Test Data
 * 
 * Creates two test todos via Admin API for the bidirectional sync test.
 */

var APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
var DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";
var ADMIN_TOKEN = ADMIN_TOKEN || "";

function debugLog(message, data) {
  var payload = {
    location: "maestro/setup-test-data.js",
    message: message,
    data: data || {},
    timestamp: Date.now(),
    sessionId: "maestro-test",
    hypothesisId: "SETUP"
  };
  
  try {
    http.post(DEBUG_ENDPOINT, {
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
  } catch (e) {
    // Ignore
  }
}

function generateUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    var r = Math.random() * 16 | 0;
    var v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

debugLog("=== Setup Test Data ===", { hasAdminToken: !!ADMIN_TOKEN });

if (!ADMIN_TOKEN) {
  output.success = false;
  output.error = "No ADMIN_TOKEN provided";
  debugLog("FAILED: No admin token", {});
} else {
  var todoAId = generateUUID();
  var todoBId = generateUUID();
  var now = Date.now();
  
  // Create two todos
  var response = http.post("https://api.instantdb.com/admin/transact", {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + ADMIN_TOKEN
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      steps: [
        ["update", "todos", todoAId, {
          createdAt: now,
          done: false,
          title: "Test Todo A"
        }],
        ["update", "todos", todoBId, {
          createdAt: now - 1000,
          done: false,
          title: "Test Todo B"
        }]
      ]
    })
  });
  
  debugLog("Created test todos", {
    todoAId: todoAId,
    todoBId: todoBId,
    status: response.status
  });
  
  // Store IDs for later cleanup
  output.todoAId = todoAId;
  output.todoBId = todoBId;
  output.success = response.status === 200;
}

debugLog("=== Setup Complete ===", output);
