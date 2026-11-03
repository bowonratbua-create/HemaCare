create table if not exists public.staff_profiles (
  user_id uuid primary key references auth.users (id) on delete restrict,
  role text not null check (role = 'medical_staff'),
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.patient_visits (
  id uuid primary key default gen_random_uuid(),
  hn text not null check (length(btrim(hn)) between 1 and 128),
  full_name text not null check (length(btrim(full_name)) between 1 and 200),
  age integer not null check (age between 0 and 130),
  sex text not null check (sex in ('ชาย', 'หญิง', 'หญิงตั้งครรภ์', 'อื่น ๆ')),
  weight numeric(6, 2) not null check (weight > 0),
  height numeric(6, 2) not null check (height > 0),
  symptoms text[] not null default '{}',
  history text[] not null default '{}',
  family_history text[] not null default '{}',
  classification text not null check (length(btrim(classification)) > 0),
  cbc jsonb not null check (jsonb_typeof(cbc) = 'object'),
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists patient_visits_hn_created_at_idx
  on public.patient_visits (lower(btrim(hn)), created_at desc);
create index if not exists patient_visits_name_created_at_idx
  on public.patient_visits (lower(btrim(full_name)), created_at desc);

create table if not exists public.patient_access_logs (
  id uuid primary key default gen_random_uuid(),
  staff_user_id uuid not null references auth.users (id) on delete restrict,
  action text not null check (action in ('search', 'view_history', 'save_visit')),
  patient_hn text,
  created_at timestamptz not null default now()
);

alter table public.staff_profiles enable row level security;
alter table public.patient_visits enable row level security;
alter table public.patient_access_logs enable row level security;

revoke all on table public.staff_profiles from anon, authenticated;
revoke all on table public.patient_visits from anon, authenticated;
revoke all on table public.patient_access_logs from anon, authenticated;
grant select on table public.staff_profiles to authenticated;
grant usage on schema public to authenticated;

create or replace function public.is_approved_medical_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_profiles as profile
    where profile.user_id = (select auth.uid())
      and profile.role = 'medical_staff'
      and profile.approved
  );
$$;

revoke all on function public.is_approved_medical_staff() from public, anon;
grant execute on function public.is_approved_medical_staff() to authenticated;

drop policy if exists "staff can read their own profile" on public.staff_profiles;
create policy "staff can read their own profile"
  on public.staff_profiles
  for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "approved staff can read patient visits" on public.patient_visits;
create policy "approved staff can read patient visits"
  on public.patient_visits
  for select
  to authenticated
  using (public.is_approved_medical_staff());

drop policy if exists "approved staff can insert patient visits" on public.patient_visits;
create policy "approved staff can insert patient visits"
  on public.patient_visits
  for insert
  to authenticated
  with check (public.is_approved_medical_staff() and created_by = (select auth.uid()));

create or replace function public.save_patient_visit(
  p_hn text,
  p_full_name text,
  p_age integer,
  p_sex text,
  p_weight numeric,
  p_height numeric,
  p_symptoms text[],
  p_history text[],
  p_family_history text[],
  p_classification text,
  p_cbc jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff_id uuid := (select auth.uid());
  v_visit_id uuid;
begin
  if v_staff_id is null or not public.is_approved_medical_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์บันทึกประวัติผู้ป่วย';
  end if;

  insert into public.patient_visits (
    hn,
    full_name,
    age,
    sex,
    weight,
    height,
    symptoms,
    history,
    family_history,
    classification,
    cbc,
    created_by
  )
  values (
    p_hn,
    p_full_name,
    p_age,
    p_sex,
    p_weight,
    p_height,
    coalesce(p_symptoms, '{}'),
    coalesce(p_history, '{}'),
    coalesce(p_family_history, '{}'),
    p_classification,
    p_cbc,
    v_staff_id
  )
  returning id into v_visit_id;

  insert into public.patient_access_logs (staff_user_id, action, patient_hn)
  values (v_staff_id, 'save_visit', p_hn);

  return v_visit_id;
end;
$$;

create or replace function public.search_patient_visits(p_query text)
returns table (
  hn text,
  full_name text,
  visit_count bigint,
  last_seen timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff_id uuid := (select auth.uid());
  v_query text := lower(btrim(coalesce(p_query, '')));
  v_has_exact_name boolean;
begin
  if v_staff_id is null or not public.is_approved_medical_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ค้นประวัติผู้ป่วย';
  end if;
  if length(v_query) < 2 then
    raise exception 'กรุณาค้นหาด้วย HN หรือชื่ออย่างน้อย 2 ตัวอักษร';
  end if;

  insert into public.patient_access_logs (staff_user_id, action)
  values (v_staff_id, 'search');

  with patient_groups as (
    select
      lower(btrim(visit.hn)) as hn_key,
      (array_agg(visit.hn order by visit.created_at desc))[1] as patient_hn,
      (array_agg(visit.full_name order by visit.created_at desc))[1] as patient_name,
      count(*) as total_visits,
      max(visit.created_at) as latest_visit,
      bool_or(lower(btrim(visit.full_name)) = v_query) as exact_name,
      bool_or(
        position(v_query in lower(visit.hn)) > 0
        or position(v_query in lower(visit.full_name)) > 0
      ) as partial_match
    from public.patient_visits as visit
    group by lower(btrim(visit.hn))
  )
  select coalesce(bool_or(patient_groups.exact_name), false)
  into v_has_exact_name
  from patient_groups;

  return query
  with patient_groups as (
    select
      lower(btrim(visit.hn)) as hn_key,
      (array_agg(visit.hn order by visit.created_at desc))[1] as patient_hn,
      (array_agg(visit.full_name order by visit.created_at desc))[1] as patient_name,
      count(*) as total_visits,
      max(visit.created_at) as latest_visit,
      bool_or(lower(btrim(visit.full_name)) = v_query) as exact_name,
      bool_or(
        position(v_query in lower(visit.hn)) > 0
        or position(v_query in lower(visit.full_name)) > 0
      ) as partial_match
    from public.patient_visits as visit
    group by lower(btrim(visit.hn))
  )
  select
    patient_groups.patient_hn,
    patient_groups.patient_name,
    patient_groups.total_visits,
    patient_groups.latest_visit
  from patient_groups
  where case
    when v_has_exact_name then patient_groups.exact_name
    else patient_groups.partial_match
  end
  order by patient_groups.patient_name
  limit 100;
end;
$$;

create or replace function public.get_patient_visit_history(p_hn text)
returns table (
  id uuid,
  created_at timestamptz,
  hn text,
  full_name text,
  age integer,
  sex text,
  weight numeric,
  height numeric,
  symptoms text[],
  history text[],
  family_history text[],
  classification text,
  cbc jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff_id uuid := (select auth.uid());
begin
  if v_staff_id is null or not public.is_approved_medical_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ดูประวัติผู้ป่วย';
  end if;
  if length(btrim(coalesce(p_hn, ''))) = 0 then
    raise exception 'ไม่พบ HN สำหรับค้นประวัติ';
  end if;

  insert into public.patient_access_logs (staff_user_id, action, patient_hn)
  values (v_staff_id, 'view_history', p_hn);

  return query
  select
    visit.id,
    visit.created_at,
    visit.hn,
    visit.full_name,
    visit.age,
    visit.sex,
    visit.weight,
    visit.height,
    visit.symptoms,
    visit.history,
    visit.family_history,
    visit.classification,
    visit.cbc
  from public.patient_visits as visit
  where lower(btrim(visit.hn)) = lower(btrim(p_hn))
  order by visit.created_at;
end;
$$;

revoke all on function public.save_patient_visit(text, text, integer, text, numeric, numeric, text[], text[], text[], text, jsonb) from public, anon;
revoke all on function public.search_patient_visits(text) from public, anon;
revoke all on function public.get_patient_visit_history(text) from public, anon;
grant execute on function public.save_patient_visit(text, text, integer, text, numeric, numeric, text[], text[], text[], text, jsonb) to authenticated;
grant execute on function public.search_patient_visits(text) to authenticated;
grant execute on function public.get_patient_visit_history(text) to authenticated;
