// Docs: https://www.instantdb.com/docs/modeling-data
// 
// This schema demonstrates:
// - Basic entities (todos, facts, logs)
// - Microblog-style entities with rich relationships (profiles, posts, comments)
// - Real-time rooms for presence and topics

import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    $files: i.entity({
      path: i.string().unique().indexed(),
      url: i.string(),
    }),
    $users: i.entity({
      email: i.string().unique().indexed().optional(),
      imageURL: i.string().optional(),
      type: i.string().optional(),
    }),

    // ─────────────────────────────────────────────────────────────────────────
    // Basic Demo Entities
    // ─────────────────────────────────────────────────────────────────────────

    facts: i.entity({
      count: i.number(),
      text: i.string(),
    }),

    // Remote logging entity for debugging iOS apps
    logs: i.entity({
      level: i.string().indexed(),
      message: i.string(),
      jsonPayload: i.string().optional(),
      file: i.string(),
      line: i.number(),
      timestamp: i.number().indexed(),
      formattedDate: i.string(),
      timezone: i.string(),
    }),

    todos: i.entity({
      createdAt: i.number().indexed(),
      done: i.boolean(),
      title: i.string(),
    }),

    // ─────────────────────────────────────────────────────────────────────────
    // Microblog Demo Entities
    // Demonstrates rich relationships between entities
    // ─────────────────────────────────────────────────────────────────────────

    // User profiles with display name and handle
    profiles: i.entity({
      displayName: i.string(),
      handle: i.string().unique().indexed(),
      bio: i.string().optional(),
      avatarUrl: i.string().optional(),
      createdAt: i.number().indexed(),
    }),

    // Posts/tweets with content and metadata
    posts: i.entity({
      content: i.string(),
      imageUrl: i.string().optional(),
      createdAt: i.number().indexed(),
    }),

    // Comments on posts
    comments: i.entity({
      text: i.string(),
      createdAt: i.number().indexed(),
    }),

    // Likes junction entity (for many-to-many between profiles and posts)
    likes: i.entity({
      createdAt: i.number().indexed(),
    }),

    tiles: i.entity({
      x: i.number().indexed(),
      y: i.number().indexed(),
      color: i.string(),
      createdAt: i.number(),
    }),

    boards: i.entity({
      title: i.string(),
      createdAt: i.number(),
    }),

    // ─────────────────────────────────────────────────────────────────────────
    // Rapid Transcription Demo Entities
    // Mirrors SpeechRecorderApp schema for testing rapid updates
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * A piece of media (audio recording, video, etc).
     */
    media: i.entity({
      /** Title of the media (user-editable for recordings). */
      title: i.string().indexed(),
      /** Duration in seconds. */
      durationSeconds: i.number(),
      /** Type of media: "audio" for recordings. */
      mediaType: i.string().indexed(),
      /** When this media was ingested/created. ISO 8601 format. */
      ingestedAt: i.string(),
      /** Optional description. */
      description: i.string().optional(),
    }),

    /**
     * A transcription run for a piece of media.
     */
    transcriptionRuns: i.entity({
      /** Tool version used (e.g., "SpeechAnalyzer-iOS18"). */
      toolVersion: i.string(),
      /** When the transcription run was executed. ISO 8601 format. */
      executedAt: i.string(),
      /** Type of run: "volatile" or "finalized". */
      runType: i.string().indexed().optional(),
      /** Whether this run is currently active. */
      isActive: i.boolean().indexed().optional(),
    }),

    /**
     * A segment of transcription text with timing.
     * Words are embedded as JSON rather than separate entities.
     */
    transcriptionSegments: i.entity({
      /** Start time in seconds. */
      startTime: i.number().indexed(),
      /** End time in seconds. */
      endTime: i.number().indexed(),
      /** The transcribed text for this segment. */
      text: i.string(),
      /** Segment index within the transcription run. */
      segmentIndex: i.number().indexed(),
      /** Whether this segment is finalized. */
      isFinalized: i.boolean().indexed(),
      /** When this segment was ingested. ISO 8601 format. */
      ingestedAt: i.string(),
      /** Speaker number (for diarization). */
      speaker: i.number().optional(),
      /** Word-level timing data (only populated for finalized segments). */
      words: i.json<{ text: string; startTime: number; endTime: number }[]>().optional(),
    }),
  },

  links: {
    // $users self-referential link (for guest accounts)
    // $usersLinkedPrimaryUser: {
    //   forward: {
    //     on: "$users",
    //     has: "one",
    //     label: "linkedPrimaryUser",
    //     onDelete: "cascade",
    //   },
    //   reverse: {
    //     on: "$users",
    //     has: "many",
    //     label: "linkedGuestUsers",
    //   },
    // },

    // ─────────────────────────────────────────────────────────────────────────
    // Tile Game Links
    // ─────────────────────────────────────────────────────────────────────────

    boardTiles: {
      forward: {
        on: "boards",
        has: "many",
        label: "tiles",
      },
      reverse: {
        on: "tiles",
        has: "one",
        label: "board",
        onDelete: "cascade",
      }
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Microblog Links
    // ─────────────────────────────────────────────────────────────────────────

    // Profile → Posts (one-to-many: a profile has many posts)
    profilePosts: {
      forward: {
        on: "profiles",
        has: "many",
        label: "posts",
      },
      reverse: {
        on: "posts",
        has: "one",
        label: "author",
        onDelete: "cascade",
      },
    },

    // Profile → Comments (one-to-many: a profile has many comments)
    profileComments: {
      forward: {
        on: "profiles",
        has: "many",
        label: "comments",
      },
      reverse: {
        on: "comments",
        has: "one",
        label: "author",
        onDelete: "cascade",
      },
    },

    // Post → Comments (one-to-many: a post has many comments)
    postComments: {
      forward: {
        on: "posts",
        has: "many",
        label: "comments",
      },
      reverse: {
        on: "comments",
        has: "one",
        label: "post",
        onDelete: "cascade",
      },
    },

    // Profile → Likes (one-to-many: a profile has many likes)
    profileLikes: {
      forward: {
        on: "profiles",
        has: "many",
        label: "likes",
      },
      reverse: {
        on: "likes",
        has: "one",
        label: "profile",
        onDelete: "cascade",
      },
    },

    // Post → Likes (one-to-many: a post has many likes)
    postLikes: {
      forward: {
        on: "posts",
        has: "many",
        label: "likes",
      },
      reverse: {
        on: "likes",
        has: "one",
        label: "post",
        onDelete: "cascade",
      },
    },

    // ─────────────────────────────────────────────────────────────────────────
    // Transcription Links
    // ─────────────────────────────────────────────────────────────────────────

    // Media → TranscriptionRuns (one-to-many)
    mediaTranscriptionRuns: {
      forward: {
        on: "media",
        has: "many",
        label: "transcriptionRuns",
      },
      reverse: {
        on: "transcriptionRuns",
        has: "one",
        label: "media",
      },
    },

    // TranscriptionRuns → TranscriptionSegments (one-to-many)
    transcriptionRunsSegments: {
      forward: {
        on: "transcriptionRuns",
        has: "many",
        label: "transcriptionSegments",
      },
      reverse: {
        on: "transcriptionSegments",
        has: "one",
        label: "transcriptionRun",
      },
    },
  },

  rooms: {
    // Avatar stack demo - shows who's online
    avatars: {
      presence: i.entity({
        name: i.string(),
        color: i.string(),
      }),
    },
    // Chat/typing indicator demo
    chat: {
      presence: i.entity({
        name: i.string(),
        color: i.string(),
        isTyping: i.boolean(),
      }),
    },
    // Cursors demo - real-time cursor positions
    cursors: {
      presence: i.entity({
        name: i.string(),
        color: i.string(),
        cursorX: i.number(),
        cursorY: i.number(),
      }),
    },
    // Emoji reactions demo - fire-and-forget events
    reactions: {
      presence: i.entity({
        name: i.string(),
      }),
      topics: {
        emoji: i.entity({
          name: i.string(),
          directionAngle: i.number(),
          rotationAngle: i.number(),
        }),
      },
    },
    // Tile game demo - collaborative game
    tileGame: {
      presence: i.entity({
        name: i.string(),
        color: i.string(),
      }),
    },
  },
});

// This helps Typescript display nicer intellisense
type _AppSchema = typeof _schema;
interface AppSchema extends _AppSchema { }
const schema: AppSchema = _schema;

export type { AppSchema };
export default schema;

