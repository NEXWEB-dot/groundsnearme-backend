-- ============================================================================
-- GroundsNearMe — 0008 · WhatsApp owner-onboarding intake + audit log
-- Owners message the WhatsApp deep link on the public site; staff log the
-- conversation here, then create the ground from the admin view.
-- ============================================================================

create table if not exists public.ground_leads (
  id                uuid primary key default gen_random_uuid(),
  owner_name        text,
  whatsapp_number   text not null,
  phone             text,
  ground_name       text,
  area_text         text,
  city              text not null default 'Karachi',
  asking_price      integer check (asking_price is null or asking_price > 0),
  source            text not null default 'whatsapp',
  status            public.lead_status not null default 'new',
  notes             text,
  assigned_to       uuid references public.profiles(id) on delete set null,
  created_ground_id uuid references public.grounds(id) on delete set null,
  first_contact_at  timestamptz,
  created_by        uuid references public.profiles(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ground_leads_whatsapp_format
    check (whatsapp_number ~ '^[0-9]{10,15}$')
);

comment on table public.ground_leads is
  'Manual intake queue for owner onboarding. Internal only — never public.';

create index if not exists ground_leads_status_idx on public.ground_leads (status, created_at desc);
create index if not exists ground_leads_wa_idx     on public.ground_leads (whatsapp_number);

drop trigger if exists ground_leads_set_updated_at on public.ground_leads;
create trigger ground_leads_set_updated_at
  before update on public.ground_leads
  for each row execute function public.tg_set_updated_at();

-- ---------------------------------------------------------------------------

create table if not exists public.audit_log (
  id          bigserial primary key,
  actor_id    uuid references public.profiles(id) on delete set null,
  actor_role  public.user_role,
  action      text not null,
  entity      text not null,
  entity_id   text,
  diff        jsonb,
  created_at  timestamptz not null default now()
);

comment on table public.audit_log is
  'Append-only trail for staff actions (ground created/approved, status flips).';

create index if not exists audit_log_entity_idx on public.audit_log (entity, entity_id, created_at desc);
create index if not exists audit_log_actor_idx  on public.audit_log (actor_id, created_at desc);

create or replace function public.log_audit(
  p_action    text,
  p_entity    text,
  p_entity_id text,
  p_diff      jsonb default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.audit_log (actor_id, actor_role, action, entity, entity_id, diff)
  values (auth.uid(), public.current_app_role(), p_action, p_entity, p_entity_id, p_diff);
$$;

-- Track every ground status transition automatically.
create or replace function public.tg_grounds_audit_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    perform public.log_audit('ground.created', 'grounds', new.id::text,
      jsonb_build_object('status', new.status, 'name', new.name));
  elsif new.status is distinct from old.status then
    perform public.log_audit('ground.status_changed', 'grounds', new.id::text,
      jsonb_build_object('from', old.status, 'to', new.status));
  end if;
  return null;
end
$$;

drop trigger if exists grounds_audit_status on public.grounds;
create trigger grounds_audit_status
  after insert or update of status on public.grounds
  for each row execute function public.tg_grounds_audit_status();
