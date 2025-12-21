import SharingInstant
import SwiftUI

struct MicroblogDemo: SwiftUICaseStudy {
  let readMe = """
    This demo shows **entity links** (relationships) in InstantDB:
    
    • **Profiles** have many **Posts** (one-to-many)
    • **Posts** have one **Author** (many-to-one, the reverse link)
    • Use `.with(\\.author)` to include linked entities in queries
    
    Two authors post to a shared feed. Each post shows its author's name, \
    demonstrating how links connect entities across the graph.
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
  
  // Deterministic UUIDs so all clients share the same profiles
  // Generated from consistent namespace + name using UUID v5 style
  private let aliceId = "00000000-0000-0000-0000-00000000A11C"
  private let bobId = "00000000-0000-0000-0000-0000000000B0"
  
  var body: some View {
    VStack(spacing: 0) {
      // Author selector at top
      authorSelector
      
      Divider()
      
      // Post composer
      postComposer
      
      Divider()
      
      // Feed
      feedList
    }
    .task {
      await ensureProfilesExist()
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
  
  private var feedList: some View {
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
        }
        .onDelete(perform: deletePosts)
      }
    }
    .listStyle(.plain)
  }
  
  // MARK: - Actions
  
  private func ensureProfilesExist() async {
    print("[MicroblogDemo] 🔄 ensureProfilesExist() called")
    print("[MicroblogDemo]   Current profiles count: \(profiles.count)")
    print("[MicroblogDemo]   Alice exists: \(profiles[id: aliceId] != nil)")
    print("[MicroblogDemo]   Bob exists: \(profiles[id: bobId] != nil)")
    
    // Create Alice if she doesn't exist
    if profiles[id: aliceId] == nil {
      print("[MicroblogDemo] 👤 Creating Alice profile with id: \(aliceId)")
      let alice = Profile(
        id: aliceId,
        displayName: "Alice",
        handle: "alice",
        bio: "Swift enthusiast",
        createdAt: Date().timeIntervalSince1970
      )
      _ = $profiles.withLock { $0.append(alice) }
      print("[MicroblogDemo] ✅ Alice profile created")
    }
    
    // Create Bob if he doesn't exist
    if profiles[id: bobId] == nil {
      print("[MicroblogDemo] 👤 Creating Bob profile with id: \(bobId)")
      let bob = Profile(
        id: bobId,
        displayName: "Bob",
        handle: "bob",
        bio: "InstantDB fan",
        createdAt: Date().timeIntervalSince1970 + 1
      )
      _ = $profiles.withLock { $0.append(bob) }
      print("[MicroblogDemo] ✅ Bob profile created")
    }
    
    // Select Alice by default
    if selectedAuthorId == nil {
      selectedAuthorId = aliceId
      print("[MicroblogDemo] 📌 Selected Alice as default author")
    }
    
    print("[MicroblogDemo] 🔄 ensureProfilesExist() completed, profiles count: \(profiles.count)")
  }
  
  private func createPost() {
    print("[MicroblogDemo] 📝 createPost() called")
    print("[MicroblogDemo]   Selected author ID: \(selectedAuthorId ?? "nil")")
    
    guard let authorId = selectedAuthorId,
          let author = profiles[id: authorId] else {
      print("[MicroblogDemo] ⚠️ createPost() - No author selected or author not found")
      return
    }
    
    print("[MicroblogDemo]   Author: \(author.displayName) (@\(author.handle))")
    
    let content = newPostContent.trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else {
      print("[MicroblogDemo] ⚠️ createPost() - Content is empty")
      return
    }
    
    print("[MicroblogDemo]   Content: \"\(content)\"")
    
    // Create post with linked author
    let post = Post(
      content: content,
      createdAt: Date().timeIntervalSince1970,
      likesCount: 0,
      // The author link - this connects the post to its profile
      author: author
    )
    
    print("[MicroblogDemo] 📤 Creating post with ID: \(post.id)")
    print("[MicroblogDemo]   Post author link -> Profile ID: \(author.id)")
    
    _ = $posts.withLock { $0.insert(post, at: 0) }
    newPostContent = ""
    
    print("[MicroblogDemo] ✅ Post created and added to local state")
    print("[MicroblogDemo]   Total posts count: \(posts.count)")
  }
  
  private func createFakePost() {
    print("[MicroblogDemo] 🎲 createFakePost() called")
    print("[MicroblogDemo]   Selected author ID: \(selectedAuthorId ?? "nil")")
    
    guard let authorId = selectedAuthorId,
          let author = profiles[id: authorId] else {
      print("[MicroblogDemo] ⚠️ createFakePost() - No author selected or author not found")
      return
    }
    
    print("[MicroblogDemo]   Author: \(author.displayName) (@\(author.handle))")
    
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
    print("[MicroblogDemo]   Random content: \"\(randomContent)\"")
    
    let post = Post(
      content: randomContent,
      createdAt: Date().timeIntervalSince1970,
      likesCount: 0,
      author: author
    )
    
    print("[MicroblogDemo] 📤 Creating fake post with ID: \(post.id)")
    print("[MicroblogDemo]   Post author link -> Profile ID: \(author.id)")
    
    _ = $posts.withLock { $0.insert(post, at: 0) }
    
    print("[MicroblogDemo] ✅ Fake post created and added to local state")
    print("[MicroblogDemo]   Total posts count: \(posts.count)")
  }
  
  private func deletePosts(at offsets: IndexSet) {
    print("[MicroblogDemo] 🗑️ deletePosts() called for offsets: \(offsets)")
    let postsToDelete = offsets.map { posts[$0] }
    for post in postsToDelete {
      print("[MicroblogDemo]   Deleting post ID: \(post.id), content: \"\(post.content.prefix(30))...\"")
    }
    
    _ = $posts.withLock { posts in
      posts.remove(atOffsets: offsets)
    }
    
    print("[MicroblogDemo] ✅ Posts deleted, remaining count: \(posts.count)")
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
          
          Text(Date(timeIntervalSince1970: post.createdAt), style: .relative)
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

