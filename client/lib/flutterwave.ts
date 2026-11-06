export interface FlutterwaveHostedSession {
  paymentUrl: string;
  txRef: string;
  orderId: string;
}

export interface MenuCheckoutCustomer {
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  roomNumber: string;
  deliveryAddress: string;
  specialRequests: string;
}

export interface ResumableMenuOrder {
  orderId: string;
  orderNumber: string;
  cart: Record<string, number>;
  orderType: "delivery" | "take-away" | "dine-in" | "room-service";
  paymentMethod: "card" | "mobile-money";
  tipAmount: number;
  tipPercentage: number;
  usePoints: boolean;
  customer: MenuCheckoutCustomer;
}

const legacyPendingCheckoutKey = "sheraton.pending-checkout";

export const clearPendingCheckout = () => {
  sessionStorage.removeItem(legacyPendingCheckoutKey);
};
