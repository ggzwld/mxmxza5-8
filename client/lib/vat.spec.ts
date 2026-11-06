import { describe, it, expect } from "vitest";
import { getVatIncludedBreakdown } from "./vat";

describe("getVatIncludedBreakdown", () => {
  it("carves VAT out of a whole-currency gross amount", () => {
    expect(getVatIncludedBreakdown(118000, "UGX", 18)).toEqual({ net: 100000, vat: 18000 });
  });

  it("rounds to the currency's minor units", () => {
    expect(getVatIncludedBreakdown(10, "USD", 18)).toEqual({ net: 8.47, vat: 1.53 });
  });

  it("returns null when no confirmed rate is available", () => {
    expect(getVatIncludedBreakdown(118000, "UGX", null)).toBeNull();
  });

  it("returns null for zero amounts", () => {
    expect(getVatIncludedBreakdown(0, "UGX", 18)).toBeNull();
  });
});
