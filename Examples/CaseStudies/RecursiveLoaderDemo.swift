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

    **Try it:** Tap a post to add a comment and see the 3-level sync in action!
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

  @State private var showingCommentSheet = false
  @State private var selectedPostId: String?
  @State private var newCommentText = ""

  var body: some View {
    List {
      if profiles.isEmpty {
        ContentUnavailableView("No Profiles", systemImage: "person.slash")
      }

      ForEach(profiles) { profile in
        Section {
          ForEach(profile.posts ?? []) { post in
            PostRowView(
              post: post,
              onAddComment: {
                selectedPostId = post.id
                newCommentText = ""
                showingCommentSheet = true
              }
            )
          }
        } header: {
          HStack {
            Text(profile.displayName)
            Spacer()
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
    .sheet(isPresented: $showingCommentSheet) {
      AddCommentSheet(
        commentText: $newCommentText,
        onSubmit: addComment,
        onCancel: { showingCommentSheet = false }
      )
      .presentationDetents([.height(200)])
    }
  }

  private func addComment() {
    guard let postId = selectedPostId, !newCommentText.isEmpty else { return }

    let now = Date().timeIntervalSince1970 * 1_000
    let commentId = UUID().uuidString.lowercased()

    // Create comment
    $comments.createComment(
      id: commentId,
      text: newCommentText,
      createdAt: now
    )

    // Link comment to post
    $posts.linkComments(postId, to: Comment(id: commentId, text: "", createdAt: now))

    showingCommentSheet = false
    selectedPostId = nil
    newCommentText = ""
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
      content: "Recursive queries are powerful!",
      createdAt: now
    )

    // Link post to profile
    $profiles.linkPosts(profileId, to: Post(id: postId, content: "", createdAt: now))

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

// MARK: - Helper Views

private struct PostRowView: View {
  let post: Post
  let onAddComment: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(post.content)
        .font(.body)

      if let comments = post.comments, !comments.isEmpty {
        Divider()
        Text("Comments (\(comments.count))")
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

      Button(action: onAddComment) {
        Label("Add Comment", systemImage: "plus.bubble")
          .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(.vertical, 4)
  }
}

private struct AddCommentSheet: View {
  @Binding var commentText: String
  let onSubmit: () -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        TextField("Write a comment...", text: $commentText, axis: .vertical)
          .lineLimit(3...6)
      }
      .navigationTitle("Add Comment")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Post", action: onSubmit)
            .disabled(commentText.isEmpty)
        }
      }
    }
  }
}
