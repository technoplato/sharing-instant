/**
 * Bidirectional Sync Test for Maestro
 * 
 * This script tests the bug where server-side mutations don't
 * update the SwiftUI after a local mutation has been made.
 * 
 * Test Flow:
 * 1. Query current todos via Admin API
 * 2. Tap a todo in the UI (local mutation)
 * 3. Wait for local mutation to sync
 * 4. Toggle a DIFFERENT todo via Admin API (server mutation)
 * 5. Wait and verify if UI updates
 */

var APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
var DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";
var ADMIN_TOKEN = ADMIN_TOKEN || "";

// Debug logging helper
function debugLog(message, data, hypothesisId) {
  var payload = {
    location: "maestro/bidirectional-sync-test.js",
    message: message,
    data: data || {},
    timestamp: Date.now(),
    sessionId: "maestro-test",
    hypothesisId: hypothesisId || "MAESTRO-SYNC"
  };
  
  try {
    http.post(DEBUG_ENDPOINT, {
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
  } catch (e) {
    // Ignore logging errors
  }
}

// Query todos via Admin API
function queryTodos() {
  if (!ADMIN_TOKEN) {
    debugLog("ERROR: No ADMIN_TOKEN provided", { error: "Missing INSTANT_ADMIN_TOKEN" });
    return [];
  }
  
  var url = "https://api.instantdb.com/admin/query";
  var response = http.post(url, {
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

// Update todo done status via Admin API
function updateTodoDone(todoId, done) {
  if (!ADMIN_TOKEN) {
    debugLog("ERROR: No ADMIN_TOKEN provided", { error: "Missing INSTANT_ADMIN_TOKEN" });
    return false;
  }
  
  var url = "https://api.instantdb.com/admin/transact";
  var response = http.post(url, {
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

// Main test execution
debugLog("=== Bidirectional Sync Test Started ===", {
  hasAdminToken: !!ADMIN_TOKEN,
  platform: maestro.platform
});

// Step 1: Query current todos
var todos = queryTodos();
debugLog("Step 1: Queried todos", {
  count: todos.length,
  sample: todos.slice(0, 3).map(function(t) {
    return { id: t.id, title: t.title, done: t.done };
  })
});

if (todos.length < 2) {
  debugLog("ERROR: Need at least 2 todos for this test", { 
    actualCount: todos.length 
  });
  output.success = false;
  output.error = "Need at least 2 todos";
} else {
  // Find a todo that is NOT done (for local toggle)
  var localTodo = null;
  var serverTodo = null;
  
  for (var i = 0; i < todos.length; i++) {
    if (!localTodo && !todos[i].done) {
      localTodo = todos[i];
    } else if (!serverTodo && localTodo) {
      serverTodo = todos[i];
      break;
    }
  }
  
  // Fallback: just use first two todos
  if (!localTodo) localTodo = todos[0];
  if (!serverTodo) serverTodo = todos[1];
  
  debugLog("Step 2: Selected todos for test", {
    localTodo: { id: localTodo.id, title: localTodo.title, done: localTodo.done },
    serverTodo: { id: serverTodo.id, title: serverTodo.title, done: serverTodo.done }
  });
  
  // Store for output (Maestro can use these)
  output.localTodoId = localTodo.id;
  output.localTodoTitle = localTodo.title;
  output.localTodoDone = localTodo.done;
  
  output.serverTodoId = serverTodo.id;
  output.serverTodoTitle = serverTodo.title;
  output.serverTodoDone = serverTodo.done;
  output.serverTodoNewDone = !serverTodo.done;
  
  debugLog("Step 3: Test data prepared", {
    willToggleLocalTodo: localTodo.title,
    willToggleServerTodo: serverTodo.title,
    serverTodoCurrentDone: serverTodo.done,
    serverTodoNewDone: !serverTodo.done
  });
  
  output.success = true;
  output.message = "Test data prepared. Next: tap local todo, then server mutation will be triggered.";
}

debugLog("=== Test Preparation Complete ===", output);
