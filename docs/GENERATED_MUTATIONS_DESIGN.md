# Generated Mutations Design

## Overview

The schema generator can create **complete type-safe mutation APIs** for each entity:
- **Create** with typed parameters (not just raw entity)
- **Update** with field-specific methods
- **Delete** with type safety
- **Link/Unlink** with no string literals

This eliminates string literals entirely and provides full autocomplete support.

## Current Generic API (Runtime)

```swift
@Shared(Schema.posts.with(\.author)) var posts: [Post]

// Create - requires constructing the full entity
try await $posts.create(Post(id: UUID().uuidString, content: "Hello", createdAt: Date().timeIntervalSince1970, likesCount: 0))

// Update - closure-based, no field validation
try await $posts.update(id: post.id) { $0.content = "Updated" }

// Delete
try await $posts.delete(id: post.id)

// Link - requires string literals for label and namespace
try await $posts.link(post.id, "author", to: profile.id, namespace: "profiles")
```

## Proposed Generated API

The schema generator would output a `Mutations.swift` file with **complete
type-safe mutations** for each entity:

```swift
// GENERATED: Mutations.swift

import Foundation
import SharingInstant
import IdentifiedCollections

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Post Mutations
// ═══════════════════════════════════════════════════════════════════════════════

extension Shared where Value: RangeReplaceableCollection, Value.Element == Post {
    
    // MARK: - Create
    
    /// Create a new post.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await $posts.createPost(content: "Hello world!")
    /// ```
    ///
    /// - Parameters:
    ///   - id: The entity ID (defaults to new UUID)
    ///   - content: The post content
    ///   - imageUrl: Optional image URL
    ///   - createdAt: Creation timestamp (defaults to now)
    ///   - likesCount: Initial likes count (defaults to 0)
    /// - Returns: The created post
    @MainActor
    @discardableResult
    func createPost(
        id: String = UUID().uuidString.lowercased(),
        content: String,
        imageUrl: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        likesCount: Double = 0
    ) async throws -> Post {
        let post = Post(
            id: id,
            content: content,
            imageUrl: imageUrl,
            createdAt: createdAt,
            likesCount: likesCount
        )
        try await create(post)
        return post
    }
    
    /// Create a new post with an author.
    ///
    /// This is a convenience method that creates the post and links it to
    /// an author in a single operation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let post = try await $posts.createPost(
    ///     content: "Hello world!",
    ///     author: currentProfile
    /// )
    /// ```
    @MainActor
    @discardableResult
    func createPost(
        id: String = UUID().uuidString.lowercased(),
        content: String,
        imageUrl: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        likesCount: Double = 0,
        author: Profile
    ) async throws -> Post {
        let post = try await createPost(
            id: id,
            content: content,
            imageUrl: imageUrl,
            createdAt: createdAt,
            likesCount: likesCount
        )
        try await linkAuthor(post.id, to: author)
        return post
    }
    
    // MARK: - Update
    
    /// Update a post's content.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await $posts.updateContent(post.id, to: "New content")
    /// ```
    @MainActor
    func updateContent(_ postId: String, to content: String) async throws {
        try await update(id: postId) { $0.content = content }
    }
    
    /// Update a post's image URL.
    @MainActor
    func updateImageUrl(_ postId: String, to imageUrl: String?) async throws {
        try await update(id: postId) { $0.imageUrl = imageUrl }
    }
    
    /// Update a post's likes count.
    @MainActor
    func updateLikesCount(_ postId: String, to likesCount: Double) async throws {
        try await update(id: postId) { $0.likesCount = likesCount }
    }
    
    /// Increment a post's likes count.
    @MainActor
    func incrementLikes(_ postId: String) async throws {
        try await update(id: postId) { $0.likesCount += 1 }
    }
    
    /// Decrement a post's likes count.
    @MainActor
    func decrementLikes(_ postId: String) async throws {
        try await update(id: postId) { $0.likesCount = max(0, $0.likesCount - 1) }
    }
    
    // MARK: - Delete
    
    /// Delete a post by ID.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await $posts.deletePost(post.id)
    /// ```
    @MainActor
    func deletePost(_ postId: String) async throws {
        try await delete(id: postId)
    }
    
    /// Delete a post.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await $posts.deletePost(post)
    /// ```
    @MainActor
    func deletePost(_ post: Post) async throws {
        try await delete(id: post.id)
    }
    
    // MARK: - Link: Author (Profile)
    
    /// Link a post to its author.
    ///
    /// Uses the `profilePosts` relationship defined in your schema.
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await $posts.linkAuthor(post.id, to: profile)
    /// ```
    @MainActor
    func linkAuthor(_ postId: String, to profile: Profile) async throws {
        try await link(postId, "author", to: profile.id, namespace: "profiles")
    }
    
    /// Unlink a post from its author.
    @MainActor
    func unlinkAuthor(_ postId: String, from profile: Profile) async throws {
        try await unlink(postId, "author", from: profile.id, namespace: "profiles")
    }
    
    // MARK: - Link: Comments
    
    /// Link a post to a comment.
    ///
    /// Uses the `postComments` relationship defined in your schema.
    @MainActor
    func linkComment(_ postId: String, to comment: Comment) async throws {
        try await link(postId, "comments", to: comment.id, namespace: "comments")
    }
    
    /// Unlink a post from a comment.
    @MainActor
    func unlinkComment(_ postId: String, from comment: Comment) async throws {
        try await unlink(postId, "comments", from: comment.id, namespace: "comments")
    }
    
    // MARK: - Link: Likes
    
    /// Link a post to a like.
    ///
    /// Uses the `postLikes` relationship defined in your schema.
    @MainActor
    func linkLike(_ postId: String, to like: Like) async throws {
        try await link(postId, "likes", to: like.id, namespace: "likes")
    }
    
    /// Unlink a post from a like.
    @MainActor
    func unlinkLike(_ postId: String, from like: Like) async throws {
        try await unlink(postId, "likes", from: like.id, namespace: "likes")
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Profile Mutations
// ═══════════════════════════════════════════════════════════════════════════════

extension Shared where Value: RangeReplaceableCollection, Value.Element == Profile {
    
    // MARK: - Create
    
    /// Create a new profile.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let profile = try await $profiles.createProfile(
    ///     displayName: "John Doe",
    ///     handle: "johndoe"
    /// )
    /// ```
    @MainActor
    @discardableResult
    func createProfile(
        id: String = UUID().uuidString.lowercased(),
        displayName: String,
        handle: String,
        bio: String? = nil,
        avatarUrl: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) async throws -> Profile {
        let profile = Profile(
            id: id,
            displayName: displayName,
            handle: handle,
            bio: bio,
            avatarUrl: avatarUrl,
            createdAt: createdAt
        )
        try await create(profile)
        return profile
    }
    
    // MARK: - Update
    
    /// Update a profile's display name.
    @MainActor
    func updateDisplayName(_ profileId: String, to displayName: String) async throws {
        try await update(id: profileId) { $0.displayName = displayName }
    }
    
    /// Update a profile's handle.
    @MainActor
    func updateHandle(_ profileId: String, to handle: String) async throws {
        try await update(id: profileId) { $0.handle = handle }
    }
    
    /// Update a profile's bio.
    @MainActor
    func updateBio(_ profileId: String, to bio: String?) async throws {
        try await update(id: profileId) { $0.bio = bio }
    }
    
    /// Update a profile's avatar URL.
    @MainActor
    func updateAvatarUrl(_ profileId: String, to avatarUrl: String?) async throws {
        try await update(id: profileId) { $0.avatarUrl = avatarUrl }
    }
    
    // MARK: - Delete
    
    /// Delete a profile by ID.
    @MainActor
    func deleteProfile(_ profileId: String) async throws {
        try await delete(id: profileId)
    }
    
    /// Delete a profile.
    @MainActor
    func deleteProfile(_ profile: Profile) async throws {
        try await delete(id: profile.id)
    }
    
    // MARK: - Link: Posts
    
    /// Link a profile to a post (as author).
    @MainActor
    func linkPost(_ profileId: String, to post: Post) async throws {
        try await link(profileId, "posts", to: post.id, namespace: "posts")
    }
    
    /// Unlink a profile from a post.
    @MainActor
    func unlinkPost(_ profileId: String, from post: Post) async throws {
        try await unlink(profileId, "posts", from: post.id, namespace: "posts")
    }
    
    // MARK: - Link: Comments
    
    /// Link a profile to a comment (as author).
    @MainActor
    func linkComment(_ profileId: String, to comment: Comment) async throws {
        try await link(profileId, "comments", to: comment.id, namespace: "comments")
    }
    
    /// Unlink a profile from a comment.
    @MainActor
    func unlinkComment(_ profileId: String, from comment: Comment) async throws {
        try await unlink(profileId, "comments", from: comment.id, namespace: "comments")
    }
    
    // MARK: - Link: Likes
    
    /// Link a profile to a like.
    @MainActor
    func linkLike(_ profileId: String, to like: Like) async throws {
        try await link(profileId, "likes", to: like.id, namespace: "likes")
    }
    
    /// Unlink a profile from a like.
    @MainActor
    func unlinkLike(_ profileId: String, from like: Like) async throws {
        try await unlink(profileId, "likes", from: like.id, namespace: "likes")
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Comment Mutations
// ═══════════════════════════════════════════════════════════════════════════════

extension Shared where Value: RangeReplaceableCollection, Value.Element == Comment {
    
    // MARK: - Create
    
    /// Create a comment with required author and post links.
    ///
    /// Comments typically require both an author and a post.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let comment = try await $comments.createComment(
    ///     text: "Great post!",
    ///     author: currentProfile,
    ///     post: post
    /// )
    /// ```
    @MainActor
    @discardableResult
    func createComment(
        id: String = UUID().uuidString.lowercased(),
        text: String,
        createdAt: Double = Date().timeIntervalSince1970,
        author: Profile,
        post: Post
    ) async throws -> Comment {
        let comment = Comment(
            id: id,
            text: text,
            createdAt: createdAt
        )
        try await create(comment)
        try await linkAuthor(comment.id, to: author)
        try await linkPost(comment.id, to: post)
        return comment
    }
    
    // MARK: - Update
    
    /// Update a comment's text.
    @MainActor
    func updateText(_ commentId: String, to text: String) async throws {
        try await update(id: commentId) { $0.text = text }
    }
    
    // MARK: - Delete
    
    /// Delete a comment by ID.
    @MainActor
    func deleteComment(_ commentId: String) async throws {
        try await delete(id: commentId)
    }
    
    /// Delete a comment.
    @MainActor
    func deleteComment(_ comment: Comment) async throws {
        try await delete(id: comment.id)
    }
    
    // MARK: - Link: Author (Profile)
    
    /// Link a comment to its author.
    @MainActor
    func linkAuthor(_ commentId: String, to profile: Profile) async throws {
        try await link(commentId, "author", to: profile.id, namespace: "profiles")
    }
    
    /// Unlink a comment from its author.
    @MainActor
    func unlinkAuthor(_ commentId: String, from profile: Profile) async throws {
        try await unlink(commentId, "author", from: profile.id, namespace: "profiles")
    }
    
    // MARK: - Link: Post
    
    /// Link a comment to its post.
    @MainActor
    func linkPost(_ commentId: String, to post: Post) async throws {
        try await link(commentId, "post", to: post.id, namespace: "posts")
    }
    
    /// Unlink a comment from its post.
    @MainActor
    func unlinkPost(_ commentId: String, from post: Post) async throws {
        try await unlink(commentId, "post", from: post.id, namespace: "posts")
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Todo Mutations (Simple entity, no links)
// ═══════════════════════════════════════════════════════════════════════════════

extension Shared where Value: RangeReplaceableCollection, Value.Element == Todo {
    
    // MARK: - Create
    
    /// Create a new todo.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let todo = try await $todos.createTodo(title: "Buy groceries")
    /// ```
    @MainActor
    @discardableResult
    func createTodo(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        done: Bool = false,
        createdAt: Double = Date().timeIntervalSince1970
    ) async throws -> Todo {
        let todo = Todo(
            id: id,
            createdAt: createdAt,
            done: done,
            title: title
        )
        try await create(todo)
        return todo
    }
    
    // MARK: - Update
    
    /// Update a todo's title.
    @MainActor
    func updateTitle(_ todoId: String, to title: String) async throws {
        try await update(id: todoId) { $0.title = title }
    }
    
    /// Mark a todo as done.
    @MainActor
    func markDone(_ todoId: String) async throws {
        try await update(id: todoId) { $0.done = true }
    }
    
    /// Mark a todo as not done.
    @MainActor
    func markNotDone(_ todoId: String) async throws {
        try await update(id: todoId) { $0.done = false }
    }
    
    /// Toggle a todo's done status.
    @MainActor
    func toggleDone(_ todoId: String) async throws {
        try await update(id: todoId) { $0.done.toggle() }
    }
    
    // MARK: - Delete
    
    /// Delete a todo by ID.
    @MainActor
    func deleteTodo(_ todoId: String) async throws {
        try await delete(id: todoId)
    }
    
    /// Delete a todo.
    @MainActor
    func deleteTodo(_ todo: Todo) async throws {
        try await delete(id: todo.id)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - IdentifiedArrayOf Variants
// ═══════════════════════════════════════════════════════════════════════════════

// The same extensions would be generated for IdentifiedArrayOf<Entity> to support
// both Array and IdentifiedArray usage patterns.

extension Shared where Value == IdentifiedArrayOf<Post> {
    // ... same methods as above ...
}

extension Shared where Value == IdentifiedArrayOf<Profile> {
    // ... same methods as above ...
}

// etc.
```

## Benefits

### 1. Complete Type-Safe CRUD

```swift
// CREATE - typed parameters, sensible defaults
let post = try await $posts.createPost(content: "Hello!", author: profile)
let todo = try await $todos.createTodo(title: "Buy milk")
let comment = try await $comments.createComment(text: "Great!", author: profile, post: post)

// UPDATE - field-specific methods
try await $posts.updateContent(post.id, to: "Updated content")
try await $todos.toggleDone(todo.id)
try await $profiles.updateBio(profile.id, to: "New bio")

// DELETE - type-safe
try await $posts.deletePost(post)
try await $todos.deleteTodo(todo.id)

// LINK/UNLINK - no string literals
try await $posts.linkAuthor(post.id, to: profile)
try await $comments.unlinkPost(comment.id, from: post)
```

### 2. No String Literals Anywhere

```swift
// Before (error-prone)
try await $posts.create(Post(id: UUID().uuidString, content: "Hi", imageUrl: nil, createdAt: Date().timeIntervalSince1970, likesCount: 0))
try await $posts.link(post.id, "author", to: profile.id, namespace: "profiles")
//                              ^^^^^^^^                            ^^^^^^^^^^
//                              Easy to typo!

// After (type-safe)
let post = try await $posts.createPost(content: "Hi", author: profile)
//                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                          Autocomplete! Type-checked! Sensible defaults!
```

### 3. Semantic Update Methods

```swift
// Before - generic closure
try await $todos.update(id: todo.id) { $0.done = true }

// After - semantic methods
try await $todos.markDone(todo.id)
try await $todos.toggleDone(todo.id)
try await $posts.incrementLikes(post.id)
try await $profiles.updateBio(profile.id, to: "New bio")
```

### 4. Required Links Enforced at Compile Time

```swift
// Comments require author AND post - enforced by the API
let comment = try await $comments.createComment(
    text: "Great post!",
    author: profile,  // Required
    post: post        // Required
)

// Can't forget required links - won't compile without them!
```

### 5. Full Autocomplete Discovery

```swift
$posts.      // Shows: createPost, updateContent, updateImageUrl, deletePost, linkAuthor, linkComment...
$todos.      // Shows: createTodo, updateTitle, markDone, toggleDone, deleteTodo
$profiles.   // Shows: createProfile, updateDisplayName, updateHandle, updateBio, deleteProfile, linkPost...
```

## Implementation in Schema Generator

The schema generator already has all the information needed:

1. **Entity names and fields** - From `Entities.swift` generation
2. **Field types** - String, Double, Bool, Optional variants
3. **Link metadata** - From `Links.swift` (forward/reverse labels, cardinality)
4. **Namespace names** - From `Schema.swift`

### What the Generator Knows Per Entity

For each entity, the generator knows:

```
Entity: Post
  Namespace: "posts"
  Fields:
    - id: String (always present)
    - content: String (required)
    - imageUrl: String? (optional)
    - createdAt: Double (required, default: now)
    - likesCount: Double (required, default: 0)
  Links:
    - author: Profile (one, via profilePosts)
    - comments: [Comment] (many, via postComments)
    - likes: [Like] (many, via postLikes)
```

### Pseudocode for Generation

```swift
func generateMutations(schema: ParsedSchema) -> String {
    var output = fileHeader()
    
    for entity in schema.entities {
        output += "// MARK: - \(entity.name) Mutations\n\n"
        output += "extension Shared where Value: RangeReplaceableCollection, Value.Element == \(entity.name) {\n"
        
        // Generate CREATE methods
        output += generateCreateMethods(entity)
        
        // Generate UPDATE methods for each field
        for field in entity.fields where field.name != "id" {
            output += generateUpdateMethod(entity, field)
        }
        
        // Generate semantic update methods for common patterns
        output += generateSemanticUpdates(entity)
        
        // Generate DELETE methods
        output += generateDeleteMethods(entity)
        
        // Generate LINK/UNLINK methods for each relationship
        for link in entity.links {
            output += generateLinkMethods(entity, link)
        }
        
        output += "}\n\n"
        
        // Also generate IdentifiedArrayOf variant
        output += generateIdentifiedArrayVariant(entity)
    }
    
    return output
}

func generateCreateMethods(_ entity: Entity) -> String {
    // Basic create with all fields as parameters
    var output = """
    @MainActor
    @discardableResult
    func create\(entity.name)(
        id: String = UUID().uuidString.lowercased(),
    """
    
    for field in entity.fields where field.name != "id" {
        let defaultValue = getDefaultValue(field)
        if let defaultValue = defaultValue {
            output += "    \(field.name): \(field.type) = \(defaultValue),\n"
        } else {
            output += "    \(field.name): \(field.type),\n"
        }
    }
    
    output += """
    ) async throws -> \(entity.name) {
        let entity = \(entity.name)(...)
        try await create(entity)
        return entity
    }
    """
    
    // If entity has required links, generate convenience create with links
    let requiredLinks = entity.links.filter { $0.isRequired }
    if !requiredLinks.isEmpty {
        output += generateCreateWithLinks(entity, requiredLinks)
    }
    
    return output
}

func generateUpdateMethod(_ entity: Entity, _ field: Field) -> String {
    let methodName = "update\(field.name.capitalized)"
    return """
    @MainActor
    func \(methodName)(_ \(entity.name.lowercased())Id: String, to \(field.name): \(field.type)) async throws {
        try await update(id: \(entity.name.lowercased())Id) { $0.\(field.name) = \(field.name) }
    }
    """
}

func generateSemanticUpdates(_ entity: Entity) -> String {
    var output = ""
    
    // For Bool fields, generate toggle methods
    for field in entity.fields where field.type == "Bool" {
        output += """
        @MainActor
        func toggle\(field.name.capitalized)(_ id: String) async throws {
            try await update(id: id) { $0.\(field.name).toggle() }
        }
        """
    }
    
    // For numeric "count" fields, generate increment/decrement
    for field in entity.fields where field.name.contains("Count") && field.type == "Double" {
        output += """
        @MainActor
        func increment\(field.name.replacingOccurrences(of: "Count", with: ""))(_ id: String) async throws {
            try await update(id: id) { $0.\(field.name) += 1 }
        }
        """
    }
    
    return output
}

func generateLinkMethods(_ entity: Entity, _ link: Link) -> String {
    let targetEntity = link.targetEntity
    let label = link.label
    
    return """
    @MainActor
    func link\(label.capitalized)(_ \(entity.name.lowercased())Id: String, to \(targetEntity.name.lowercased()): \(targetEntity.name)) async throws {
        try await link(\(entity.name.lowercased())Id, "\(label)", to: \(targetEntity.name.lowercased()).id, namespace: "\(targetEntity.namespace)")
    }
    
    @MainActor
    func unlink\(label.capitalized)(_ \(entity.name.lowercased())Id: String, from \(targetEntity.name.lowercased()): \(targetEntity.name)) async throws {
        try await unlink(\(entity.name.lowercased())Id, "\(label)", from: \(targetEntity.name.lowercased()).id, namespace: "\(targetEntity.namespace)")
    }
    """
}
```

## File Structure

After generation:

```
Generated/
├── Entities.swift      # Entity structs
├── Links.swift         # Link metadata
├── Schema.swift        # EntityKey instances
├── Rooms.swift         # Room types (if any)
└── Mutations.swift     # NEW: Type-safe mutation extensions
```

## Migration Path

1. **Phase 1 (Current)**: Generic `$collection.link()` methods work for all entities
2. **Phase 2 (Generated)**: Schema generator outputs type-safe `Mutations.swift`
3. **Phase 3 (Optional)**: Deprecate generic `link()` in favor of generated methods

## Open Questions

1. **Should create methods return the entity or be void?**
   - Current design: `@discardableResult func createPost(...) -> Post`
   - Allows chaining: `let post = try await $posts.createPost(...)`
   - Can be ignored if not needed

2. **How to handle required vs optional links in create?**
   - Option A: Separate methods (`createComment(...)` vs `createComment(..., author:, post:)`)
   - Option B: Required links as required parameters
   - Current design uses Option B for entities with required relationships

3. **Should we generate batch operations?**
   - e.g., `createPosts(_ posts: [Post])`, `deletePosts(_ ids: [String])`
   - Probably useful for bulk imports, but adds complexity

4. **Naming conventions for semantic updates?**
   - `markDone` vs `setDone(true)` vs `updateDone(to: true)`
   - Current design prefers semantic names where obvious

5. **Should update methods accept the entity or just the ID?**
   - Current: `updateContent(_ postId: String, to: String)`
   - Alternative: `updateContent(_ post: Post, to: String)`
   - ID-based is more flexible (works even if you don't have the full entity)

6. **How to handle entities with many fields?**
   - Generate individual update methods for each field
   - Also keep the generic `update(id:) { }` closure for complex updates

## Comparison: Before vs After

| Operation | Before (Generic) | After (Generated) |
|-----------|-----------------|-------------------|
| Create | `$posts.create(Post(id: ..., content: ..., imageUrl: ..., createdAt: ..., likesCount: ...))` | `$posts.createPost(content: "Hi")` |
| Create with link | `create(post); link(post.id, "author", to: profile.id, namespace: "profiles")` | `$posts.createPost(content: "Hi", author: profile)` |
| Update field | `$posts.update(id: id) { $0.content = "New" }` | `$posts.updateContent(id, to: "New")` |
| Toggle bool | `$todos.update(id: id) { $0.done.toggle() }` | `$todos.toggleDone(id)` |
| Delete | `$posts.delete(id: post.id)` | `$posts.deletePost(post)` |
| Link | `$posts.link(id, "author", to: profile.id, namespace: "profiles")` | `$posts.linkAuthor(id, to: profile)` |
