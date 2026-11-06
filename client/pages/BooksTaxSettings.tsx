import type { Dispatch, SetStateAction } from "react";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { taxEntityTypes, type IncomeTaxSchedule, type TaxEntityType } from "../lib/booksTaxSummary";

type TaxRate = { id: string; name: string; country_code: string; rate_percentage: number; effective_from: string; effective_to: string | null; is_active: boolean; confirmed_at: string | null; tax_scope: "invoice" | "other" };
type TaxProfile = { country_code: string; tax_entity_type: TaxEntityType | null };
type BracketForm = { lowerBound: string; upperBound: string; rate: string; baseTax: string };

type Props = {
  currency: string;
  isTaxProfileSaved: boolean;
  taxProfileForm: TaxProfile;
  setTaxProfileForm: Dispatch<SetStateAction<TaxProfile>>;
  saveTaxProfile: () => void;
  taxRates: TaxRate[];
  vatRateForm: { name: string; rate: string; effectiveFrom: string };
  setVatRateForm: Dispatch<SetStateAction<{ name: string; rate: string; effectiveFrom: string }>>;
  saveVatRate: () => void;
  confirmVatRate: (rateId: string) => void;
  incomeTaxSchedules: IncomeTaxSchedule[];
  incomeTaxForm: { name: string; rateMethod: "flat" | "progressive"; rate: string; effectiveFrom: string };
  setIncomeTaxForm: Dispatch<SetStateAction<{ name: string; rateMethod: "flat" | "progressive"; rate: string; effectiveFrom: string }>>;
  incomeTaxBrackets: BracketForm[];
  setIncomeTaxBrackets: Dispatch<SetStateAction<BracketForm[]>>;
  saveIncomeTaxSchedule: () => void;
};

const today = new Date().toISOString().slice(0, 10);

const countries = [
  ["UG", "Uganda"],
  ["KE", "Kenya"],
  ["TZ", "Tanzania"],
  ["RW", "Rwanda"],
  ["GB", "United Kingdom"],
  ["US", "United States"],
  ["XX", "Other / manual setup"],
];

const TaxField = ({ label, children }: { label: string; children: React.ReactNode }) => <div className="space-y-2"><Label>{label}</Label>{children}</div>;

