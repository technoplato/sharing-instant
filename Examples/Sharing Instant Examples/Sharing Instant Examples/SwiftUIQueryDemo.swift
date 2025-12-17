//
//  SwiftUIQueryDemo.swift
//  Sharing Instant Examples
//

import Dependencies
import IdentifiedCollections
import SharingInstant
import SwiftUI

struct SwiftUIQueryDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows how to use the `@SharedReader` annotation with `.instantQuery` \
    to fetch read-only data from InstantDB.
    
    The query automatically subscribes to real-time updates, so when data changes \
    in the database, the view re-renders automatically.
    
    This is useful for displaying data that the user shouldn't modify directly, \
    like leaderboards, statistics, or reference data.
    
    The view demonstrates proper loading and error state handling using \
    `$todos.isLoading` and `$todos.loadError`.
    """
  let caseStudyTitle = "Query Demo"
  
  @SharedReader(
    .instantQuery(
      configuration: SharingInstantQuery.Configuration<Todo>(
        namespace: "todos",
        orderBy: OrderBy.desc("createdAt"),
        animation: Animation.default
      )
    )
  )
  private var todos: IdentifiedArrayOf<Todo> = []
  
  var body: some View {
    Group {
      // Show loading state
      if $todos.isLoading {
        ProgressView("Loading todos...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      // Show error state
      else if let loadError = $todos.loadError {
        ContentUnavailableView {
          Label("Failed to load", systemImage: "xmark.circle")
        } description: {
          Text(loadError.localizedDescription)
        } actions: {
          Button("Retry") {
            Task {
              try? await $todos.load()
            }
          }
          .buttonStyle(.borderedProminent)
        }
      }
      // Show content
      else {
        todoList
      }
    }
    .refreshable {
      try? await $todos.load()
    }
  }
  
  private var todoList: some View {
    List {
      Section {
        HStack {
          Text("Total Todos")
          Spacer()
          Text("\(todos.count)")
            .font(.title2)
            .bold()
            .contentTransition(.numericText(value: Double(todos.count)))
        }
      }
      
      Section("Todos (Read-Only)") {
        if todos.isEmpty {
          ContentUnavailableView {
            Label("No Todos", systemImage: "checklist")
          } description: {
            Text("Add some todos in the Sync Demo to see them here.")
          }
        } else {
          ForEach(todos) { todo in
            HStack {
              Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(todo.done ? .green : .secondary)
              Text(todo.title)
                .strikethrough(todo.done)
              Spacer()
              Text(todo.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      SwiftUIQueryDemo()
    }
  }
}

