
import { init } from '@instantdb/core';

// App ID from the swift logs
const APP_ID = 'b9319949-2f2d-410b-8f8a-6990177c1d44';

const db = init({ appId: APP_ID });

async function verify() {
    console.log("Querying profiles with posts and comments...");

    const query = {
        profiles: {
            posts: {
                comments: {}
            }
        }
    };

    return new Promise<void>((resolve) => {
        // Cast to any to bypass TS checks for quick script
        const unsubscribe = (db as any).subscribeQuery(query, (result: any) => {
            if (result.data) {
                console.log("Result:", JSON.stringify(result.data, null, 2));

                const profiles = result.data.profiles || [];
                console.log(`Found ${profiles.length} profiles.`);

                profiles.forEach((p: any) => {
                    console.log(`Profile: ${p.displayName} (${p.id})`);
                    const posts = p.posts || [];
                    console.log(`  Posts: ${posts.length}`);
                    posts.forEach((post: any) => {
                        console.log(`    Post: ${post.content} (${post.id})`);
                        const comments = post.comments || [];
                        console.log(`    Comments: ${comments.length}`);
                        comments.forEach((c: any) => {
                            console.log(`      Comment: ${c.text}`);
                        });
                    });
                });

                unsubscribe();
                resolve();
            } else if (result.error) {
                console.error("Error:", result.error);
                unsubscribe();
                resolve();
            }
        });
    });
}

verify();
