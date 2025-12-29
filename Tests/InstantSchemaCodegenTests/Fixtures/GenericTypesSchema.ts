/**
 * Generic Types Schema
 * 
 * Test fixture demonstrating all supported generic type patterns:
 * - Inline string unions: i.string<"a" | "b" | "c">()
 * - Type alias string unions: type Status = "a" | "b"; i.string<Status>()
 * - Imported type aliases: import { MyType } from "./types"; i.string<MyType>()
 * - Inline JSON objects: i.json<{ field: type }>()
 * - Type alias JSON objects: type Word = { ... }; i.json<Word>()
 * - JSON arrays: i.json<Item[]>() and i.json<Array<Item>>()
 */

import { i } from "@instantdb/core";
import { TaskPriority, Word } from "./ImportedTypes";

// =========================================================================
// TYPE ALIASES (defined in same file)
// =========================================================================

export type TaskStatus = "pending" | "in_progress" | "completed" | "cancelled";

export type MediaType = "audio" | "video" | "text";

export type Timestamp = {
  start: number;
  end: number;
};

export type Speaker = {
  id: string;
  name: string;
  confidence: number;
};

// =========================================================================
// SCHEMA
// =========================================================================

const _schema = i.schema({
  entities: {
    /**
     * A task with various generic type patterns.
     */
    tasks: i.entity({
      /** Task title */
      title: i.string(),
      
      /** Task status - inline string union */
      statusInline: i.string<"pending" | "active" | "done">(),
      
      /** Task status - type alias from same file */
      statusAlias: i.string<TaskStatus>(),
      
      /** Task priority - imported type alias */
      priority: i.string<TaskPriority>(),
      
      /** Task metadata - inline JSON object */
      metadataInline: i.json<{ createdBy: string, version: number }>(),
      
      /** Task timestamp - type alias from same file */
      timestamp: i.json<Timestamp>(),
      
      /** Task speaker - type alias from same file */
      speaker: i.json<Speaker>().optional(),
    }),
    
    /**
     * Media entity demonstrating array patterns.
     */
    media: i.entity({
      /** Media title */
      title: i.string(),
      
      /** Media type - type alias */
      mediaType: i.string<MediaType>(),
      
      /** Words array - imported type with bracket syntax */
      wordsBracket: i.json<Word[]>(),
      
      /** Words array - imported type with Array<T> syntax */
      wordsGeneric: i.json<Array<Word>>(),
      
      /** Timestamps array - inline object with bracket syntax */
      timestampsInline: i.json<{ start: number, end: number }[]>(),
      
      /** Speakers array - type alias with Array<T> syntax */
      speakers: i.json<Array<Speaker>>().optional(),
    }),
    
    /**
     * Entity with nested object types.
     */
    transcriptions: i.entity({
      /** Transcription text */
      text: i.string(),
      
      /** Nested metadata object */
      metadata: i.json<{
        source: string,
        language: string,
        confidence: number,
        timestamps: { start: number, end: number }
      }>(),
      
      /** Array of segments with nested structure */
      segments: i.json<Array<{
        text: string,
        speaker: number,
        start: number,
        end: number
      }>>(),
    }),
  },
  
  links: {
    /** Task to media relationship */
    taskMedia: {
      forward: { on: "tasks", has: "many", label: "media" },
      reverse: { on: "media", has: "one", label: "task" },
    },
    
    /** Media to transcription relationship */
    mediaTranscription: {
      forward: { on: "media", has: "one", label: "transcription" },
      reverse: { on: "transcriptions", has: "one", label: "media" },
    },
  },
});

export type Schema = typeof _schema;


