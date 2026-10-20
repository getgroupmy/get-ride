/**
 * Every payment gateway the admin can add, by provider id — the same list,
 * in the same order, as `gatewayProviders` in
 * lib/src/admin/screens/commerce/commerce_logic.dart, with the same secret
 * fields as payment_gateway_secret_fields() in
 * supabase/migrations/0252_payment_gateways.sql (registry_test.ts checks
 * all three).
 */
import { adyen } from "./adyen.ts";
import { airwallex } from "./airwallex.ts";
import { billplz } from "./billplz.ts";
import { curlec } from "./curlec.ts";
import { eghl } from "./eghl.ts";
import { fiuu } from "./fiuu.ts";
import { hitpay } from "./hitpay.ts";
import { ipay88 } from "./ipay88.ts";
import { adaptis, paydibs, payhalal } from "./not_ready.ts";
import { paypal } from "./paypal.ts";
import { senangpay } from "./senangpay.ts";
import { stripe } from "./stripe.ts";
import { toyyibpay } from "./toyyibpay.ts";
import { twoc2p } from "./twoc2p.ts";
import type { Adapter } from "./types.ts";
import { xendit } from "./xendit.ts";

export const ADAPTER_LIST: Adapter[] = [
  stripe,
  fiuu,
  adaptis,
  ipay88,
  eghl,
  senangpay,
  billplz,
  hitpay,
  paypal,
  airwallex,
  payhalal,
  toyyibpay,
  paydibs,
  curlec,
  twoc2p,
  adyen,
  xendit,
];

export const ADAPTERS: Record<string, Adapter> = Object.fromEntries(ADAPTER_LIST.map((a) => [a.id, a]));

/** What Admin → Payment Gateways shows of each adapter (GET /payments/providers). */
export const providerInfo = () =>
  ADAPTER_LIST.map((a) => ({
    id: a.id,
    name: a.name,
    ready: a.ready,
    verified: a.verified,
    lookup: typeof a.lookup === "function",
    dashboardUrls: a.dashboardUrls === true,
    notes: a.notes,
  }));
