import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { CalendarDays, Clock, Heart, Loader2 } from "lucide-react";
import { Button } from "../components/ui/button";
import { Card, CardContent } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { useHotelTenant } from "../lib/hotelTenant";
import { useSupabaseAuth } from "../lib/supabase";

type SpaService = {
  id: string;
  name: string;
  description: string;
  price: number;
  currency_code: string;
  duration_minutes: number;
  slot_interval_minutes: number;
  capacity: number;
  deposit_type: "fixed" | "percentage";
  deposit_value: number;
};
type SpaSlot = { slot_start: string; slot_end: string; remaining_capacity: number };
type SpaResponse = { tenant?: { name?: string; timezone?: string }; services?: SpaService[]; error?: string };
type SpaBooking = { booking_id: string; confirmation_number: string; amount_due: number; service_price: number; currency_code: string; booking_status: string; payment_status: string; starts_at: string; expires_at: string | null; timezone: string; accessToken: string };

const money = (amount: number, currency: string) => `${currency} ${Number(amount).toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
const hotelDate = (timezone: string) => {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date());
  return `${parts.find((part) => part.type === "year")?.value}-${parts.find((part) => part.type === "month")?.value}-${parts.find((part) => part.type === "day")?.value}`;
};
const addDays = (date: string, days: number) => {
  const next = new Date(`${date}T12:00:00Z`);
  next.setUTCDate(next.getUTCDate() + days);
  return next.toISOString().slice(0, 10);
};
const formatSlot = (slot: SpaSlot, timezone: string) => new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit", timeZone: timezone }).format(new Date(slot.slot_start));

const HotelSpaPage = () => {
  const { loading: tenantLoading, error: tenantError } = useHotelTenant();
  const { session } = useSupabaseAuth();
  const [services, setServices] = useState<SpaService[]>([]);
  const [hotelName, setHotelName] = useState("Hotel spa");
  const [timezone, setTimezone] = useState("Africa/Kampala");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(tenantError || "");
  const [selectedService, setSelectedService] = useState<SpaService | null>(null);
  const [date, setDate] = useState("");
  const [slots, setSlots] = useState<SpaSlot[]>([]);
  const [slotLoading, setSlotLoading] = useState(false);
  const [slotStart, setSlotStart] = useState("");
  const [firstName, setFirstName] = useState(session?.user?.user_metadata?.first_name || "");
  const [lastName, setLastName] = useState(session?.user?.user_metadata?.last_name || "");
  const [email, setEmail] = useState(session?.user?.email || "");
  const [phone, setPhone] = useState("");
  const [paymentChoice, setPaymentChoice] = useState<"pay_at_spa" | "full" | "deposit">("pay_at_spa");
  const [submitting, setSubmitting] = useState(false);
  const [confirmation, setConfirmation] = useState<SpaBooking | null>(null);

  useEffect(() => {
    if (tenantLoading) return;
    let active = true;
    setLoading(true);
    void fetch("/api/hotel-spa/services", { cache: "no-store" })
      .then(async (response) => {
        const payload = await response.json().catch(() => null) as SpaResponse | null;
        if (!response.ok || !payload?.services) throw new Error(payload?.error || "Spa services could not be loaded.");
        if (!active) return;
        setServices(payload.services);
        setHotelName(payload.tenant?.name || "Hotel spa");
        setTimezone(payload.tenant?.timezone || "Africa/Kampala");
      })
      .catch((loadError: unknown) => { if (active) setError(loadError instanceof Error ? loadError.message : "Spa services could not be loaded."); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [tenantLoading]);

  const minimumDate = useMemo(() => hotelDate(timezone), [timezone]);
  const maximumDate = useMemo(() => addDays(minimumDate, 60), [minimumDate]);
  const depositAmount = selectedService ? selectedService.deposit_type === "fixed" ? Number(selectedService.deposit_value) : Number((selectedService.price * selectedService.deposit_value / 100).toFixed(2)) : 0;
  const amountDue = paymentChoice === "full" && selectedService ? Number(selectedService.price) : paymentChoice === "deposit" ? depositAmount : 0;

  useEffect(() => {
    if (!selectedService || !date) {
      setSlots([]);
      setSlotStart("");
      return;
    }
    let active = true;
    setSlotLoading(true);
    setError("");
    void fetch(`/api/hotel-spa/availability?serviceId=${encodeURIComponent(selectedService.id)}&date=${encodeURIComponent(date)}`, { cache: "no-store" })
      .then(async (response) => {
        const payload = await response.json().catch(() => null) as { slots?: SpaSlot[]; error?: string } | null;
        if (!response.ok || !payload?.slots) throw new Error(payload?.error || "Appointment times could not be loaded.");
        if (active) { setSlots(payload.slots); setSlotStart(""); }
      })
      .catch((loadError: unknown) => { if (active) setError(loadError instanceof Error ? loadError.message : "Appointment times could not be loaded."); })
      .finally(() => { if (active) setSlotLoading(false); });
    return () => { active = false; };
  }, [selectedService, date]);

  const beginBooking = (service: SpaService) => {
    setSelectedService(service);
    setDate("");
    setSlotStart("");
    setPaymentChoice("pay_at_spa");
    setConfirmation(null);
    setError("");
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const submitBooking = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!selectedService || !slotStart) return;
    setSubmitting(true);
    setError("");
    try {
      const createResponse = await fetch("/api/hotel-spa/bookings", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ serviceId: selectedService.id, slotStart, paymentChoice, guest: { firstName, lastName, email, phone } }),
      });
      const created = await createResponse.json().catch(() => null) as SpaBooking & { error?: string } | null;
      if (!createResponse.ok || !created?.booking_id || !created.accessToken) throw new Error(created?.error || "Appointment could not be booked.");
      if (paymentChoice === "pay_at_spa") {
        setConfirmation(created);
        setSelectedService(null);
        return;
      }
      localStorage.setItem("hotel-spa-access", JSON.stringify({ bookingId: created.booking_id, accessToken: created.accessToken, confirmationNumber: created.confirmation_number }));
      const paymentResponse = await fetch("/api/payments/hotel-spa/session", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ bookingId: created.booking_id, accessToken: created.accessToken }),
      });
      const payment = await paymentResponse.json().catch(() => null) as { paymentUrl?: string; error?: string } | null;
      if (!paymentResponse.ok || !payment?.paymentUrl) throw new Error(payment?.error || "Secure payment could not be prepared.");
      window.location.assign(payment.paymentUrl);
    } catch (bookingError) {
      setError(bookingError instanceof Error ? bookingError.message : "Appointment could not be booked.");
    } finally {
      setSubmitting(false);
    }
  };

  if (tenantLoading || loading) return <main className="container min-h-screen px-4 py-12" aria-busy="true"><div className="mx-auto h-80 max-w-5xl animate-pulse rounded-xl bg-muted" /></main>;

  return <main className="min-h-screen bg-gradient-to-br from-sheraton-cream via-white to-sheraton-pearl px-4 py-8">
    <div className="container mx-auto max-w-6xl">
      <header className="mb-8 text-center"><div className="mb-3 flex items-center justify-center gap-3"><Heart className="h-9 w-9 text-sheraton-gold" /><h1 className="text-4xl font-bold text-sheraton-navy">Spa & Wellness</h1></div><p className="text-gray-600">Book a treatment at {hotelName}.</p></header>
      {selectedService && <Card className="mx-auto mb-8 max-w-3xl border-sheraton-gold/60"><CardContent className="p-6"><div className="mb-5 flex items-start justify-between gap-4"><div><h2 className="text-xl font-semibold text-sheraton-navy">Book {selectedService.name}</h2><p className="mt-1 text-sm text-muted-foreground">{selectedService.duration_minutes} minutes · {money(Number(selectedService.price), selectedService.currency_code)}</p></div><Button type="button" variant="outline" onClick={() => { setSelectedService(null); setError(""); }}>Close</Button></div>
        <form onSubmit={(event) => void submitBooking(event)} className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2"><label className="space-y-2 text-sm">Appointment date<Input type="date" min={minimumDate} max={maximumDate} value={date} onChange={(event) => setDate(event.target.value)} required /></label><label className="space-y-2 text-sm">Available time<select className="h-10 w-full rounded-md border bg-background px-3" value={slotStart} onChange={(event) => setSlotStart(event.target.value)} required disabled={!date || slotLoading || !slots.length}><option value="">{slotLoading ? "Loading times…" : date ? slots.length ? "Choose a time" : "No times available" : "Choose a date first"}</option>{slots.map((slot) => <option key={slot.slot_start} value={slot.slot_start}>{formatSlot(slot, timezone)} · {slot.remaining_capacity} left</option>)}</select></label></div>
          {selectedService && <fieldset className="space-y-2"><legend className="text-sm font-medium">Payment option</legend><label className="flex cursor-pointer items-start gap-3 rounded-md border p-3"><input type="radio" name="spa-payment" checked={paymentChoice === "pay_at_spa"} onChange={() => setPaymentChoice("pay_at_spa")} /><span><strong>Pay at the spa</strong><span className="block text-sm text-muted-foreground">Book now and pay {money(Number(selectedService.price), selectedService.currency_code)} at the hotel.</span></span></label><label className="flex cursor-pointer items-start gap-3 rounded-md border p-3"><input type="radio" name="spa-payment" checked={paymentChoice === "full"} onChange={() => setPaymentChoice("full")} /><span><strong>Pay in full online</strong><span className="block text-sm text-muted-foreground">Pay {money(Number(selectedService.price), selectedService.currency_code)} securely now.</span></span></label><label className="flex cursor-pointer items-start gap-3 rounded-md border p-3"><input type="radio" name="spa-payment" checked={paymentChoice === "deposit"} onChange={() => setPaymentChoice("deposit")} /><span><strong>Pay a deposit online</strong><span className="block text-sm text-muted-foreground">Pay {money(depositAmount, selectedService.currency_code)} now; pay the remaining {money(Math.max(0, Number(selectedService.price) - depositAmount), selectedService.currency_code)} at the spa.</span></span></label></fieldset>}
          <div className="grid gap-4 sm:grid-cols-2"><label className="space-y-2 text-sm">First name<Input autoComplete="given-name" value={firstName} onChange={(event) => setFirstName(event.target.value)} maxLength={100} required /></label><label className="space-y-2 text-sm">Last name<Input autoComplete="family-name" value={lastName} onChange={(event) => setLastName(event.target.value)} maxLength={100} required /></label><label className="space-y-2 text-sm">Email<Input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} maxLength={254} required /></label><label className="space-y-2 text-sm">Phone<Input type="tel" autoComplete="tel" value={phone} onChange={(event) => setPhone(event.target.value)} maxLength={40} required /></label></div>
          {error && <p className="rounded-md border border-destructive/30 p-3 text-sm text-destructive" role="alert">{error}</p>}
          <div className="flex flex-wrap gap-3"><Button type="submit" disabled={submitting || !slotStart} className="bg-sheraton-gold text-sheraton-navy hover:bg-sheraton-gold/90">{submitting ? <><Loader2 className="mr-2 h-4 w-4 animate-spin" />Booking…</> : paymentChoice === "pay_at_spa" ? "Confirm appointment" : `Continue to pay ${money(amountDue, selectedService.currency_code)}`}</Button><Button type="button" variant="outline" onClick={() => setSelectedService(null)}>Cancel</Button></div>
        </form></CardContent></Card>}
      {confirmation && <Card className="mx-auto mb-8 max-w-3xl border-green-300 bg-green-50"><CardContent className="p-6"><h2 className="font-semibold text-green-900">Appointment confirmed</h2><p className="mt-1 text-sm text-green-900">{confirmation.confirmation_number} · {new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short", timeZone: confirmation.timezone }).format(new Date(confirmation.starts_at))}</p><p className="mt-1 text-sm text-green-900">Pay {money(Number(confirmation.service_price), confirmation.currency_code)} at the spa.</p></CardContent></Card>}
      {tenantError && <p className="mb-5 rounded-md border border-destructive/30 p-4 text-sm text-destructive">{tenantError}</p>}
      {!services.length ? <Card><CardContent className="p-10 text-center text-muted-foreground">Spa services are not available at this hotel yet.</CardContent></Card> : <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{services.map((service) => <Card key={service.id} className="overflow-hidden"><CardContent className="p-6"><div className="mb-4 flex items-center gap-3"><span className="text-4xl">🧖</span><div><h2 className="font-semibold text-sheraton-navy">{service.name}</h2><p className="font-semibold text-sheraton-gold">{money(Number(service.price), service.currency_code)}</p></div></div><p className="min-h-12 text-sm text-muted-foreground">{service.description}</p><div className="my-4 flex items-center gap-2 text-sm text-muted-foreground"><Clock className="h-4 w-4" />{service.duration_minutes} minutes</div><Button className="w-full bg-sheraton-gold text-sheraton-navy hover:bg-sheraton-gold/90" onClick={() => beginBooking(service)}><CalendarDays className="mr-2 h-4 w-4" />Book treatment</Button></CardContent></Card>)}</div>}
      <p className="mt-8 text-center text-sm text-muted-foreground"><Link to="/offers" className="underline">Back to offers</Link></p>
    </div>
  </main>;
};

export default HotelSpaPage;
