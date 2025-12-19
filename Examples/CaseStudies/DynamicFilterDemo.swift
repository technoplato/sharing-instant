import SharingInstant
import SwiftUI

struct DynamicFilterDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows how to filter and search data in real-time using \
    the type-safe `@Shared(Schema.todos)` API.
    
    **Features demonstrated:**
    • Search todos by title (client-side filtering)
    • Filter by completion status (All, Active, Completed)
    • Toggle todo completion with optimistic updates
    • Real-time sync - changes appear across all clients
    
    This demo shares the same `todos` collection as the Sync Demo. \
    Add todos there and filter them here!
    """
  let caseStudyTitle = "Dynamic Filtering"
  
  var body: some View {
    DynamicFilterView()
  }
}

/// Filter options for todos
enum TodoFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case active = "Active"
  case completed = "Completed"
  
  var id: String { rawValue }
}

private struct DynamicFilterView: View {
  /// Type-safe sync using EntityKey.
  ///
  /// Uses `Schema.todos` which is defined in SwiftUISyncDemo.swift.
  /// Once the schema generator is fixed, this will come from the generated Schema.swift.
  @Shared(Schema.todos.orderBy(\.createdAt, .desc))
  private var todos: IdentifiedArrayOf<Todo> = []
  
  @State private var searchText = ""
  @State private var selectedFilter: TodoFilter = .all
  
  /// Filtered todos based on search text and filter selection
  private var filteredTodos: [Todo] {
    var result = Array(todos)
    
    // Apply search filter
    if !searchText.isEmpty {
      result = result.filter { todo in
        todo.title.localizedCaseInsensitiveContains(searchText)
      }
    }
    
    // Apply completion filter
    switch selectedFilter {
    case .all:
      break
    case .active:
      result = result.filter { !$0.done }
    case .completed:
      result = result.filter { $0.done }
    }
    
    return result
  }
  
  /// Stats for the filter badges
  private var activeCount: Int {
    todos.filter { !$0.done }.count
  }
  
  private var completedCount: Int {
    todos.filter { $0.done }.count
  }
  
  var body: some View {
    List {
      // Stats section
      Section {
        HStack(spacing: 16) {
          StatBadge(title: "Total", count: todos.count, color: .blue)
          StatBadge(title: "Active", count: activeCount, color: .orange)
          StatBadge(title: "Done", count: completedCount, color: .green)
        }
        .frame(maxWidth: .infinity)
      }
      
      // Filter picker
      Section {
        Picker("Filter", selection: $selectedFilter) {
          ForEach(TodoFilter.allCases) { filter in
            Text(filter.rawValue).tag(filter)
          }
        }
        .pickerStyle(.segmented)
      }
      
      // Filtered results
      Section("Results (\(filteredTodos.count))") {
        if filteredTodos.isEmpty {
          ContentUnavailableView {
            Label(emptyStateTitle, systemImage: emptyStateIcon)
          } description: {
            Text(emptyStateDescription)
          }
        } else {
          ForEach(filteredTodos) { todo in
            TodoFilterRow(
              todo: todo,
              onToggle: { toggleTodo(todo) }
            )
          }
        }
      }
    }
    .searchable(text: $searchText, prompt: "Search todos...")
    .animation(.default, value: filteredTodos.count)
  }
  
  private var emptyStateTitle: String {
    if !searchText.isEmpty {
      return "No Results"
    }
    switch selectedFilter {
    case .all: return "No Todos"
    case .active: return "No Active Todos"
    case .completed: return "No Completed Todos"
    }
  }
  
  private var emptyStateIcon: String {
    if !searchText.isEmpty {
      return "magnifyingglass"
    }
    switch selectedFilter {
    case .all: return "checklist"
    case .active: return "circle"
    case .completed: return "checkmark.circle"
    }
  }
  
  private var emptyStateDescription: String {
    if !searchText.isEmpty {
      return "No todos match '\(searchText)'"
    }
    switch selectedFilter {
    case .all: return "Add some todos in the Sync Demo"
    case .active: return "All todos are completed!"
    case .completed: return "Complete some todos to see them here"
    }
  }
  
  private func toggleTodo(_ todo: Todo) {
    $todos.withLock { todos in
      if let index = todos.firstIndex(where: { $0.id == todo.id }) {
        todos[index].done.toggle()
      }
    }
  }
}

private struct StatBadge: View {
  let title: String
  let count: Int
  let color: Color
  
  var body: some View {
    VStack(spacing: 4) {
      Text("\(count)")
        .font(.title2)
        .bold()
        .foregroundStyle(color)
        .contentTransition(.numericText(value: Double(count)))
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct TodoFilterRow: View {
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
        
        Text(todo.createdAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      DynamicFilterDemo()
    }
  }
}
