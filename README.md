# Supabase setup

This app uses Supabase Auth for individual staff accounts and Postgres RPCs for
patient record access. Do not put a Supabase `service_role` or secret key in
the browser.

## 1. Create and configure the project

1. Create a Supabase project approved by the organization responsible for the
   patient data. Configure the project's region, retention, backups, and access
   controls to meet that organization's requirements.
2. In the Supabase SQL Editor, run `schema.sql`.
3. In Authentication settings, disable public sign-ups. Administrators must
   create or invite each staff account; do not allow public self-registration.
4. Create each authorized staff member's Auth user before granting access.
   The currently provided staff list can be approved by running
   `approve_medical_staff.sql`. It checks that every listed Auth user exists
   before granting any of them access. For other staff, use this SQL with that
   user's Auth UUID:

   ```sql
   insert into public.staff_profiles (user_id, role, approved)
   values ('AUTH_USER_UUID', 'medical_staff', true);
   ```

   Approve or revoke access by changing the profile's `approved` value. Prefer
   disabling the Auth account when access must be revoked.
5. In Project Settings > API, copy the Project URL and publishable/anon key to
   `supabase-config.js`. These are browser-visible values; never use a
   `service_role` or secret key there.
6. Host this app over HTTPS and add the deployed origin to Supabase Auth's
   allowed Site URL and redirect URL settings. Do not use a `file://` URL for
   a shared deployment.

## Access model

- Users first choose a role. Medical staff sign in before the patient-entry
  form appears; approved staff open patient history from the form's search
  button. General users go directly to analysis without history access.
- General users can analyze a CBC in the browser, but the app does not save
  their report or show patient search/history.
- Staff sign-in alone is insufficient. A matching approved row in
  `staff_profiles` is also required.
- Patient visits are only saved and read through approved-staff RPCs. Direct
  table access is revoked from browser roles; row-level security is enabled.
- Search and history-view operations and saved visits are recorded in
  `patient_access_logs`. Browser clients cannot read or alter that audit table.

Existing records in browser `localStorage` are not migrated. Review and handle
them according to the organization's retention policy before using production
patient data.

Do not use real patient information until the organization has reviewed the
deployment, privacy, security, and applicable legal requirements.
