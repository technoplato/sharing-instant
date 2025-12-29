/**
 * Toggle Todo B via Admin API
 * 
 * This script toggles "Test Todo B" via the Admin API to test
 * if server-side mutations are reflected in the UI after a local mutation.
 */

var APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
var DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";
var ADMIN_TOKEN = ADMIN_TOKEN || "";

function debugLog(message, data, hypothesisId) {
  var payload = {
    location: "maestro/toggle-todo-b.js",
    message: message,
    data: data || {},
    timestamp: Date.now(),
    sessionId: "maestro-test",
    hypothesisId: hypothesisId || "SERVER-MUTATION"
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

debugLog("=== Toggle Todo B ===", { hasAdminToken: !!ADMIN_TOKEN });

if (!ADMIN_TOKEN) {
  output.success = false;
  output.error = "No ADMIN_TOKEN provided";
  debugLog("FAILED: No admin token", {});
} else {
  // Find Test Todo B
  var todos = queryTodos();
  var todoB = null;
  
  for (var i = 0; i < todos.length; i++) {
    if (todos[i].title === "Test Todo B") {
      todoB = todos[i];
      break;
    }
  }
  
  if (!todoB) {
    output.success = false;
    output.error = "Test Todo B not found";
    debugLog("FAILED: Test Todo B not found", { 
      availableTodos: todos.map(function(t) { return t.title; })
    });
  } else {
    var newDone = !todoB.done;
    
    debugLog("Toggling Test Todo B via Admin API", {
      todoId: todoB.id,
      currentDone: todoB.done,
      newDone: newDone
    }, "SERVER-MUTATION");
    
    var response = http.post("https://api.instantdb.com/admin/transact", {
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + ADMIN_TOKEN
      },
      body: JSON.stringify({
        "app-id": APP_ID,
        steps: [
          ["update", "todos", todoB.id, { done: newDone }]
        ]
      })
    });
    
    debugLog("Toggle result", {
      todoId: todoB.id,
      newDone: newDone,
      status: response.status
    }, "SERVER-MUTATION");
    
    output.success = response.status === 200;
    output.todoId = todoB.id;
    output.oldDone = todoB.done;
    output.newDone = newDone;
  }
}

debugLog("=== Toggle Complete ===", output);
