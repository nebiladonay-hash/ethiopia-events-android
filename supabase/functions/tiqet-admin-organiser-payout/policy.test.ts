import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { canTransitionOrganiserPayout } from "./policy.ts";

Deno.test("requested payouts can only be approved or rejected", () => {
  assertEquals(canTransitionOrganiserPayout("requested", "approved"), true);
  assertEquals(canTransitionOrganiserPayout("requested", "rejected"), true);
  assertEquals(canTransitionOrganiserPayout("requested", "processing"), false);
  assertEquals(canTransitionOrganiserPayout("requested", "paid"), false);
});

Deno.test("approved payouts must enter processing before payment confirmation", () => {
  assertEquals(canTransitionOrganiserPayout("approved", "processing"), true);
  assertEquals(canTransitionOrganiserPayout("approved", "rejected"), true);
  assertEquals(canTransitionOrganiserPayout("approved", "paid"), false);
});

Deno.test("processing payouts can complete or fail", () => {
  assertEquals(canTransitionOrganiserPayout("processing", "paid"), true);
  assertEquals(canTransitionOrganiserPayout("processing", "failed"), true);
  assertEquals(canTransitionOrganiserPayout("processing", "reversed"), false);
});

Deno.test("a paid payout can only move to a verified reversal", () => {
  assertEquals(canTransitionOrganiserPayout("paid", "reversed"), true);
  assertEquals(canTransitionOrganiserPayout("paid", "failed"), false);
  assertEquals(canTransitionOrganiserPayout("paid", "pending"), false);
});

Deno.test("rejected, failed and reversed states are terminal", () => {
  for (const status of ["rejected", "failed", "reversed"]) {
    assertEquals(canTransitionOrganiserPayout(status, "approved"), false);
    assertEquals(canTransitionOrganiserPayout(status, "processing"), false);
    assertEquals(canTransitionOrganiserPayout(status, "paid"), false);
  }
});
