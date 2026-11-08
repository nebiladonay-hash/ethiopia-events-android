/** Public-safe provider capabilities. These records never contain credentials. */
export const PROVIDER_CAPABILITIES = [
  { provider: 'chapa', name: 'Chapa', adapter: 'ready', enabledByDefault: true, marketSplit: true, organiserPayouts: true, methodsSource: 'live_merchant_api' },
  { provider: 'arifpay', name: 'ArifPay', adapter: 'contract_required', enabledByDefault: false, marketSplit: false, organiserPayouts: false, methodsSource: 'not_connected' },
  { provider: 'fenanpay', name: 'FenanPay', adapter: 'contract_required', enabledByDefault: false, marketSplit: false, organiserPayouts: false, methodsSource: 'not_connected' },
  { provider: 'santimpay', name: 'SantimPay', adapter: 'contract_required', enabledByDefault: false, marketSplit: false, organiserPayouts: false, methodsSource: 'not_connected' },
  { provider: 'yagoutpay', name: 'YagoutPay', adapter: 'contract_required', enabledByDefault: false, marketSplit: false, organiserPayouts: false, methodsSource: 'not_connected' },
] as const
