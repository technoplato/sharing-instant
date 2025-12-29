/**
 * Imported Types
 * 
 * Type definitions that are imported by GenericTypesSchema.ts.
 * Tests the import resolution functionality.
 */

// =========================================================================
// STRING UNION TYPES
// =========================================================================

/** Task priority levels */
export type TaskPriority = "low" | "medium" | "high" | "urgent";

/** Identity types for different actors */
export type IdentityType = "human" | "llm_agent" | "bot" | "organization" | "service";

/** Processing status */
export type ProcessingStatus = "pending" | "running" | "completed" | "failed";

// =========================================================================
// OBJECT TYPES
// =========================================================================

/** A word with timing and confidence information */
export type Word = {
  text: string;
  start: number;
  end: number;
  confidence: number;
};

/** A segment of transcribed text */
export type Segment = {
  text: string;
  start: number;
  end: number;
  speaker: number;
  words: Word[];
};

/** Metadata about a processing run */
export type RunMetadata = {
  toolVersion: string;
  executedAt: string;
  durationSeconds: number;
  peakMemoryMb: number;
};

// =========================================================================
// NESTED OBJECT TYPES
// =========================================================================

/** Complex nested type for testing */
export type ComplexMetadata = {
  source: {
    type: string;
    url: string;
  };
  processing: {
    status: ProcessingStatus;
    attempts: number;
  };
  timestamps: {
    created: string;
    updated: string;
  };
};


