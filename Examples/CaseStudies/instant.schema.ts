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
    facts: i.entity({
      count: i.number(),
      text: i.string(),
    }),
    // Remote logging entity for debugging iOS apps
    // Logs are synced from the iOS app and can be tailed via ReadLogs.swift
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
interface AppSchema extends _AppSchema {}
const schema: AppSchema = _schema;

export type { AppSchema };
export default schema;

