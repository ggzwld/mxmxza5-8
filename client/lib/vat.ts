export const getVatIncludedBreakdown = (grossAmount: number, currency: string, vatRatePercentage: number | null) => {
  if (vatRatePercentage === null || grossAmount <= 0 || !currency) return null;
  const digits = new Intl.NumberFormat(undefined, { style: "currency", currency }).resolvedOptions().maximumFractionDigits ?? 2;
  const scale = 10 ** digits;
  const net = Math.round((grossAmount / (1 + vatRatePercentage / 100)) * scale) / scale;
  return { net, vat: Math.round((grossAmount - net) * scale) / scale };
};
