import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowLeft, Plus } from "lucide-react";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { useHotelTenant } from "../lib/hotelTenant";
import { useSupabaseAuth } from "../lib/supabase";

type Hours = Record<string, { open: string; close: string }[]>;
type SpaService = {
  id: string;
  name: string;
  description: string;
  price: number;
  currency_code: string;
  duration_minutes: number;
  slot_interval_minutes: number;
  capacity: number;
  weekly_hours: Hours;
  deposit_type: "fixed" | "percentage";
  deposit_value: number;
  is_active: boolean;
};
type SpaResponse = { services?: SpaService[]; timezone?: string; error?: string };
const dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const emptyHours = (): Hours => Object.fromEntries(dayNames.map((_, day) => [String(day), []]));
const emptyForm = (): Omit<SpaService, "id"> => ({ name: "", description: "", price: 0, currency_code: "UGX", duration_minutes: 60, slot_interval_minutes: 30, capacity: 1, weekly_hours: emptyHours(), deposit_type: "percentage", deposit_value: 20, is_active: false });

const HotelSpaManagementPage = () => {
  const { loading: tenantLoading, error: tenantError } = useHotelTenant();
  const { session } = useSupabaseAuth();
  const [services, setServices] = useState<SpaService[]>([]);
  const [form, setForm] = useState<Omit<SpaService, "id"> & { id?: string }>(emptyForm());
  const [timezone, setTimezone] = useState("Africa/Kampala");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(tenantError || "");
  const [notice, setNotice] = useState("");

  const loadServices = useCallback(async () => {
    if (!session?.access_token) return;
    setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/hotel-spa/manage", { headers: { Authorization: `Bearer ${session.access_token}` }, cache: "no-store" });
      const payload = await response.json().catch(() => null) as SpaResponse | null;
      if (!response.ok || !payload?.services) throw new Error(payload?.error || "Spa services could not be loaded.");
      setServices(payload.services);
      setTimezone(payload.timezone || "Africa/Kampala");
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Spa services could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, [session?.access_token]);

  useEffect(() => { if (!tenantLoading) void loadServices(); }, [tenantLoading, loadServices]);

  const startEditing = (service: SpaService) => {
    const weeklyHours = emptyHours();
    for (const day of dayNames.keys()) weeklyHours[String(day)] = (service.weekly_hours?.[String(day)] || []).map((range) => ({ ...range }));
    setForm({ ...service, weekly_hours: weeklyHours });
    setNotice("");
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const updateRange = (day: number, enabled: boolean, key: "open" | "close", value?: string) => {
    setForm((current) => {
      const weeklyHours = { ...current.weekly_hours };
      if (!enabled) weeklyHours[String(day)] = [];
      else {
        const first = weeklyHours[String(day)]?.[0] || { open: "09:00", close: "17:00" };
        weeklyHours[String(day)] = [{ ...first, ...(value ? { [key]: value } : {}) }];
      }
      return { ...current, weekly_hours: weeklyHours };
    });
  };

  const save = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!session?.access_token) return;
    setSaving(true);
    setError("");
    setNotice("");
    try {
      const response = await fetch("/api/hotel-spa/manage", {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify({ ...form, timezone }),
      });
      const payload = await response.json().catch(() => null) as { error?: string } | null;
      if (!response.ok) throw new Error(payload?.error || "Spa service could not be saved.");
      setNotice(form.id ? "Spa service updated." : "Spa service created.");
      setForm(emptyForm());
      await loadServices();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Spa service could not be saved.");
    } finally {
      setSaving(false);
    }
  };

  const update = <K extends keyof typeof form>(key: K, value: (typeof form)[K]) => setForm((current) => ({ ...current, [key]: value }));

  if (tenantLoading || loading) return <main className="container min-h-screen px-4 py-12" aria-busy="true"><div className="h-72 animate-pulse rounded-xl bg-muted" /></main>;
  return <main className="container mx-auto min-h-screen max-w-5xl px-4 py-8">
    <Link to="/offers" className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground"><ArrowLeft className="h-4 w-4" />Back to offers</Link>
    <header className="mb-7"><h1 className="text-3xl font-bold text-sheraton-navy">Spa services</h1><p className="mt-2 text-sm text-muted-foreground">Set services, weekly appointment hours, capacity, and deposit options for this hotel.</p></header>
    {error && <p role="alert" className="mb-4 rounded-md border border-destructive/30 p-4 text-sm text-destructive">{error}</p>}
    {notice && <p role="status" className="mb-4 rounded-md border border-green-300 bg-green-50 p-4 text-sm text-green-900">{notice}</p>}
    <Card className="mb-8"><CardHeader><CardTitle>{form.id ? "Edit spa service" : "Add spa service"}</CardTitle></CardHeader><CardContent><form onSubmit={(event) => void save(event)} className="grid gap-4 sm:grid-cols-2">
      <label className="space-y-2 text-sm">Service name<Input value={form.name} onChange={(event) => update("name", event.target.value)} maxLength={120} required /></label>
      <label className="space-y-2 text-sm">Hotel timezone<Input value={timezone} onChange={(event) => setTimezone(event.target.value)} placeholder="Africa/Kampala" required /></label>
      <label className="space-y-2 text-sm sm:col-span-2">Description<textarea className="min-h-24 w-full rounded-md border bg-background px-3 py-2" value={form.description} onChange={(event) => update("description", event.target.value)} maxLength={2000} /></label>
      <label className="space-y-2 text-sm">Price<Input type="number" min="0.01" step="0.01" value={form.price} onChange={(event) => update("price", Number(event.target.value))} required /></label>
      <label className="space-y-2 text-sm">Currency<select className="h-10 w-full rounded-md border bg-background px-3" value={form.currency_code} onChange={(event) => update("currency_code", event.target.value)}>{["UGX", "USD", "EUR", "GBP", "KES", "TZS", "RWF"].map((currency) => <option key={currency}>{currency}</option>)}</select></label>
      <label className="space-y-2 text-sm">Treatment duration (minutes)<Input type="number" min="10" max="480" step="5" value={form.duration_minutes} onChange={(event) => update("duration_minutes", Number(event.target.value))} required /></label>
      <label className="space-y-2 text-sm">Start-time interval (minutes)<Input type="number" min="5" max="240" step="5" value={form.slot_interval_minutes} onChange={(event) => update("slot_interval_minutes", Number(event.target.value))} required /></label>
      <label className="space-y-2 text-sm">Concurrent capacity<Input type="number" min="1" max="100" step="1" value={form.capacity} onChange={(event) => update("capacity", Number(event.target.value))} required /></label>
      <label className="space-y-2 text-sm">Deposit type<select className="h-10 w-full rounded-md border bg-background px-3" value={form.deposit_type} onChange={(event) => update("deposit_type", event.target.value as SpaService["deposit_type"])}><option value="percentage">Percentage</option><option value="fixed">Fixed amount</option></select></label>
      <label className="space-y-2 text-sm">Deposit {form.deposit_type === "percentage" ? "percentage" : `amount (${form.currency_code})`}<Input type="number" min="0.01" max={form.deposit_type === "percentage" ? 100 : form.price} step="0.01" value={form.deposit_value} onChange={(event) => update("deposit_value", Number(event.target.value))} required /></label>
      <fieldset className="space-y-3 sm:col-span-2"><legend className="text-sm font-medium">Weekly opening hours</legend><div className="space-y-2">{dayNames.map((day, index) => { const range = form.weekly_hours[String(index)]?.[0]; return <div key={day} className="grid items-center gap-2 sm:grid-cols-[120px_1fr_1fr]"><label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={Boolean(range)} onChange={(event) => updateRange(index, event.target.checked, "open")} />{day}</label><Input aria-label={`${day} opens`} type="time" disabled={!range} value={range?.open || "09:00"} onChange={(event) => updateRange(index, true, "open", event.target.value)} /><Input aria-label={`${day} closes`} type="time" disabled={!range} value={range?.close || "17:00"} onChange={(event) => updateRange(index, true, "close", event.target.value)} /></div>; })}</div></fieldset>
      <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={form.is_active} onChange={(event) => update("is_active", event.target.checked)} />Published and bookable</label>
      <div className="flex gap-2 sm:col-span-2"><Button type="submit" disabled={saving}>{saving ? "Saving…" : form.id ? "Save service" : <><Plus className="mr-2 h-4 w-4" />Create service</>}</Button>{form.id && <Button type="button" variant="outline" onClick={() => { setForm(emptyForm()); setNotice(""); }}>Cancel edit</Button>}</div>
    </form></CardContent></Card>
    <section className="space-y-3"><h2 className="text-xl font-semibold">Services at this hotel</h2>{services.length ? services.map((service) => <Card key={service.id}><CardContent className="flex flex-wrap items-center justify-between gap-3 p-4"><div><div className="flex flex-wrap items-center gap-2"><h3 className="font-semibold">{service.name}</h3><span className="rounded-full border px-2 py-0.5 text-xs">{service.is_active ? "Published" : "Draft"}</span></div><p className="mt-1 text-sm text-muted-foreground">{service.currency_code} {Number(service.price).toLocaleString()} · {service.duration_minutes} min · capacity {service.capacity}</p></div><Button variant="outline" size="sm" onClick={() => startEditing(service)}>Edit</Button></CardContent></Card>) : <p className="rounded-xl border border-dashed p-8 text-center text-sm text-muted-foreground">No spa services yet.</p>}</section>
  </main>;
};

export default HotelSpaManagementPage;
