alter table public.menu_items
  add column if not exists media_aspect_ratio double precision;

do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'menu_items_media_aspect_ratio_positive'
       and conrelid = 'public.menu_items'::regclass
  ) then
    alter table public.menu_items
      add constraint menu_items_media_aspect_ratio_positive
      check (media_aspect_ratio is null or media_aspect_ratio > 0);
  end if;
end;
$$;
