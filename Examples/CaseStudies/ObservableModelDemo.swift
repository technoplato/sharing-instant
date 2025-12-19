import Dependencies
import IdentifiedCollections
import Observation
import SharingInstant
import SwiftUI

struct ObservableModelDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows how to use SharingInstant with `@Observable` models.
    
    The `@ObservationIgnored @Shared` pattern allows you to use shared state \
    within an observable model while still getting automatic view updates.
    
    This is useful when you want to encapsulate your business logic in a \
    view model while still leveraging SharingInstant's real-time sync.
    """
  let caseStudyTitle = "Observable Model"
  
  @State private var model = TodoListModel()
  
  var body: some View {
    List {
      Section {
        HStack {
          Text("Todos")
          Spacer()
          Text("\(model.todos.count)")
            .font(.title2)
            .bold()
            .contentTransition(.numericText(value: Double(model.todos.count)))
        }
      }
      
      Section("Add New Todo") {
        HStack {
          TextField("What needs to be done?", text: $model.newTodoTitle)
            .onSubmit { model.addTodo() }
          
          Button(action: { model.addTodo() }) {
            Image(systemName: "plus.circle.fill")
              .font(.title2)
          }
          .disabled(model.newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      
      Section("Todos") {
        if model.todos.isEmpty {
          ContentUnavailableView {
            Label("No Todos", systemImage: "checklist")
          } description: {
            Text("Add your first todo above!")
          }
        } else {
          ForEach(model.todos) { todo in
            ObservableTodoRow(todo: todo, model: model)
          }
          .onDelete { offsets in
            model.deleteTodos(at: offsets)
          }
        }
      }
      
      Section("Statistics") {
        LabeledContent("Total", value: "\(model.totalCount)")
        LabeledContent("Completed", value: "\(model.completedCount)")
        LabeledContent("Remaining", value: "\(model.remainingCount)")
      }
    }
  }
}

@Observable
final class TodoListModel {
  @ObservationIgnored
  @Shared(Schema.todos.orderBy(\Todo.createdAt, .desc))
  var todos: IdentifiedArrayOf<Todo> = []
  
  var newTodoTitle = ""
  
  var totalCount: Int { todos.count }
  var completedCount: Int { todos.filter(\.done).count }
  var remainingCount: Int { todos.filter { !$0.done }.count }
  
  func addTodo() {
    let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return }
    
    // Generated Todo uses Double for createdAt (Unix timestamp)
    let todo = Todo(
      createdAt: Date().timeIntervalSince1970,
      done: false,
      title: title
    )
    _ = $todos.withLock { todos in
      todos.insert(todo, at: 0)
    }
    
    newTodoTitle = ""
  }
  
  func toggleTodo(_ todo: Todo) {
    _ = $todos.withLock { todos in
      if let index = todos.firstIndex(where: { $0.id == todo.id }) {
        todos[index].done.toggle()
      }
    }
  }
  
  func deleteTodos(at offsets: IndexSet) {
    _ = $todos.withLock { todos in
      todos.remove(atOffsets: offsets)
    }
  }
  
  func deleteTodo(_ todo: Todo) {
    _ = $todos.withLock { todos in
      todos.remove(id: todo.id)
    }
  }
}

private struct ObservableTodoRow: View {
  let todo: Todo
  let model: TodoListModel
  
  var body: some View {
    HStack {
      Button {
        model.toggleTodo(todo)
      } label: {
        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundStyle(todo.done ? .green : .secondary)
      }
      .buttonStyle(.plain)
      
      VStack(alignment: .leading, spacing: 4) {
        Text(todo.title)
          .strikethrough(todo.done)
        
        // Convert Unix timestamp to Date for display
        Text(Date(timeIntervalSince1970: todo.createdAt), style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    #if os(iOS)
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        model.deleteTodo(todo)
      } label: {
        Image(systemName: "trash")
      }
    }
    .swipeActions(edge: .leading) {
      Button {
        model.toggleTodo(todo)
      } label: {
        Image(systemName: todo.done ? "xmark.circle" : "checkmark.circle")
      }
      .tint(todo.done ? .orange : .green)
    }
    #endif
    .contextMenu {
      Button {
        model.toggleTodo(todo)
      } label: {
        Label(
          todo.done ? "Mark Incomplete" : "Mark Complete",
          systemImage: todo.done ? "xmark.circle" : "checkmark.circle"
        )
      }
      Button(role: .destructive) {
        model.deleteTodo(todo)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      ObservableModelDemo()
    }
  }
}
