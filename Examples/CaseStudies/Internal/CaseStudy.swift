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
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            isShowingReadMe = true
          } label: {
            Image(systemName: "info.circle")
          }
        }
      }
      .sheet(isPresented: $isShowingReadMe) {
        NavigationStack {
          ScrollView {
            Text(content.readMe)
              .padding()
          }
          .navigationTitle("About")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
              Button("Done") {
                isShowingReadMe = false
              }
            }
          }
        }
      }
  }
}

