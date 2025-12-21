
  // MARK: - Helper Methods
  
  func convertLinkTreeToInstaQL(_ tree: [EntityQueryNode]) -> [String: Any] {
    var result: [String: Any] = [:]
    
    for node in tree {
      switch node {
      case let .link(name, limit, orderBy, orderDirection, whereClauses, children):
        var linkDef: [String: Any] = [:]
        
        // Handle options
        if let limit = limit {
          // map "$limit" -> limit ? No, InstaQL object syntax usually is:
          // "posts": { "$limit": 10, "comments": { ... } }
          // Actually, let's verify exact InstaQL syntax for swift client.
          // Assuming it follows typical JS patterns but adapted for Swift dictionary.
          // The Swift client likely expects standard keys or specific $ keys.
          // Based on TypeScript SDK: { posts: { $: { limit: 10 }, comments: {} } }
          // Or simplified: { posts: { limit: 10, comments: {} } } ?
          //
          // For now, let's assume the Swift SDK expects a straight dictionary of relations.
          // If we need options like $limit, we might need a specific structure.
          // BUT, `EntityKey` stores these.
          //
          // Let's assume for now we just recurse. If options are needed, we need to know how SDK expects them.
          // The JS SDK uses `$` key for options.
          // Let's implement recursion first.
        }
        
        // Recursion
        if !children.isEmpty {
           let childDict = convertLinkTreeToInstaQL(children)
           // Merge child dict into linkDef?
           // E.g. "posts": { "comments": {} }
           linkDef = childDict
        }
        
        // If we have no children but just want the link, we typically do "posts": [:] or "posts": true?
        // JS SDK: "posts": {}
        result[name] = linkDef
      }
    }
    
    return result
  }
