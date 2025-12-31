/**
 * Mixed Types Schema
 * 
 * Test fixture that combines typed JSON fields with boolean/number fields
 * to verify the custom decoder uses the correct types for JSON fields.
 */
import { i } from "@instantdb/core";

type Word = {
  text: string;
  start: number;
  end: number;
};

type Speaker = {
  id: string;
  name: string;
};

const _schema = i.schema({
  entities: {
    transcriptions: i.entity({
      text: i.string(),
      // Typed JSON array - should decode as [Word]
      words: i.json<Word[]>().optional(),
      // Typed JSON object - should decode as Speaker
      speaker: i.json<Speaker>().optional(),
      // Boolean field (optional) - triggers custom decoder
      isActive: i.boolean().optional(),
      // Number field (optional) - triggers custom decoder
      duration: i.number().optional(),
      // Required boolean
      isPublished: i.boolean(),
      // Required number
      createdAt: i.number(),
    }),
  },
});

export default _schema;
