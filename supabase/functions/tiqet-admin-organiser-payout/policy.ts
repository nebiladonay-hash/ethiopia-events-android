export const organiserPayoutTransitions: Readonly<Record<string, ReadonlySet<string>>> = {
  requested: new Set(["approved", "rejected"]),
  approved: new Set(["processing", "rejected", "failed"]),
  processing: new Set(["paid", "failed"]),
  paid: new Set(["reversed"]),
  rejected: new Set(),
  failed: new Set(),
  reversed: new Set(),
};

export function canTransitionOrganiserPayout(current: string, next: string): boolean {
  return organiserPayoutTransitions[current]?.has(next) === true;
}
