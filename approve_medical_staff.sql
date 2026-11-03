do $$
declare
  v_emails text[] := array[
    'pipearlrr@gmail.com',
    'ingfahrakmark@gmail.com',
    'atchariya.pin@gmail.com',
    'narongrit.kaw@gmail.com',
    'jinnanicekrocd@gmail.com',
    'thichagornn2401@gmail.com',
    'thongdeenok1212@gmail.com',
    'bowonrat.bua@student.mahidol.edu',
    'bowonratbuasri@gmail.com'
  ];
  v_missing_emails text[];
begin
  select array_agg(requested.email order by requested.email)
  into v_missing_emails
  from unnest(v_emails) as requested(email)
  where not exists (
    select 1
    from auth.users as auth_user
    where lower(auth_user.email) = lower(requested.email)
  );

  if v_missing_emails is not null then
    raise exception 'Create these Supabase Auth users before granting medical staff access: %',
      array_to_string(v_missing_emails, ', ');
  end if;

  insert into public.staff_profiles (user_id, role, approved)
  select auth_user.id, 'medical_staff', true
  from auth.users as auth_user
  where lower(auth_user.email) = any (
    select lower(requested.email)
    from unnest(v_emails) as requested(email)
  )
  on conflict (user_id) do update
    set role = excluded.role,
        approved = excluded.approved;
end;
$$;
