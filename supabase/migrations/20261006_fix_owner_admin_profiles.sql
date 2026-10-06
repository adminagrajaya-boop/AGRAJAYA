-- ==============================================================================
-- AGRA JAYA POS — PROFILE ROLE FIX MIGRATION
-- Target Database: PostgreSQL (Supabase Production)
-- Mode: Idempotent, Targeted Profile Role Fix
-- ==============================================================================

BEGIN;

-- 1. FIX OWNER PROFILE ROLE (arvendy.00581602@gmail.com / UID: 0041f669-01f0-4278-bad1-98244f0f362b)
INSERT INTO public.profiles (id, username, full_name, role, is_active)
VALUES ('0041f669-01f0-4278-bad1-98244f0f362b', 'arvendy.00581602', 'Dymas Danang', 'owner', true)
ON CONFLICT (id) DO UPDATE 
SET role = 'owner',
    is_active = true,
    updated_at = now();

-- 2. FIX / UPSERT ADMIN PROFILE ROLE (admin.agrajaya@gmail.com / UID: eb2fd85f-8c7f-4ce8-98ca-960b701bd7de)
INSERT INTO public.profiles (id, username, full_name, role, is_active)
VALUES ('eb2fd85f-8c7f-4ce7-98ca-960b701bd7de', 'admin.agrajaya', 'Admin Agra Jaya', 'admin', true)
ON CONFLICT (id) DO UPDATE 
SET role = 'admin',
    is_active = true,
    updated_at = now();

COMMIT;
