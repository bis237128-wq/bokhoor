-- Staged bridge for old direct inserts and new create-order inserts.
-- New orders carrying client_request_id use the Edge Function -> UltraMsg path.
-- Legacy rows without that key continue to use the existing DB trigger -> Make path.
-- This migration does not disable or delete the legacy trigger.
-- Apply only after the new Edge Function route is staged and verified.

alter function public.notify_make_on_new_order()
    set search_path = pg_catalog, public;

revoke execute on function public.notify_make_on_new_order()
    from public, anon, authenticated;

drop trigger if exists trigger_notify_make on public.orders;
create trigger trigger_notify_make
    after insert on public.orders
    for each row
    when (new.client_request_id is null)
    execute function public.notify_make_on_new_order();

comment on trigger trigger_notify_make on public.orders is
    'Legacy Make route for direct inserts only; create-order inserts are sent by the Edge Function.';
