// Docs: https://www.instantdb.com/docs/modeling-data
// Schema redesign: Platform-free, with People/Speakers separation
// All timestamps use ISO 8601 format (e.g., "2025-12-16T14:30:00Z")

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

    // =========================================================================
    // NEW ENTITIES (Platform-Free Schema Redesign)
    // =========================================================================

    /**
     * A person in the real world.
     *
     * People exist independently of their roles. A person may be an author,
     * narrator, podcast host, guest making an appearance, article writer,
     * or just referenced/mentioned in media. Not all people speak in media -
     * use the Speakers entity for that relationship.
     *
     * Examples:
     * - Eckhart Tolle (author and narrator of "A New Earth")
     * - Lex Fridman (podcast host)
     * - A guest mentioned but never heard
     * - Someone who wrote an article
     *
     * Links:
     * - speakers: Instances where this person speaks in media
     * - externalIds: Platform profiles (YouTube channel, Twitter, Wikidata, Wikipedia, etc.)
     */
    people: i.entity({
      /**
       * Full name as commonly known.
       * Examples: "Eckhart Tolle", "Lex Fridman"
       */
      name: i.string().indexed(),

      /**
       * Brief bio or description.
       */
      bio: i.string().optional(),

      /**
       * When this person was added to the system.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),

      /**
       * Freeform metadata (birth date, nationality, etc.)
       * NOT queryable - use for display only.
       */
      metadata: i.json().optional(),
    }),

    /**
     * A piece of media content with a duration.
     *
     * Platform-agnostic: could originate from any source. The source is tracked
     * via external IDs, not embedded here.
     *
     * Types:
     * - "audio": Podcasts, audiobooks, music, voice recordings
     * - "video": Screen recordings, lectures, interviews
     * - "text": Articles, books, blog posts (duration = estimated read time)
     *
     * Examples:
     * - An audiobook ("A New Earth" by Eckhart Tolle - 8.5 hours)
     * - A podcast episode ("Lex Fridman #123")
     * - A local screen recording
     * - An article (duration = ~5 min read time)
     *
     * Links:
     * - files: MediaFiles storing this content locally/remotely
     * - segments: Named time ranges (chapters, sections)
     * - externalIds: Platform links (Audible ASIN, YouTube video ID, etc.)
     * - author: Speaker who created this (optional)
     * - narrator: Speaker who narrates (optional, for audiobooks)
     * - transcriptionRuns: Transcription processing runs
     * - diarizationRuns: Speaker diarization runs
     * - shazamCatalogEntries: Audio fingerprint entries
     */
    media: i.entity({
      /**
       * Title of the media.
       * Examples: "A New Earth", "Lex Fridman Podcast #123"
       */
      title: i.string().indexed(),

      /**
       * Type of media content.
       * - "audio": Sound-only content (podcasts, audiobooks, music)
       * - "video": Visual + audio content (screen recordings, lectures)
       * - "text": Written content (articles, books)
       */
      media_type: i.string().indexed(),

      /**
       * Total duration in seconds.
       * For text: estimated read time in seconds.
       */
      duration_seconds: i.number(),

      /**
       * Optional description or summary.
       */
      description: i.string().optional(),

      /**
       * When this media was added to our system.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),

      /**
       * When this media was originally published (if known).
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      published_at: i.string().optional(),

      /**
       * Freeform metadata (ISBN, language, etc.)
       * NOT queryable - use for display only.
       */
      source_metadata: i.json().optional(),
    }),

    /**
     * A file storing media content, either locally or remotely.
     *
     * Supports distributed caching: the same media may have files on multiple
     * machines. Query by machine_id to find files available locally.
     *
     * Machine identification: Use IOPlatformUUID on macOS (stable, unique per machine).
     * Get it via: ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID
     * Example: "CF17FBE0-0E64-5426-8FC8-00DB233891F4"
     *
     * Examples:
     * - Local MP3: machine_id="CF17FBE0-...", path="/Users/me/audiobooks/new-earth.mp3"
     * - Server copy: machine_id="ABC123...", path="/srv/audiobooks/new-earth.mp3"
     * - Remote URL: machine_id=null, remote_url="https://cdn.example.com/new-earth.mp3"
     *
     * Links:
     * - media: The Media entity this file belongs to
     */
    mediaFiles: i.entity({
      /**
       * Local filesystem path (if stored locally).
       * Examples: "/Users/me/audiobooks/new-earth.mp3"
       */
      path: i.string().indexed().optional(),

      /**
       * Remote URL (if accessible via HTTP/HTTPS).
       */
      remote_url: i.string().optional(),

      /**
       * IOPlatformUUID of the machine where this file exists.
       * null = remote URL only (not stored locally).
       * On macOS: ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID
       * Example: "CF17FBE0-0E64-5426-8FC8-00DB233891F4"
       */
      machine_id: i.string().indexed().optional(),

      /**
       * File format/extension.
       * Examples: "mp3", "aax", "mp4", "txt", "aaxc"
       */
      format: i.string().indexed().optional(),

      /**
       * MIME type of the file.
       * Examples: "audio/mpeg", "video/mp4", "text/plain"
       */
      mime_type: i.string().optional(),

      /**
       * File size in bytes.
       */
      size_bytes: i.number().optional(),

      /**
       * Protection/access requirements for this file.
       * Examples: { "requires_api_key": true, "service": "aws_s3" }
       * NOT queryable.
       */
      access_requirements: i.json().optional(),

      /**
       * When this file was added to the system.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),

      /**
       * When this file was last accessed/verified to exist.
       * Used for cache management. Must be updated manually by clients.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      last_accessed_at: i.string().optional(),
    }),

    /**
     * A named time range within media.
     *
     * Platform-agnostic: represents chapters, sections, tracks, or any named
     * portion of media. Can be nested (parent/child) for sub-chapters.
     *
     * Source types (how the segment was created):
     * - "import": Imported from external metadata
     * - "manual": Manually annotated by a user
     * - "auto": Auto-detected (silence detection, topic change, etc.)
     * - "script": Created by an ingestion script
     *
     * Source (where the data came from, when source_type is "import" or "script"):
     * - "audible_json": Audible chapter JSON file
     * - "youtube_api": YouTube Data API chapters
     * - "audio_ingestion.py": Our audio ingestion script
     * - etc.
     *
     * Examples:
     * - Audiobook chapter: "Chapter One: The Ego" (parent)
     * - Audiobook sub-chapter: "Evocation" (child of above)
     * - Podcast segment: "Interview", "Ad Break"
     *
     * Links:
     * - media: The Media this segment belongs to
     * - parent: Parent segment (for sub-chapters/nested sections)
     * - children: Child segments
     * - externalIds: Platform-specific deep links (optional)
     */
    segments: i.entity({
      /**
       * Title/name of this segment.
       * Examples: "Chapter One", "Introduction", "Ad Break"
       */
      title: i.string().indexed(),

      /**
       * Start time in milliseconds from media start.
       */
      start_time_ms: i.number().indexed(),

      /**
       * End time in milliseconds from media start.
       */
      end_time_ms: i.number().indexed(),

      /**
       * Duration in milliseconds (end_time_ms - start_time_ms).
       */
      length_ms: i.number(),

      /**
       * Position within siblings (1, 2, 3...).
       * Determined by start_time_ms order among segments at same nesting level.
       */
      ordinal: i.number().indexed(),

      /**
       * How this segment was created.
       * - "import": From external metadata
       * - "manual": User-annotated
       * - "auto": Auto-detected (silence, topic modeling)
       * - "script": Created by an ingestion script
       */
      source_type: i.string().indexed(),

      /**
       * Where the data came from (when source_type is "import" or "script").
       * Examples: "audible_json", "youtube_api", "audio_ingestion.py"
       */
      source: i.string().indexed().optional(),

      /**
       * Freeform metadata from the source.
       * Examples for "import" source_type:
       * - Audible: { "audible_chapter_id": "123", "original_title": "..." }
       * NOT queryable.
       */
      source_metadata: i.json().optional(),

      /**
       * When this segment was created.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),
    }),

    /**
     * An external platform where media or people can be found.
     *
     * Examples:
     * - YouTube (video, text posts)
     * - Audible (audiobooks)
     * - Spotify (podcasts, music)
     * - Twitter/X (profiles, posts, videos)
     * - Medium (articles)
     * - dev.to (articles)
     * - Wikipedia (reference)
     * - Wikidata (structured data)
     * - Libby (library audiobooks/ebooks)
     *
     * Links:
     * - externalMediaIds: Media linked to this platform
     * - externalPeopleIds: People linked to this platform
     * - externalSegmentIds: Segments linked to this platform
     */
    platforms: i.entity({
      /**
       * Platform name.
       * Examples: "YouTube", "Audible", "Spotify", "Medium", "Wikipedia", "Wikidata"
       */
      name: i.string().unique().indexed(),

      /**
       * Base URL for the platform.
       * Examples: "https://youtube.com", "https://audible.com", "https://wikidata.org"
       */
      base_url: i.string().optional(),

      /**
       * Types of content this platform hosts (array).
       * Each type should be addressable by URL on that platform.
       * Examples: ["video", "text"], ["audio"], ["text"]
       * Note: Stored as JSON since InstantDB doesn't have native arrays.
       */
      content_types: i.json().optional(),

      /**
       * When this platform was added.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),
    }),

    /**
     * Links media to an external platform with platform-specific identifiers.
     *
     * Examples:
     * - Audible: platform="Audible", external_id="B002V0RAUU",
     *   normalized_url="https://www.audible.com/pd/B002V0RAUU"
     * - YouTube: platform="YouTube", external_id="jNQXAC9IVRw",
     *   normalized_url="https://www.youtube.com/watch?v=jNQXAC9IVRw"
     *   (Note: YouTube has many URL formats - use yt-dlp's URL normalization)
     *
     * Links:
     * - media: The Media entity this refers to
     * - platform: The Platform this ID is on
     * - accessMetadata: Access restrictions (paywall, subscription, etc.)
     */
    externalMediaIds: i.entity({
      /**
       * Platform-specific identifier.
       * Examples: "B002V0RAUU" (ASIN), "jNQXAC9IVRw" (YouTube video ID)
       */
      external_id: i.string().indexed(),

      /**
       * Normalized deep link URL to the media on this platform.
       * Use canonical/normalized format (e.g., yt-dlp for YouTube).
       * Examples: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
       */
      normalized_url: i.string().indexed().optional(),

      /**
       * When this was published on the platform (if known).
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      external_published_at: i.string().optional(),

      /**
       * When we added this external link.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),
    }),

    /**
     * Links people to their profiles on external platforms.
     *
     * Examples:
     * - YouTube channel: platform="YouTube", external_id="UCxxxxxx",
     *   normalized_url="https://www.youtube.com/@lexfridman"
     * - Twitter: platform="Twitter", external_id="lexfridman",
     *   normalized_url="https://twitter.com/lexfridman"
     * - Wikidata: platform="Wikidata", external_id="Q123456",
     *   normalized_url="https://www.wikidata.org/wiki/Q123456"
     * - Wikipedia: platform="Wikipedia", external_id="Eckhart_Tolle",
     *   normalized_url="https://en.wikipedia.org/wiki/Eckhart_Tolle"
     *
     * Links:
     * - person: The People entity this refers to
     * - platform: The Platform this profile is on
     */
    externalPeopleIds: i.entity({
      /**
       * Platform-specific identifier.
       * Examples: "UCxxxxxx" (YouTube channel ID), "lexfridman" (Twitter handle),
       * "Q123456" (Wikidata ID), "Eckhart_Tolle" (Wikipedia article name)
       */
      external_id: i.string().indexed(),

      /**
       * Normalized URL to the profile.
       */
      normalized_url: i.string().indexed().optional(),

      /**
       * When this profile was created on the platform (if known).
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      external_created_at: i.string().optional(),

      /**
       * When we added this external link.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),
    }),

    /**
     * Links segments to platform-specific deep links.
     *
     * Examples:
     * - YouTube timestamp: normalized_url="https://www.youtube.com/watch?v=jNQXAC9IVRw&t=120"
     * - Spotify chapter: normalized_url="spotify:episode:xxx#t=120"
     *
     * Links:
     * - segment: The Segment entity this refers to
     * - platform: The Platform this link is on
     */
    externalSegmentIds: i.entity({
      /**
       * Platform-specific identifier (if any).
       */
      external_id: i.string().indexed().optional(),

      /**
       * Normalized deep link URL to this specific segment/timestamp.
       */
      normalized_url: i.string().indexed(),

      /**
       * When we added this external link.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),
    }),

    /**
     * Describes access restrictions for external media.
     *
     * Linked to ExternalMediaIds because access varies by platform:
     * - Same audiobook might be subscription on Audible, one-time on Apple Books,
     *   or free via Libby (library)
     * - Same video might be free on YouTube, paywalled on Nebula
     *
     * Access types (what gets in your way before you can access content):
     * - "free": No payment required, no account needed
     * - "free_with_ads": Free but has advertisements
     * - "account_required": Must create account (no additional payment)
     * - "subscription": Requires ongoing subscription (e.g., Audible, Netflix)
     * - "one_time_purchase": Single payment to own
     * - "rental": Temporary access for a fee
     *
     * Links:
     * - externalMediaId: The external media link this describes
     */
    accessMetadata: i.entity({
      /**
       * Type of access required.
       * Values: "free", "free_with_ads", "account_required", "subscription",
       *         "one_time_purchase", "rental"
       */
      access_type: i.string().indexed(),

      /**
       * Whether ads are shown.
       */
      has_ads: i.boolean().optional(),

      /**
       * Price in cents (if applicable).
       * null = varies or unknown
       */
      price_cents: i.number().optional(),

      /**
       * Currency code (if price is set).
       * Examples: "USD", "EUR"
       */
      currency: i.string().optional(),

      /**
       * When we last verified this access info.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      last_checked_at: i.string().optional(),

      /**
       * When this was created.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),
    }),

    // =========================================================================
    // LEGACY ENTITIES (kept for migration, will be deprecated)
    // =========================================================================
    diarizationConfigs: i.entity({
      additional_params: i.any().optional(),
      cluster_threshold: i.number().optional(),
      clustering_method: i.string().optional(),
      created_at: i.string(),
      embedding_model: i.string().indexed(),
      identification_threshold: i.number().optional(),
      tool: i.string().indexed(),
    }),
    diarizationRuns: i.entity({
      cost_usd: i.number().optional(),
      executed_at: i.string(),
      git_commit_sha: i.string().optional(),
      input_duration_seconds: i.number().optional(),
      is_preferred: i.boolean().indexed(),
      logs: i.any().optional(),
      num_speakers_detected: i.number().optional(),
      peak_memory_mb: i.number().optional(),
      pipeline_script: i.string().optional(),
      processing_time_seconds: i.number().optional(),
      tool_version: i.string().optional(),
      workflow: i.string().indexed(),
    }),
    diarizationSegments: i.entity({
      confidence: i.number().optional(),
      created_at: i.string(),
      embedding_id: i.string().optional(),
      end_time: i.number().indexed(),
      is_invalidated: i.boolean().optional(),
      speaker_label: i.string().indexed(),
      start_time: i.number().indexed(),
    }),
    publications: i.entity({
      external_id: i.string().indexed().optional(),
      ingested_at: i.string(),
      name: i.string().indexed(),
      publication_type: i.string().indexed(),
      raw_metadata: i.any().optional(),
      url: i.string().unique().indexed(),
    }),
    segmentSplits: i.entity({
      split_at: i.string(),
      split_by: i.string().indexed(),
      split_time: i.number(),
    }),
    shazamCatalogEntries: i.entity({
      catalog_version: i.string().optional(),
      cataloged_at: i.string().optional(),
      end_time: i.number().optional(),
      media_item_id: i.string().optional(),
      start_time: i.number().optional(),
    }),
    shazamMatches: i.entity({
      artist: i.string(),
      created_at: i.string(),
      end_time: i.number(),
      match_offset: i.number().optional(),
      shazam_track_id: i.string().indexed(),
      start_time: i.number().indexed(),
      title: i.string(),
    }),
    speakerAssignments: i.entity({
      assigned_at: i.string(),
      assigned_by: i.string().indexed(),
      confidence: i.number().optional(),
      note: i.string().optional(),
      source: i.string().indexed(),
    }),
    /**
     * A person who speaks in media.
     *
     * Speakers link a Person to their speaking roles. A person can have multiple
     * speaker entries (different roles, different media, different segments).
     *
     * Note: Voice embeddings are stored in PostgreSQL (pgvector) and linked
     * via the speakerAssignments entity, not directly on speakers.
     *
     * Examples:
     * - Eckhart Tolle as narrator of "A New Earth"
     * - Eckhart Tolle as interviewee on a podcast (different speaker entry)
     *
     * Links:
     * - person: The People entity this speaker is
     * - authoredMedia: Media where this speaker is the author
     * - narratedMedia: Media where this speaker is the narrator
     * - speakerAssignments: Diarization assignments
     *
     * LEGACY FIELDS (kept for migration):
     * - name: Use person.name instead
     * - embedding_centroid_id: Use speakerAssignments instead
     */
    speakers: i.entity({
      /**
       * Role/label for this speaker instance.
       * Examples: "narrator", "host", "guest", "SPEAKER_00"
       */
      role: i.string().indexed().optional(),

      /**
       * Whether this is a human speaker (vs. AI/TTS).
       */
      is_human: i.boolean(),

      /**
       * When this speaker was created.
       * Format: ISO 8601 (e.g., "2025-12-16T14:30:00Z")
       */
      ingested_at: i.string(),

      /**
       * Freeform metadata.
       * Examples: { "voice_description": "deep male voice", "accent": "British" }
       * NOT queryable.
       */
      metadata: i.json().optional(),

      // LEGACY FIELDS (kept for migration)
      /**
       * @deprecated Use person.name instead via the person link
       */
      name: i.string().indexed().optional(),

      /**
       * @deprecated Use speakerAssignments for embedding links
       */
      embedding_centroid_id: i.string().optional(),
    }),
    transcriptionConfigs: i.entity({
      additional_params: i.any().optional(),
      beam_size: i.number().optional(),
      created_at: i.string(),
      language: i.string().optional(),
      model: i.string().indexed(),
      temperature: i.number().optional(),
      tool: i.string().indexed(),
      vad_filter: i.boolean().optional(),
      word_timestamps: i.boolean(),
    }),
    transcriptionRuns: i.entity({
      cost_usd: i.number().optional(),
      executed_at: i.string(),
      git_commit_sha: i.string().optional(),
      input_duration_seconds: i.number().optional(),
      is_preferred: i.boolean().indexed(),
      logs: i.any().optional(),
      peak_memory_mb: i.number().optional(),
      pipeline_script: i.string().optional(),
      processing_time_seconds: i.number().optional(),
      tool_version: i.string(),
    }),
    videos: i.entity({
      description: i.string().optional(),
      duration: i.number(),
      external_published_at: i.string().optional(),
      filepath: i.string().optional(),
      ingested_at: i.string(),
      raw_metadata: i.any().optional(),
      source_id: i.string().optional(),
      title: i.string(),
      url: i.string().unique().indexed(),
    }),
    words: i.entity({
      confidence: i.number().optional(),
      end_time: i.number().indexed(),
      ingested_at: i.string(),
      start_time: i.number().indexed(),
      text: i.string(),
      transcription_segment_index: i.number().optional(),
    }),
    wordTextCorrections: i.entity({
      corrected_at: i.string(),
      corrected_by: i.string().indexed(),
      corrected_text: i.string(),
      note: i.string().optional(),
    }),
    /**
     * Audiobook entity for tracking audiobook metadata.
     * Links to speakers (narrator, author) and chapters.
     * Note: narrator and author are stored as links to speakers, not as string fields.
     */
    audiobooks: i.entity({
      title: i.string().indexed(),
      asin: i.string().unique().indexed().optional(),
      sku: i.string().indexed().optional(),
      runtime_seconds: i.number(),
      chapter_count: i.number(),
      ingested_at: i.string(),
      raw_metadata: i.json().optional(),
    }),
    /**
     * Audiobook chapter entity for tracking chapter/sub-chapter metadata.
     * Chapters have timestamps (start_time_ms, end_time_ms) rather than page numbers.
     * Sub-chapters link to their parent chapter via the parent link.
     */
    audiobookChapters: i.entity({
      title: i.string().indexed(),
      chapter_number: i.number().indexed(),
      start_time_ms: i.number().indexed(),
      end_time_ms: i.number().indexed(),
      length_ms: i.number(),
      is_subchapter: i.boolean().indexed(),
      parent_chapter_number: i.number().optional(),
      ingested_at: i.string(),
    }),
  },
  links: {
    // =========================================================================
    // NEW LINKS (Platform-Free Schema Redesign)
    // =========================================================================

    /**
     * Link speakers to their person (People entity).
     * A speaker is a person in a specific speaking role.
     */
    speakersPerson: {
      forward: {
        on: "speakers",
        has: "one",
        label: "person",
      },
      reverse: {
        on: "people",
        has: "many",
        label: "speakers",
      },
    },

    /**
     * Link external people IDs to their person.
     */
    externalPeopleIdsPerson: {
      forward: {
        on: "externalPeopleIds",
        has: "one",
        label: "person",
      },
      reverse: {
        on: "people",
        has: "many",
        label: "externalIds",
      },
    },

    /**
     * Link external people IDs to their platform.
     */
    externalPeopleIdsPlatform: {
      forward: {
        on: "externalPeopleIds",
        has: "one",
        label: "platform",
      },
      reverse: {
        on: "platforms",
        has: "many",
        label: "externalPeopleIds",
      },
    },

    /**
     * Link media files to their media.
     */
    mediaFilesMedia: {
      forward: {
        on: "mediaFiles",
        has: "one",
        label: "media",
      },
      reverse: {
        on: "media",
        has: "many",
        label: "files",
      },
    },

    /**
     * Link segments to their media.
     */
    segmentsMedia: {
      forward: {
        on: "segments",
        has: "one",
        label: "media",
      },
      reverse: {
        on: "media",
        has: "many",
        label: "segments",
      },
    },

    /**
     * Link segments to their parent segment (for sub-chapters/nested sections).
     */
    segmentsParent: {
      forward: {
        on: "segments",
        has: "one",
        label: "parent",
      },
      reverse: {
        on: "segments",
        has: "many",
        label: "children",
      },
    },

    /**
     * Link external media IDs to their media.
     */
    externalMediaIdsMedia: {
      forward: {
        on: "externalMediaIds",
        has: "one",
        label: "media",
      },
      reverse: {
        on: "media",
        has: "many",
        label: "externalIds",
      },
    },

    /**
     * Link external media IDs to their platform.
     */
    externalMediaIdsPlatform: {
      forward: {
        on: "externalMediaIds",
        has: "one",
        label: "platform",
      },
      reverse: {
        on: "platforms",
        has: "many",
        label: "externalMediaIds",
      },
    },

    /**
     * Link external segment IDs to their segment.
     */
    externalSegmentIdsSegment: {
      forward: {
        on: "externalSegmentIds",
        has: "one",
        label: "segment",
      },
      reverse: {
        on: "segments",
        has: "many",
        label: "externalIds",
      },
    },

    /**
     * Link external segment IDs to their platform.
     */
    externalSegmentIdsPlatform: {
      forward: {
        on: "externalSegmentIds",
        has: "one",
        label: "platform",
      },
      reverse: {
        on: "platforms",
        has: "many",
        label: "externalSegmentIds",
      },
    },

    /**
     * Link access metadata to its external media ID.
     */
    accessMetadataExternalMediaId: {
      forward: {
        on: "accessMetadata",
        has: "one",
        label: "externalMediaId",
      },
      reverse: {
        on: "externalMediaIds",
        has: "one",
        label: "accessMetadata",
      },
    },

    /**
     * Link media to its author (Speaker entity).
     */
    mediaAuthor: {
      forward: {
        on: "media",
        has: "one",
        label: "author",
      },
      reverse: {
        on: "speakers",
        has: "many",
        label: "authoredMedia",
      },
    },

    /**
     * Link media to its narrator (Speaker entity, for audiobooks).
     */
    mediaNarrator: {
      forward: {
        on: "media",
        has: "one",
        label: "narrator",
      },
      reverse: {
        on: "speakers",
        has: "many",
        label: "narratedMedia",
      },
    },

    /**
     * Link shazam catalog entries to media (new entity).
     */
    shazamCatalogEntriesMedia: {
      forward: {
        on: "shazamCatalogEntries",
        has: "one",
        label: "media",
      },
      reverse: {
        on: "media",
        has: "many",
        label: "shazamCatalogEntries",
      },
    },

    /**
     * Link diarization runs to media (new entity).
     */
    mediaDiarizationRuns: {
      forward: {
        on: "media",
        has: "many",
        label: "diarizationRuns",
      },
      reverse: {
        on: "diarizationRuns",
        has: "one",
        label: "media",
      },
    },

    /**
     * Link transcription runs to media (new entity).
     */
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

    // =========================================================================
    // LEGACY LINKS (kept for migration)
    // =========================================================================

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
    diarizationRunsConfig: {
      forward: {
        on: "diarizationRuns",
        has: "one",
        label: "config",
      },
      reverse: {
        on: "diarizationConfigs",
        has: "many",
        label: "diarizationRuns",
      },
    },
    diarizationRunsDiarizationSegments: {
      forward: {
        on: "diarizationRuns",
        has: "many",
        label: "diarizationSegments",
      },
      reverse: {
        on: "diarizationSegments",
        has: "one",
        label: "diarizationRun",
      },
    },
    diarizationSegmentsSpeakerAssignments: {
      forward: {
        on: "diarizationSegments",
        has: "many",
        label: "speakerAssignments",
      },
      reverse: {
        on: "speakerAssignments",
        has: "one",
        label: "diarizationSegment",
      },
    },
    segmentSplitsOriginalSegment: {
      forward: {
        on: "segmentSplits",
        has: "one",
        label: "originalSegment",
      },
      reverse: {
        on: "diarizationSegments",
        has: "many",
        label: "splits",
      },
    },
    segmentSplitsResultingSegments: {
      forward: {
        on: "segmentSplits",
        has: "many",
        label: "resultingSegments",
      },
      reverse: {
        on: "diarizationSegments",
        has: "one",
        label: "createdFromSplit",
      },
    },
    shazamCatalogEntriesVideo: {
      forward: {
        on: "shazamCatalogEntries",
        has: "one",
        label: "video",
      },
      reverse: {
        on: "videos",
        has: "many",
        label: "shazamCatalogEntries",
      },
    },
    speakerAssignmentsSpeaker: {
      forward: {
        on: "speakerAssignments",
        has: "one",
        label: "speaker",
      },
      reverse: {
        on: "speakers",
        has: "many",
        label: "speakerAssignments",
      },
    },
    speakersPublications: {
      forward: {
        on: "speakers",
        has: "many",
        label: "publications",
      },
      reverse: {
        on: "publications",
        has: "many",
        label: "regularSpeakers",
      },
    },
    transcriptionRunsConfig: {
      forward: {
        on: "transcriptionRuns",
        has: "one",
        label: "config",
      },
      reverse: {
        on: "transcriptionConfigs",
        has: "many",
        label: "transcriptionRuns",
      },
    },
    transcriptionRunsWords: {
      forward: {
        on: "transcriptionRuns",
        has: "many",
        label: "words",
      },
      reverse: {
        on: "words",
        has: "one",
        label: "transcriptionRun",
      },
    },
    videosDiarizationRuns: {
      forward: {
        on: "videos",
        has: "many",
        label: "diarizationRuns",
      },
      reverse: {
        on: "diarizationRuns",
        has: "one",
        label: "video",
      },
    },
    videosPublication: {
      forward: {
        on: "videos",
        has: "one",
        label: "publication",
      },
      reverse: {
        on: "publications",
        has: "many",
        label: "videos",
      },
    },
    videosShazamMatches: {
      forward: {
        on: "videos",
        has: "many",
        label: "shazamMatches",
      },
      reverse: {
        on: "shazamMatches",
        has: "one",
        label: "video",
      },
    },
    videosTranscriptionRuns: {
      forward: {
        on: "videos",
        has: "many",
        label: "transcriptionRuns",
      },
      reverse: {
        on: "transcriptionRuns",
        has: "one",
        label: "video",
      },
    },
    wordsTextCorrections: {
      forward: {
        on: "words",
        has: "many",
        label: "textCorrections",
      },
      reverse: {
        on: "wordTextCorrections",
        has: "one",
        label: "word",
      },
    },
    /**
     * Link audiobook to its narrator (speaker entity).
     */
    audiobooksNarrator: {
      forward: {
        on: "audiobooks",
        has: "one",
        label: "narrator",
      },
      reverse: {
        on: "speakers",
        has: "many",
        label: "narratedAudiobooks",
      },
    },
    /**
     * Link audiobook to its author (speaker entity, optional - author may also be narrator).
     */
    audiobooksAuthor: {
      forward: {
        on: "audiobooks",
        has: "one",
        label: "author",
      },
      reverse: {
        on: "speakers",
        has: "many",
        label: "authoredAudiobooks",
      },
    },
    /**
     * Link chapters to their audiobook.
     */
    audiobookChaptersAudiobook: {
      forward: {
        on: "audiobookChapters",
        has: "one",
        label: "audiobook",
      },
      reverse: {
        on: "audiobooks",
        has: "many",
        label: "chapters",
      },
    },
    /**
     * Link sub-chapters to their parent chapter.
     */
    audiobookChaptersParent: {
      forward: {
        on: "audiobookChapters",
        has: "one",
        label: "parentChapter",
      },
      reverse: {
        on: "audiobookChapters",
        has: "many",
        label: "subchapters",
      },
    },
    /**
     * Link video (audio file) to its audiobook.
     * A video can be a chapter clip from an audiobook.
     */
    videosAudiobook: {
      forward: {
        on: "videos",
        has: "one",
        label: "audiobook",
      },
      reverse: {
        on: "audiobooks",
        has: "many",
        label: "audioFiles",
      },
    },
    /**
     * Link video (audio file) to its chapter.
     * Used when a video represents a specific chapter clip.
     */
    videosAudiobookChapter: {
      forward: {
        on: "videos",
        has: "one",
        label: "audiobookChapter",
      },
      reverse: {
        on: "audiobookChapters",
        has: "many",
        label: "audioFiles",
      },
    },
  },
  rooms: {},
});

// This helps Typescript display nicer intellisense
type _AppSchema = typeof _schema;
interface AppSchema extends _AppSchema {}
const schema: AppSchema = _schema;

export type { AppSchema };
export default schema;