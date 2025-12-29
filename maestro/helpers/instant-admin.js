/**
 * InstantDB Admin SDK helpers for Maestro tests
 * 
 * These functions allow Maestro tests to interact with InstantDB
 * to create, update, and verify data during UI tests.
 */

// Configuration
const APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
const DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";

/**
 * Log to debug endpoint
 */
function debugLog(message, data, hypothesisId) {
  const payload = {
    location: "instant-admin.js",
    message: message,
    data: data || {},
    timestamp: Date.now(),
    sessionId: "maestro-test",
    hypothesisId: hypothesisId || "MAESTRO"
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

/**
 * Query todos from InstantDB via Admin API
 */
function queryTodos(adminToken) {
  debugLog("Querying todos via Admin API", { appId: APP_ID });
  
  const url = "https://api.instantdb.com/admin/query";
  const response = http.post(url, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + adminToken
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      query: { todos: {} }
    })
  });
  
  const result = json(response.body);
  debugLog("Query result", { 
    todoCount: result.todos ? result.todos.length : 0,
    todos: result.todos ? result.todos.slice(0, 3) : []
  });
  
  return result.todos || [];
}

/**
 * Create a todo via Admin API
 */
function createTodo(adminToken, title, done) {
  const todoId = generateUUID();
  const createdAt = Date.now();
  
  debugLog("Creating todo via Admin API", { 
    todoId: todoId, 
    title: title, 
    done: done || false 
  });
  
  const url = "https://api.instantdb.com/admin/transact";
  const response = http.post(url, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + adminToken
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      steps: [
        ["update", "todos", todoId, {
          createdAt: createdAt,
          done: done || false,
          title: title
        }]
      ]
    })
  });
  
  debugLog("Create result", { 
    todoId: todoId, 
    status: response.status 
  });
  
  return todoId;
}

/**
 * Update a todo's done status via Admin API
 */
function updateTodoDone(adminToken, todoId, done) {
  debugLog("Updating todo done status via Admin API", { 
    todoId: todoId, 
    newDone: done 
  });
  
  const url = "https://api.instantdb.com/admin/transact";
  const response = http.post(url, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + adminToken
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      steps: [
        ["update", "todos", todoId, {
          done: done
        }]
      ]
    })
  });
  
  debugLog("Update result", { 
    todoId: todoId, 
    newDone: done, 
    status: response.status 
  });
  
  return response.status === 200;
}

/**
 * Delete a todo via Admin API
 */
function deleteTodo(adminToken, todoId) {
  debugLog("Deleting todo via Admin API", { todoId: todoId });
  
  const url = "https://api.instantdb.com/admin/transact";
  const response = http.post(url, {
    headers: {
      "Content-Type": "application/json",
      "Authorization": "Bearer " + adminToken
    },
    body: JSON.stringify({
      "app-id": APP_ID,
      steps: [
        ["delete-entity", "todos", todoId]
      ]
    })
  });
  
  debugLog("Delete result", { 
    todoId: todoId, 
    status: response.status 
  });
  
  return response.status === 200;
}

/**
 * Generate a UUID (simple implementation for Maestro/Rhino)
 */
function generateUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    var r = Math.random() * 16 | 0;
    var v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

/**
 * Wait for a condition with polling
 */
function waitForCondition(checkFn, timeoutMs, intervalMs) {
  var deadline = Date.now() + (timeoutMs || 10000);
  var interval = intervalMs || 500;
  
  while (Date.now() < deadline) {
    if (checkFn()) {
      return true;
    }
    // Maestro doesn't have sleep, but we can use a busy wait
    var waitUntil = Date.now() + interval;
    while (Date.now() < waitUntil) {
      // busy wait
    }
  }
  return false;
}

// Export for Maestro
output.queryTodos = queryTodos;
output.createTodo = createTodo;
output.updateTodoDone = updateTodoDone;
output.deleteTodo = deleteTodo;
output.generateUUID = generateUUID;
output.debugLog = debugLog;
output.waitForCondition = waitForCondition;
