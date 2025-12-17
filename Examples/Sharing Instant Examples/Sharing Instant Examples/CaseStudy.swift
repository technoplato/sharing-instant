//
//  CaseStudy.swift
//  Sharing Instant Examples
//

import SwiftUI

/// A protocol for case study views that provide documentation.
protocol SwiftUICaseStudy: View {
  /// A description of what this case study demonstrates.
  var readMe: String { get }
  
  /// The title of this case study.
  var caseStudyTitle: String { get }
}

/// A wrapper view that displays a case study with its documentation.
struct CaseStudyView<Content: SwiftUICaseStudy>: View {
  let content: Content
  @State private var isShowingReadMe = false
  
  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }
  
  var body: some View {
    content
      .navigationTitle(content.caseStudyTitle)
      .toolbar {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
          infoButton
        }
        #else
        ToolbarItem(placement: .automatic) {
          infoButton
        }
        #endif
      }
      .sheet(isPresented: $isShowingReadMe) {
        readMeSheet
      }
  }
  
  private var infoButton: some View {
    Button {
      isShowingReadMe = true
    } label: {
      Image(systemName: "info.circle")
    }
  }
  
  private var readMeSheet: some View {
    NavigationStack {
      ScrollView {
        Text(content.readMe)
          .padding()
      }
      .navigationTitle("About")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") {
            isShowingReadMe = false
          }
        }
        #else
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            isShowingReadMe = false
          }
        }
        #endif
      }
    }
    #if os(macOS)
    .frame(minWidth: 400, minHeight: 300)
    #endif
  }
}


