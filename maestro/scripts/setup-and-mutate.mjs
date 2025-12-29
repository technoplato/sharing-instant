/**
 * Setup and Mutate Script for Maestro Tests
 * 
 * This script handles InstantDB Admin API calls separately from Maestro
 * to avoid SSL certificate issues with Zscaler.
 * 
 * Usage:
 *   node setup-and-mutate.mjs setup   - Create test todos
 *   node setup-and-mutate.mjs mutate  - Toggle Test Todo B
 *   node setup-and-mutate.mjs cleanup - Delete test todos
 *   node setup-and-mutate.mjs query   - Show current todos
 */

const APP_ID = "b9319949-2f2d-410b-8f8a-6990177c1d44";
const ADMIN_TOKEN = "10c2aaea-5942-4e64-b105-3db598c14409";
const DEBUG_ENDPOINT = "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385";

async function debugLog(message, data = {}, hypothesisId = "NODE-SCRIPT") {
  const payload = {
    location: "maestro/scripts/setup-and-mutate.mjs",
    message,
    data,
    timestamp: Date.now(),
    sessionId: "maestro-test",
    hypothesisId
  };
  
  try {
    await fetch(DEBUG_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
  } catch (e) {
    // Ignore
  }
}

async function queryTodos() {
  const response = await fetch("https://api.instantdb.com/admin/query", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${ADMIN_TOKEN}`,
      "app-id": APP_ID
    },
    body: JSON.stringify({
      query: { todos: {} }
    })
  });
  
  if (!response.ok) {
    const text = await response.text();
    console.error("Query failed:", text);
    return [];
  }
  
  const result = await response.json();
  return result.todos || [];
}

async function transact(steps) {
  const response = await fetch("https://api.instantdb.com/admin/transact", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${ADMIN_TOKEN}`,
      "app-id": APP_ID
    },
    body: JSON.stringify({ steps })
  });
  
  if (!response.ok) {
    const text = await response.text();
    console.error("Transact failed:", text);
    return false;
  }
  
  return true;
}

async function setup() {
  console.log("Setting up test todos...");
  await debugLog("Setup: Creating test todos");
  
  const todoAId = crypto.randomUUID();
  const todoBId = crypto.randomUUID();
  const now = Date.now();
  
  const success = await transact([
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
  ]);
  
  if (success) {
    console.log("✅ Created Test Todo A:", todoAId);
    console.log("✅ Created Test Todo B:", todoBId);
    await debugLog("Setup complete", { todoAId, todoBId });
  } else {
    console.log("❌ Failed to create test todos");
    await debugLog("Setup failed");
  }
}

async function mutate() {
  console.log("Toggling Test Todo B via Admin API...");
  await debugLog("Mutate: Looking for Test Todo B", {}, "SERVER-MUTATION");
  
  const todos = await queryTodos();
  const todoB = todos.find(t => t.title === "Test Todo B");
  
  if (!todoB) {
    console.log("❌ Test Todo B not found");
    console.log("Available todos:", todos.map(t => t.title));
    await debugLog("Mutate failed: Test Todo B not found", { 
      availableTodos: todos.map(t => t.title) 
    }, "SERVER-MUTATION");
    return;
  }
  
  const newDone = !todoB.done;
  
  await debugLog("Mutate: Toggling Test Todo B", {
    todoId: todoB.id,
    currentDone: todoB.done,
    newDone
  }, "SERVER-MUTATION");
  
  const success = await transact([
    ["update", "todos", todoB.id, { done: newDone }]
  ]);
  
  if (success) {
    console.log(`✅ Toggled Test Todo B: done=${todoB.done} -> done=${newDone}`);
    await debugLog("Mutate complete", { todoId: todoB.id, newDone }, "SERVER-MUTATION");
  } else {
    console.log("❌ Failed to toggle Test Todo B");
    await debugLog("Mutate failed", {}, "SERVER-MUTATION");
  }
}

async function cleanup() {
  console.log("Cleaning up test todos...");
  await debugLog("Cleanup: Deleting test todos");
  
  const todos = await queryTodos();
  const testTodos = todos.filter(t => 
    t.title === "Test Todo A" || t.title === "Test Todo B"
  );
  
  if (testTodos.length === 0) {
    console.log("No test todos to delete");
    return;
  }
  
  const steps = testTodos.map(t => ["delete-entity", "todos", t.id]);
  const success = await transact(steps);
  
  if (success) {
    console.log(`✅ Deleted ${testTodos.length} test todos`);
    await debugLog("Cleanup complete", { deletedCount: testTodos.length });
  } else {
    console.log("❌ Failed to delete test todos");
    await debugLog("Cleanup failed");
  }
}

async function query() {
  console.log("Querying todos...");
  
  const todos = await queryTodos();
  console.log(`\nFound ${todos.length} todos:\n`);
  
  for (const todo of todos) {
    const doneStr = todo.done ? "✅" : "⬜";
    console.log(`  ${doneStr} ${todo.title} (${todo.id})`);
  }
  console.log("");
}

// Main
const command = process.argv[2];

switch (command) {
  case "setup":
    await setup();
    break;
  case "mutate":
    await mutate();
    break;
  case "cleanup":
    await cleanup();
    break;
  case "query":
    await query();
    break;
  default:
    console.log("Usage: node setup-and-mutate.mjs <setup|mutate|cleanup|query>");
    process.exit(1);
}
