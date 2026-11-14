-- Keep the existing database trigger as the only WhatsApp notification sender.
-- The Edge Function persists orders only; the trigger sends the insert event to Make.
-- It is intentionally installed without a condition, so all new orders follow the same route.

alter function public.notify_make_on_new_order()
    set search_path = pg_catalog, public;

revoke execute on function public.notify_make_on_new_order()
    from public, anon, authenticated;

drop trigger if exists trigger_notify_make on public.orders;
create trigger trigger_notify_make
    after insert on public.orders
    for each row
    execute function public.notify_make_on_new_order();

comment on trigger trigger_notify_make on public.orders is
    'Single order notification route: new order inserts are sent to Make.';
