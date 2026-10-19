/**
 * Test traffic (migration 0241): whether a caller is one of the tester
 * accounts the admin lists, so the speed and usage figures can label their
 * calls. The user id must be one the function verified from the caller's JWT
 * (auth.getUser), never a value the client sent.
 *
 * The answer only labels a log row or a counter. Nothing may use it to skip
 * a rate limit, a payment, a security check or a real side effect.
 */

/** Asks the database (`is_test_account`) whether [uid] is a tester. */
export type TestAccountLookup = (uid: string) => Promise<boolean>;

/**
 * A cached check: each id is looked up at most once per [ttlMs] per
 * instance. A failed lookup (or a database without migration 0241) answers
 * false — real traffic — and is not remembered.
 */
export function testAccountCheck(
  lookup: TestAccountLookup,
  { ttlMs = 60_000, max = 5000, now = () => Date.now() }: { ttlMs?: number; max?: number; now?: () => number } = {},
): (uid: string | null | undefined) => Promise<boolean> {
  const known = new Map<string, { test: boolean; at: number }>();
  return async (uid) => {
    if (!uid) return false;
    const hit = known.get(uid);
    if (hit && now() - hit.at < ttlMs) return hit.test;
    let test: boolean;
    try {
      test = (await lookup(uid)) === true;
    } catch {
      return false;
    }
    if (known.size >= max) known.clear();
    known.set(uid, { test, at: now() });
    return test;
  };
}

/** The `is_test_account` call through a service-role client's `rpc`. */
export function rpcTestAccountLookup(
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>,
): TestAccountLookup {
  return async (uid) => {
    const { data, error } = await rpc("is_test_account", { p_uid: uid });
    if (error) throw error;
    return data === true;
  };
}
