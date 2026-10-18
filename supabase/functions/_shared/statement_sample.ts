/**
 * A made-up statement for Admin → Partner statements → Layout's sample PDF:
 * the real company header, a partner and trips that do not exist.
 */
import type { Lang, PeriodType, StatementData, Totals } from "./partner_statement.ts";

function totals(trips: number): Totals {
  const fare = 22 * trips, surcharges = 1.5 * trips, tolls = 0.8 * trips;
  const commission = +(fare * 0.15).toFixed(2);
  const platformFees = Math.ceil(trips / 10), incentives = 10 * Math.ceil(trips / 20);
  const totalEarnings = +(fare + surcharges + incentives).toFixed(2);
  const totalDeductions = +(commission + platformFees).toFixed(2);
  return {
    fare, surcharges, platformCollected: 0, surchargesPass: 0, taxes: 0, tolls, otherCharges: 0, commission, platformFees,
    coins: +(fare * 0.05).toFixed(2), cash: +(fare * 0.6).toFixed(2), distanceKm: 9.5 * trips, trips, incentives,
    handoverIn: 0, handoverOut: 0, adjustments: trips > 20 ? -2 : 0, onlineHours: 1.6 * trips, totalEarnings,
    totalDeductions, net: +(totalEarnings - totalDeductions - (trips > 20 ? 2 : 0)).toFixed(2), passThrough: tolls,
  };
}

const pad = (n: number) => String(n).padStart(2, "0");

export function sampleStatement(type: PeriodType, lang: Lang, company: StatementData["company"]): StatementData {
  const base = {
    status: "final" as const,
    lang,
    company,
    weekStart: "monday",
    partner: {
      name: "Ahmad Bin Ali", displayId: "GR201A", ic: "******-**-5678", plate: "WXY 201",
      bank: { bank: "Maybank", account: "****4321", holder: "AHMAD BIN ALI" },
    },
    incentives: [{ at: "2026-09-09T00:00:00Z", label: "Rainy day bonus", amount: 10 }],
    adjustments: type === "weekly" ? [] : [{ at: "2026-09-18T04:00:00Z", reason: "Toll refunded twice", amount: -2 }],
  };
  if (type === "weekly") {
    const perDay = [1, 2, 0, 1, 2, 3, 0];
    return {
      ...base, type, periodStart: "2026-09-07", periodEnd: "2026-09-13", totals: totals(9),
      breakdown: perDay.map((n, i) => ({ start: `2026-09-${pad(7 + i)}`, totals: totals(n) })),
      trips: Array.from({ length: 9 }, (_, i) => ({
        at: `2026-09-${pad(7 + (i % 7))}T0${1 + (i % 8)}:15:00Z`, service: i % 3 ? "car" : "comfort",
        pickup: "KLCC", drop: "KL Sentral", payment: i % 2 ? "cash" : "wallet",
        lines: { fare: 22, surcharges: 1.5, tolls: 0.8, commission: 3.3 },
      })),
    };
  }
  if (type === "monthly") {
    const weeks: [string, string, number][] = [
      ["2026-09-01", "2026-09-06", 14], ["2026-09-07", "2026-09-13", 21], ["2026-09-14", "2026-09-20", 24],
      ["2026-09-21", "2026-09-27", 17], ["2026-09-28", "2026-09-30", 8],
    ];
    return {
      ...base, type, periodStart: "2026-09-01", periodEnd: "2026-09-30", totals: totals(84), trips: [],
      breakdown: weeks.map(([start, end, n]) => ({ start, end, totals: totals(n) })),
    };
  }
  return {
    ...base, type, periodStart: "2025-01-01", periodEnd: "2025-12-31", totals: totals(960), trips: [],
    breakdown: Array.from({ length: 12 }, (_, i) => ({ start: `2025-${pad(i + 1)}-01`, totals: totals(70 + i * 3) })),
  };
}
