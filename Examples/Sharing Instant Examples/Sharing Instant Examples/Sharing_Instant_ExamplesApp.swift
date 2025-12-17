//
//  Sharing_Instant_ExamplesApp.swift
//  Sharing Instant Examples
//
//  Created by Michael Lustig on 12/17/25.
//

import Dependencies
import SharingInstant
import SwiftUI

@main
struct Sharing_Instant_ExamplesApp: App {
  
  init() {
    prepareDependencies {
      // Use the test InstantDB app
      $0.instantAppID = "b9319949-2f2d-410b-8f8a-6990177c1d44"
    }
  }
  
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
