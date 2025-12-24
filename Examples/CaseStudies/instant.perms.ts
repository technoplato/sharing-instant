// Docs: https://www.instantdb.com/docs/permissions

import type { InstantRules } from "@instantdb/react";

const rules = {
  // Allow all operations for guest users during development
  // In production, you should add proper authentication checks
  "$files": {
    allow: {
      view: "isOwner",
      create: "isOwner",
      delete: "isOwner",
    },
    bind: ["isOwner", "auth.id != null && data.path.startsWith(auth.id + '/')"],
  },
  todos: {
    allow: {
      view: "true",
      create: "true",
      update: "true",
      delete: "true",
    },
  },
  facts: {
    allow: {
      view: "true",
      create: "true",
      update: "true",
      delete: "true",
    },
  },
} satisfies InstantRules;

export default rules;






