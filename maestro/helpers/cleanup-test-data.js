/**
 * Cleanup Test Data
 * 
 * Deletes the test todos created during the test.
 */

var APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
var DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";
var ADMIN_TOKEN = ADMIN_TOKEN || "";

function debugLog(message, data) {
  var payload = {
    location: "maestro/cleanup-test-data.js",
    message: message,
    data: data || {},
    timestamp: Date.now(),
    sessionId: "maestro-test",
    hypothesisId: "CLEANUP"
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

function queryTodos() {
  var response = http.post("https://api.instantdb.com/admin/query", {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + ADMIN_TOKEN
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      query: { todos: {} }
    })
  });
  
  var result = json(response.body);
  return result.todos || [];
}

debugLog("=== Cleanup Test Data ===", { hasAdminToken: !!ADMIN_TOKEN });

if (!ADMIN_TOKEN) {
  output.success = false;
  output.error = "No ADMIN_TOKEN provided";
} else {
  // Find and delete test todos
  var todos = queryTodos();
  var deleteSteps = [];
  
  for (var i = 0; i < todos.length; i++) {
    var t = todos[i];
    if (t.title === "Test Todo A" || t.title === "Test Todo B") {
      deleteSteps.push(["delete-entity", "todos", t.id]);
    }
  }
  
  if (deleteSteps.length > 0) {
    var response = http.post("https://api.instantdb.com/admin/transact", {
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + ADMIN_TOKEN
      },
      body: JSON.stringify({
        "app-id": APP_ID,
        steps: deleteSteps
      })
    });
    
    debugLog("Deleted test todos", {
      count: deleteSteps.length,
      status: response.status
    });
    
    output.success = response.status === 200;
    output.deletedCount = deleteSteps.length;
  } else {
    debugLog("No test todos to delete", {});
    output.success = true;
    output.deletedCount = 0;
  }
}

debugLog("=== Cleanup Complete ===", output);
