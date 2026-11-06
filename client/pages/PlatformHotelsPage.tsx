import { useEffect, useMemo, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { Building2, CheckCircle2, RefreshCw, ShieldCheck } from "lucide-react";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "../components/ui/select";
import { Textarea } from "../components/ui/textarea";
import { supabase } from "../lib/supabase";

type Organization = { id: string; name: string; country_code: string; base_currency: string; owner_id: string };
type HotelDomain = { domain: string; organization_id: string; verification_status: string; verification_method: string | null; verified_at: string | null };
type Hotel = {
  organization_id: string;
  display_name: string;
  logo_url: string | null;
  primary_color: string | null;
  accent_color: string | null;
  booking_title: string;
  booking_subtitle: string;
  is_active: boolean;
  domains: HotelDomain[];
};
type OnboardingData = { organizations: Organization[]; hotels: Hotel[] };
type VerificationData = { organizationId: string; domain: string; verificationStatus: string; verificationMethod: "dns_txt" | "vercel_project"; dnsTxtName: string | null; dnsTxtValue: string | null };

type HotelForm = {
  organizationId: string;
  organizationName: string;
  ownerEmail: string;
  countryCode: string;
  baseCurrency: string;
  displayName: string;
  bookingTitle: string;
  bookingSubtitle: string;
  logoUrl: string;
  primaryColor: string;
  accentColor: string;
  domain: string;
  verificationMethod: "dns_txt" | "vercel_project";
};

const initialForm: HotelForm = {
  organizationId: "new",
  organizationName: "",
  ownerEmail: "",
  countryCode: "UG",
  baseCurrency: "UGX",
  displayName: "",
  bookingTitle: "",
  bookingSubtitle: "",
  logoUrl: "",
  primaryColor: "",
  accentColor: "",
  domain: "",
  verificationMethod: "dns_txt",
};

const PlatformHotelsPage = () => {
  const [isLoading, setIsLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [data, setData] = useState<OnboardingData>({ organizations: [], hotels: [] });
  const [form, setForm] = useState<HotelForm>(initialForm);
  const [createdDomain, setCreatedDomain] = useState<VerificationData | null>(null);
  const [vercelConfirmed, setVercelConfirmed] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  const selectedOrganization = useMemo(
    () => data.organizations.find((organization) => organization.id === form.organizationId),
    [data.organizations, form.organizationId],
  );

  const request = async <T,>(path: string, options: RequestInit = {}) => {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.access_token) throw new Error("Sign in with the platform admin account to continue.");
    const response = await fetch(path, {
      ...options,
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        ...(options.body ? { "content-type": "application/json" } : {}),
        ...options.headers,
      },
      cache: "no-store",
    });
    const payload = await response.json().catch(() => null) as (T & { error?: string }) | null;
    if (!response.ok) throw new Error(payload?.error || "The platform request could not be completed.");
    return payload as T;
  };

  const load = async () => {
    setIsLoading(true);
    setError("");
    try {
      const status = await request<{ isPlatformAdmin: boolean }>("/api/platform/admin-status");
      setIsAdmin(status.isPlatformAdmin);
      if (!status.isPlatformAdmin) return;
      setData(await request<OnboardingData>("/api/platform/hotels"));
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Platform hotel data could not be loaded.");
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    void load();
  }, []);

  const setField = <K extends keyof HotelForm>(key: K, value: HotelForm[K]) => {
    setForm((previous) => ({ ...previous, [key]: value }));
  };

  const handleOrganizationChange = (value: string) => {
    setCreatedDomain(null);
    if (value === "new") {
      setForm({ ...initialForm });
      return;
    }
    const organization = data.organizations.find((item) => item.id === value);
    const tenant = data.hotels.find((item) => item.organization_id === value);
    setForm((previous) => ({
      ...previous,
      organizationId: value,
      domain: "",
      organizationName: organization?.name || "",
      countryCode: organization?.country_code || "UG",
      baseCurrency: organization?.base_currency || "UGX",
      displayName: tenant?.display_name || organization?.name || "",
      bookingTitle: tenant?.booking_title || `Book Your Stay at ${organization?.name || ""}`,
      bookingSubtitle: tenant?.booking_subtitle || "Enjoy a comfortable stay with thoughtful service and convenient amenities.",
      logoUrl: tenant?.logo_url || "",
      primaryColor: tenant?.primary_color || "",
      accentColor: tenant?.accent_color || "",
    }));
    setCreatedDomain(null);
  };

  const saveHotel = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setIsSaving(true);
    setNotice("");
    setError("");
    try {
      const result = await request<VerificationData>("/api/platform/hotels", {
        method: "POST",
        body: JSON.stringify({
          organizationId: form.organizationId === "new" ? null : form.organizationId,
          organizationName: form.organizationName,
          ownerEmail: form.ownerEmail,
          countryCode: form.countryCode,
          baseCurrency: form.baseCurrency,
          displayName: form.displayName,
          bookingTitle: form.bookingTitle,
          bookingSubtitle: form.bookingSubtitle,
          logoUrl: form.logoUrl || null,
          primaryColor: form.primaryColor || null,
          accentColor: form.accentColor || null,
          domain: form.domain.trim().toLowerCase(),
          verificationMethod: form.verificationMethod,
        }),
      });
      setCreatedDomain(result);
      setVercelConfirmed(false);

      setNotice(result.verificationStatus === "verified"
        ? `${result.domain} is already verified for this hotel.`
        : "Hotel saved. The pending hostname will not resolve until it is verified.");
      await load();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Hotel onboarding failed.");
    } finally {
      setIsSaving(false);
    }
  };

  const verifyDomain = async (domain: string, method: "dns_txt" | "vercel_project") => {
    setIsSaving(true);
    setNotice("");
    setError("");
    try {
      await request("/api/platform/hotels/verify-domain", {
        method: "POST",
        body: JSON.stringify({ domain, confirmVercelAssignment: method === "vercel_project" && vercelConfirmed }),
      });
      setNotice(`${domain} is verified.`);
      setCreatedDomain(null);
      setVercelConfirmed(false);

      await load();
    } catch (verifyError) {
      setError(verifyError instanceof Error ? verifyError.message : "Hostname verification failed.");
    } finally {
      setIsSaving(false);
    }
  };

  const prepareDomainVerification = async (hotel: Hotel, domain: HotelDomain) => {
    setIsSaving(true);
    setNotice("");
    setError("");
    try {
      const organization = data.organizations.find((item) => item.id === hotel.organization_id);
      const verificationMethod = domain.domain.endsWith(".vercel.app") ? "vercel_project" : "dns_txt";
      const result = await request<VerificationData>("/api/platform/hotels", {
        method: "POST",
        body: JSON.stringify({
          organizationId: hotel.organization_id,
          organizationName: organization?.name,
          countryCode: organization?.country_code,
          baseCurrency: organization?.base_currency,
          displayName: hotel.display_name,
          bookingTitle: hotel.booking_title,
          bookingSubtitle: hotel.booking_subtitle,
          logoUrl: hotel.logo_url,
          primaryColor: hotel.primary_color,
          accentColor: hotel.accent_color,
          domain: domain.domain,
          verificationMethod,
        }),
      });
      setCreatedDomain(result);

      setNotice(`A new verification challenge is ready for ${result.domain}.`);
    } catch (prepareError) {
      setError(prepareError instanceof Error ? prepareError.message : "A verification challenge could not be created.");
    } finally {
      setIsSaving(false);
    }
  };

  const activateHotel = async (organizationId: string) => {
    setIsSaving(true);
    setNotice("");
    setError("");
    try {
      await request("/api/platform/hotels/activate", {
        method: "POST",
        body: JSON.stringify({ organizationId }),
      });
      setNotice("Hotel activated. Refresh its domain to load the hotel experience.");
      await load();
    } catch (activateError) {
      setError(activateError instanceof Error ? activateError.message : "Hotel activation failed.");
    } finally {
      setIsSaving(false);
    }
  };

  if (isLoading) return <main className="container py-12">Loading platform hotel onboarding…</main>;

  if (!isAdmin) {
    return (
      <main className="container max-w-2xl py-12">
        <Card>
          <CardHeader><CardTitle>Platform admin access required</CardTitle></CardHeader>
          <CardContent className="space-y-3 text-sm text-muted-foreground">
            <p>Sign in with the approved platform administrator account to onboard hotels.</p>
            <Button asChild variant="outline"><Link to="/login">Sign in</Link></Button>
            {error && <p role="alert" className="text-destructive">{error}</p>}
          </CardContent>
        </Card>
      </main>
    );
  }

  return (
    <main className="container max-w-6xl space-y-8 py-10">
      <header className="space-y-2">
        <div className="flex items-center gap-3">
          <Building2 className="h-7 w-7 text-primary" />
          <h1 className="text-3xl font-bold">Platform hotel onboarding</h1>
        </div>
        <p className="text-muted-foreground">Assign an organization, configure hotel presentation, verify its hostname, then activate it.</p>
      </header>

      {(notice || error) && (
        <div role={error ? "alert" : "status"} className={`rounded-md border p-3 text-sm ${error ? "border-destructive/40 bg-destructive/10 text-destructive" : "border-emerald-500/40 bg-emerald-500/10"}`}>
          {error || notice}
        </div>
      )}

      <Card>
        <CardHeader><CardTitle>Onboard a hotel</CardTitle></CardHeader>
        <CardContent>
          <form className="space-y-6" onSubmit={saveHotel}>
            <div className="grid gap-4 md:grid-cols-2">
              <div className="space-y-2 md:col-span-2">
                <Label>Books organization</Label>
                <Select value={form.organizationId} onValueChange={handleOrganizationChange}>
                  <SelectTrigger><SelectValue placeholder="Choose or create an organization" /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="new">Create a new organization</SelectItem>
                    {data.organizations.map((organization) => (
                      <SelectItem key={organization.id} value={organization.id}>{organization.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {form.organizationId === "new" ? (
                <>
                  <div className="space-y-2">
                    <Label htmlFor="organizationName">Organization name</Label>
                    <Input id="organizationName" value={form.organizationName} onChange={(event) => setField("organizationName", event.target.value)} required />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="ownerEmail">Confirmed Supabase account email for an owner with a manager profile</Label>
                    <Input id="ownerEmail" type="email" value={form.ownerEmail} onChange={(event) => setField("ownerEmail", event.target.value)} required />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="countryCode">Country code</Label>
                    <Input id="countryCode" maxLength={2} value={form.countryCode} onChange={(event) => setField("countryCode", event.target.value.toUpperCase())} required />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="baseCurrency">Base currency</Label>
                    <Input id="baseCurrency" maxLength={3} value={form.baseCurrency} onChange={(event) => setField("baseCurrency", event.target.value.toUpperCase())} required />
                  </div>
                </>
              ) : (
                <p className="text-sm text-muted-foreground md:col-span-2">Using existing organization: {selectedOrganization?.name}</p>
              )}

              <div className="space-y-2">
                <Label htmlFor="displayName">Hotel display name</Label>
                <Input id="displayName" value={form.displayName} onChange={(event) => setField("displayName", event.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="domain">Hostname (no https:// or path)</Label>
                <Input id="domain" placeholder="hgrtxz00.vercel.app" value={form.domain} onChange={(event) => {
                  const domain = event.target.value.trim().toLowerCase();
                  setField("domain", domain);
                  setField("verificationMethod", domain.endsWith(".vercel.app") ? "vercel_project" : "dns_txt");
                }} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="bookingTitle">Booking page title</Label>
                <Input id="bookingTitle" value={form.bookingTitle} onChange={(event) => setField("bookingTitle", event.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="bookingSubtitle">Booking page subtitle</Label>
                <Textarea id="bookingSubtitle" value={form.bookingSubtitle} onChange={(event) => setField("bookingSubtitle", event.target.value)} required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="logoUrl">Logo URL (optional)</Label>
                <Input id="logoUrl" type="url" value={form.logoUrl} onChange={(event) => setField("logoUrl", event.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="primaryColor">Primary color (optional, #RRGGBB)</Label>
                <Input id="primaryColor" pattern="^#[0-9A-Fa-f]{6}$" placeholder="#132040" value={form.primaryColor} onChange={(event) => setField("primaryColor", event.target.value)} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="accentColor">Accent color (optional, #RRGGBB)</Label>
                <Input id="accentColor" pattern="^#[0-9A-Fa-f]{6}$" placeholder="#D5AF37" value={form.accentColor} onChange={(event) => setField("accentColor", event.target.value)} />
              </div>
            </div>

            <div className="rounded-md border p-4 text-sm text-muted-foreground">
              {form.verificationMethod === "dns_txt"
                ? "A one-time DNS TXT challenge will be generated. Add it at your domain’s DNS provider, verify it, then activate the hotel."
                : "For a Vercel hostname, save the hotel, confirm that this exact hostname is assigned to your Vercel project, then verify and activate it."}
            </div>
            <Button type="submit" disabled={isSaving}>
              {isSaving ? "Saving…" : "Save hotel as inactive"}
            </Button>
          </form>
        </CardContent>
      </Card>

      {createdDomain?.dnsTxtName && createdDomain.dnsTxtValue && (
        <Card>
          <CardHeader><CardTitle>Verify DNS ownership</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-muted-foreground">Create a TXT record at your DNS provider with these exact values. The challenge expires after 24 hours.</p>
            <div className="grid gap-3 md:grid-cols-2">
              <div className="space-y-2"><Label>Record name</Label><Input readOnly value={createdDomain.dnsTxtName} /></div>
              <div className="space-y-2"><Label>TXT value</Label><Input readOnly value={createdDomain.dnsTxtValue} /></div>
            </div>
            <Button variant="outline" onClick={() => void verifyDomain(createdDomain.domain, "dns_txt")} disabled={isSaving}>
              <ShieldCheck className="mr-2 h-4 w-4" /> Verify DNS record
            </Button>
          </CardContent>
        </Card>
      )}

      {createdDomain?.verificationMethod === "vercel_project" && createdDomain.verificationStatus !== "verified" && (
        <Card>
          <CardHeader><CardTitle>Verify Vercel hostname</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-muted-foreground">Vercel does not provide a DNS challenge for its shared vercel.app zone. Confirm the exact hostname is assigned to your project before marking this admin review complete.</p>
            <label className="flex items-start gap-3 text-sm">
              <input type="checkbox" className="mt-1" checked={vercelConfirmed} onChange={(event) => setVercelConfirmed(event.target.checked)} />
              <span>I verified this exact hostname in the Vercel project’s Domains settings.</span>
            </label>
            <Button variant="outline" onClick={() => void verifyDomain(createdDomain.domain, "vercel_project")} disabled={isSaving || !vercelConfirmed}>
              <ShieldCheck className="mr-2 h-4 w-4" /> Mark reviewed and verify
            </Button>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-3">
          <CardTitle>Hotels</CardTitle>
          <Button variant="outline" size="sm" onClick={() => void load()} disabled={isLoading}>
            <RefreshCw className="mr-2 h-4 w-4" /> Refresh
          </Button>
        </CardHeader>
        <CardContent className="space-y-4">
          {data.hotels.length === 0 ? (
            <p className="text-sm text-muted-foreground">No hotel tenants have been configured.</p>
          ) : data.hotels.map((hotel) => {
            const canActivate = hotel.domains.some((domain) => domain.verification_status === "verified");
            return (
              <div key={hotel.organization_id} className="flex flex-col gap-4 rounded-md border p-4 md:flex-row md:items-center md:justify-between">
                <div className="space-y-2">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-semibold">{hotel.display_name}</h3>
                    <Badge variant={hotel.is_active ? "default" : "secondary"}>{hotel.is_active ? "Active" : "Inactive"}</Badge>
                  </div>
                  <p className="text-xs text-muted-foreground">Organization: {data.organizations.find((organization) => organization.id === hotel.organization_id)?.name || hotel.organization_id}</p>
                  {hotel.domains.length === 0 ? <p className="text-sm text-muted-foreground">No hostname registered</p> : (
                    <div className="space-y-2">
                      {hotel.domains.map((domain) => (
                        <div key={domain.domain} className="flex flex-wrap items-center gap-2 text-sm">
                          <span>{domain.domain}</span>
                          <Badge variant={domain.verification_status === "verified" || domain.verification_status === "legacy" ? "outline" : "secondary"}>
                            {domain.verification_status === "legacy" ? "Existing mapping" : domain.verification_status}
                          </Badge>
                          {(domain.verification_status === "pending" || domain.verification_status === "legacy") && (
                            <Button size="sm" variant="outline" onClick={() => {
                              void prepareDomainVerification(hotel, domain);
                            }}>
                              Prepare verification
                            </Button>
                          )}
                          {domain.verification_status === "verified" && <CheckCircle2 className="h-4 w-4 text-emerald-600" />}
                        </div>
                      ))}
                    </div>
                  )}
                </div>
                {!hotel.is_active && (
                  <Button onClick={() => void activateHotel(hotel.organization_id)} disabled={isSaving || !canActivate}>
                    Activate hotel
                  </Button>
                )}
              </div>
            );
          })}
        </CardContent>
      </Card>
    </main>
  );
};

export default PlatformHotelsPage;
