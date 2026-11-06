import { useState, useEffect } from "react";
import { Link, useNavigate } from "react-router-dom";
import { toast } from "sonner";
import { Button } from "../components/ui/button";
import CheckoutPage from "../components/checkout/CheckoutPage";
import MuxVideoPlayer from "../components/MuxVideoPlayer";
import { menuItemFromDatabaseRow, MenuItem } from "../lib/menuData";
import { supabase } from "../lib/supabase";
import { clearPendingCheckout, type ResumableMenuOrder } from "../lib/flutterwave";
import { loadActiveMenuCart, syncActiveMenuCart } from "../lib/menuCart";
import { useHotelTenant } from "../lib/hotelTenant";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Badge } from "../components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "../components/ui/select";
import { Separator } from "../components/ui/separator";
import {
  Crown,
  QrCode,
  Clock,
  Star,
  Heart,
  Utensils,
  Coffee,
  Wine,
  IceCream,
  Search,
  Filter,
  ShoppingCart,
  Plus,
  Minus,
  Leaf,
  Flame,
  Fish,
  Apple,
  AlertCircle,
  TrendingUp,
  Timer,
  Users,
  ChefHat,
  Globe,
  Bell,
  Gift,
} from "lucide-react";

const MenuSpecialOffer = () => {
  const [currentTime, setCurrentTime] = useState(() => new Date());

  useEffect(() => {
    const timer = setInterval(() => setCurrentTime(new Date()), 60_000);
    return () => clearInterval(timer);
  }, []);

  const hour = currentTime.getHours();
  const offer = hour >= 11 && hour < 15
    ? {
        title: "Lunch Special",
        description: "Order now and skip the queue - you come first!",
        emoji: "🍽️",
        endsAt: new Date(currentTime.getTime() + (15 - hour) * 60 * 60 * 1000 - currentTime.getMinutes() * 60 * 1000),
      }
    : hour >= 17 && hour < 23
      ? {
          title: "Evening Delight",
          description: "Live jazz band + special cocktail prices",
          emoji: "🎷",
          endsAt: new Date(currentTime.getTime() + (23 - hour) * 60 * 60 * 1000 - currentTime.getMinutes() * 60 * 1000),
        }
      : null;

  if (!offer) return null;

  const remainingTime = offer.endsAt.getTime() - currentTime.getTime();

  return (
    <Card className="mb-8 border-sheraton-gold bg-gradient-to-r from-sheraton-gold/10 to-sheraton-gold/5">
      <CardContent className="p-6">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-4">
            <div className="text-4xl">{offer.emoji}</div>
            <div>
              <h3 className="text-xl font-bold text-sheraton-navy">{offer.title}</h3>
              <p className="text-muted-foreground">{offer.description}</p>
            </div>
          </div>
          <div className="text-right">
            <div className="text-sm text-muted-foreground">Ends in:</div>
            <div className="text-2xl font-bold text-sheraton-gold">
              {Math.floor(remainingTime / (1000 * 60 * 60))}h {Math.floor((remainingTime % (1000 * 60 * 60)) / (1000 * 60))}m
            </div>
          </div>
        </div>
      </CardContent>
    </Card>
  );
};

