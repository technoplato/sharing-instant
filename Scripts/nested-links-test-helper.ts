/**
 * HOW:
 *   npx ts-node scripts/nested-links-test-helper.ts --action seed --app-id <id> --admin-token <token>
 *   npx ts-node scripts/nested-links-test-helper.ts --action verify --app-id <id> --admin-token <token>
 *   npx ts-node scripts/nested-links-test-helper.ts --action verify-writes --app-id <id> --admin-token <token> --profile-id <id>
 *   npx ts-node scripts/nested-links-test-helper.ts --action cleanup --app-id <id> --admin-token <token>
 *
 *   [Inputs]
 *   - --action: 'seed' | 'verify' | 'verify-writes' | 'cleanup'
 *   - --app-id: InstantDB app ID
 *   - --admin-token: Admin token for the app
 *   - --profile-id: (verify-writes only) Profile ID to verify
 *   - --json: Output JSON instead of human-readable text
 *
 *   [Outputs]
 *   - JSON object with { success: boolean, data?: any, error?: string }
 *
 *   [Side Effects]
 *   - seed: Creates test data with deeply nested relationships
 *   - cleanup: Deletes all test data
 *
 * WHO:
 *   Agent, User
 *   (Context: Integration testing for nested link resolution in Swift SDK)
 *
 * WHAT:
 *   A helper script for Swift integration tests that need to:
 *   1. Set up known data structures with deeply nested relationships
 *   2. Verify data was written correctly by the Swift SDK
 *   3. Clean up test data after tests complete
 *
 *   This serves as the "ground truth" for testing the Swift SDK's ability to:
 *   - Read deeply nested linked data (profiles.posts.comments)
 *   - Write data with proper link resolution
 *   - Handle both has-one and has-many relationships
 *
 * WHEN:
 *   2025-12-26
 *   Last Modified: 2025-12-26
 *   [Change Log:
 *     - 2025-12-26: Initial creation for nested link integration tests
 *   ]
 *
 * WHERE:
 *   sharing-instant/scripts/nested-links-test-helper.ts
 *
 * WHY:
 *   To provide a reliable, independent source of truth for verifying Swift SDK behavior.
 *   The Admin SDK bypasses client-side caching and decoding, giving us direct access
 *   to what the backend actually stores and returns.
 */

import { init, id, tx } from "@instantdb/admin";

// Parse command line arguments
const args = process.argv.slice(2);
const getArg = (name: string): string | undefined => {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : undefined;
};
const hasFlag = (name: string): boolean => args.includes(`--${name}`);

const action = getArg("action");
const appId = getArg("app-id");
const adminToken = getArg("admin-token");
const profileId = getArg("profile-id");
const jsonOutput = hasFlag("json");

function output(result: { success: boolean; data?: any; error?: string }) {
  if (jsonOutput) {
    console.log(JSON.stringify(result));
  } else {
    if (result.success) {
      console.log("✅ Success");
      if (result.data) {
        console.log(JSON.stringify(result.data, null, 2));
      }
    } else {
      console.error("❌ Error:", result.error);
    }
  }
  process.exit(result.success ? 0 : 1);
}

if (!action || !appId || !adminToken) {
  output({
    success: false,
    error:
      "Missing required arguments. Usage: --action <seed|verify|verify-writes|cleanup> --app-id <id> --admin-token <token>",
  });
}

const db = init({ appId: appId!, adminToken: adminToken! });

// Test data IDs - deterministic for easy cleanup
const TEST_PREFIX = "nested-link-test";
const PROFILE_ID = `${TEST_PREFIX}-profile-1`;
const POST_1_ID = `${TEST_PREFIX}-post-1`;
const POST_2_ID = `${TEST_PREFIX}-post-2`;
const COMMENT_1_ID = `${TEST_PREFIX}-comment-1`;
const COMMENT_2_ID = `${TEST_PREFIX}-comment-2`;
const COMMENT_3_ID = `${TEST_PREFIX}-comment-3`;

async function seed() {
  const now = Date.now();

  // Create profile
  await db.transact([
    tx.profiles[PROFILE_ID].update({
      displayName: "Test User",
      handle: `test-${now}`,
      createdAt: now,
    }),
  ]);

  // Create posts linked to profile
  await db.transact([
    tx.posts[POST_1_ID]
      .update({
        content: "First post content",
        createdAt: now,
        likesCount: 5,
      })
      .link({ author: PROFILE_ID }),
    tx.posts[POST_2_ID]
      .update({
        content: "Second post content",
        createdAt: now + 1000,
        likesCount: 10,
      })
      .link({ author: PROFILE_ID }),
  ]);

  // Create comments linked to posts and profile
  await db.transact([
    tx.comments[COMMENT_1_ID]
      .update({
        text: "Comment on first post",
        createdAt: now,
      })
      .link({ post: POST_1_ID, author: PROFILE_ID }),
    tx.comments[COMMENT_2_ID]
      .update({
        text: "Another comment on first post",
        createdAt: now + 500,
      })
      .link({ post: POST_1_ID, author: PROFILE_ID }),
    tx.comments[COMMENT_3_ID]
      .update({
        text: "Comment on second post",
        createdAt: now + 1500,
      })
      .link({ post: POST_2_ID, author: PROFILE_ID }),
  ]);

  output({
    success: true,
    data: {
      profileId: PROFILE_ID,
      postIds: [POST_1_ID, POST_2_ID],
      commentIds: [COMMENT_1_ID, COMMENT_2_ID, COMMENT_3_ID],
    },
  });
}

