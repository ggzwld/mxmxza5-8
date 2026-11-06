import { useEffect, useState } from "react";
import { Checkbox } from "../ui/checkbox";
import { Input } from "../ui/input";
import { Label } from "../ui/label";
import { supabase } from "../../lib/supabase";

export const useSavedBuyerTaxId = () => {
  const [state, setState] = useState<{ loaded: boolean; savedTaxId: string | null }>({ loaded: false, savedTaxId: null });

  useEffect(() => {
    let active = true;
    const loadSavedTaxId = async () => {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) {
        if (active) setState({ loaded: true, savedTaxId: null });
        return;
      }
      const { data: profile } = await supabase
        .from("user_profiles")
        .select("buyer_tin")
        .eq("user_id", user.id)
        .maybeSingle();
      if (active) setState({ loaded: true, savedTaxId: profile?.buyer_tin?.trim() || null });
    };
    void loadSavedTaxId();
    return () => {
      active = false;
    };
  }, []);

  return state;
};

export const resolveBuyerTaxId = (businessPurchase: boolean, typedTaxId: string, savedTaxId: string | null): string | null =>
  businessPurchase ? savedTaxId || typedTaxId.trim() || null : null;

type BuyerTaxIdentityFieldsProps = {
  businessPurchase: boolean;
  onBusinessPurchaseChange: (value: boolean) => void;
  typedTaxId: string;
  onTypedTaxIdChange: (value: string) => void;
  savedTaxId: string | null;
  loaded: boolean;
};

export const BuyerTaxIdentityFields = ({
  businessPurchase,
  onBusinessPurchaseChange,
  typedTaxId,
  onTypedTaxIdChange,
  savedTaxId,
  loaded,
}: BuyerTaxIdentityFieldsProps) => (
  <div className="space-y-3 rounded-lg border p-4">
    <div className="flex items-center gap-2">
      <Checkbox
        id="business-purchase"
        checked={businessPurchase}
        onCheckedChange={(checked) => onBusinessPurchaseChange(checked === true)}
      />
      <Label htmlFor="business-purchase">This is a business purchase</Label>
    </div>
    {businessPurchase && loaded && savedTaxId && (
      <p className="text-sm text-muted-foreground">
        Your saved TIN, BRN or NIN <span className="font-medium text-foreground">{savedTaxId}</span> will appear on this receipt.
      </p>
    )}
    {businessPurchase && loaded && !savedTaxId && (
      <div className="space-y-2">
        <Label htmlFor="buyer-tax-id">TIN, BRN or NIN</Label>
        <Input
          id="buyer-tax-id"
          value={typedTaxId}
          onChange={(event) => onTypedTaxIdChange(event.target.value)}
          placeholder="Enter once; saved for future purchases"
        />
      </div>
    )}
  </div>
);
