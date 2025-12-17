import Dependencies
import SharingInstant
import SwiftUI

func prepareInstant(_ values: inout DependencyValues) {
  // Use the test InstantDB app from the plan
  values.defaultInstant = InstantClient(appID: "b9319949-2f2d-410b-8f8a-6990177c1d44")
}

@main
struct CaseStudiesApp: App {
  
  init() {
    prepareDependencies(prepareInstant(_:))
  }
  
  var body: some Scene {
    WindowGroup {
      NavigationStack {
        Form {
          Section("Query Examples") {
            NavigationLink("Query Demo") {
              CaseStudyView {
                SwiftUIQueryDemo()
              }
            }
          }
          
          Section("Sync Examples") {
            NavigationLink("Sync Demo") {
              CaseStudyView {
                SwiftUISyncDemo()
              }
            }
          }
          
          Section("Advanced Examples") {
            NavigationLink("Observable Model Demo") {
              CaseStudyView {
                ObservableModelDemo()
              }
            }
          }
        }
        .navigationTitle("SharingInstant")
      }
    }
  }
}

