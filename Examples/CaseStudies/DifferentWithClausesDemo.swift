import SharingInstant
import SwiftUI

/// # Different `.with()` Clauses Bug Demo
///
/// This case study demonstrates a potential bug where two features querying the same
/// entity type with DIFFERENT `.with()` clauses may not share optimistic updates correctly.
///
/// ## The Problem
///
/// In a real app like SpeechRecorderApp:
/// - **RecordingFeature** queries: `Schema.media.with(\.transcriptionRuns) { runs in runs.with(\.transcriptionSegments) }`
/// - **RecordingsListFeature** queries: `Schema.media.with(\.transcriptionRuns) { ... }.with(\.files)`
///
/// The difference is `.with(\.files)` - this causes them to have different `UniqueRequestKeyID` values,
/// which means they create **separate subscriptions** in the Reactor.
///
/// When RecordingFeature inserts a new media entity:
/// 1. ✅ The optimistic update is applied to RecordingFeature's subscription
/// 2. ❌ RecordingsListFeature's subscription may NOT see it (different key)
/// 3. ❌ When a server refresh arrives, it may overwrite with stale data
///
/// ## How This Demo Works
///
/// We simulate this with Posts:
/// - **PostComposerView**: Uses `Schema.posts.with(\.author)` - includes author link
/// - **PostFeedView**: Uses `Schema.posts.with(\.author).with(\.comments)` - includes author AND comments
///
/// These have DIFFERENT `.with()` clauses, so they have different `UniqueRequestKeyID` values.
///
/// ## Expected Behavior (TypeScript Client)
/// In the official TypeScript client, ALL queries share a centralized `pendingMutations` store.
/// When you insert via one query, ALL queries see the optimistic update immediately.
///
/// ## Actual Behavior (Swift SharingInstant)
/// Each subscription has its own `SubscriptionState` actor with its own `optimisticIDs`.
/// Optimistic updates may not propagate correctly across different query shapes.
///
/// ## To Reproduce
/// 1. Open this demo
/// 2. Create a new post using the composer
/// 3. Watch the feed - the post should appear immediately
/// 4. If the bug exists, the post may briefly appear then disappear, or not appear at all
struct DifferentWithClausesDemo: SwiftUICaseStudy {
  let readMe = """
    **Bug Reproduction: Different `.with()` Clauses**
    
    This demo shows a potential issue where two views querying the same entity \
    with DIFFERENT `.with()` clauses may not share optimistic updates.
    
    • **Composer** uses: `Schema.posts.with(\\.author)`
    • **Feed** uses: `Schema.posts.with(\\.author).with(\\.comments)`
    
    The different query shapes create separate subscriptions. When you create \
    a post via the Composer, the Feed may not see it immediately because \
    optimistic updates don't propagate across different subscription keys.
    
    **Watch for:**
    • Post appears in composer's count but not in feed
    • Post briefly appears then disappears from feed
    • Feed shows stale data after server refresh
    """
  let caseStudyTitle = "Different .with() Bug"
  
  var body: some View {
    DifferentWithClausesDemoView()
  }
}

// MARK: - Main Demo View

private struct DifferentWithClausesDemoView: View {
  var body: some View {
    VStack(spacing: 0) {
      // Composer uses Schema.posts.with(\.author) - SIMPLER query
      PostComposerView()
      
      Divider()
        .padding(.vertical, 8)
      
      // Feed uses Schema.posts.with(\.author).with(\.comments) - MORE COMPLEX query
      PostFeedView()
    }
    .padding()
  }
}

// MARK: - Post Composer (Simpler Query)

/// This view uses a SIMPLER query: `Schema.posts.with(\.author)`
/// It does NOT include `.with(\.comments)`
private struct PostComposerView: View {
  /// Query posts with author ONLY - no comments
  /// This creates a subscription with a specific UniqueRequestKeyID
  @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
  private var posts: IdentifiedArrayOf<Post> = []
  
