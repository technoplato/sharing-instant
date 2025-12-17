import Dependencies
import IdentifiedCollections
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
  
  @Shared(
    .instantSync(
      configuration: .init(
        namespace: "todos",
        orderBy: .desc("createdAt"),
        animation: .default
      )
    )
  )
  private var todos: IdentifiedArrayOf<Todo> = []
  
  @State private var newTodoTitle = ""
  @FocusState private var isInputFocused: Bool
  
  @Dependency(\.defaultInstant) var instant
  
  var body: some View {
    List {
      Section {
        HStack {
          Text("Todos")
          Spacer()
          Text("\(todos.count)")
            .font(.title2)
            .bold()
            .contentTransition(.numericText(value: Double(todos.count)))
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
      
      Section("Todos") {
        if todos.isEmpty {
          ContentUnavailableView {
            Label("No Todos", systemImage: "checklist")
          } description: {
            Text("Add your first todo above!")
          }
        } else {
          ForEach(Binding($todos)) { $todo in
            TodoRow(todo: $todo)
          }
          .onDelete(perform: deleteTodos)
        }
      }
      
      if !todos.isEmpty {
        Section {
          Button("Clear Completed", role: .destructive) {
            $todos.withLock { todos in
              todos.removeAll { $0.done }
            }
          }
          .disabled(!todos.contains { $0.done })
        }
      }
    }
  }
  
  private func addTodo() {
    let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    
    let todo = Todo(title: title)
    $todos.withLock { todos in
      todos.insert(todo, at: 0)
    }
    
    newTodoTitle = ""
    isInputFocused = false
  }
  
  private func deleteTodos(at offsets: IndexSet) {
    $todos.withLock { todos in
      todos.remove(atOffsets: offsets)
    }
  }
}

private struct TodoRow: View {
  @Binding var todo: Todo
  
  var body: some View {
    HStack {
      Button {
        todo.done.toggle()
      } label: {
        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundStyle(todo.done ? .green : .secondary)
      }
      .buttonStyle(.plain)
      
      VStack(alignment: .leading, spacing: 4) {
        TextField("Todo title", text: $todo.title)
          .strikethrough(todo.done)
        
        Text(todo.createdAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions(edge: .leading) {
      Button {
        todo.done.toggle()
      } label: {
        Image(systemName: todo.done ? "xmark.circle" : "checkmark.circle")
      }
      .tint(todo.done ? .orange : .green)
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

