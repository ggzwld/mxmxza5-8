import * as React from "react";
import { DayPicker } from "react-day-picker";

import { cn } from "../../lib/utils";
import { buttonVariants } from "./button";

export type CalendarProps = React.ComponentProps<typeof DayPicker>;

function Calendar({
  className,
  classNames,
  showOutsideDays = true,
  ...props
}: CalendarProps) {
  return (
    <DayPicker
      showOutsideDays={showOutsideDays}
      className={cn("p-3", className)}
      classNames={{
        root: "relative w-fit",
        months: "flex flex-col gap-6 sm:flex-row sm:gap-8",
        month: "space-y-3",
        month_caption: "relative flex h-10 items-center justify-center",
        caption_label: "text-sm font-semibold text-foreground",
        nav: "absolute inset-x-0 top-0 z-10 flex items-center justify-between",
        button_previous: cn(
          buttonVariants({ variant: "ghost", size: "icon" }),
          "h-8 w-8 rounded-full text-muted-foreground hover:bg-muted hover:text-foreground",
        ),
        button_next: cn(
          buttonVariants({ variant: "ghost", size: "icon" }),
          "h-8 w-8 rounded-full text-muted-foreground hover:bg-muted hover:text-foreground",
        ),
        chevron: "h-4 w-4",
        month_grid: "w-full border-collapse",
        weekdays: "flex",
        weekday: "w-10 text-center text-xs font-medium text-muted-foreground",
        weeks: "mt-2 space-y-1",
        week: "flex w-full",
        day: "relative h-10 w-10 p-0 text-center text-sm",
        day_button: cn(
          buttonVariants({ variant: "ghost" }),
          "h-10 w-10 rounded-full p-0 font-normal hover:bg-muted aria-selected:font-semibold",
        ),
        selected: "bg-sheraton-navy text-white hover:bg-sheraton-navy hover:text-white focus:bg-sheraton-navy focus:text-white",
        today: "font-semibold text-sheraton-gold ring-1 ring-inset ring-sheraton-gold/50",
        outside: "text-muted-foreground opacity-40",
        disabled: "cursor-not-allowed text-muted-foreground opacity-30",
        range_start: "day-range-start",
        range_end: "day-range-end",
        range_middle: "bg-sheraton-gold/15 text-foreground",
        hidden: "invisible",
        ...classNames,
      }}
      {...props}
    />
  );
}
Calendar.displayName = "Calendar";

export { Calendar };
