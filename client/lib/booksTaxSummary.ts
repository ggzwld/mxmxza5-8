export const taxEntityTypes = [
  { value: "individual", label: "Individual" },
  { value: "sole_proprietor", label: "Sole proprietor" },
  { value: "company", label: "Company" },
  { value: "partnership", label: "Partnership" },
  { value: "trust", label: "Trust" },
  { value: "ngo", label: "NGO / non-profit" },
  { value: "other", label: "Other" },
] as const;

export type TaxEntityType = typeof taxEntityTypes[number]["value"];
export type IncomeTaxBracket = { lower_bound: number; upper_bound: number | null; rate_percentage: number; base_tax: number };
export type IncomeTaxSchedule = {
  country_code: string;
  tax_entity_type: TaxEntityType;
  name: string;
  rate_method: "flat" | "progressive";
  rate_schedule: IncomeTaxBracket[];
  effective_from: string;
  effective_to: string | null;
  confirmed_at: string | null;
};

export type TaxSummaryInvoice = {
  issue_date: string;
  currency_code: string;
  subtotal: number;
  tax_amount: number;
  status: "draft" | "sent" | "paid" | "overdue" | "void";
};

export type TaxSummaryExpense = {
  expense_date: string;
  currency_code: string;
  amount: number;
  tax_amount: number;
  payment_status: "paid" | "unpaid" | "refunded";
  tax_treatment: "deductible" | "non_deductible" | "review";
  vat_recoverable: boolean;
};

const expenseCost = (expense: TaxSummaryExpense) =>
  Number(expense.amount) + (expense.vat_recoverable ? 0 : Number(expense.tax_amount));

export const calculateBooksTaxSummary = (
  invoices: TaxSummaryInvoice[],
  expenses: TaxSummaryExpense[],
  currency: string,
  periodStart: string,
  periodEnd: string,
) => {
  const includedInvoiceStatuses = new Set(["sent", "overdue", "paid"]);
  const periodInvoices = invoices.filter((invoice) =>
    invoice.currency_code.trim() === currency
    && invoice.issue_date >= periodStart
    && invoice.issue_date <= periodEnd
    && includedInvoiceStatuses.has(invoice.status),
  );
  const periodExpenses = expenses.filter((expense) =>
    expense.currency_code.trim() === currency
    && expense.expense_date >= periodStart
    && expense.expense_date <= periodEnd
    && expense.payment_status !== "refunded",
  );

  return {
    invoiceIncome: periodInvoices.reduce((total, invoice) => total + Number(invoice.subtotal), 0),
    invoiceTax: periodInvoices.reduce((total, invoice) => total + Number(invoice.tax_amount), 0),
    allowableDeductions: periodExpenses
      .filter((expense) => expense.tax_treatment === "deductible")
      .reduce((total, expense) => total + expenseCost(expense), 0),
    nonDeductibleExpenses: periodExpenses
      .filter((expense) => expense.tax_treatment === "non_deductible")
      .reduce((total, expense) => total + expenseCost(expense), 0),
    expensesToReview: periodExpenses.filter((expense) => expense.tax_treatment === "review").length,
    recoverableInputVat: periodExpenses
      .filter((expense) => expense.vat_recoverable)
      .reduce((total, expense) => total + Number(expense.tax_amount), 0),
  };
};

export const estimateIncomeTax = (
  taxableIncome: number,
  countryCode: string,
  entityType: TaxEntityType | null,
  periodEnd: string,
  schedules: IncomeTaxSchedule[],
) => {
  if (taxableIncome <= 0) return { status: "loss" as const, estimatedTax: 0, scheduleName: null };
  if (!entityType) return { status: "entity_unset" as const, estimatedTax: null, scheduleName: null };

  const schedule = schedules.find((candidate) =>
    candidate.country_code.trim() === countryCode.trim()
    && candidate.tax_entity_type === entityType
    && candidate.confirmed_at !== null
    && candidate.effective_from <= periodEnd
    && (candidate.effective_to === null || candidate.effective_to >= periodEnd),
  );
  if (!schedule) return { status: "unconfigured" as const, estimatedTax: null, scheduleName: null };

  const bracket = schedule.rate_schedule.find((item) =>
    taxableIncome >= item.lower_bound
    && (item.upper_bound === null || taxableIncome < item.upper_bound),
  );
  if (!bracket) return { status: "unconfigured" as const, estimatedTax: null, scheduleName: null };

  return {
    status: "estimated" as const,
    estimatedTax: bracket.base_tax + ((taxableIncome - bracket.lower_bound) * bracket.rate_percentage / 100),
    scheduleName: schedule.name,
  };
};
