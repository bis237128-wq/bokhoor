CREATE OR REPLACE FUNCTION public.is_store_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
    SELECT COALESCE(auth.jwt() -> 'app_metadata' ->> 'store_admin', 'false') = 'true';
$$;

GRANT EXECUTE ON FUNCTION public.is_store_admin() TO anon, authenticated;

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_admin_products_read ON public.products;
CREATE POLICY store_admin_products_read
    ON public.products FOR SELECT TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS store_admin_products_insert ON public.products;
CREATE POLICY store_admin_products_insert
    ON public.products FOR INSERT TO authenticated
    WITH CHECK (public.is_store_admin());
DROP POLICY IF EXISTS store_admin_products_insert_guard ON public.products;
CREATE POLICY store_admin_products_insert_guard
    ON public.products AS RESTRICTIVE FOR INSERT TO anon, authenticated
    WITH CHECK (public.is_store_admin());

DROP POLICY IF EXISTS store_admin_products_update ON public.products;
CREATE POLICY store_admin_products_update
    ON public.products FOR UPDATE TO authenticated
    USING (public.is_store_admin())
    WITH CHECK (public.is_store_admin());
DROP POLICY IF EXISTS store_admin_products_update_guard ON public.products;
CREATE POLICY store_admin_products_update_guard
    ON public.products AS RESTRICTIVE FOR UPDATE TO anon, authenticated
    USING (public.is_store_admin())
    WITH CHECK (public.is_store_admin());

DROP POLICY IF EXISTS store_admin_products_delete ON public.products;
CREATE POLICY store_admin_products_delete
    ON public.products FOR DELETE TO authenticated
    USING (public.is_store_admin());
DROP POLICY IF EXISTS store_admin_products_delete_guard ON public.products;
CREATE POLICY store_admin_products_delete_guard
    ON public.products AS RESTRICTIVE FOR DELETE TO anon, authenticated
    USING (public.is_store_admin());

DROP POLICY IF EXISTS store_admin_reviews_read ON public.reviews;
CREATE POLICY store_admin_reviews_read
    ON public.reviews FOR SELECT TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS store_admin_reviews_insert ON public.reviews;
CREATE POLICY store_admin_reviews_insert
    ON public.reviews FOR INSERT TO authenticated
    WITH CHECK (public.is_store_admin());
DROP POLICY IF EXISTS store_admin_reviews_insert_guard ON public.reviews;
CREATE POLICY store_admin_reviews_insert_guard
    ON public.reviews AS RESTRICTIVE FOR INSERT TO anon, authenticated
    WITH CHECK (public.is_store_admin());

DROP POLICY IF EXISTS store_admin_reviews_update ON public.reviews;
CREATE POLICY store_admin_reviews_update
    ON public.reviews FOR UPDATE TO authenticated
    USING (public.is_store_admin())
    WITH CHECK (public.is_store_admin());
DROP POLICY IF EXISTS store_admin_reviews_update_guard ON public.reviews;
CREATE POLICY store_admin_reviews_update_guard
    ON public.reviews AS RESTRICTIVE FOR UPDATE TO anon, authenticated
    USING (public.is_store_admin())
    WITH CHECK (public.is_store_admin());

DROP POLICY IF EXISTS store_admin_reviews_delete ON public.reviews;
CREATE POLICY store_admin_reviews_delete
    ON public.reviews FOR DELETE TO authenticated
    USING (public.is_store_admin());
DROP POLICY IF EXISTS store_admin_reviews_delete_guard ON public.reviews;
CREATE POLICY store_admin_reviews_delete_guard
    ON public.reviews AS RESTRICTIVE FOR DELETE TO anon, authenticated
    USING (public.is_store_admin());

