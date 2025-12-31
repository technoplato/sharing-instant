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
          $0.limit(5).with(\.comments)
        }
    )
  )
  private var profiles: IdentifiedArrayOf<Profile> = []
  
  // Separate subscriptions for creating entities
  @Shared(.instantSync(Schema.posts)) private var posts: IdentifiedArrayOf<Post> = []
  @Shared(.instantSync(Schema.comments)) private var comments: IdentifiedArrayOf<Comment> = []

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
              
              if let comments = post.comments, !comments.isEmpty {
                Divider()
                Text("Comments")
                  .font(.caption)
                  .fontWeight(.bold)
                  .foregroundStyle(.secondary)
                
                ForEach(comments) { comment in
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
    let now = Date().timeIntervalSince1970 * 1_000
    let profileId = UUID().uuidString.lowercased()
    let postId = UUID().uuidString.lowercased()
    let commentId = UUID().uuidString.lowercased()
    
    // Create profile using generated mutation
    $profiles.createProfile(
      id: profileId,
      displayName: "User \(Int.random(in: 1...100))",
      handle: "@user\(Int.random(in: 1...100))",
      createdAt: now
    )
    
    // Create post using generated mutation (via posts subscription)
    $posts.createPost(
      id: postId,
      content: "Recursive queries are powerful! 🚀",
      createdAt: now,
      likesCount: 0
    )
    
    // Link post to profile
    $profiles.linkPosts(profileId, to: Post(id: postId, content: "", createdAt: now, likesCount: 0))
    
    // Create comment using generated mutation (via comments subscription)
    $comments.createComment(
      id: commentId,
      text: "Totally agree! Simple and effective.",
      createdAt: now
    )
    
    // Link comment to post
    $posts.linkComments(postId, to: Comment(id: commentId, text: "", createdAt: now))
  }
}
