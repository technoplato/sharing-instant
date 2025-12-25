import Foundation
import XCTest

// MARK: - EphemeralAppFactory

/// Test-only helpers for creating isolated ephemeral InstantDB apps.
///
/// ## Why This Exists
/// Many integration tests need to mutate data and assert on real backend behavior. Using a shared
/// app ID makes those tests:
/// - flaky (state can leak between runs)
/// - order-dependent (tests can interfere in parallel execution)
/// - hard to trust (failures can be caused by stale data)
///
/// Ephemeral apps are created server-side via `/dash/apps/ephemeral` and expire automatically.
/// This lets tests create a fresh app per run with minimal schema and open rules.
enum EphemeralAppFactory {
  struct EphemeralApp: Sendable {
    let id: String
    let adminToken: String
  }

  private struct EphemeralAppResponse: Decodable {
    struct App: Decodable {
      let id: String
      let adminToken: String

      enum CodingKeys: String, CodingKey {
        case id
        case adminToken = "admin-token"
      }
    }

    let app: App
    let expiresMs: Int64

    enum CodingKeys: String, CodingKey {
      case app
      case expiresMs = "expires_ms"
    }
  }

  static func createApp(
    titlePrefix: String,
    schema: [String: Any],
    rules: [String: Any]
  ) async throws -> EphemeralApp {
    let apiOrigin = ProcessInfo.processInfo.environment["INSTANT_TEST_API_ORIGIN"] ?? "https://api.instantdb.com"

    guard let url = URL(string: "\(apiOrigin)/dash/apps/ephemeral") else {
      throw XCTSkip("Invalid INSTANT_TEST_API_ORIGIN: \(apiOrigin)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let title = "\(titlePrefix)-\(UUID().uuidString.prefix(8))"
    let body: [String: Any] = [
      "title": title,
      "schema": schema,
      "rules": ["code": rules],
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw XCTSkip("Ephemeral app creation returned a non-HTTP response.")
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      throw XCTSkip(
        """
        Failed to create ephemeral app.

        Status: \(httpResponse.statusCode)
        Body: \(raw)
        """
      )
    }

    let decoded = try JSONDecoder().decode(EphemeralAppResponse.self, from: data)
    _ = decoded.expiresMs

    return EphemeralApp(id: decoded.app.id, adminToken: decoded.app.adminToken)
  }

  static func openRules(for entities: [String]) -> [String: Any] {
    var rules: [String: Any] = [:]
    for entity in entities {
      rules[entity] = [
        "allow": [
          "view": "true",
          "create": "true",
          "update": "true",
          "delete": "true",
        ]
      ]
    }
    return rules
  }

  // MARK: - Minimal Schemas

  static func minimalTodosSchema() -> [String: Any] {
    func dataAttr(
      valueType: String,
      required: Bool,
      indexed: Bool = false,
      unique: Bool = false
    ) -> [String: Any] {
      [
        "valueType": valueType,
        "required": required,
        "isIndexed": indexed,
        "config": [
          "indexed": indexed,
          "unique": unique,
        ],
        "metadata": [:] as [String: Any],
      ]
    }

    func entityDef(attrs: [String: Any]) -> [String: Any] {
      [
        "attrs": attrs,
        "links": [:] as [String: Any],
      ]
    }

    return [
      "entities": [
        "todos": entityDef(
          attrs: [
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
            "done": dataAttr(valueType: "boolean", required: true),
            "title": dataAttr(valueType: "string", required: true),
          ]
        ),
      ],
      "links": [:] as [String: Any],
      "rooms": [:] as [String: Any],
    ]
  }

  static func minimalProfilesSchema() -> [String: Any] {
    func dataAttr(
      valueType: String,
      required: Bool,
      indexed: Bool = false,
      unique: Bool = false
    ) -> [String: Any] {
      [
        "valueType": valueType,
        "required": required,
        "isIndexed": indexed,
        "config": [
          "indexed": indexed,
          "unique": unique,
        ],
        "metadata": [:] as [String: Any],
      ]
    }

    func entityDef(attrs: [String: Any]) -> [String: Any] {
      [
        "attrs": attrs,
        "links": [:] as [String: Any],
      ]
    }

    return [
      "entities": [
        "profiles": entityDef(
          attrs: [
            "displayName": dataAttr(valueType: "string", required: true),
            "handle": dataAttr(valueType: "string", required: true, indexed: true, unique: true),
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
          ]
        ),
      ],
      "links": [:] as [String: Any],
      "rooms": [:] as [String: Any],
    ]
  }

  static func minimalMicroblogSchema() -> [String: Any] {
    func dataAttr(
      valueType: String,
      required: Bool,
      indexed: Bool = false,
      unique: Bool = false
    ) -> [String: Any] {
      [
        "valueType": valueType,
        "required": required,
        "isIndexed": indexed,
        "config": [
          "indexed": indexed,
          "unique": unique,
        ],
        "metadata": [:] as [String: Any],
      ]
    }

    func entityDef(
      attrs: [String: Any],
      links: [String: Any]
    ) -> [String: Any] {
      [
        "attrs": attrs,
        "links": links,
      ]
    }

    return [
      "entities": [
        "profiles": entityDef(
          attrs: [
            "displayName": dataAttr(valueType: "string", required: true),
            "handle": dataAttr(valueType: "string", required: true, indexed: true, unique: true),
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
          ],
          links: [
            "posts": [
              "entityName": "posts",
              "cardinality": "many",
            ],
          ]
        ),
        "posts": entityDef(
          attrs: [
            "content": dataAttr(valueType: "string", required: true),
            "createdAt": dataAttr(valueType: "number", required: true, indexed: true),
            "likesCount": dataAttr(valueType: "number", required: true),
          ],
          links: [
            "author": [
              "entityName": "profiles",
              "cardinality": "one",
            ],
          ]
        ),
      ],
      "links": [
        "profilePosts": [
          "forward": [
            "on": "profiles",
            "has": "many",
            "label": "posts",
          ],
          "reverse": [
            "on": "posts",
            "has": "one",
            "label": "author",
            "onDelete": "cascade",
          ],
        ],
      ],
      "rooms": [:] as [String: Any],
    ]
  }
}

