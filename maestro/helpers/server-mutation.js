/**
 * Server Mutation Script
 * 
 * This script is called AFTER a local mutation has been made in the UI.
 * It toggles a DIFFERENT todo via the Admin API to test if the UI updates.
 */

var APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
var DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";
var ADMIN_TOKEN = ADMIN_TOKEN || "";

function debugLog(message, data, hypothesisId) {
  var payload = {
    location: "maestro/server-mutation.js",
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
  if (!ADMIN_TOKEN) {
    debugLog("ERROR: No ADMIN_TOKEN", { error: "Missing token" });
    return [];
  }
  
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

function updateTodoDone(todoId, done) {
  var response = http.post("https://api.instantdb.com/admin/transact", {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + ADMIN_TOKEN
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      steps: [
        ["update", "todos", todoId, { done: done }]
      ]
    })
  });
  
  return response.status === 200;
}

// Main execution
debugLog("=== Server Mutation Script Started ===", {
  hasAdminToken: !!ADMIN_TOKEN
});

if (!ADMIN_TOKEN) {
  output.success = false;
  output.error = "No ADMIN_TOKEN provided. Run with: maestro test --env INSTANT_ADMIN_TOKEN=<token>";
  debugLog("FAILED: No admin token", {});
} else {
  // Query current todos
  var todos = queryTodos();
  debugLog("Queried todos", {
    count: todos.length,
    todos: todos.map(function(t) {
      return { id: t.id, title: t.title, done: t.done };
    })
  });
  
  if (todos.length === 0) {
    output.success = false;
    output.error = "No todos found";
    debugLog("FAILED: No todos", {});
  } else {
    // Find a todo to toggle (prefer one named "From iPhone" or similar)
    var todoToToggle = null;
    
    for (var i = 0; i < todos.length; i++) {
      var t = todos[i];
      // Skip "something else" since we toggled that locally
      if (t.title && t.title.indexOf("something else") === -1) {
        todoToToggle = t;
        break;
      }
    }
    
    // Fallback to first todo if none found
    if (!todoToToggle && todos.length > 0) {
      todoToToggle = todos[0];
    }
    
    if (todoToToggle) {
      var newDone = !todoToToggle.done;
      
      debugLog("Toggling todo via Admin API", {
        todoId: todoToToggle.id,
        title: todoToToggle.title,
        currentDone: todoToToggle.done,
        newDone: newDone
      }, "SERVER-MUTATION");
      
      var success = updateTodoDone(todoToToggle.id, newDone);
      
      debugLog("Server mutation result", {
        success: success,
        todoId: todoToToggle.id,
        newDone: newDone
      }, "SERVER-MUTATION");
      
      output.success = success;
      output.todoId = todoToToggle.id;
      output.todoTitle = todoToToggle.title;
      output.oldDone = todoToToggle.done;
      output.newDone = newDone;
    } else {
      output.success = false;
      output.error = "Could not find a todo to toggle";
      debugLog("FAILED: No suitable todo", {});
    }
  }
}

debugLog("=== Server Mutation Script Complete ===", output);
