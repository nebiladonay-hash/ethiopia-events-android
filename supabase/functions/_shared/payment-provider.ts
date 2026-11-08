/** Provider-neutral contract used by Tiqet payment Edge Functions.
 * Implementations must verify money server-to-server; client redirects are never proof of payment.
 */
export type PaymentStatus = 'pending' | 'succeeded' | 'failed' | 'review' | 'refunded'

export interface PaymentMethod {
  slug: string
  name: string
  mobileMoney?: boolean
  currencies?: string[]
  countries?: string[]
}

export interface CheckoutInput {
  amountMinor: number
  currency: 'ETB'
  merchantReference: string
  idempotencyKey: string
  description: string
  customer: { email: string; firstName?: string; lastName?: string; phone?: string }
  paymentMethod?: string
  organiserAccountReference?: string
  organiserSplitMinor?: number
  metadata: Record<string, string>
}

export interface CheckoutResult {
  checkoutUrl: string
  providerPaymentReference?: string
  rawStatus: string
}

export interface VerifiedPayment {
  status: PaymentStatus
  merchantReference: string
  providerPaymentReference?: string
  amountMinor: number
  currency: 'ETB'
  paymentMethod?: string
  rawStatus: string
}

export interface PayoutInput {
  amountMinor: number
  currency: 'ETB'
  merchantReference: string
  idempotencyKey: string
  destinationReference: string
  accountName: string
}

export interface PayoutResult {
  providerReference: string
  status: 'pending' | 'succeeded' | 'failed' | 'review'
  rawStatus: string
}

export interface PaymentProviderAdapter {
  readonly id: string
  readonly displayName: string
  readonly supportsMarketplaceSplit: boolean
  readonly supportsOrganiserPayouts: boolean
  getPaymentMethods(): Promise<PaymentMethod[]>
  createCheckout(input: CheckoutInput): Promise<CheckoutResult>
  verifyPayment(reference: string): Promise<VerifiedPayment>
  verifyWebhook(rawBody: string, headers: Headers): Promise<boolean>
  createPayout?(input: PayoutInput): Promise<PayoutResult>
  verifyPayout?(reference: string): Promise<PayoutResult>
}

export function toMinorUnits(etb: number): number {
  if (!Number.isFinite(etb) || etb < 0) throw new Error('Amount must be a non-negative ETB value')
  return Math.round((etb + Number.EPSILON) * 100)
}

export function fromMinorUnits(minor: number): number {
  if (!Number.isSafeInteger(minor) || minor < 0) throw new Error('Invalid ETB minor-unit amount')
  return minor / 100
}
