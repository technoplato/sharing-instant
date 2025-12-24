// Docs: https://www.instantdb.com/docs/permissions

import type { InstantRules } from "@instantdb/core";

const rules = {
  "$files": {
    allow: {
      view: "isOwner",
      create: "isOwner",
      delete: "isOwner",
    },
    bind: ["isOwner", "auth.id != null && data.path.startsWith(auth.id + '/')"],
  },
  /**
   * Welcome to Instant's permission system!
   *
   * This repo keeps a small `$files` rule so Swift storage integration tests can run.
   * Add your own namespace rules below. For more details, see:
   * https://www.instantdb.com/docs/permissions
   *
   * Here's an example to give you a feel:
   * posts: {
   *   allow: {
   *     view: "true",
   *     create: "isOwner",
   *     update: "isOwner",
   *     delete: "isOwner",
   *   },
   *   bind: ["isOwner", "auth.id != null && auth.id == data.ownerId"],
   * },
   */
} satisfies InstantRules;

export default rules;
