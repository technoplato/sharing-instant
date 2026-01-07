// Docs: https://www.instantdb.com/docs/modeling-data

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
    boards: i.entity({
      createdAt: i.number(),
      title: i.string(),
    }),
    comments: i.entity({
      createdAt: i.number().indexed(),
      text: i.string(),
    }),
    facts: i.entity({
      count: i.number(),
      text: i.string(),
    }),
    likes: i.entity({
      createdAt: i.number().indexed(),
    }),
    logs: i.entity({
      file: i.string(),
      formattedDate: i.string(),
      jsonPayload: i.string().optional(),
      level: i.string().indexed(),
      line: i.number(),
      message: i.string(),
      timestamp: i.number().indexed(),
      timezone: i.string(),
    }),
    posts: i.entity({
      content: i.string(),
      createdAt: i.number().indexed(),
      imageUrl: i.string().optional(),
    }),
    profiles: i.entity({
      avatarUrl: i.string().optional(),
      bio: i.string().optional(),
      createdAt: i.number().indexed(),
      displayName: i.string(),
      handle: i.string().unique().indexed(),
    }),
    tiles: i.entity({
      color: i.string(),
      createdAt: i.number(),
      x: i.number().indexed(),
      y: i.number().indexed(),
    }),
    todos: i.entity({
      createdAt: i.number().indexed(),
      done: i.boolean(),
      title: i.string(),
    }),
    // Rapid Transcription Demo Entities
    media: i.entity({
      title: i.string().indexed(),
      durationSeconds: i.number(),
      mediaType: i.string().indexed(),
      ingestedAt: i.string(),
      description: i.string().optional(),
    }),
    transcriptionRuns: i.entity({
      toolVersion: i.string(),
      executedAt: i.string(),
      runType: i.string().indexed().optional(),
      isActive: i.boolean().indexed().optional(),
    }),
    transcriptionSegments: i.entity({
      startTime: i.number().indexed(),
      endTime: i.number().indexed(),
      text: i.string(),
      segmentIndex: i.number().indexed(),
      isFinalized: i.boolean().indexed(),
      ingestedAt: i.string(),
      speaker: i.number().optional(),
      words: i.json<{ text: string; startTime: number; endTime: number }[]>().optional(),
    }),
  },
  links: {
    $usersLinkedPrimaryUser: {
      forward: {
        on: "$users",
        has: "one",
        label: "linkedPrimaryUser",
        onDelete: "cascade",
      },
      reverse: {
        on: "$users",
        has: "many",
        label: "linkedGuestUsers",
      },
    },
    boardsLinkedTiles: {
      forward: {
        on: "boards",
        has: "many",
        label: "linkedTiles",
      },
      reverse: {
        on: "tiles",
        has: "many",
        label: "linkedBoard",
      },
    },
    boardsTiles: {
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
      },
    },
    postsComments: {
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
    postsLikes: {
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
    profilesComments: {
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
    profilesLikes: {
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
    profilesPosts: {
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
    // Transcription Links
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
    avatars: {
      presence: i.entity({
        color: i.string(),
        name: i.string(),
      }),
    },
    chat: {
      presence: i.entity({
        color: i.string(),
        isTyping: i.boolean(),
        name: i.string(),
      }),
    },
    cursors: {
      presence: i.entity({
        color: i.string(),
        cursorX: i.number(),
        cursorY: i.number(),
        name: i.string(),
      }),
    },
    reactions: {
      presence: i.entity({
        name: i.string(),
      }),
      topics: {
        emoji: i.entity({
          directionAngle: i.number(),
          name: i.string(),
          rotationAngle: i.number(),
        }),
      },
    },
    tileGame: {
      presence: i.entity({
        color: i.string(),
        name: i.string(),
      }),
    },
  },
});

// This helps Typescript display nicer intellisense
type _AppSchema = typeof _schema;
interface AppSchema extends _AppSchema {}
const schema: AppSchema = _schema;

export type { AppSchema };
export default schema;
