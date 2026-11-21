-- Trigger function must not be callable through the API
revoke execute on function public.log_service_change() from public, anon, authenticated;

-- Move is_admin() out of the exposed API schema (policies follow automatically)
create schema if not exists private;
grant usage on schema private to anon, authenticated;
alter function public.is_admin() set schema private;
revoke execute on function private.is_admin() from public;
grant execute on function private.is_admin() to anon, authenticated;
