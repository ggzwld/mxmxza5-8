import { createContext, useCallback, useContext, useEffect, useRef, useState, type Dispatch, type ReactNode, type SetStateAction } from "react";
import { supabase, useSupabaseAuth } from "./supabase";
import { useHotelTenant } from "./hotelTenant";

export type HotelRewardsSummary = {
  organizationId: string;
  organizationName: string;
  programName: string;
  availablePoints: number;
  lifetimePoints: number;
  enrolled: boolean;
  debtPoints: number;
  referralCode: string | null;
  referrals: { total: number; qualified: number; pending: number; pointsEarned: number };
  entries: Array<{ id: string; entryType: string; pointsDelta: number; description: string; createdAt: string }>;
  policy: {
    pointsPer1000Ugx: number;
    guestReferralMinimumUgx: number;
    referrerBonusPoints: number;
    inviteeBonusPoints: number;
    taskApprovalPoints: number;
    monthlyTaskPointsCap: number;
    ugxValuePerPoint: number;
    redemptionEnabled: boolean;
    pointsExpire: boolean;
    programEnabled: boolean;
  };
};

export type RewardsBalance = {
  organizationId: string;
  availablePoints: number;
} | null;

type RewardsPointsContextValue = {
  rewardsBalance: RewardsBalance;
  setRewardsBalance: Dispatch<SetStateAction<RewardsBalance>>;
  refreshRewardsBalance: () => Promise<void>;
};

const RewardsPointsContext = createContext<RewardsPointsContextValue | null>(null);

export const fetchCurrentHotelRewards = async (accessToken?: string): Promise<HotelRewardsSummary | null> => {
  let token = accessToken;
  if (!token) {
    const { data: { session } } = await supabase.auth.getSession();
    token = session?.access_token;
  }
  if (!token) throw new Error("Sign in to view hotel rewards");
  const response = await fetch("/api/hotel-rewards", {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store",
  });
  const payload = await response.json().catch(() => null) as HotelRewardsSummary | { error?: string } | null;
  if (!response.ok) {
    throw new Error(payload && "error" in payload ? payload.error || "Hotel rewards could not be loaded" : "Hotel rewards could not be loaded");
  }
  return payload as HotelRewardsSummary | null;
};

export const updateCurrentHotelRewardsEnrollment = async (enrolled: boolean) => {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session?.access_token) throw new Error("Sign in to manage rewards enrollment");
  const response = await fetch("/api/hotel-rewards/enrollment", {
    method: "POST",
    headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
    body: JSON.stringify({ enrolled }),
  });
  const payload = await response.json().catch(() => null) as { error?: string } | null;
  if (!response.ok) throw new Error(payload?.error || "Rewards preference could not be saved");
};

export const RewardsPointsProvider = ({ children }: { children: ReactNode }) => {
  const { tenant } = useHotelTenant();
  const { session, initialized: authInitialized } = useSupabaseAuth();
  const [rewardsBalance, setRewardsBalance] = useState<RewardsBalance>(null);
  const refreshInFlightRef = useRef<Promise<void> | null>(null);
  const refreshRewardsBalance = useCallback(async () => {
    if (!authInitialized || !tenant || !session) {
      setRewardsBalance(null);
      return;
    }
    if (refreshInFlightRef.current) return refreshInFlightRef.current;

    const refresh = (async () => {
      try {
        const rewards = await fetchCurrentHotelRewards(session.access_token);
        setRewardsBalance(rewards?.organizationId === tenant.organizationId
          ? { organizationId: tenant.organizationId, availablePoints: rewards.availablePoints }
          : null);
      } catch {
        setRewardsBalance(null);
      }
    })();
    refreshInFlightRef.current = refresh;
    try {
      await refresh;
    } finally {
      if (refreshInFlightRef.current === refresh) refreshInFlightRef.current = null;
    }
  }, [authInitialized, session?.access_token, tenant]);

  useEffect(() => {
    setRewardsBalance(null);
    void refreshRewardsBalance();
  }, [refreshRewardsBalance]);

  return (
    <RewardsPointsContext.Provider value={{ rewardsBalance, setRewardsBalance, refreshRewardsBalance }}>
      {children}
    </RewardsPointsContext.Provider>
  );
};

export const useRewardsPoints = () => {
  const context = useContext(RewardsPointsContext);
  if (!context) throw new Error("useRewardsPoints must be used within RewardsPointsProvider");
  return context;
};
