-- Keep the legacy order_details text column while adding structured order data.
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS order_number text,
    ADD COLUMN IF NOT EXISTS items jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.orders.order_number IS 'Store-generated order reference, e.g. BKH-...';
COMMENT ON COLUMN public.orders.items IS 'Structured ordered items; each item includes product name, variant, quantity, unit price, and subtotal.';
