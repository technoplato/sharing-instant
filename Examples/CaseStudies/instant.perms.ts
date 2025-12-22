// Docs: https://www.instantdb.com/docs/permissions

import type { InstantRules } from "@instantdb/react";

const rules = {
  // Allow all operations for guest users during development
  // In production, you should add proper authentication checks
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







