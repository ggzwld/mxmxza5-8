import { describe, expect, it } from "vitest";
import { calculateBooksTaxSummary, estimateIncomeTax, type IncomeTaxSchedule } from "./booksTaxSummary";

describe("calculateBooksTaxSummary", () => {
  it("separates invoice tax from income and only counts classified deductions", () => {
    const summary = calculateBooksTaxSummary(
      [
        { issue_date: "2026-01-10", currency_code: "UGX", subtotal: 1000, tax_amount: 180, status: "paid" },
        { issue_date: "2026-02-10", currency_code: "UGX", subtotal: 500, tax_amount: 90, status: "sent" },
        { issue_date: "2026-02-11", currency_code: "UGX", subtotal: 999, tax_amount: 0, status: "draft" },
      ],
      [
        { expense_date: "2026-01-20", currency_code: "UGX", amount: 200, tax_amount: 36, payment_status: "paid", tax_treatment: "deductible", vat_recoverable: false },
        { expense_date: "2026-01-21", currency_code: "UGX", amount: 100, tax_amount: 18, payment_status: "paid", tax_treatment: "deductible", vat_recoverable: true },
        { expense_date: "2026-02-20", currency_code: "UGX", amount: 300, tax_amount: 54, payment_status: "unpaid", tax_treatment: "non_deductible", vat_recoverable: false },
        { expense_date: "2026-03-20", currency_code: "UGX", amount: 400, tax_amount: 72, payment_status: "paid", tax_treatment: "review", vat_recoverable: true },
      ],
      "UGX",
      "2026-01-01",
      "2026-12-31",
    );

    expect(summary).toEqual({
      invoiceIncome: 1500,
      invoiceTax: 270,
      allowableDeductions: 336,
      nonDeductibleExpenses: 354,
      expensesToReview: 1,
      recoverableInputVat: 90,
    });
    expect(summary.invoiceIncome - summary.allowableDeductions).toBe(1164);
  });

  it("calculates only confirmed entity-specific effective schedules and treats losses as no current tax", () => {
    const schedule: IncomeTaxSchedule = {
      country_code: "UG",
      tax_entity_type: "company",
      name: "Confirmed company rate",
      rate_method: "flat",
      rate_schedule: [{ lower_bound: 0, upper_bound: null, rate_percentage: 30, base_tax: 0 }],
      effective_from: "2026-01-01",
      effective_to: null,
      confirmed_at: "2026-06-01T00:00:00Z",
    };

    expect(estimateIncomeTax(1000, "UG", "company", "2026-12-31", [schedule])).toEqual({
      status: "estimated",
      estimatedTax: 300,
      scheduleName: "Confirmed company rate",
    });
    expect(estimateIncomeTax(1000, "UG", "individual", "2026-12-31", [schedule]).status).toBe("unconfigured");
    expect(estimateIncomeTax(1000, "UG", "company", "2025-12-31", [schedule]).status).toBe("unconfigured");
    expect(estimateIncomeTax(1000, "UG", "company", "2026-12-31", [{ ...schedule, confirmed_at: null }]).status).toBe("unconfigured");
    expect(estimateIncomeTax(-100, "UG", "company", "2026-12-31", [schedule])).toEqual({
      status: "loss",
      estimatedTax: 0,
      scheduleName: null,
    });
  });

  it("calculates a confirmed progressive schedule using the matching bracket", () => {
    const estimate = estimateIncomeTax(150, "UG", "individual", "2026-12-31", [{
      country_code: "UG",
      tax_entity_type: "individual",
      name: "Confirmed progressive schedule",
      rate_method: "progressive",
      rate_schedule: [
        { lower_bound: 0, upper_bound: 100, rate_percentage: 10, base_tax: 0 },
        { lower_bound: 100, upper_bound: null, rate_percentage: 20, base_tax: 10 },
      ],
      effective_from: "2026-01-01",
      effective_to: null,
      confirmed_at: "2026-06-01T00:00:00Z",
    }]);

    expect(estimate.estimatedTax).toBe(20);
  });

  it("keeps dates, currencies, void invoices, and refunded expenses out of the summary", () => {
    const summary = calculateBooksTaxSummary(
      [
        { issue_date: "2025-12-31", currency_code: "UGX", subtotal: 100, tax_amount: 0, status: "paid" },
        { issue_date: "2026-01-01", currency_code: "USD", subtotal: 200, tax_amount: 0, status: "paid" },
        { issue_date: "2026-06-01", currency_code: "UGX", subtotal: 300, tax_amount: 0, status: "void" },
      ],
      [
        { expense_date: "2026-06-01", currency_code: "UGX", amount: 400, tax_amount: 0, payment_status: "refunded", tax_treatment: "deductible", vat_recoverable: false },
      ],
      "UGX",
      "2026-01-01",
      "2026-12-31",
    );

    expect(summary.invoiceIncome).toBe(0);
    expect(summary.allowableDeductions).toBe(0);
    expect(summary.expensesToReview).toBe(0);
  });
});
