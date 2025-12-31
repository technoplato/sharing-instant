import SharingInstant
import SwiftUI

// #region agent log
private func debugLog(location: String, message: String, data: [String: Any], hypothesisId: String) {
  let payload: [String: Any] = [
    "location": location,
    "message": message,
    "data": data,
    "timestamp": Date().timeIntervalSince1970 * 1000,
    "sessionId": "debug-session",
    "hypothesisId": hypothesisId
  ]
  guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
  var request = URLRequest(url: URL(string: "http://127.0.0.1:7243/ingest/b61a72ba-9985-415b-9c60-d4184ed05385")!)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = jsonData
  let task = URLSession.shared.dataTask(with: request) { _, _, _ in }
  task.resume()
}
// #endregion

struct MicroblogDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows **entity links** (relationships) in InstantDB:
    
    • **Profiles** have many **Posts** (one-to-many)
    • **Posts** have one **Author** (many-to-one, the reverse link)
    • Use `.with(\\.author)` to include linked entities in queries
    
    Two authors post to a shared feed. Each post shows its author's name, \
    demonstrating how links connect entities across the graph.
    
    **New**: Uses generated mutation methods like `createProfile()`, \
    `createPost()`, and `linkAuthor()` for type-safe operations!
    """
  let caseStudyTitle = "Microblog (Links)"
  
  var body: some View {
    MicroblogView()
  }
}

// MARK: - Main View

private struct MicroblogView: View {
  // Query posts with their linked author
  @Shared(.instantSync(Schema.posts.with(\.author).orderBy(\.createdAt, .desc)))
  private var posts: IdentifiedArrayOf<Post> = []
  
  // Query all profiles
  @Shared(.instantSync(Schema.profiles.orderBy(\.createdAt, .asc)))
  private var profiles: IdentifiedArrayOf<Profile> = []
  
  @State private var newPostContent = ""
  @State private var selectedAuthorId: String?
  @State private var toast: Toast?
  
  // Deterministic UUIDs so all clients share the same profiles
  // Generated from consistent namespace + name using UUID v5 style
  // Note: UUIDs are lowercased to match server response format
  private let aliceId = "00000000-0000-0000-0000-00000000a11c"
  private let bobId = "00000000-0000-0000-0000-0000000000b0"
  
  var body: some View {
    VStack(spacing: 0) {
      // Author selector at top
      authorSelector
      
      Divider()
      
      // Post composer
      postComposer
      
      Divider()
      
      // Feed with scroll-to-top support
      ScrollViewReader { scrollProxy in
        feedList(scrollProxy: scrollProxy)
      }
    }
    .toast($toast)
    .task {
      // #region agent log
      debugLog(location: "MicroblogDemo.task", message: "Task started - about to ensureProfilesExist", data: ["profilesCount": profiles.count, "profileIDs": profiles.map { $0.id }, "aliceId": aliceId, "bobId": bobId], hypothesisId: "H1")
      // #endregion
      await ensureProfilesExist()
    }
    .onChange(of: profiles.first?.id) { _, firstProfileId in
      // Auto-select the first author once profiles are loaded
      if selectedAuthorId == nil, let firstProfileId {
        selectedAuthorId = firstProfileId
      }
    }
  }
  
  // MARK: - Author Selector
  
  private var authorSelector: some View {
    VStack(spacing: 12) {
      Text("Select Author")
        .font(.caption)
        .foregroundStyle(.secondary)
      
      HStack(spacing: 16) {
        ForEach(profiles) { profile in
          AuthorButton(
            profile: profile,
            isSelected: selectedAuthorId == profile.id,
            postCount: posts.filter { $0.author?.id == profile.id }.count
          ) {
            selectedAuthorId = profile.id
          }
        }
        
        if profiles.isEmpty {
          Text("Loading profiles...")
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding()
    #if os(iOS) || os(tvOS)
    .background(Color(uiColor: .systemGroupedBackground))
    #else
    .background(Color(nsColor: .windowBackgroundColor))
    #endif
  }
  
  // MARK: - Post Composer
  
  private var postComposer: some View {
    HStack(spacing: 12) {
      if let authorId = selectedAuthorId,
         let author = profiles[id: authorId] {
        MicroblogAvatarView(name: author.displayName, color: colorForHandle(author.handle))
          .frame(width: 36, height: 36)
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 36, height: 36)
      }
      
      TextField("What's happening?", text: $newPostContent, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(3)
      
      Button(action: createPost) {
        Text("Post")
          .fontWeight(.semibold)
      }
      .buttonStyle(.borderedProminent)
      .disabled(newPostContent.trimmingCharacters(in: .whitespaces).isEmpty || selectedAuthorId == nil)
      
      Button(action: createFakePost) {
        Image(systemName: "wand.and.stars")
      }
      .disabled(selectedAuthorId == nil)
    }
    .padding()
  }
  
  // MARK: - Feed List
  
  private func feedList(scrollProxy: ScrollViewProxy) -> some View {
    List {
      if posts.isEmpty {
        ContentUnavailableView {
          Label("No Posts Yet", systemImage: "text.bubble")
        } description: {
          Text("Select an author and write the first post!")
        }
      } else {
        ForEach(posts) { post in
          PostRow(post: post)
            .id(post.id)
        }
        .onDelete(perform: deletePosts)
      }
    }
    .listStyle(.plain)
    .onChange(of: posts.first?.id) { _, newFirstId in
      // Scroll to top when a new post appears at the top
      if let newFirstId {
        withAnimation {
          scrollProxy.scrollTo(newFirstId, anchor: .top)
        }
      }
    }
  }
  
  // MARK: - Actions
  
  private func ensureProfilesExist() async {
    let now = Date().timeIntervalSince1970 * 1_000

    // #region agent log
    debugLog(location: "ensureProfilesExist.start", message: "Starting ensureProfilesExist", data: [
      "profilesCount": profiles.count,
      "profileIDs": profiles.map { $0.id },
      "aliceExists": profiles[id: aliceId] != nil,
      "bobExists": profiles[id: bobId] != nil,
      "aliceId": aliceId,
      "bobId": bobId
    ], hypothesisId: "H1")
    // #endregion

    // Create Alice if she doesn't exist using the generated createProfile method
    if profiles[id: aliceId] == nil {
      // #region agent log
      debugLog(location: "ensureProfilesExist.createAlice", message: "Creating Alice - she doesn't exist locally", data: ["aliceId": aliceId], hypothesisId: "H1")
      // #endregion
      $profiles.createProfile(
        id: aliceId,
        displayName: "Alice",
        handle: "alice",
        bio: "Swift enthusiast",
        createdAt: now
      )
    }
    
    // Create Bob if he doesn't exist
    if profiles[id: bobId] == nil {
      // #region agent log
      debugLog(location: "ensureProfilesExist.createBob", message: "Creating Bob - he doesn't exist locally", data: ["bobId": bobId, "profilesAfterAlice": profiles.map { $0.id }], hypothesisId: "H1")
      // #endregion
      $profiles.createProfile(
        id: bobId,
        displayName: "Bob",
        handle: "bob",
        bio: "InstantDB fan",
        createdAt: now + 1_000
      )
    } else {
      // #region agent log
      debugLog(location: "ensureProfilesExist.bobExists", message: "Bob already exists - NOT creating", data: ["bobId": bobId, "profileIDs": profiles.map { $0.id }], hypothesisId: "H1")
      // #endregion
    }
    
    // #region agent log
    debugLog(location: "ensureProfilesExist.end", message: "Finished ensureProfilesExist", data: [
      "profilesCount": profiles.count,
      "profileIDs": profiles.map { $0.id }
    ], hypothesisId: "H1")
    // #endregion
    
    // Select Alice by default
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
    guard !content.isEmpty else {
      return
    }
    
    let postId = UUID().uuidString.lowercased()
    let now = Date().timeIntervalSince1970 * 1_000
    
    // Create post using the generated createPost method with callbacks
    $posts.createPost(
      id: postId,
      content: content,
      createdAt: now,
      likesCount: 0,
      callbacks: .init(
        onSuccess: { _ in
          withAnimation {
            toast = Toast(type: .success, message: "Posted!")
          }
        },
        onError: { error in
          withAnimation {
            toast = Toast(type: .error, message: "Failed: \(error.localizedDescription)")
          }
        }
      )
    )
    
    // Link the post to its author using the generated linkAuthor method
    $posts.linkAuthor(postId, to: author)
    
    newPostContent = ""
  }
  
  private func createFakePost() {
    guard let authorId = selectedAuthorId,
          let author = profiles[id: authorId] else {
      return
    }
    
    let fakePosts = [
      "Just shipped a new feature! 🚀",
      "SwiftUI is amazing once you get the hang of it",
      "Real-time sync is the future of apps",
      "Coffee ☕️ + Code = Happiness",
      "InstantDB makes building apps so much easier",
      "Who else loves @Shared property wrappers?",
      "Finally fixed that bug that's been haunting me",
      "Working on something cool... stay tuned 👀",
      "Hot take: declarative UI is better than imperative",
      "Links in InstantDB are chef's kiss 🤌",
    ]
    
    let randomContent = fakePosts.randomElement() ?? "Hello world!"
    let postId = UUID().uuidString.lowercased()
    let now = Date().timeIntervalSince1970 * 1_000
    
    // #region agent log
    debugLog(location: "createFakePost.beforeCreate", message: "About to create post", data: [
      "postId": postId,
      "authorId": authorId,
      "authorNamespace": Profile.namespace,
      "postNamespace": Post.namespace
    ], hypothesisId: "H2")
    // #endregion
    
    // Create post using the generated createPost method
    $posts.createPost(
      id: postId,
      content: randomContent,
      createdAt: now,
      likesCount: 0
    )
    
    // #region agent log
    debugLog(location: "createFakePost.beforeLink", message: "About to link post to author", data: [
      "postId": postId,
      "authorId": author.id,
      "linkLabel": "author"
    ], hypothesisId: "H2")
    // #endregion
    
    // Link the post to its author
    $posts.linkAuthor(postId, to: author)
  }
  
  private func deletePosts(at offsets: IndexSet) {
    // Delete posts using the generated deletePost method with callbacks
    for index in offsets {
      let post = posts[index]
      $posts.deletePost(
        post,
        callbacks: .init(
          onSuccess: { _ in
            withAnimation {
              toast = Toast(type: .success, message: "Post deleted!")
            }
          },
          onError: { error in
            withAnimation {
              toast = Toast(type: .error, message: "Failed: \(error.localizedDescription)")
            }
          }
        )
      )
    }
  }
  
  private func colorForHandle(_ handle: String) -> Color {
    handle == "alice" ? .purple : .blue
  }
}

// MARK: - Author Button

private struct AuthorButton: View {
  let profile: Profile
  let isSelected: Bool
  let postCount: Int
  let action: () -> Void
  
  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        MicroblogAvatarView(
          name: profile.displayName,
          color: profile.handle == "alice" ? .purple : .blue
        )
        .frame(width: 50, height: 50)
        .overlay {
          if isSelected {
            Circle()
              .strokeBorder(Color.accentColor, lineWidth: 3)
          }
        }
        
        VStack(spacing: 2) {
          Text(profile.displayName)
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
          
          Text("@\(profile.handle)")
            .font(.caption2)
            .foregroundStyle(.secondary)
          
          Text("\(postCount) posts")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Post Row

private struct PostRow: View {
  let post: Post
  
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // Author avatar (from linked entity!)
      if let author = post.author {
        MicroblogAvatarView(
          name: author.displayName,
          color: author.handle == "alice" ? .purple : .blue
        )
        .frame(width: 40, height: 40)
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 40, height: 40)
      }
      
      VStack(alignment: .leading, spacing: 4) {
        // Author info (from linked entity!)
        HStack(spacing: 4) {
          if let author = post.author {
            Text(author.displayName)
              .fontWeight(.semibold)
            Text("@\(author.handle)")
              .foregroundStyle(.secondary)
          } else {
            Text("Unknown Author")
              .foregroundStyle(.secondary)
          }
          
          Text("·")
            .foregroundStyle(.secondary)
          
          Text(InstantEpochTimestamp.date(from: post.createdAt), style: .relative)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        
        // Post content
        Text(post.content)
          .font(.body)
      }
    }
    .padding(.vertical, 8)
  }
}

// MARK: - Microblog Avatar View

private struct MicroblogAvatarView: View {
  let name: String
  let color: Color
  
  var body: some View {
    Circle()
      .fill(color.gradient)
      .overlay {
        Text(String(name.prefix(1)))
          .font(.headline)
          .fontWeight(.bold)
          .foregroundStyle(.white)
      }
  }
}

#Preview {
  NavigationStack {
    CaseStudyView {
      MicroblogDemo()
    }
  }
}
