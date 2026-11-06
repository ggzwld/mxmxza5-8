import { memo, useMemo, useState } from "react";
import { addDays, format, startOfToday } from "date-fns";
import { Bed, CalendarDays, Users } from "lucide-react";
import { Calendar } from "../ui/calendar";
import { Button } from "../ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../ui/card";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "../ui/dialog";
import { Label } from "../ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "../ui/select";
import { cn } from "../../lib/utils";

type StayDateSelectorProps = {
  checkIn?: Date;
  checkOut?: Date;
  totalNights: number;
  onCheckInChange: (date: Date | undefined) => void;
  onCheckOutChange: (date: Date | undefined) => void;
  guests: string;
  onGuestsChange: (value: string) => void;
  roomCount: string;
  onRoomCountChange: (value: string) => void;
};

const today = startOfToday();
const rangeClasses = {
  stayStart: "rounded-l-full bg-sheraton-gold/20",
  stayMiddle: "rounded-none bg-sheraton-gold/20",
  stayEnd: "rounded-r-full bg-sheraton-gold/20",
};

const StayDateSelector = memo(function StayDateSelector({
  checkIn,
  checkOut,
  totalNights,
  onCheckInChange,
  onCheckOutChange,
  guests,
  onGuestsChange,
  roomCount,
  onRoomCountChange,
}: StayDateSelectorProps) {
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<"check-in" | "check-out">("check-in");
  const modifiers = useMemo(() => ({
    stayStart: checkIn,
    stayEnd: checkOut,
    stayMiddle: (date: Date) => Boolean(checkIn && checkOut && date > checkIn && date < checkOut),
  }), [checkIn, checkOut]);

  const handleDateSelect = (date?: Date) => {
    if (!date) return;
    if (step === "check-in") {
      onCheckInChange(date);
      setStep("check-out");
      return;
    }
    onCheckOutChange(date);
    setOpen(false);
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <Card className="border-border/70 shadow-sm">
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2"><CalendarDays className="h-5 w-5 text-sheraton-gold" />When would you like to stay?</CardTitle>
          <p className="text-sm text-muted-foreground">Choose your dates, guests, and rooms to see what’s available.</p>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-3 pt-0 lg:grid-cols-4">
          <div className="space-y-1.5">
            <Label>Check-in</Label>
            <DialogTrigger asChild>
              <Button type="button" id="booking-check-in" variant="outline" aria-label={`Choose check-in date${checkIn ? `, ${format(checkIn, "PPP")}` : ""}`} onClick={() => setStep("check-in")} className="h-12 w-full justify-start gap-2 rounded-lg px-3 text-left font-normal hover:border-sheraton-gold/50 hover:bg-sheraton-gold/5">
                <CalendarDays className="h-4 w-4 shrink-0 text-sheraton-gold" />
                <span className="truncate text-sm font-medium text-foreground">{checkIn ? format(checkIn, "MMM d") : "Select date"}</span>
              </Button>
            </DialogTrigger>
          </div>
          <div className="space-y-1.5">
            <Label>Check-out</Label>
            <DialogTrigger asChild>
              <Button type="button" id="booking-check-out" variant="outline" aria-label={`Choose check-out date${checkOut ? `, ${format(checkOut, "PPP")}` : ""}`} onClick={() => setStep(checkIn ? "check-out" : "check-in")} className="h-12 w-full justify-start gap-2 rounded-lg px-3 text-left font-normal hover:border-sheraton-gold/50 hover:bg-sheraton-gold/5">
                <CalendarDays className="h-4 w-4 shrink-0 text-sheraton-gold" />
                <span className="truncate text-sm font-medium text-foreground">{checkOut ? format(checkOut, "MMM d") : "Select date"}</span>
              </Button>
            </DialogTrigger>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="booking-guests">Guests</Label>
            <Select value={guests} onValueChange={onGuestsChange}>
              <SelectTrigger id="booking-guests" className="h-12 rounded-lg px-3"><span className="flex items-center gap-2"><Users className="h-4 w-4 text-sheraton-gold" /><SelectValue /></span></SelectTrigger>
              <SelectContent className="duration-100">{Array.from({ length: 20 }, (_, index) => String(index + 1)).map((count) => <SelectItem key={count} value={count}>{count} {count === "1" ? "guest" : "guests"}</SelectItem>)}</SelectContent>
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="booking-rooms">Rooms</Label>
            <Select value={roomCount} onValueChange={onRoomCountChange}>
              <SelectTrigger id="booking-rooms" className="h-12 rounded-lg px-3"><span className="flex items-center gap-2"><Bed className="h-4 w-4 text-sheraton-gold" /><SelectValue /></span></SelectTrigger>
              <SelectContent className="duration-100">{Array.from({ length: 10 }, (_, index) => String(index + 1)).map((count) => <SelectItem key={count} value={count}>{count} {count === "1" ? "room" : "rooms"}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        </CardContent>
      </Card>
      <DialogContent overlayClassName="data-[state=open]:animate-none data-[state=closed]:animate-none" className="left-0 top-auto bottom-0 max-h-[92dvh] w-full max-w-none translate-x-0 translate-y-0 overflow-y-auto rounded-t-2xl p-4 data-[state=open]:animate-none data-[state=closed]:animate-none sm:left-1/2 sm:top-1/2 sm:bottom-auto sm:w-fit sm:max-w-[calc(100vw_-_2rem)] sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-2xl sm:p-6">
        <DialogHeader className="pr-8 text-left">
          <DialogTitle className="text-xl">Choose your stay dates</DialogTitle>
          <DialogDescription>{step === "check-in" ? "Start by choosing the day you’ll arrive." : "Now choose the day you’ll check out."}</DialogDescription>
        </DialogHeader>
        <div className="grid grid-cols-2 gap-2 rounded-xl bg-muted/60 p-1">
          <Button type="button" variant={step === "check-in" ? "default" : "ghost"} onClick={() => setStep("check-in")} className={cn("h-auto min-h-14 flex-col items-start rounded-lg px-3 py-2 text-left", step === "check-in" && "bg-sheraton-navy text-white hover:bg-sheraton-navy")}>
            <span className="text-xs opacity-75">Check-in</span><span className="text-sm font-semibold">{checkIn ? format(checkIn, "EEE, MMM d") : "Select date"}</span>
          </Button>
          <Button type="button" variant={step === "check-out" ? "default" : "ghost"} onClick={() => setStep("check-out")} className={cn("h-auto min-h-14 flex-col items-start rounded-lg px-3 py-2 text-left", step === "check-out" && "bg-sheraton-navy text-white hover:bg-sheraton-navy")}>
            <span className="text-xs opacity-75">Check-out</span><span className="text-sm font-semibold">{checkOut ? format(checkOut, "EEE, MMM d") : "Select date"}</span>
          </Button>
        </div>
        <div className="flex justify-center rounded-xl border bg-card px-1 py-2 sm:px-3 sm:py-3">
          <Calendar
            mode="single"
            selected={step === "check-in" ? checkIn : checkOut}
            onSelect={handleDateSelect}
            disabled={{ before: step === "check-in" ? today : addDays(checkIn || today, 1) }}
            defaultMonth={checkIn || today}
            numberOfMonths={1}
            modifiers={modifiers}
            modifiersClassNames={rangeClasses}
            className="p-2 sm:p-3"
          />
        </div>
        <p className="border-t pt-4 text-sm text-muted-foreground" aria-live="polite">
          {checkIn && checkOut ? `${totalNights} ${totalNights === 1 ? "night" : "nights"} selected` : "Select a check-in and check-out date"}
        </p>
      </DialogContent>
    </Dialog>
  );
});

export default StayDateSelector;
