import SharingInstant
import SwiftUI

struct SwiftUISyncDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows how to use the `@Shared` annotation with `.instantSync` \
    for bidirectional synchronization with InstantDB.
    
    Changes you make are applied optimistically—they show immediately in the UI \
    while being sent to the server in the background. If the server rejects \
    a change, it will be rolled back.
    
    Try adding, editing, and deleting todos. Open the app on multiple devices \
    or simulators to see real-time sync in action!
    """
  let caseStudyTitle = "Sync Demo"
  
  var body: some View {
    TodoListView()
      .onAppear {
        InstantLogger.viewAppeared("SwiftUISyncDemo")
      }
      .onDisappear {
        InstantLogger.viewDisappeared("SwiftUISyncDemo")
      }
  }
}

/// The main todo list view with shared state
private struct TodoListView: View {
  @Shared(
    .instantSync(
      configuration: SharingInstantSync.CollectionConfiguration<Todo>(
        namespace: "todos",
        orderBy: OrderBy.desc("createdAt")
      )
    )
  )
  private var todos: IdentifiedArrayOf<Todo> = []
  
  @State private var newTodoTitle = ""
  @FocusState private var isInputFocused: Bool
  
  /// Track previous count to detect data received from server
  @State private var previousTodoCount: Int = 0
  
  var body: some View {
    List {
      Section {
        HStack {
          Text("Total Todos")
          Spacer()
          Text("\(todos.count)")
            .font(.title2)
            .bold()
        }
      }
      
      Section("Add New Todo") {
        HStack {
          TextField("What needs to be done?", text: $newTodoTitle)
            .focused($isInputFocused)
            .onSubmit(addTodo)
          
          Button(action: addTodo) {
            Image(systemName: "plus.circle.fill")
              .font(.title2)
          }
          .disabled(newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      
      Section("Todos (Read-Only)") {
        if todos.isEmpty {
          ContentUnavailableView {
            Label("No Todos", systemImage: "checklist")
          } description: {
            Text("Add your first todo above!")
          }
        } else {
          ForEach(todos) { todo in
            TodoRowReadOnly(todo: todo)
          }
        }
      }
    }
    .onChange(of: todos.count) { oldCount, newCount in
      // Log when data is received from server (count changes without user action)
      if oldCount != previousTodoCount {
        InstantLogger.dataReceived(
          "Todos updated",
          count: newCount,
          details: ["previousCount": oldCount, "newCount": newCount]
        )
      }
      previousTodoCount = newCount
    }
    .onAppear {
      InstantLogger.info("TodoListView appeared", json: ["initialCount": todos.count])
      previousTodoCount = todos.count
    }
  }
  
  private func addTodo() {
    let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    
    let todo = Todo(title: title)
    
    // Log user action
    InstantLogger.userAction("Add todo", details: ["title": title, "id": todo.id])
    
    _ = $todos.withLock { todos in
      todos.insert(todo, at: 0)
    }
    
    newTodoTitle = ""
    isInputFocused = false
  }
}

/// A simple read-only todo row to avoid AttributeGraph cycles
private struct TodoRowReadOnly: View {
  let todo: Todo
  
  var body: some View {
    HStack {
      Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
        .font(.title2)
        .foregroundStyle(todo.done ? .green : .secondary)
      
      VStack(alignment: .leading, spacing: 4) {
        Text(todo.title)
          .strikethrough(todo.done)
        
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
      SwiftUISyncDemo()
    }
  }
}