  /// Query profiles for author selection
  @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .asc)))
  private var profiles: IdentifiedArrayOf<Profile> = []
  
  @State private var newPostContent = ""
  @State private var selectedAuthorId: String?
  
  // Deterministic UUIDs for demo profiles
  private let aliceId = "00000000-0000-0000-0000-00000000a11c"
  private let bobId = "00000000-0000-0000-0000-0000000000b0"
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header showing query type
      HStack {
        Image(systemName: "pencil.circle.fill")
          .foregroundStyle(.blue)
        Text("Composer View")
          .font(.headline)
        Spacer()
        Text("Query: .with(\\.author)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.blue.opacity(0.1))
          .cornerRadius(4)
      }
      
      // Post count from this subscription
      Text("Posts in this subscription: \(posts.count)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      
      // Author selector
      HStack(spacing: 12) {
        Text("Author:")
          .font(.subheadline)
        
        ForEach(profiles) { profile in
          Button {
            selectedAuthorId = profile.id
          } label: {
            Text(profile.displayName)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(selectedAuthorId == profile.id ? Color.blue : Color.gray.opacity(0.2))
              .foregroundStyle(selectedAuthorId == profile.id ? .white : .primary)
              .cornerRadius(8)
          }
          .buttonStyle(.plain)
        }
      }
      
      // Composer
      HStack {
        TextField("What's on your mind?", text: $newPostContent)
          .textFieldStyle(.roundedBorder)
        
        Button("Post") {
          createPost()
        }
        .buttonStyle(.borderedProminent)
        .disabled(newPostContent.isEmpty || selectedAuthorId == nil)
      }
    }
    .padding()
    .background(Color.blue.opacity(0.05))
    .cornerRadius(12)
    .task {
      await ensureProfilesExist()
    }
  }
  
  private func ensureProfilesExist() async {
    let now = Date().timeIntervalSince1970 * 1_000
    
    if profiles[id: aliceId] == nil {
      let alice = Profile(
        id: aliceId,
        displayName: "Alice",
        handle: "alice",
        bio: "Swift enthusiast",
        createdAt: now
      )
      _ = $profiles.withLock { $0.append(alice) }
    }
    
    if profiles[id: bobId] == nil {
      let bob = Profile(
        id: bobId,
        displayName: "Bob",
        handle: "bob",
        bio: "InstantDB fan",
        createdAt: now + 1_000
      )
      _ = $profiles.withLock { $0.append(bob) }
    }
    
    if selectedAuthorId == nil {
      selectedAuthorId = aliceId
    }
  }
  
  private func createPost() {
    guard let authorId = selectedAuthorId,
          let author = profiles[id: authorId] else {
      return
    }
    
    let content = newPostContent.trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return }
    
    let post = Post(
      content: content,
      createdAt: Date().timeIntervalSince1970 * 1_000,
      likesCount: 0,
      author: author
    )
    
    // Insert into THIS subscription (with author only)
    _ = $posts.withLock { $0.insert(post, at: 0) }
    newPostContent = ""
    
    print("🔵 [Composer] Created post: \(post.id)")
    print("🔵 [Composer] Posts count after insert: \(posts.count)")
  }
}

// MARK: - Post Feed (More Complex Query)

/// This view uses a MORE COMPLEX query: `Schema.posts.with(\.author).with(\.comments)`
/// It includes BOTH `.with(\.author)` AND `.with(\.comments)`
private struct PostFeedView: View {
  /// Query posts with author AND comments - more complex query
  /// This creates a DIFFERENT subscription with a DIFFERENT UniqueRequestKeyID
  @Shared(.instantSync(Schema.posts.with(\.author).with(\.comments).orderBy(\.createdAt, .desc)))
  private var posts: IdentifiedArrayOf<Post> = []
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header showing query type
      HStack {
        Image(systemName: "list.bullet.circle.fill")
          .foregroundStyle(.green)
        Text("Feed View")
          .font(.headline)
        Spacer()
        Text("Query: .with(\\.author).with(\\.comments)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.green.opacity(0.1))
          .cornerRadius(4)
      }
      
      // Post count from this subscription
      Text("Posts in this subscription: \(posts.count)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      
      // Post list
      if posts.isEmpty {
        ContentUnavailableView {
          Label("No Posts", systemImage: "text.bubble")
        } description: {
          Text("Create a post using the composer above")
        }
        .frame(minHeight: 200)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(posts) { post in
              PostRowView(post: post)
            }
          }
        }
        .frame(minHeight: 200)
      }
    }
    .padding()
    .background(Color.green.opacity(0.05))
    .cornerRadius(12)
    .onChange(of: posts.count) { oldCount, newCount in
      print("🟢 [Feed] Posts count changed: \(oldCount) -> \(newCount)")
      print("🟢 [Feed] Post IDs: \(posts.map { $0.id })")
    }
  }
}

// MARK: - Post Row

private struct PostRowView: View {
  let post: Post
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Author info
      HStack {
        Circle()
          .fill(post.author?.handle == "alice" ? Color.purple : Color.blue)
          .frame(width: 32, height: 32)
          .overlay {
            Text(String(post.author?.displayName.prefix(1) ?? "?"))
              .font(.caption)
              .fontWeight(.bold)
              .foregroundStyle(.white)
          }
        
        VStack(alignment: .leading) {
          Text(post.author?.displayName ?? "Unknown")
            .font(.subheadline)
            .fontWeight(.semibold)
          Text("@\(post.author?.handle ?? "unknown")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        Spacer()
        
        // Show comment count if available
        if let comments = post.comments {
          Label("\(comments.count)", systemImage: "bubble.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      // Content
      Text(post.content)
        .font(.body)
      
      // ID for debugging
      Text("ID: \(post.id.prefix(8))...")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding()
    .background(Color.white)
    .cornerRadius(8)
    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      DifferentWithClausesDemo()
    }
  }
}
