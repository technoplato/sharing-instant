import SharingInstant
import Sharing
import SwiftUI

// #region agent log
private func debugLog(_ location: String, _ message: String, _ data: [String: Any] = [:]) {
  var payload: [String: Any] = [
    "location": location,
    "message": message,
    "timestamp": Date().timeIntervalSince1970 * 1000,
    "sessionId": "debug-session",
    "runId": "advanced-todo-debug"
  ]
  if !data.isEmpty { payload["data"] = data }
  guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
        let jsonString = String(data: jsonData, encoding: .utf8) else { return }
  let url = URL(string: "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385")!
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = jsonData
  URLSession.shared.dataTask(with: request).resume()
}
// #endregion

struct AdvancedTodoDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows advanced querying features with **server-side filtering**:
    
    • **Search** - Filter todos by title using InstantDB's `$ilike` operator
    • **Sort** - Order by name or date (server-side)
    • **Filter** - Show all, active, or completed todos (server-side)
    
    All filtering happens on the server using dynamic EntityKeys with \
    `.where()` predicates. This is more efficient than client-side filtering \
    because only matching data is transferred.
    """
  let caseStudyTitle = "Advanced Todo"
  
  var body: some View {
    AdvancedTodoView()
  }
}

// MARK: - Sort Options

enum TodoSortOption: String, CaseIterable, Identifiable {
  case dateDesc = "Newest"
  case dateAsc = "Oldest"
  case nameAsc = "A-Z"
  case nameDesc = "Z-A"
  
  var id: String { rawValue }
  
  var field: String {
    switch self {
    case .dateDesc, .dateAsc: return "createdAt"
    case .nameAsc, .nameDesc: return "title"
    }
  }
  
  var direction: EntityKeyOrderDirection {
    switch self {
    case .dateDesc, .nameDesc: return .desc
    case .dateAsc, .nameAsc: return .asc
    }
  }
}

// MARK: - Filter Options

enum TodoFilterOption: String, CaseIterable, Identifiable {
  case all = "All"
  case active = "Active"
  case completed = "Done"
  
  var id: String { rawValue }
}

// MARK: - Main View

private struct AdvancedTodoView: View {
  // Use @State.Shared to persist the key across view recreations
  // This is critical for dynamic queries - see swift-sharing DynamicKeys.md
  @State.Shared(.instantSync(Schema.todos.orderBy(\Todo.createdAt, EntityKeyOrderDirection.desc)))
  private var todos: IdentifiedArrayOf<Todo> = []
  
  @State private var searchText = ""
  @State private var sortOption: TodoSortOption = .dateDesc
  @State private var filterOption: TodoFilterOption = .all
  @State private var newTodoTitle = ""
  
  // Debug: track query changes
  private func logQueryChange(_ reason: String) {
    print("[AdvancedTodoDemo] Query change: \(reason)")
    print("[AdvancedTodoDemo]   queryKey: \(queryKey)")
    print("[AdvancedTodoDemo]   todos count: \(todos.count)")
  }
  
  // Build dynamic query based on current filters
  private var currentQuery: EntityKey<Todo> {
    var query = Schema.todos
      .orderBy(sortOption.field, sortOption.direction)
    
    // Add status filter
    switch filterOption {
    case .all:
      break
    case .active:
      query = query.where(\Todo.done, .eq(false))
    case .completed:
      query = query.where(\Todo.done, .eq(true))
    }
    
    // Add search filter (server-side with $ilike)
    if !searchText.isEmpty {
      query = query.where(\Todo.title, .contains(searchText))
    }
    
    return query
  }
  
  var body: some View {
    List {
      // Stats
      Section {
        HStack {
          StatView(label: "Total", count: todos.count, color: .blue)
          StatView(label: "Active", count: todos.filter { !$0.done }.count, color: .orange)
          StatView(label: "Done", count: todos.filter { $0.done }.count, color: .green)
        }
      }
      
      // Controls
      Section {
        // Sort picker
        Picker("Sort", selection: $sortOption) {
          ForEach(TodoSortOption.allCases) { option in
            Text(option.rawValue).tag(option)
          }
        }
        
        // Filter picker
        Picker("Filter", selection: $filterOption) {
          ForEach(TodoFilterOption.allCases) { option in
            Text(option.rawValue).tag(option)
          }
        }
        .pickerStyle(.segmented)
      }
      
      // Add todo
      Section("Add Todo") {
        HStack {
          TextField("New todo...", text: $newTodoTitle)
            .onSubmit(addTodo)
          
          Button(action: addTodo) {
            Image(systemName: "plus.circle.fill")
          }
          .disabled(newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      
      // Results
      Section("Results (\(todos.count))") {
        if todos.isEmpty {
          ContentUnavailableView {
            Label("No Todos", systemImage: "checklist")
          } description: {
            Text(emptyMessage)
          }
        } else {
          ForEach(todos) { todo in
            TodoRowView(todo: todo, onToggle: { toggleTodo(todo) })
          }
          .onDelete(perform: deleteTodos)
        }
      }
    }
    .searchable(text: $searchText, prompt: "Search todos...")
    .task(id: queryKey) {
      // #region agent log
      debugLog("AdvancedTodoDemo:task", "task triggered - reassigning shared reference", [
        "hypothesisId": "A",
        "queryKey": queryKey,
        "filterOption": filterOption.rawValue,
        "sortOption": sortOption.rawValue,
        "currentTodosCount": todos.count
      ])
      // #endregion
      
      // Reassign the projected value to create a NEW subscription
      // Using load() only does a one-shot fetch and doesn't maintain real-time updates
      // Reassigning $todos creates a new reference with a new subscribe() call
      logQueryChange("task triggered")
      $todos = Shared(.instantSync(currentQuery))
      
      // #region agent log
      debugLog("AdvancedTodoDemo:task", "shared reference reassigned", [
        "hypothesisId": "A",
        "queryKey": queryKey,
        "todosCount": todos.count
      ])
      // #endregion
      
      print("[AdvancedTodoDemo] Reference reassigned, todos count: \(todos.count)")
    }
    .onChange(of: todos.count) { oldValue, newValue in
      // #region agent log
      debugLog("AdvancedTodoDemo:onChange", "todos.count changed", [
        "hypothesisId": "B",
        "oldValue": oldValue,
        "newValue": newValue,
        "filterOption": filterOption.rawValue
      ])
      // #endregion
      
      print("[AdvancedTodoDemo] todos.count changed: \(oldValue) -> \(newValue)")
    }
    .onChange(of: todos) { oldValue, newValue in
      // #region agent log
      debugLog("AdvancedTodoDemo:onChange:todos", "todos array changed", [
        "hypothesisId": "B",
        "oldCount": oldValue.count,
        "newCount": newValue.count,
        "oldIds": oldValue.map { $0.id }.prefix(5).map { $0 },
        "newIds": newValue.map { $0.id }.prefix(5).map { $0 }
      ])
      // #endregion
    }
    .onAppear {
      // #region agent log
      debugLog("AdvancedTodoDemo:onAppear", "view appeared", [
        "hypothesisId": "D",
        "todosCount": todos.count
      ])
      // #endregion
    }
    .animation(.default, value: todos.count)
  }
  
  // Unique key for the current query state
  private var queryKey: String {
    "\(sortOption.rawValue)-\(filterOption.rawValue)-\(searchText)"
  }
  
  private var emptyMessage: String {
    if !searchText.isEmpty {
      return "No todos match '\(searchText)'"
    }
    switch filterOption {
    case .all: return "Add your first todo!"
    case .active: return "All done! 🎉"
    case .completed: return "Nothing completed yet"
    }
  }
  
  private func addTodo() {
    let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    
    // Generated Todo uses Double for createdAt (Unix timestamp)
    let todo = Todo(
      createdAt: Date().timeIntervalSince1970,
      done: false,
      title: title
    )
    _ = $todos.withLock { $0.insert(todo, at: 0) }
    newTodoTitle = ""
  }
  
  private func toggleTodo(_ todo: Todo) {
    _ = $todos.withLock { todos in
      if let index = todos.firstIndex(where: { $0.id == todo.id }) {
        todos[index].done.toggle()
      }
    }
  }
  
  private func deleteTodos(at offsets: IndexSet) {
    _ = $todos.withLock { todos in
      todos.remove(atOffsets: offsets)
    }
  }
}

// MARK: - Subviews

private struct StatView: View {
  let label: String
  let count: Int
  let color: Color
  
  var body: some View {
    VStack(spacing: 4) {
      Text("\(count)")
        .font(.title2)
        .bold()
        .foregroundStyle(color)
        .contentTransition(.numericText(value: Double(count)))
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct TodoRowView: View {
  let todo: Todo
  let onToggle: () -> Void
  
  var body: some View {
    HStack {
      Button(action: onToggle) {
        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundStyle(todo.done ? .green : .secondary)
      }
      .buttonStyle(.plain)
      
      VStack(alignment: .leading, spacing: 4) {
        Text(todo.title)
          .strikethrough(todo.done)
          .foregroundStyle(todo.done ? .secondary : .primary)
        
        // Convert Unix timestamp to Date for display
        Text(Date(timeIntervalSince1970: todo.createdAt), style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      AdvancedTodoDemo()
    }
  }
}
