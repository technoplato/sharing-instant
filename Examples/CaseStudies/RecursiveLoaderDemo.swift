import SwiftUI
import SharingInstant
import IdentifiedCollections

struct RecursiveLoaderDemo: SwiftUICaseStudy {
  let readMe = """
    This demo showcases Deep Recursive Queries in InstantDB.
    
    We are querying:
    `Profiles -> Posts -> Comments`
    
    This 3-level deep query is constructed using the fluent `.with` API:
    ```swift
    Schema.profiles
      .with(\\.posts) {
        $0.with(\\.comments)
      }
    ```
    
    The data is fetched efficiently in a single query, and updates at any level
    (e.g., adding a comment) will propagate automatically.
    """
  let caseStudyTitle = "Recursive Loader"

  // Query: All profiles -> their posts -> posts' replies
  @Shared(
    .instantSync(
      Schema.profiles
        .limit(10)
        .with(\.posts) {
          $0.limit(5).with(\.replies)
        }
    )
  )
  private var profiles: IdentifiedArrayOf<Profile> = []

  var body: some View {
    List {
      if profiles.isEmpty {
        ContentUnavailableView("No Profiles", systemImage: "person.slash")
      }

      ForEach(profiles) { profile in
        Section {
          ForEach(profile.posts ?? []) { post in
            VStack(alignment: .leading, spacing: 8) {
              Text(post.content)
                .font(.body)
              
              if let replies = post.replies, !replies.isEmpty {
                Divider()
                Text("Comments")
                  .font(.caption)
                  .fontWeight(.bold)
                  .foregroundStyle(.secondary)
                
                ForEach(replies) { comment in
                  HStack(alignment: .top) {
                    Image(systemName: "bubble.left.fill")
                      .font(.caption2)
                    Text(comment.text)
                      .font(.caption)
                  }
                  .foregroundStyle(.secondary)
                }
              }
            }
            .padding(.vertical, 4)
          }
        } header: {
          HStack {
            Text(profile.displayName)
            Spacer()
            // Verify link tree depth
            Text("\(profile.posts?.count ?? 0) Posts")
              .font(.caption)
          }
        }
      }
    }
    .navigationTitle("Recursive Loader")
    .toolbar {
      Button("Generate Data", action: generateData)
    }
  }

  private func generateData() {
    let profile = Profile(
      displayName: "User \(Int.random(in: 1...100))",
      handle: "@user\(Int.random(in: 1...100))",
      createdAt: Date().timeIntervalSince1970
    )
    
    // Create nested data
    let post = Post(
      content: "Recursive queries are powerful! 🚀",
      createdAt: Date().timeIntervalSince1970,
      likesCount: 0
    )
    
    let comment = Comment(
      text: "Totally agree! simple and effective.",
      createdAt: Date().timeIntervalSince1970
    )
    
    // Link them up
    // Note: We need to set relationships manually if our library doesn't link them automatically on read?
    // Actually, for saving, we construct the graph.
    var fullPost = post
    fullPost.replies = [comment]
    
    var fullProfile = profile
    fullProfile.posts = [fullPost]
    
    // Optimistic update
    $profiles.withLock {
      $0.append(fullProfile)
    }
  }
}
