import Dependencies
import Foundation

private enum InstantReactorKey: DependencyKey {
  static let liveValue = Reactor(store: SharedTripleStore())
}

extension DependencyValues {
  public var instantReactor: Reactor {
    get { self[InstantReactorKey.self] }
    set { self[InstantReactorKey.self] = newValue }
  }
}