async function verify() {
  // Query with deeply nested relationships
  const result = await db.query({
    profiles: {
      $: { where: { id: PROFILE_ID } },
      posts: {
        comments: {},
      },
    },
  });

  const profile = result.profiles?.[0] as any;
  if (!profile) {
    output({ success: false, error: `Profile ${PROFILE_ID} not found` });
    return;
  }

  const posts = profile.posts || [];
  const assertions: string[] = [];

  // Verify profile
  if (profile.displayName !== "Test User") {
    assertions.push(
      `Expected displayName "Test User", got "${profile.displayName}"`
    );
  }

  // Verify posts (has-many from profile)
  if (posts.length !== 2) {
    assertions.push(`Expected 2 posts, got ${posts.length}`);
  }

  // Verify nested comments on posts
  const post1 = posts.find((p: any) => p.id === POST_1_ID);
  const post2 = posts.find((p: any) => p.id === POST_2_ID);

  if (!post1) {
    assertions.push(`Post ${POST_1_ID} not found in profile.posts`);
  } else {
    const comments1 = post1.comments || [];
    if (comments1.length !== 2) {
      assertions.push(
        `Expected 2 comments on post1, got ${comments1.length}`
      );
    }
  }

  if (!post2) {
    assertions.push(`Post ${POST_2_ID} not found in profile.posts`);
  } else {
    const comments2 = post2.comments || [];
    if (comments2.length !== 1) {
      assertions.push(
        `Expected 1 comment on post2, got ${comments2.length}`
      );
    }
  }

  if (assertions.length > 0) {
    output({
      success: false,
      error: assertions.join("; "),
      data: { profile, assertions },
    });
  } else {
    output({
      success: true,
      data: {
        profile: {
          id: profile.id,
          displayName: profile.displayName,
          postsCount: posts.length,
          post1CommentsCount: post1?.comments?.length || 0,
          post2CommentsCount: post2?.comments?.length || 0,
        },
      },
    });
  }
}

async function verifyWrites() {
  if (!profileId) {
    output({
      success: false,
      error: "Missing --profile-id for verify-writes action",
    });
    return;
  }

  // Query the profile created by Swift SDK with nested data
  const result = await db.query({
    profiles: {
      $: { where: { id: profileId } },
      posts: {
        comments: {},
      },
    },
  });

  const profile = result.profiles?.[0] as any;
  if (!profile) {
    output({ success: false, error: `Profile ${profileId} not found` });
    return;
  }

  output({
    success: true,
    data: {
      profile: {
        id: profile.id,
        displayName: profile.displayName,
        handle: profile.handle,
        posts: (profile.posts || []).map((p: any) => ({
          id: p.id,
          content: p.content,
          commentsCount: (p.comments || []).length,
          comments: (p.comments || []).map((c: any) => ({
            id: c.id,
            text: c.text,
          })),
        })),
      },
    },
  });
}

async function cleanup() {
  try {
    // Delete in reverse order of dependencies
    await db.transact([
      tx.comments[COMMENT_1_ID].delete(),
      tx.comments[COMMENT_2_ID].delete(),
      tx.comments[COMMENT_3_ID].delete(),
    ]);

    await db.transact([
      tx.posts[POST_1_ID].delete(),
      tx.posts[POST_2_ID].delete(),
    ]);

    await db.transact([tx.profiles[PROFILE_ID].delete()]);

    output({ success: true, data: { deleted: true } });
  } catch (error: any) {
    // Ignore errors from already-deleted entities
    output({ success: true, data: { deleted: true, note: "Some entities may have been already deleted" } });
  }
}

// Main
(async () => {
  try {
    switch (action) {
      case "seed":
        await seed();
        break;
      case "verify":
        await verify();
        break;
      case "verify-writes":
        await verifyWrites();
        break;
      case "cleanup":
        await cleanup();
        break;
      default:
        output({
          success: false,
          error: `Unknown action: ${action}. Expected: seed, verify, verify-writes, cleanup`,
        });
    }
  } catch (error: any) {
    output({ success: false, error: error.message || String(error) });
  }
})();