CREATE TABLE IF NOT EXISTS public.order_stock_deductions (
    order_number text PRIMARY KEY,
    phone text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.order_stock_deductions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_stock_deductions FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS order_stock_deductions_phone_created_at_idx
    ON public.order_stock_deductions (phone, created_at DESC);

CREATE OR REPLACE FUNCTION public.deduct_stock_for_order(p_order_number text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_items jsonb;
    v_phone text;
    v_claimed_order text;
    v_item record;
BEGIN
    IF p_order_number !~ '^BKH-[0-9]+-[A-Z0-9]{5}$' THEN
        RAISE EXCEPTION 'Invalid order number';
    END IF;

    SELECT o.items,
           regexp_replace(o.customer_phone, '\D', '', 'g')
      INTO v_items, v_phone
      FROM public.orders AS o
     WHERE o.order_number = p_order_number
     LIMIT 1
     FOR UPDATE;

    IF v_phone LIKE '0020%' THEN
        v_phone := substring(v_phone FROM 3);
    ELSIF v_phone LIKE '0%' THEN
        v_phone := '20' || substring(v_phone FROM 2);
    ELSIF length(v_phone) = 10 AND v_phone LIKE '1%' THEN
        v_phone := '20' || v_phone;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid or missing order';
    END IF;

    IF v_phone !~ '^201[0125][0-9]{8}$'
       OR jsonb_typeof(v_items) <> 'array' THEN
        RAISE EXCEPTION 'Invalid or missing order';
    END IF;

    IF jsonb_array_length(v_items) = 0 OR jsonb_array_length(v_items) > 50 THEN
        RAISE EXCEPTION 'Invalid or missing order';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM jsonb_array_elements(v_items) AS entries(item)
         WHERE COALESCE(item ->> 'product_id', '') !~ '^[0-9]+$'
            OR COALESCE(item ->> 'quantity', '') !~ '^[1-9][0-9]{0,2}$'
    ) THEN
        RAISE EXCEPTION 'Invalid order items';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_phone, 0));
    IF EXISTS (
        SELECT 1
          FROM public.order_stock_deductions
         WHERE phone = v_phone
           AND created_at > now() - interval '60 seconds'
    ) THEN
        RETURN false;
    END IF;

    INSERT INTO public.order_stock_deductions (order_number, phone)
    VALUES (p_order_number, v_phone)
    ON CONFLICT DO NOTHING
    RETURNING order_number INTO v_claimed_order;

    IF v_claimed_order IS NULL THEN
        RETURN false;
    END IF;

    FOR v_item IN
        SELECT (entry ->> 'product_id')::bigint AS product_id,
               sum((entry ->> 'quantity')::integer)::integer AS quantity
          FROM jsonb_array_elements(v_items) AS entries(item)
         GROUP BY (item ->> 'product_id')::bigint
         ORDER BY (item ->> 'product_id')::bigint
    LOOP
        UPDATE public.products
           SET stock_quantity = stock_quantity - v_item.quantity
         WHERE id = v_item.product_id
           AND stock_quantity >= v_item.quantity;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Insufficient stock or unknown product';
        END IF;
    END LOOP;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.deduct_stock_for_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.deduct_stock_for_order(text) TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.whatsapp_notification_dispatches (
    order_number text PRIMARY KEY,
    phone text NOT NULL,
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'sent', 'failed')),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS whatsapp_notification_dispatches_phone_created_at_idx
    ON public.whatsapp_notification_dispatches (phone, created_at DESC);

ALTER TABLE public.whatsapp_notification_dispatches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.whatsapp_notification_dispatches FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.whatsapp_notification_dispatches TO service_role;

CREATE OR REPLACE FUNCTION public.claim_whatsapp_notification(
    p_order_number text,
    p_phone text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_claimed_order text;
BEGIN
    IF p_order_number !~ '^BKH-[0-9]+-[A-Z0-9]{5}$'
       OR p_phone !~ '^201[0125][0-9]{8}$' THEN
        RAISE EXCEPTION 'Invalid notification request';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_phone, 0));

    IF EXISTS (
        SELECT 1
          FROM public.whatsapp_notification_dispatches
         WHERE phone = p_phone
           AND created_at > now() - interval '60 seconds'
    ) THEN
        RETURN false;
    END IF;

    INSERT INTO public.whatsapp_notification_dispatches (order_number, phone)
    VALUES (p_order_number, p_phone)
    ON CONFLICT DO NOTHING
    RETURNING order_number INTO v_claimed_order;

    RETURN v_claimed_order IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_whatsapp_notification(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_whatsapp_notification(text, text) TO service_role;