const BooksTaxSettings = ({
  currency,
  isTaxProfileSaved,
  taxProfileForm,
  setTaxProfileForm,
  saveTaxProfile,
  taxRates,
  vatRateForm,
  setVatRateForm,
  saveVatRate,
  confirmVatRate,
  incomeTaxSchedules,
  incomeTaxForm,
  setIncomeTaxForm,
  incomeTaxBrackets,
  setIncomeTaxBrackets,
  saveIncomeTaxSchedule,
}: Props) => (
  <div className="space-y-6">
    <Card>
      <CardHeader>
        <CardTitle>Organization tax profile</CardTitle>
        <p className="text-sm text-muted-foreground">Jurisdiction and legal entity determine which tax setup Books can present. Profile defaults do not override this organization’s settings.</p>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <TaxField label="Tax jurisdiction">
            <select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={taxProfileForm.country_code} onChange={(event) => {
              const countryCode = event.target.value;
              setTaxProfileForm({ ...taxProfileForm, country_code: countryCode });
              setVatRateForm((form) => ({ ...form, name: countryCode === "UG" ? "URA VAT" : "Sales tax", rate: countryCode === "UG" ? "18" : "" }));
              setIncomeTaxForm((form) => ({ ...form, name: countryCode === "UG" && taxProfileForm.tax_entity_type === "company" ? "URA Corporation Tax" : "Confirmed business income-tax schedule", rate: countryCode === "UG" && taxProfileForm.tax_entity_type === "company" ? "30" : "" }));
            }}>
              {countries.map(([code, name]) => <option key={code} value={code}>{name} ({code})</option>)}
            </select>
          </TaxField>
          <TaxField label="Tax entity type">
            <select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={taxProfileForm.tax_entity_type || ""} onChange={(event) => {
              const entityType = (event.target.value || null) as TaxEntityType | null;
              setTaxProfileForm({ ...taxProfileForm, tax_entity_type: entityType });
              setIncomeTaxForm((form) => ({ ...form, name: taxProfileForm.country_code === "UG" && entityType === "company" ? "URA Corporation Tax" : "Confirmed business income-tax schedule", rateMethod: entityType === "company" ? "flat" : "progressive", rate: taxProfileForm.country_code === "UG" && entityType === "company" ? "30" : "" }));
              if (entityType !== "company") setIncomeTaxBrackets([{ lowerBound: "0", upperBound: "", rate: "", baseTax: "0" }]);
            }}>
              <option value="">Select entity type</option>
              {taxEntityTypes.map((entityType) => <option key={entityType.value} value={entityType.value}>{entityType.label}</option>)}
            </select>
          </TaxField>
        </div>
        <Button type="button" variant="outline" onClick={() => void saveTaxProfile()} >Save tax profile</Button>
        <p className="text-xs text-muted-foreground">For Uganda, 30% is suggested for company income tax. Individual and sole-proprietor business tax is not inferred from monthly PAYE rates.</p>
      </CardContent>
    </Card>

    <Card>
      <CardHeader>
        <CardTitle>Invoice VAT / sales-tax rates</CardTitle>
        <p className="text-sm text-muted-foreground">Rates are effective-dated, saved per organization and jurisdiction, and snapshotted on the invoice. Confirm applicability before use.</p>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full min-w-[650px]">
            <thead><tr className="border-b bg-muted/30"><th className="p-3 text-left">Rate</th><th className="p-3 text-left">Country</th><th className="p-3 text-left">Effective period</th><th className="p-3 text-left">Status</th></tr></thead>
            <tbody>{taxRates.filter((rate) => rate.tax_scope === "invoice").map((rate) => <tr key={rate.id} className="border-b"><td className="p-3">{rate.name} · {rate.rate_percentage}%</td><td className="p-3">{rate.country_code}</td><td className="p-3">{rate.effective_from} – {rate.effective_to || "ongoing"}</td><td className="p-3">{rate.confirmed_at ? <Badge>Confirmed</Badge> : rate.effective_from <= today && (!rate.effective_to || rate.effective_to >= today) ? <Button type="button" size="sm" variant="outline" onClick={() => void confirmVatRate(rate.id)}>Confirm rate</Button> : <Badge variant="outline">Historical / future</Badge>}</td></tr>)}</tbody>
          </table>
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <TaxField label="Rate name"><Input value={vatRateForm.name} onChange={(event) => setVatRateForm({ ...vatRateForm, name: event.target.value })} /></TaxField>
          <TaxField label="Rate (%)"><Input type="number" min="0" max="100" step="0.0001" value={vatRateForm.rate} onChange={(event) => setVatRateForm({ ...vatRateForm, rate: event.target.value })} /></TaxField>
          <TaxField label="Effective from"><Input type="date" value={vatRateForm.effectiveFrom} onChange={(event) => setVatRateForm({ ...vatRateForm, effectiveFrom: event.target.value })} /></TaxField>
          <div className="flex items-end"><Button type="button" onClick={() => void saveVatRate()} disabled={!isTaxProfileSaved || !vatRateForm.name.trim() || !vatRateForm.rate || !vatRateForm.effectiveFrom}>Save and confirm VAT rate</Button></div>
        </div>
        <p className="text-xs text-muted-foreground">The Uganda VAT 18% entry is an unconfirmed suggestion. Confirm applicability before use. A saved rate closes the prior invoice-tax period without changing invoice snapshots or other tax categories.</p>
      </CardContent>
    </Card>

    <Card>
      <CardHeader>
        <CardTitle>Income-tax schedule</CardTitle>
        <p className="text-sm text-muted-foreground">Set a confirmed flat or progressive schedule for the selected entity. Individual business income stays unconfigured until you confirm the applicable regime; PAYE rates are not substituted.</p>
      </CardHeader>
      <CardContent className="space-y-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <TaxField label="Schedule name"><Input value={incomeTaxForm.name} onChange={(event) => setIncomeTaxForm({ ...incomeTaxForm, name: event.target.value })} placeholder="Tax authority / regime" /></TaxField>
          <TaxField label="Calculation method"><select className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm" value={incomeTaxForm.rateMethod} onChange={(event) => setIncomeTaxForm({ ...incomeTaxForm, rateMethod: event.target.value as "flat" | "progressive" })}><option value="flat">Flat rate</option><option value="progressive">Progressive brackets</option></select></TaxField>
          <TaxField label="Effective from"><Input type="date" value={incomeTaxForm.effectiveFrom} onChange={(event) => setIncomeTaxForm({ ...incomeTaxForm, effectiveFrom: event.target.value })} /></TaxField>
          {incomeTaxForm.rateMethod === "flat" && <TaxField label="Rate (%)"><Input type="number" min="0" max="100" step="0.0001" value={incomeTaxForm.rate} onChange={(event) => setIncomeTaxForm({ ...incomeTaxForm, rate: event.target.value })} /></TaxField>}
        </div>
        {incomeTaxForm.rateMethod === "progressive" && <div className="space-y-3">
          <div className="grid grid-cols-[1fr_1fr_1fr_1fr_auto] gap-2 text-xs font-medium text-muted-foreground"><span>From ({currency})</span><span>To (exclusive)</span><span>Marginal rate (%)</span><span>Base tax ({currency})</span><span /></div>
          {incomeTaxBrackets.map((bracket, index) => <div key={index} className="grid grid-cols-[1fr_1fr_1fr_1fr_auto] gap-2">
            <Input aria-label={`Bracket ${index + 1} lower bound`} type="number" min="0" value={bracket.lowerBound} onChange={(event) => setIncomeTaxBrackets((rows) => rows.map((row, rowIndex) => rowIndex === index ? { ...row, lowerBound: event.target.value } : row))} />
            <Input aria-label={`Bracket ${index + 1} upper bound`} type="number" min="0" placeholder="No upper limit" value={bracket.upperBound} onChange={(event) => setIncomeTaxBrackets((rows) => rows.map((row, rowIndex) => rowIndex === index ? { ...row, upperBound: event.target.value } : row))} />
            <Input aria-label={`Bracket ${index + 1} marginal rate`} type="number" min="0" max="100" step="0.0001" value={bracket.rate} onChange={(event) => setIncomeTaxBrackets((rows) => rows.map((row, rowIndex) => rowIndex === index ? { ...row, rate: event.target.value } : row))} />
            <Input aria-label={`Bracket ${index + 1} base tax`} type="number" min="0" value={bracket.baseTax} onChange={(event) => setIncomeTaxBrackets((rows) => rows.map((row, rowIndex) => rowIndex === index ? { ...row, baseTax: event.target.value } : row))} />
            <Button type="button" variant="outline" aria-label={`Remove bracket ${index + 1}`} disabled={incomeTaxBrackets.length === 1} onClick={() => setIncomeTaxBrackets((rows) => rows.filter((_, rowIndex) => rowIndex !== index))}>×</Button>
          </div>)}
          <Button type="button" variant="outline" onClick={() => setIncomeTaxBrackets((rows) => [...rows, { lowerBound: rows.at(-1)?.upperBound || "0", upperBound: "", rate: "", baseTax: "0" }])}>Add bracket</Button>
        </div>}
        <div>
          <Button type="button" onClick={() => void saveIncomeTaxSchedule()} disabled={!isTaxProfileSaved || !taxProfileForm.tax_entity_type || !incomeTaxForm.name.trim() || !incomeTaxForm.effectiveFrom || (incomeTaxForm.rateMethod === "flat" && (incomeTaxForm.rate === "" || Number(incomeTaxForm.rate) < 0 || Number(incomeTaxForm.rate) > 100))}>Confirm and save income-tax schedule</Button>
          {taxProfileForm.tax_entity_type === "company" && <p className="mt-2 text-xs text-muted-foreground">Suggested Uganda company rate: 30% of chargeable income, subject to confirmation and any special regime or relief.</p>}
        </div>
        {incomeTaxSchedules.filter((schedule) => schedule.country_code.trim() === taxProfileForm.country_code && schedule.tax_entity_type === taxProfileForm.tax_entity_type).map((schedule) => <p key={`${schedule.tax_entity_type}-${schedule.effective_from}`} className="text-sm">{schedule.name} · {schedule.effective_from} – {schedule.effective_to || "ongoing"} · {schedule.confirmed_at ? "Confirmed" : "Unconfirmed"}</p>)}
      </CardContent>
    </Card>
  </div>
);

export default BooksTaxSettings;