const MenuPage = () => {
  const { tenant } = useHotelTenant();
  const navigate = useNavigate();
  const [availabilitySubscriptions, setAvailabilitySubscriptions] = useState<Set<string>>(new Set());
  const [subscribingItemId, setSubscribingItemId] = useState<string | null>(null);
  const [searchTerm, setSearchTerm] = useState("");
  const [selectedCategory, setSelectedCategory] = useState("all");
  const [cart, setCart] = useState<{ [key: string]: number }>({});
  const [isDesktopViewport, setIsDesktopViewport] = useState(() => typeof window !== "undefined" && window.innerWidth >= 768);
  const [mediaAspectRatios, setMediaAspectRatios] = useState<Record<string, number>>({});
  const [showCheckoutPage, setShowCheckoutPage] = useState(false);
  const [resumableOrder, setResumableOrder] = useState<ResumableMenuOrder | undefined>();
  const [resumeCart, setResumeCart] = useState<Record<string, number> | null>(null);
  const [durableCartId, setDurableCartId] = useState<string | null>(null);
  const [cartReady, setCartReady] = useState(false);

  useEffect(() => {
    const updateViewport = () => setIsDesktopViewport(window.innerWidth >= 768);
    window.addEventListener("resize", updateViewport);
    return () => window.removeEventListener("resize", updateViewport);
  }, []);

  useEffect(() => {
    if (!tenant) return;
    setCartReady(false);
    setCart({});
    setDurableCartId(null);
    setResumableOrder(undefined);
    setResumeCart(null);
    clearPendingCheckout();

    loadActiveMenuCart(tenant.organizationId)
      .then((savedCart) => {
        if (!savedCart) return;
        setDurableCartId(savedCart.id);
        setCart(Object.fromEntries(savedCart.items.map((item) => [item.menu_item_id, Number(item.quantity)])));
      })
      .catch((error) => console.error("Unable to load saved menu cart", error))
      .finally(() => setCartReady(true));
  }, [tenant?.organizationId]);

  useEffect(() => {
    let active = true;

    const restoreUnpaidOrder = async () => {
      if (!tenant) return;

      const { data: { user } } = await supabase.auth.getUser();
      if (!user) return;

      const { data: order } = await supabase
        .from("menu_orders")
        .select("id, order_number, order_type, payment_method, tip_amount, points_discount, first_name, last_name, email, phone, room_number, delivery_address, special_requests")
        .eq("organization_id", tenant.organizationId)
        .eq("user_id", user.id)
        .eq("status", "pending")
        .in("payment_status", ["pending", "cancelled", "failed"])
        .in("payment_method", ["card", "mobile-money"])
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      if (!order || !active) return;

      const { data: orderItems } = await supabase
        .from("menu_order_items")
        .select("menu_item_id, quantity")
        .eq("order_id", order.id);

      if (!orderItems?.length || !active) return;

      const restoredCart = Object.fromEntries(
        orderItems.map((item) => [item.menu_item_id, Number(item.quantity)]),
      );
      const restoredOrder: ResumableMenuOrder = {
        orderId: order.id,
        orderNumber: order.order_number,
        cart: restoredCart,
        orderType: order.order_type,
        paymentMethod: order.payment_method,
        tipAmount: Number(order.tip_amount || 0),
        tipPercentage: 0,
        usePoints: Number(order.points_discount || 0) > 0,
        customer: {
          firstName: order.first_name,
          lastName: order.last_name,
          email: order.email || "",
          phone: order.phone,
          roomNumber: order.room_number || "",
          deliveryAddress: order.delivery_address || "",
          specialRequests: order.special_requests || "",
        },
      };

      setResumableOrder(restoredOrder);
    };

    restoreUnpaidOrder().catch((error) => console.error("Unable to restore unpaid menu order", error));
    return () => {
      active = false;
    };
  }, [tenant?.organizationId]);

  const [menuItems, setMenuItems] = useState<MenuItem[]>([]);
  const [menuItemsReady, setMenuItemsReady] = useState(false);

  useEffect(() => {
    if (!tenant || !cartReady || !menuItemsReady || menuItems.length === 0 || (!durableCartId && Object.keys(cart).length === 0)) return;

    const timeout = window.setTimeout(() => {
      const items = Object.entries(cart)
        .map(([menuItemId, quantity]) => {
          const item = menuItems.find((menuItem) => menuItem.id === menuItemId);
          return item ? { menuItemId, quantity, unitPrice: item.price } : null;
        })
        .filter((item): item is { menuItemId: string; quantity: number; unitPrice: number } => Boolean(item));

      syncActiveMenuCart(durableCartId, items, tenant.organizationId)
        .then((cartId) => setDurableCartId(cartId))
        .catch((error) => console.error("Unable to save menu cart", error));
    }, 250);

    return () => window.clearTimeout(timeout);
  }, [cart, cartReady, durableCartId, menuItems, menuItemsReady, tenant?.organizationId]);

  const categories = [
    { id: "all", name: "All Items", icon: Utensils },
    { id: "appetizers", name: "Appetizers", icon: Coffee },
    { id: "mains", name: "Main Courses", icon: ChefHat },
    { id: "desserts", name: "Desserts", icon: IceCream },
    { id: "beverages", name: "Beverages", icon: Wine },
    { id: "special", name: "Special Offers", icon: Crown },
  ];

  useEffect(() => {
    let active = true;
    if (!tenant) {
      setMenuItemsReady(false);
      return () => { active = false; };
    }
    fetch("/api/hotel-menu-items", { cache: "no-store" })
      .then(async (response) => {
        const payload = await response.json().catch(() => null) as { items?: Record<string, unknown>[]; error?: string } | null;
        if (!response.ok) throw new Error(payload?.error || "Menu information could not be loaded.");
        if (active && payload?.items) setMenuItems(payload.items.map(menuItemFromDatabaseRow));
      })
      .catch((error) => console.error("Unable to load tenant menu items", error))
      .finally(() => { if (active) setMenuItemsReady(true); });
    return () => { active = false; };
  }, [tenant?.organizationId]);

  useEffect(() => {
    let active = true;

    const loadAvailabilitySubscriptions = async () => {
      if (!tenant) return;
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) return;

      const { data, error } = await supabase
        .from("menu_availability_subscriptions")
        .select("menu_item_id")
        .eq("user_id", user.id)
        .eq("organization_id", tenant.organizationId);
      if (error) throw error;
      if (active) setAvailabilitySubscriptions(new Set((data || []).map((row) => row.menu_item_id)));
    };

    loadAvailabilitySubscriptions().catch((error) => console.error("Unable to load menu availability requests", error));
    return () => { active = false; };
  }, [tenant?.organizationId]);

  const requestMenuAvailability = async (item: MenuItem) => {
    const itemId = item.databaseId;
    if (!itemId) return;

    setSubscribingItemId(itemId);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) {
        toast("Sign in to get a restock notification", {
          action: { label: "Sign in", onClick: () => navigate("/login?returnTo=%2Fmenu") },
        });
        return;
      }

      const response = await fetch("/api/hotel-menu-availability", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          Authorization: `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({ menuItemId: itemId }),
      });
      const result = await response.json().catch(() => null) as { subscribed?: boolean } | null;
      if (!response.ok || !result) throw new Error("Unable to save availability request");
      if (!result.subscribed) {
        toast.message("This dish is available now. Refresh the menu to order it.");
        return;
      }

      setAvailabilitySubscriptions((current) => new Set(current).add(itemId));
      toast.success("We’ll notify you when this dish is back.");
    } catch {
      toast.error("We couldn’t save your restock request. Please try again.");
    } finally {
      setSubscribingItemId(null);
    }
  };

  const filteredItems = menuItems.filter((item) => {
    const matchesSearch =
      item.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      item.description.toLowerCase().includes(searchTerm.toLowerCase());
    const matchesCategory =
      selectedCategory === "all" || item.category === selectedCategory;
    return matchesSearch && matchesCategory;
  });

  const addToCart = (itemId: string) => {
    setCart((prev) => ({ ...prev, [itemId]: (prev[itemId] || 0) + 1 }));
  };

  const removeFromCart = (itemId: string) => {
    setCart((prev) => {
      const newCart = { ...prev };
      if (newCart[itemId] > 1) {
        newCart[itemId]--;
      } else {
        delete newCart[itemId];
      }
      return newCart;
    });
  };

  const updateCart = (itemId: string, quantity: number) => {
    if (quantity <= 0) {
      setCart((prev) => {
        const newCart = { ...prev };
        delete newCart[itemId];
        return newCart;
      });
    } else {
      setCart((prev) => ({ ...prev, [itemId]: quantity }));
    }
  };

  const removeFromCartCompletely = (itemId: string) => {
    setCart((prev) => {
      const newCart = { ...prev };
      delete newCart[itemId];
      return newCart;
    });
  };

  const getTotalPrice = () => {
    return Object.entries(cart).reduce((total, [itemId, quantity]) => {
      const item = menuItems.find((i) => i.id === itemId);
      return total + (item ? item.price * quantity : 0);
    }, 0);
  };

  const getCartCurrency = () => {
    const currencies = new Set(
      Object.keys(cart).map((itemId) => menuItems.find((item) => item.id === itemId)?.currency || "USD"),
    );
    return currencies.size === 1 ? [...currencies][0] : null;
  };

  const formatCartTotal = () => {
    const currency = getCartCurrency();
    return currency ? formatPrice(getTotalPrice(), currency) : "Multiple currencies";
  };

  const getTotalItems = () => {
    return Object.values(cart).reduce((total, quantity) => total + quantity, 0);
  };

  const getAvailabilityStatus = (item: any) => {
    const percentage = (item.availability / item.maxAvailability) * 100;
    if (percentage === 0)
      return { status: "out", color: "text-red-500", message: "Sold Out" };
    if (percentage < 25)
      return {
        status: "low",
        color: "text-orange-500",
        message: "Almost Gone!",
      };
    if (percentage < 50)
      return { status: "medium", color: "text-yellow-500", message: "Limited" };
    return { status: "good", color: "text-green-500", message: "Available" };
  };

  const formatPrice = (amount: number, currency = "USD") =>
    new Intl.NumberFormat(undefined, { style: "currency", currency }).format(amount);

  if (showCheckoutPage) {
    return (
      <CheckoutPage
        onBack={() => { setShowCheckoutPage(false); setResumeCart(null); }}
        cart={resumeCart || cart}
        menuItems={menuItems}
        onUpdateCart={resumeCart ? (itemId, quantity) => setResumeCart((current) => ({ ...(current || {}), [itemId]: quantity })) : updateCart}
        onRemoveFromCart={resumeCart ? (itemId) => setResumeCart((current) => { const next = { ...(current || {}) }; delete next[itemId]; return next; }) : removeFromCartCompletely}
        resumableOrder={resumeCart ? resumableOrder : undefined}
        durableCartId={resumeCart ? null : durableCartId}
      />
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-b from-sheraton-cream to-background">
      <div className="container mx-auto px-4 py-8 pb-24 md:px-8 md:pb-8">
        {/* Header */}
        <div className="text-center mb-8">
          <div className="flex items-center justify-center mb-4">
            <QrCode className="h-8 w-8 text-sheraton-gold mr-2" />
            <Badge className="bg-sheraton-gold text-sheraton-navy px-4 py-2">
              Digital Menu - Always Fresh
            </Badge>
          </div>
          <h1 className="text-4xl md:text-5xl font-bold text-sheraton-navy mb-4">
            {tenant?.name || "Hotel"} Menu
          </h1>
          <p className="text-lg text-muted-foreground max-w-2xl mx-auto">
            Real-time availability • Eco-friendly • Skip the queue • Special
            guest priority
          </p>

          {/* Environmental Impact */}
          <div className="flex items-center justify-center gap-2 mt-4 text-sm text-green-600">
            <Leaf className="h-4 w-4" />
            <span>
              You're helping save 12 trees per month by using our digital menu!
            </span>
          </div>
        </div>

        <MenuSpecialOffer />

        {resumableOrder && <Card className="mb-6 border-sheraton-gold/40 bg-sheraton-gold/5"><CardContent className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"><div><p className="font-semibold text-sheraton-navy">Unfinished order {resumableOrder.orderNumber}</p><p className="text-sm text-muted-foreground">Your menu is ready to browse. Resume payment whenever you’re ready.</p></div><Button className="sheraton-gradient text-white" onClick={() => { setResumeCart(resumableOrder.cart); setShowCheckoutPage(true); }}>Resume Order</Button></CardContent></Card>}

        <section aria-labelledby="menu-categories-heading" className="mb-8 lg:hidden">
          <h2 id="menu-categories-heading" className="mb-4 flex items-center justify-center gap-2 text-lg font-semibold text-sheraton-navy">
            <Filter className="h-5 w-5 text-sheraton-gold" />
            Categories
          </h2>
          <div role="group" aria-label="Menu categories" className="flex flex-wrap justify-center gap-2">
            {categories.map((category) => (
              <Button
                key={category.id}
                variant={selectedCategory === category.id ? "default" : "outline"}
                aria-pressed={selectedCategory === category.id}
                className={`flex items-center gap-2 ${
                  selectedCategory === category.id ? "bg-sheraton-gold text-sheraton-navy hover:bg-sheraton-gold" : ""
                }`}
                onClick={() => setSelectedCategory(category.id)}
              >
                <category.icon className="h-4 w-4" />
                <span>{category.name}</span>
              </Button>
            ))}
          </div>
        </section>

        <div className="grid grid-cols-1 lg:grid-cols-4 gap-8">
          {/* Filters and Categories */}
          <div className="lg:col-span-1 space-y-6">
            {/* Search */}
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Search className="h-5 w-5 text-sheraton-gold" />
                  Find Your Dish
                </CardTitle>
              </CardHeader>
              <CardContent>
                <Input
                  placeholder="Search menu items..."
                  value={searchTerm}
                  onChange={(e) => setSearchTerm(e.target.value)}
                  className="w-full"
                />
              </CardContent>
            </Card>

            <Card className="hidden lg:block">
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Filter className="h-5 w-5 text-sheraton-gold" />
                  Categories
                </CardTitle>
              </CardHeader>
              <CardContent className="flex gap-2 overflow-x-auto pb-2 md:flex-col md:overflow-visible md:pb-0">
                {categories.map((category) => (
                  <Button
                    key={category.id}
                    variant={selectedCategory === category.id ? "default" : "ghost"}
                    aria-pressed={selectedCategory === category.id}
                    className={`w-auto shrink-0 justify-start gap-2 md:w-full ${
                      selectedCategory === category.id ? "sheraton-gradient text-white" : ""
                    }`}
                    onClick={() => setSelectedCategory(category.id)}
                  >
                    <category.icon className="h-4 w-4" />
                    {category.name}
                  </Button>
                ))}
              </CardContent>
            </Card>

          </div>

          {/* Menu Items */}
          <div className="lg:col-span-3">
            {filteredItems.length === 0 ? (
              menuItemsReady ? (
                <Card className="border-dashed bg-card/80">
                  <CardContent className="flex min-h-56 flex-col items-center justify-center px-6 py-10 text-center">
                    <Utensils className="mb-4 h-8 w-8 text-sheraton-gold" aria-hidden="true" />
                    <h2 className="text-lg font-semibold">
                      {menuItems.length === 0 ? "Menu coming soon" : "No dishes match your search"}
                    </h2>
                    <p className="mt-2 max-w-sm text-sm text-muted-foreground">
                      {menuItems.length === 0
                        ? "Our team is preparing the menu. Please check back shortly."
                        : "Try another search or clear your filters to see more dishes."}
                    </p>
                    {menuItems.length > 0 && (
                      <Button
                        variant="outline"
                        className="mt-4"
                        onClick={() => { setSearchTerm(""); setSelectedCategory("all"); }}
                      >
                        Clear filters
                      </Button>
                    )}
                  </CardContent>
                </Card>
              ) : null
            ) : (
              <div className="grid grid-cols-1 gap-6">
                {filteredItems.map((item) => {
                const availability = getAvailabilityStatus(item);
                const cartQuantity = cart[item.id] || 0;
                const discountPercent = item.originalPrice > item.price
                  ? Math.round((1 - item.price / item.originalPrice) * 100)
                  : 0;
                const isVideoItem = item.mediaType === "video" && Boolean(item.mediaUrl);
                const mediaAspectRatio = item.mediaAspectRatio ?? mediaAspectRatios[item.id];
                const isPortraitMedia = mediaAspectRatio !== undefined && mediaAspectRatio < 1;
                const isDesktopPortraitMedia = Boolean(item.mediaUrl) && isDesktopViewport && isPortraitMedia;
                const isMobilePortraitVideo = isVideoItem && !isDesktopViewport && isPortraitMedia;
                const customStatuses = item.statuses || [];
                const statusLabels = availability.status === "out"
                  ? ["Sold out", ...customStatuses.filter((status) => status.toLowerCase() !== "available" && status.toLowerCase() !== "sold out")]
                  : customStatuses.length ? customStatuses : ["Available"];

                return (
                  <Card
                    key={item.id}
                    className={`overflow-hidden hover:shadow-lg transition-shadow ${
                      availability.status === "out" ? "opacity-80" : ""
                    }`}
                  >
                    <CardContent className={`p-0 ${isDesktopPortraitMedia ? "md:grid md:grid-cols-[minmax(210px,0.75fr)_minmax(0,1.65fr)] md:items-stretch" : ""}`}>
                      {item.mediaUrl && (
                        item.mediaType === "video" ? (
                          <div className={isDesktopPortraitMedia ? "min-w-0" : "w-full"}>
                            <MuxVideoPlayer
                              key={`${item.id}-${item.mediaAttachmentId}`}
                              attachmentId={item.mediaAttachmentId}
                              initialPlaybackId={item.mediaPlaybackId}
                              initialAspectRatio={item.mediaAspectRatio}
                              initialVideoStatus={item.mediaVideoStatus}
                              controlsMode="minimal"
                              presentation="immersive"
                              overlayOnlyOnMobilePortrait
                              onAspectRatioChange={(ratio) => {
                                if (item.mediaAspectRatio === ratio) return;
                                setMediaAspectRatios((current) => current[item.id] === ratio ? current : { ...current, [item.id]: ratio });
                              }}
                              overlay={(
                                <div className="pointer-events-none absolute inset-x-0 bottom-0 z-10 bg-gradient-to-t from-black/95 via-black/70 to-transparent px-4 pb-4 pt-20 text-white sm:px-6 sm:pb-5">
                                  <div className="pointer-events-auto flex items-end justify-between gap-3">
                                    <div className="min-w-0 flex-1">
                                      <h3 className="truncate text-lg font-semibold drop-shadow-sm sm:text-xl">{item.name}</h3>
                                      {item.special_offer && (
                                        <p className="mt-0.5 truncate text-sm font-medium text-white/90">{item.special_offer}</p>
                                      )}
                                      <div className="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                                        <span className="text-xl font-bold">{formatPrice(item.price, item.currency)}</span>
                                        {discountPercent > 0 && (
                                          <>
                                            <span className="text-sm text-white/80 line-through">{formatPrice(item.originalPrice, item.currency)}</span>
                                            <span className="text-sm font-semibold text-amber-200">{discountPercent}% off</span>
                                          </>
                                        )}
                                      </div>
                                    </div>
                                    {cartQuantity > 0 ? (
                                      <div className="pointer-events-auto flex shrink-0 items-center gap-1.5 rounded-full bg-white/15 p-1 backdrop-blur-sm">
                                        <Button
                                          size="icon"
                                          variant="ghost"
                                          aria-label={`Remove one ${item.name} from order`}
                                          className="h-9 w-9 text-white hover:bg-white/20 hover:text-white"
                                          onClick={() => removeFromCart(item.id)}
                                        >
                                          <Minus className="h-4 w-4" />
                                        </Button>
                                        <span className="min-w-5 text-center text-sm font-semibold" aria-label={`${cartQuantity} in order`}>{cartQuantity}</span>
                                        <Button
                                          size="icon"
                                          variant="ghost"
                                          aria-label={`Add one ${item.name} to order`}
                                          className="h-9 w-9 text-white hover:bg-white/20 hover:text-white"
                                          onClick={() => addToCart(item.id)}
                                          disabled={item.availability === 0}
                                        >
                                          <Plus className="h-4 w-4" />
                                        </Button>
                                      </div>
                                    ) : item.availability > 0 ? (
                                      <Button
                                        onClick={() => addToCart(item.id)}
                                        className="pointer-events-auto h-10 shrink-0 rounded-full bg-sheraton-gold px-4 text-sheraton-navy shadow-lg hover:bg-sheraton-gold/90"
                                      >
                                        <Plus className="mr-1.5 h-4 w-4" />
                                        <span className="hidden sm:inline">Add to order</span>
                                        <span className="sm:hidden">Add</span>
                                      </Button>
                                    ) : (
                                      <span className="shrink-0 rounded-full bg-black/45 px-3 py-2 text-xs font-medium text-white/90">Sold out</span>
                                    )}
                                  </div>
                                </div>
                              )}
                            />
                          </div>
                        ) : (
                          <img
                            src={item.mediaUrl}
                            alt={`${item.name} dish`}
                            loading="lazy"
                            onLoad={(event) => {
                              if (item.mediaAspectRatio) return;
                              const image = event.currentTarget;
                              if (!image.naturalWidth || !image.naturalHeight) return;
                              const ratio = image.naturalWidth / image.naturalHeight;
                              setMediaAspectRatios((current) => current[item.id] === ratio ? current : { ...current, [item.id]: ratio });
                            }}
                            style={mediaAspectRatio && (isDesktopPortraitMedia || !isPortraitMedia) ? { aspectRatio: mediaAspectRatio, maxHeight: "68svh" } : undefined}
                            className={mediaAspectRatio === undefined || isDesktopPortraitMedia || !isPortraitMedia
                              ? "max-h-[68svh] w-full bg-black/5 object-contain"
                              : "max-h-96 w-full aspect-[4/3] object-cover sm:aspect-[16/9]"}
                          />
                        )
                      )}
                      <div className={`flex min-w-0 flex-col md:flex-row ${isDesktopPortraitMedia ? "md:col-start-2" : ""}`}>
                        {/* Item Image and Basic Info */}
                        <div className="min-w-0 flex-1 p-4 md:p-6 md:flex md:flex-col md:justify-between">
                          <div className="mb-4 flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                            <div className="flex min-w-0 items-start gap-3 md:items-center md:gap-4">
                              {!isVideoItem && !isDesktopPortraitMedia && <div className="shrink-0 text-4xl md:text-5xl" aria-hidden="true">{item.image}</div>}
                              <div className="min-w-0">
                                <div className="mb-1 flex flex-wrap items-start gap-2">
                                  {(!isVideoItem || !isMobilePortraitVideo) && (
                                    <h3 className="break-words text-lg font-bold text-sheraton-navy md:text-xl">
                                      {item.name}
                                    </h3>
                                  )}
                                  <div className="flex flex-wrap items-center gap-1.5" aria-label={`${item.name} status`}>
                                    {statusLabels.map((status) => (
                                      <Badge
                                        key={status}
                                        variant={status.toLowerCase() === "sold out" ? "destructive" : "outline"}
                                        className={status.toLowerCase() === "available" ? "border-green-600 text-green-700" : ""}
                                      >
                                        {status}
                                      </Badge>
                                    ))}
                                    {item.trending && (
                                      <Badge
                                        variant="secondary"
                                        className="border-transparent bg-destructive/10 text-destructive"
                                      >
                                        <TrendingUp className="h-3 w-3 mr-1" />
                                        Trending
                                      </Badge>
                                    )}
                                    {item.special_offer && (
                                      <Badge className="bg-sheraton-gold text-sheraton-navy">
                                        <Gift className="h-3 w-3 mr-1" />
                                        Promotion
                                      </Badge>
                                    )}
                                  </div>
                                </div>
                                <p className="mb-2 break-words text-sm text-muted-foreground md:text-base">
                                  {item.description}
                                </p>
                                <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
                                  <span className="flex items-center gap-1">
                                    <Clock className="h-4 w-4" />
                                    {item.cookTime}
                                  </span>
                                  <span className="flex items-center gap-1">
                                    <Globe className="h-4 w-4" />
                                    {item.origin}
                                  </span>
                                  <span className="flex items-center gap-1">
                                    <Apple className="h-4 w-4" />
                                    {item.calories} cal
                                  </span>
                                </div>
                              </div>
                            </div>

                            {/* Price and Availability */}
                            {(!isVideoItem || !isMobilePortraitVideo) && <div className="w-full text-left md:w-auto md:text-right">
                              <div className="mb-2 flex flex-wrap items-center gap-2">
                                {discountPercent > 0 && (
                                  <span className="text-sm text-muted-foreground line-through" aria-label={`Original price ${formatPrice(item.originalPrice, item.currency)}`}>
                                    {formatPrice(item.originalPrice, item.currency)}
                                  </span>
                                )}
                                <span className="text-2xl font-bold text-sheraton-navy" aria-label={`Current price ${formatPrice(item.price, item.currency)}`}>
                                  {formatPrice(item.price, item.currency)}
                                </span>
                                {discountPercent > 0 && (
                                  <Badge className="border-transparent bg-destructive/10 text-destructive">
                                    {discountPercent}% off
                                  </Badge>
                                )}
                              </div>
                              <div
                                className={`text-sm font-medium ${availability.color}`}
                                aria-label={`Availability: ${availability.message}`}
                              >
                                {availability.message}
                              </div>
                              {item.availability > 0 && (
                                <div className="text-xs text-muted-foreground mt-1">
                                  {item.availability} left
                                </div>
                              )}
                            </div>}
                          </div>

                          {/* Detailed Information */}
                          {(item.description_full !== item.description || item.chef_note) && (
                            <div className="mb-4 rounded-lg bg-muted/60 p-3 text-card-foreground md:p-4">
                              {item.description_full !== item.description && (
                                <p className="mb-2 break-words text-sm text-muted-foreground">
                                  {item.description_full}
                                </p>
                              )}
                              {item.chef_note && (
                                <div className="flex items-center gap-2 text-xs text-sheraton-gold">
                                  <ChefHat className="h-3 w-3" />
                                  <span className="break-words italic">{item.chef_note}</span>
                                </div>
                              )}
                            </div>
                          )}

                          {/* Tags and Dietary Info */}
                          <div className="mb-4 flex flex-wrap items-center gap-2">
                            <div className="flex items-center gap-1">
                              <Star className="h-4 w-4 text-yellow-500" />
                              <span className="text-sm">
                                {item.popularity}% loved
                              </span>
                            </div>
                            {item.dietary.includes("vegetarian") && (
                              <Badge
                                variant="outline"
                                className="text-green-600 border-green-600"
                              >
                                <Leaf className="h-3 w-3 mr-1" />
                                Vegetarian
                              </Badge>
                            )}
                            {item.dietary.includes("gluten-free") && (
                              <Badge
                                variant="outline"
                                className="text-blue-600 border-blue-600"
                              >
                                Gluten-Free
                              </Badge>
                            )}
                            {item.spiceLevel > 0 && (
                              <Badge
                                variant="outline"
                                className="text-red-600 border-red-600"
                              >
                                {Array(item.spiceLevel).fill("🌶️").join("")}
                              </Badge>
                            )}
                          </div>

                          {/* Special Offer */}
                          {item.special_offer && (
                            <div className="mb-4 rounded-lg border border-sheraton-gold/30 bg-sheraton-gold/10 p-2 md:p-3">
                              <div className="flex flex-wrap items-center gap-2 font-medium text-sheraton-gold">
                                <Gift className="h-4 w-4" />
                                <span>{item.special_offer}</span>
                              </div>
                            </div>
                          )}

                          {/* Add to Cart */}
                          <div className="flex flex-col items-stretch gap-3 md:flex-row md:items-center md:justify-between">
                            {(!isVideoItem || !isMobilePortraitVideo) && <div className="flex items-center gap-3">
                              {cartQuantity > 0 ? (
                                <div className="flex items-center gap-2">
                                  <Button
                                    size="sm"
                                    variant="outline"
                                    onClick={() => removeFromCart(item.id)}
                                  >
                                    <Minus className="h-4 w-4" />
                                  </Button>
                                  <span className="w-8 text-center font-medium">
                                    {cartQuantity}
                                  </span>
                                  <Button
                                    size="sm"
                                    variant="outline"
                                    onClick={() => addToCart(item.id)}
                                    disabled={item.availability === 0}
                                  >
                                    <Plus className="h-4 w-4" />
                                  </Button>
                                </div>
                              ) : (
                                <Button
                                  onClick={() => addToCart(item.id)}
                                  disabled={item.availability === 0}
                                  className="sheraton-gradient text-white"
                                >
                                  <Plus className="h-4 w-4 mr-2" />
                                  Add to Order
                                </Button>
                              )}
                            </div>}

                            {item.availability === 0 && (
                              <Button
                                variant="outline"
                                size="sm"
                                className="w-full border-sheraton-gold text-sheraton-gold md:w-auto"
                                disabled={availabilitySubscriptions.has(item.databaseId || "") || subscribingItemId === item.databaseId}
                                onClick={() => void requestMenuAvailability(item)}
                              >
                                <Bell className="mr-2 h-4 w-4" />
                                {subscribingItemId === item.databaseId
                                  ? "Saving request…"
                                  : availabilitySubscriptions.has(item.databaseId || "")
                                    ? "You’ll be notified"
                                    : "Notify When Available"}
                              </Button>
                            )}
                          </div>
                        </div>
                      </div>
                    </CardContent>
                  </Card>
                );
                })}
              </div>
            )}
          </div>
        </div>

        {/* Floating Cart */}
        {getTotalItems() > 0 && (
          <div className="fixed bottom-4 left-4 right-4 z-50 md:bottom-6 md:left-auto md:right-6">
            <Card className="sheraton-gradient border-0 text-white luxury-shadow">
              <CardContent className="p-3 md:p-4">
                <div className="flex items-center justify-between gap-2 md:gap-4">
                  <div className="relative">
                    <ShoppingCart className="h-6 w-6" />
                    <Badge className="absolute -top-2 -right-2 bg-white text-sheraton-navy min-w-[20px] h-5 p-0 flex items-center justify-center text-xs">
                      {getTotalItems()}
                    </Badge>
                  </div>
                  <div>
                    <div className="font-semibold">{formatCartTotal()}</div>
                    <div className="text-xs text-white/80">
                      {getTotalItems()} items
                    </div>
                  </div>
                  <Button
                    variant="secondary"
                    size="sm"
                    className="bg-white text-sheraton-navy hover:bg-white/90"
                    onClick={() => setShowCheckoutPage(true)}
                  >
                    Order Now
                  </Button>
                </div>
              </CardContent>
            </Card>
          </div>
        )}

        {/* QR Code Info */}
        <Card className="mt-12 bg-sheraton-navy text-white">
          <CardContent className="p-8 text-center">
            <QrCode className="h-16 w-16 mx-auto mb-4 text-sheraton-gold" />
            <h3 className="text-2xl font-bold mb-4">
              Skip the Wait, Order Like a Boss!
            </h3>
            <p className="text-white/80 mb-6 max-w-2xl mx-auto">
              Scan our table QR codes to instantly access this menu. Order ahead
              and arrive to find your food ready. No more waiting, no more
              explaining dishes to staff - everything is detailed here for you.
            </p>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 max-w-2xl mx-auto">
              <div className="text-center">
                <div className="text-2xl mb-2">⚡</div>
                <div className="font-semibold">Priority Service</div>
                <div className="text-sm text-white/70">
                  App orders come first
                </div>
              </div>
              <div className="text-center">
                <div className="text-2xl mb-2">🌱</div>
                <div className="font-semibold">Eco-Friendly</div>
                <div className="text-sm text-white/70">Zero paper waste</div>
              </div>
              <div className="text-center">
                <div className="text-2xl mb-2">👨‍🍳</div>
                <div className="font-semibold">Real-Time Updates</div>
                <div className="text-sm text-white/70">Live availability</div>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

    </div>
  );
};

export default MenuPage;
