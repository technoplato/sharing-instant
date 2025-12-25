import { i } from "@instantdb/core";

const _schema = i.schema({
  entities: {
    segments: i.entity({
      title: i.string(),
    }),
    splits: i.entity({
      reason: i.string().optional(),
    }),
  },
  links: {
    segmentParent: {
      forward: { on: "segments", has: "one", label: "parent" },
      reverse: { on: "segments", has: "many", label: "children" },
    },
    segmentSplit: {
      forward: { on: "segments", has: "one", label: "createdFromSplit" },
      reverse: { on: "splits", has: "one", label: "originalSegment" },
    },
  },
});

export type Schema = typeof _schema;

