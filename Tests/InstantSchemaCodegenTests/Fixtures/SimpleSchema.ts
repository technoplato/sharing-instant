import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    /** A todo item with title and completion status */
    todos: i.entity({
      /** The title of the todo */
      title: i.string(),
      /** Whether the todo is completed */
      done: i.boolean(),
      /** Priority level (1-5) */
      priority: i.number().optional(),
    }),
    /** A user who can own todos */
    users: i.entity({
      /** User's display name */
      name: i.string(),
      /** User's email address */
      email: i.string(),
      /** When the user joined */
      createdAt: i.date(),
    }),
  },
  links: {
    /** User owns todos relationship */
    userTodos: {
      forward: { on: "users", has: "many", label: "todos" },
      reverse: { on: "todos", has: "one", label: "owner" },
    },
  },
});

export type Schema = typeof _schema;








