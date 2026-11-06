import { useEffect, useState, type FormEvent } from "react";
import { CheckCircle2, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { supabase } from "../../lib/supabase";
import { Button } from "../../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../../components/ui/card";
import { Input } from "../../components/ui/input";
import { Label } from "../../components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "../../components/ui/select";
import { Switch } from "../../components/ui/switch";

type BooksAccount = { code: string; name: string; type: "expense" | "liability" };
type LoyaltyActivity = { created_at: string; member_name: string; entry_type: string; points_delta: number; available_points: number; description: string };
type HotelProgram = {
  programName: string;
  pointsPer1000Ugx: number;
  guestReferralMinimumUgx: number;
  referrerBonusPoints: number;
  inviteeBonusPoints: number;
  taskApprovalPoints: number;
  monthlyTaskPointsCap: number;
  ugxValuePerPoint: number;
  booksExpenseAccountCode: string | null;
  booksLiabilityAccountCode: string | null;
  programEnabled: boolean;
};
type SettingsResponse = { baseCurrency: string; program: HotelProgram | null };
type SettingsForm = {
  programName: string;
  pointsPer1000Ugx: string;
  guestReferralMinimumUgx: string;
  referrerBonusPoints: string;
  inviteeBonusPoints: string;
  taskApprovalPoints: string;
  monthlyTaskPointsCap: string;
  ugxValuePerPoint: string;
  booksExpenseAccountCode: string;
  booksLiabilityAccountCode: string;
  programEnabled: boolean;
};

const defaultForm: SettingsForm = {
  programName: "Hotel Rewards",
  pointsPer1000Ugx: "1",
  guestReferralMinimumUgx: "100000",
  referrerBonusPoints: "250",
  inviteeBonusPoints: "250",
  taskApprovalPoints: "50",
  monthlyTaskPointsCap: "500",
  ugxValuePerPoint: "10",
  booksExpenseAccountCode: "",
  booksLiabilityAccountCode: "",
  programEnabled: false,
};

const HotelLoyaltySettings = ({ organizationId, hotelName }: { organizationId: string; hotelName: string }) => {
  const [form, setForm] = useState<SettingsForm>(defaultForm);
  const [success, setSuccess] = useState(false);
  const [accounts, setAccounts] = useState<BooksAccount[]>([]);
  const [activity, setActivity] = useState<LoyaltyActivity[]>([]);
  const [baseCurrency, setBaseCurrency] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    const load = async () => {
      setLoading(true);
      setError("");
      try {
        const [settingsResult, accountsResult, activityResult] = await Promise.all([
          supabase.rpc("get_hotel_loyalty_manager_settings", { target_organization_id: organizationId }),
          supabase.from("books_accounts").select("code,name,type").eq("organization_id", organizationId).in("type", ["expense", "liability"]).order("code"),
          supabase.rpc("get_hotel_loyalty_activity", { target_organization_id: organizationId }),
        ]);
        if (settingsResult.error) throw settingsResult.error;
        if (accountsResult.error) throw accountsResult.error;

        const settings = settingsResult.data as SettingsResponse;
        if (!active) return;
        setBaseCurrency(settings.baseCurrency.trim());
        setAccounts((accountsResult.data || []) as BooksAccount[]);
        setActivity(activityResult.error ? [] : (activityResult.data || []) as LoyaltyActivity[]);
        if (settings.program) {
          setForm({
            programName: settings.program.programName,
            pointsPer1000Ugx: String(settings.program.pointsPer1000Ugx),
            guestReferralMinimumUgx: String(settings.program.guestReferralMinimumUgx),
            referrerBonusPoints: String(settings.program.referrerBonusPoints),
            inviteeBonusPoints: String(settings.program.inviteeBonusPoints),
            taskApprovalPoints: String(settings.program.taskApprovalPoints),
            monthlyTaskPointsCap: String(settings.program.monthlyTaskPointsCap),
            ugxValuePerPoint: String(settings.program.ugxValuePerPoint),
            booksExpenseAccountCode: settings.program.booksExpenseAccountCode || "",
            booksLiabilityAccountCode: settings.program.booksLiabilityAccountCode || "",
            programEnabled: settings.program.programEnabled,
          });
        } else {
          setForm(defaultForm);
        }
      } catch (loadError) {
        if (active) setError(loadError instanceof Error ? loadError.message : "Hotel rewards settings could not be loaded.");
      } finally {
        if (active) setLoading(false);
      }
    };
    void load();
    return () => { active = false; };
  }, [organizationId]);

  const setField = <K extends keyof SettingsForm>(key: K, value: SettingsForm[K]) => {
    setForm((previous) => ({ ...previous, [key]: value }));
    setSuccess(false);
  };

  const save = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setSaving(true);
    setError("");
    setSuccess(false);
    try {
      const { error: saveError } = await supabase.rpc("configure_hotel_loyalty_program", {
        target_organization_id: organizationId,
        target_program_name: form.programName,
        target_points_per_1000_ugx: Number(form.pointsPer1000Ugx),
        target_guest_referral_minimum_ugx: Number(form.guestReferralMinimumUgx),
        target_referrer_bonus_points: Number(form.referrerBonusPoints),
        target_invitee_bonus_points: Number(form.inviteeBonusPoints),
        target_task_approval_points: Number(form.taskApprovalPoints),
        target_monthly_task_points_cap: Number(form.monthlyTaskPointsCap),
        target_ugx_value_per_point: Number(form.ugxValuePerPoint),
        target_expense_account_code: form.booksExpenseAccountCode || null,
        target_liability_account_code: form.booksLiabilityAccountCode || null,
        target_enable: form.programEnabled,
      });
      if (saveError) throw saveError;
      setSuccess(true);
      toast.success(form.programEnabled ? "Hotel rewards program enabled" : "Hotel rewards settings saved");
    } catch (saveError) {
      const message = saveError instanceof Error ? saveError.message : "Hotel rewards settings could not be saved.";
      setError(message);
      toast.error("Rewards settings could not be saved", { description: message });
    } finally {
      setSaving(false);
    }
  };

  const expenseAccounts = accounts.filter((account) => account.type === "expense");
  const liabilityAccounts = accounts.filter((account) => account.type === "liability");
  const missingExpenseSelection = !expenseAccounts.some((account) => account.code === form.booksExpenseAccountCode);
  const missingLiabilitySelection = !liabilityAccounts.some((account) => account.code === form.booksLiabilityAccountCode);

  if (loading) return <Card><CardContent className="py-6 text-sm text-muted-foreground">Loading {hotelName} rewards settings…</CardContent></Card>;

  return (
    <>
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><CheckCircle2 className="h-5 w-5" /> Manage {hotelName} rewards</CardTitle>
        <p className="text-sm text-muted-foreground">Configure this hotel’s points and referral rules. Only this hotel’s authorized managers can save these settings.</p>
      </CardHeader>
      <CardContent>
        {error && <p role="alert" className="mb-4 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">{error}</p>}
        <form onSubmit={save} className="space-y-6">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2 md:col-span-2">
              <Label htmlFor="hotel-rewards-name">Program name</Label>
              <Input id="hotel-rewards-name" value={form.programName} onChange={(event) => setField("programName", event.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-rewards-points">Points per UGX 1,000 eligible spend</Label>
              <Input id="hotel-rewards-points" type="number" min="1" step="1" value={form.pointsPer1000Ugx} onChange={(event) => setField("pointsPer1000Ugx", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-rewards-value">UGX value per point (accounting)</Label>
              <Input id="hotel-rewards-value" type="number" min="0.0001" step="0.0001" value={form.ugxValuePerPoint} onChange={(event) => setField("ugxValuePerPoint", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-referral-minimum">Guest referral minimum purchase (UGX)</Label>
              <Input id="hotel-referral-minimum" type="number" min="0.0001" step="0.01" value={form.guestReferralMinimumUgx} onChange={(event) => setField("guestReferralMinimumUgx", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-referrer-points">Referrer bonus points</Label>
              <Input id="hotel-referrer-points" type="number" min="1" step="1" value={form.referrerBonusPoints} onChange={(event) => setField("referrerBonusPoints", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-invitee-points">New guest referral bonus points</Label>
              <Input id="hotel-invitee-points" type="number" min="1" step="1" value={form.inviteeBonusPoints} onChange={(event) => setField("inviteeBonusPoints", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-task-points">Manager-approved task points</Label>
              <Input id="hotel-task-points" type="number" min="1" step="1" value={form.taskApprovalPoints} onChange={(event) => setField("taskApprovalPoints", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="hotel-task-cap">Monthly task points cap per member</Label>
              <Input id="hotel-task-cap" type="number" min="1" step="1" value={form.monthlyTaskPointsCap} onChange={(event) => setField("monthlyTaskPointsCap", event.target.value)} required />
            </div>
            <div className="space-y-2">
              <Label>Books expense account</Label>
              <Select value={form.booksExpenseAccountCode} onValueChange={(value) => setField("booksExpenseAccountCode", value)}>
                <SelectTrigger><SelectValue placeholder="Choose an expense account" /></SelectTrigger>
                <SelectContent>{expenseAccounts.map((account) => <SelectItem key={account.code} value={account.code}>{account.code} — {account.name}</SelectItem>)}</SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label>Books liability account</Label>
              <Select value={form.booksLiabilityAccountCode} onValueChange={(value) => setField("booksLiabilityAccountCode", value)}>
                <SelectTrigger><SelectValue placeholder="Choose a liability account" /></SelectTrigger>
                <SelectContent>{liabilityAccounts.map((account) => <SelectItem key={account.code} value={account.code}>{account.code} — {account.name}</SelectItem>)}</SelectContent>
              </Select>
            </div>
          </div>

          {(missingExpenseSelection || missingLiabilitySelection) && (
            <p className="text-sm text-muted-foreground">Add a Books expense account and a Books liability account under this organization before enabling rewards.</p>
          )}
          {baseCurrency !== "UGX" && (
            <p className="rounded-md border border-amber-400/40 bg-amber-500/10 p-3 text-sm">This Books organization uses {baseCurrency}. The current hotel rewards accounting requires UGX; change the Books base currency before enabling this program.</p>
          )}

          <div className="flex flex-col gap-3 rounded-md border p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <Label htmlFor="hotel-rewards-enabled">Enable this hotel’s rewards program</Label>
              <p className="text-sm text-muted-foreground">Guests and eligible staff can enroll after it is enabled.</p>
            </div>
            <Switch
              id="hotel-rewards-enabled"
              checked={form.programEnabled}
              onCheckedChange={(enabled) => setField("programEnabled", enabled)}
              disabled={!form.programEnabled && (baseCurrency !== "UGX" || missingExpenseSelection || missingLiabilitySelection)}
            />
          </div>
          <p className="text-xs text-muted-foreground">Redemption is currently disabled platform-wide; points can be earned but not spent or withdrawn.</p>
          {success && <p role="status" className="rounded-md border border-green-500/40 bg-green-500/10 p-3 text-sm text-green-700 dark:text-green-300">Rewards settings saved successfully.</p>}
          <Button type="submit" disabled={saving || (form.programEnabled && (baseCurrency !== "UGX" || missingExpenseSelection || missingLiabilitySelection))}>
            {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            {saving ? "Saving…" : "Save rewards settings"}
          </Button>
        </form>
      </CardContent>
    </Card>
    <Card className="mt-6">
      <CardHeader>
        <CardTitle>Recent loyalty activity</CardTitle>
        <p className="text-sm text-muted-foreground">Hotel-scoped rewards, referrals, and reversals. Current balances reflect each member’s latest account total.</p>
      </CardHeader>
      <CardContent>
        {activity.length ? (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead><tr className="border-b text-left text-muted-foreground"><th className="p-3">Date</th><th className="p-3">Member</th><th className="p-3">Activity</th><th className="p-3">Points</th><th className="p-3">Current balance</th></tr></thead>
              <tbody>{activity.map((entry, index) => <tr key={`${entry.created_at}-${index}`} className="border-b"><td className="p-3">{new Date(entry.created_at).toLocaleString()}</td><td className="p-3">{entry.member_name}</td><td className="p-3">{entry.description}</td><td className="p-3 font-medium">{entry.points_delta > 0 ? "+" : ""}{entry.points_delta}</td><td className="p-3">{entry.available_points}</td></tr>)}</tbody>
            </table>
          </div>
        ) : <p className="text-sm text-muted-foreground">No loyalty activity has been recorded for this hotel yet.</p>}
      </CardContent>
    </Card>
    </>
  );
};

export default HotelLoyaltySettings;
