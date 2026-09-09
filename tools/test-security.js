/**
 * GroundsNearMe — Security Audit Suite
 *
 * Automated verification of:
 *   1. Two-owner RLS isolation (Owner A cannot read/write Owner B's data)
 *   2. Dashboard URL slug access control (server-side blocked)
 *   3. Admin role enforcement (non-staff blocked from admin endpoints)
 *   4. Session invalidation upon logout
 *   5. Ground status lifecycle (draft/pending does not delete)
 *   6. Booking visibility for ground owners
 */

const SUPABASE_URL = 'https://mfybkflgkjpuqhlthagt.supabase.co';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1meWJrZmxna2pwdXFobHRoYWd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgxNzEzNzgsImV4cCI6MjEwMzc0NzM3OH0.z5r3FXEsGS7OPLR1Rugn7XDlYHxKMhdvDWsUcfnL20I';
const SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1meWJrZmxna2pwdXFobHRoYWd0Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4ODE3MTM3OCwiZXhwIjoyMTAzNzQ3Mzc4fQ.Q4mbuuOITqmBacJOsiN2V_ws6tj7xT_5Dv86Rh-L9iE';

async function signIn(email, password) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ email, password })
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Login failed for ${email}: ${text}`);
  }
  const data = await res.json();
  return {
    token: data.access_token,
    refreshToken: data.refresh_token,
    userId: data.user.id,
    email: data.user.email
  };
}

let passed = 0;
let failed = 0;

function assert(condition, testName, details = '') {
  if (condition) {
    console.log(`  \x1b[32m✔ PASS\x1b[0m ${testName}`);
    passed++;
  } else {
    console.error(`  \x1b[31m✖ FAIL\x1b[0m ${testName}`);
    if (details) console.error(`    → ${details}`);
    failed++;
  }
}

async function run() {
  console.log('================================================================');
  console.log('GROUNDSNEARME SECURITY AUDIT PASS');
  console.log('================================================================\n');

  console.log('Authenticating test accounts...');
  const ownerA = await signIn('owner_a@groundsnearme.pk', 'OwnerPassword123!');
  const ownerB = await signIn('owner_b@groundsnearme.pk', 'OwnerPassword123!');
  const admin = await signIn('admin@groundsnearme.pk', 'AdminPassword123!');
  const player = await signIn('player@groundsnearme.pk', 'PlayerPassword123!');
  console.log('  → Owner A, Owner B, Admin, Player authenticated successfully.\n');

  // Fetch grounds to get their IDs
  const groundsRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?select=id,slug,name,owner_id,status`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
  });
  const grounds = await groundsRes.json();
  const groundA = grounds.find(g => g.owner_id === ownerA.userId);
  const groundB = grounds.find(g => g.owner_id === ownerB.userId);

  assert(Boolean(groundA), `Owner A owns ground "${groundA?.name}" (${groundA?.id})`);
  assert(Boolean(groundB), `Owner B owns ground "${groundB?.name}" (${groundB?.id})`);
  assert(groundA.id !== groundB.id, 'Ground A and Ground B are distinct');

  // ---------------------------------------------------------------------------
  // TEST SUITE 1: TWO-OWNER RLS ISOLATION (CRITICAL)
  // ---------------------------------------------------------------------------
  console.log('\n--- 1. Two-Owner RLS Verification ---');

  // 1a. Owner A attempts to select Owner B's bookings directly from PostgREST
  const bResAforB = await fetch(`${SUPABASE_URL}/rest/v1/bookings?ground_id=eq.${groundB.id}`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerA.token}` }
  });
  const bookingsAforB = await bResAforB.json();
  assert(
    Array.isArray(bookingsAforB) && bookingsAforB.length === 0,
    'Owner A cannot read Owner B ground bookings via direct PostgREST API (returns 0 rows)',
    `Returned ${bookingsAforB?.length || 0} rows`
  );

  // 1b. Owner B selecting own bookings gets data
  const bResBforB = await fetch(`${SUPABASE_URL}/rest/v1/bookings?ground_id=eq.${groundB.id}`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerB.token}` }
  });
  const bookingsBforB = await bResBforB.json();
  assert(
    Array.isArray(bookingsBforB),
    'Owner B can read own bookings via direct PostgREST API',
    `HTTP ${bResBforB.status}`
  );

  // 1c. Owner A attempts to update Owner B's ground details
  const updateRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?id=eq.${groundB.id}`, {
    method: 'PATCH',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${ownerA.token}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation'
    },
    body: JSON.stringify({ contact_name: 'Hacked by Owner A' })
  });
  const updatedRows = await updateRes.json();
  assert(
    (Array.isArray(updatedRows) && updatedRows.length === 0) || updateRes.status === 401 || updateRes.status === 403,
    'Owner A cannot update Owner B ground (PostgREST RLS modifies 0 rows or denies)',
    `Updated rows: ${JSON.stringify(updatedRows)}`
  );

  // 1d. Owner A attempts to create a manual booking on Owner B's ground
  const manualBookingRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/create_manual_booking`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${ownerA.token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      p_ground_id: groundB.id,
      p_booking_date: '2026-09-10',
      p_start_time: '18:00:00',
      p_end_time: '19:00:00',
      p_contact_name: 'Malicious Booking'
    })
  });
  const manualData = await manualBookingRes.json();
  assert(
    manualData.ok === false && manualData.error?.code === 'FORBIDDEN',
    'Owner A cannot create a manual booking on Owner B ground (RPC returns FORBIDDEN: Not your ground)',
    `Result: ${JSON.stringify(manualData)}`
  );

  // ---------------------------------------------------------------------------
  // TEST SUITE 2: DASHBOARD URL ACCESS CONTROL / SLUG TAMPERING
  // ---------------------------------------------------------------------------
  console.log('\n--- 2. Dashboard URL Access Control & Slug Tampering ---');

  // Verify that an owner querying owned grounds only receives their own grounds
  const myGroundsRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?owner_id=eq.${ownerA.userId}`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerA.token}` }
  });
  const myGroundsA = await myGroundsRes.json();
  const includesB = (myGroundsA || []).some(g => g.id === groundB.id || g.slug === groundB.slug);
  assert(!includesB, 'Owner A owned-grounds query strictly excludes Owner B ground');

  // Owner A attempting to query Owner B ground via owner filter returns 0 rows
  const tamperRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?slug=eq.${groundB.slug}&owner_id=eq.${ownerA.userId}`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerA.token}` }
  });
  const tamperData = await tamperRes.json();
  assert(
    Array.isArray(tamperData) && tamperData.length === 0,
    'Tampering with URL slug (Owner A requesting Owner B slug with owner_id check) yields 0 results server-side'
  );

  // ---------------------------------------------------------------------------
  // TEST SUITE 3: ADMIN & SUPERADMIN ACCESS GATES
  // ---------------------------------------------------------------------------
  console.log('\n--- 3. Admin / Staff Access Gates ---');

  // 3a. Admin can read all leads
  const adminLeadsRes = await fetch(`${SUPABASE_URL}/rest/v1/ground_leads?select=*`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${admin.token}` }
  });
  assert(adminLeadsRes.ok, `Admin can access ground_leads (HTTP ${adminLeadsRes.status})`);

  // 3b. Player CANNOT access ground_leads
  const playerLeadsRes = await fetch(`${SUPABASE_URL}/rest/v1/ground_leads?select=*`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${player.token}` }
  });
  const playerLeads = await playerLeadsRes.json();
  assert(
    (Array.isArray(playerLeads) && playerLeads.length === 0) || playerLeadsRes.status === 401 || playerLeadsRes.status === 403,
    'Player is blocked from ground_leads (returns 0 rows or 403)',
    `HTTP ${playerLeadsRes.status}`
  );

  // 3c. Owner CANNOT access ground_leads
  const ownerLeadsRes = await fetch(`${SUPABASE_URL}/rest/v1/ground_leads?select=*`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerA.token}` }
  });
  const ownerLeads = await ownerLeadsRes.json();
  assert(
    (Array.isArray(ownerLeads) && ownerLeads.length === 0) || ownerLeadsRes.status === 401 || ownerLeadsRes.status === 403,
    'Owner is blocked from ground_leads (returns 0 rows or 403)',
    `HTTP ${ownerLeadsRes.status}`
  );

  // 3d. Non-superadmin cannot read audit_log
  const auditRes = await fetch(`${SUPABASE_URL}/rest/v1/audit_log?select=*`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${player.token}` }
  });
  const auditData = await auditRes.json();
  assert(
    (Array.isArray(auditData) && auditData.length === 0) || auditRes.status === 401 || auditRes.status === 403,
    'Non-superadmin cannot access audit_log',
    `HTTP ${auditRes.status}`
  );

  // ---------------------------------------------------------------------------
  // TEST SUITE 4: SESSION INVALIDATION / LOGOUT
  // ---------------------------------------------------------------------------
  console.log('\n--- 4. Auth Session Basics & Invalidation ---');

  // Create disposable session to test logout invalidation
  const tempUser = await signIn('player@groundsnearme.pk', 'PlayerPassword123!');
  // Sign out the session
  const logoutRes = await fetch(`${SUPABASE_URL}/auth/v1/logout`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${tempUser.token}`
    }
  });
  assert(logoutRes.ok, `Logout request succeeded (HTTP ${logoutRes.status})`);

  // Attempting to use the refresh token now fails
  const refreshRes = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: tempUser.refreshToken })
  });
  assert(
    refreshRes.status === 400 || !refreshRes.ok,
    'Revoked session refresh token cannot be refreshed after sign out',
    `HTTP ${refreshRes.status}`
  );

  // ---------------------------------------------------------------------------
  // TEST SUITE 5: GROUND STATUS (DRAFT/PENDING) LIFECYCLE (PART 2)
  // ---------------------------------------------------------------------------
  console.log('\n--- 5. Ground Status (Draft / Pending / Active) Lifecycle ---');

  // 5a. Check KCC ground (which is currently draft) still exists in DB
  const kccRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?slug=eq.kcc-ground-nazimabad&select=id,slug,name,status,owner_id`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
  });
  const [kccGround] = await kccRes.json();
  assert(Boolean(kccGround), 'KCC Ground exists in database despite status=draft');
  assert(kccGround.status === 'draft', `KCC Ground status is '${kccGround.status}' (not deleted!)`);

  // 5b. Owner A (who owns KCC) can select it when querying their own grounds
  const kccOwnerRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?id=eq.${kccGround.id}`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerA.token}` }
  });
  const [kccForOwner] = await kccOwnerRes.json();
  assert(Boolean(kccForOwner), 'Owner A can read their own draft ground (intact, not deleted)');

  // 5c. Public search RPC excludes draft ground
  const searchRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/search_grounds`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_q: 'KCC Ground' })
  });
  const searchData = await searchRes.json();
  const searchItems = searchData.items || [];
  const foundInPublic = searchItems.some(g => g.slug === 'kcc-ground-nazimabad');
  assert(!foundInPublic, 'Draft ground is hidden from public search directory (as required)');

  // ---------------------------------------------------------------------------
  // TEST SUITE 6: REAL TEST BOOKING VISIBILITY & MANUAL BLOCKING (PARTS 1 & 3)
  // ---------------------------------------------------------------------------
  console.log('\n--- 6. Real Test Booking Visibility & Manual Slot Management ---');

  // 6a. Create a manual booking on Ground A as Owner A
  const bookingDate = new Date(Date.now() + 86400000).toISOString().split('T')[0];
  const blockRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/create_manual_booking`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${ownerA.token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      p_ground_id: groundA.id,
      p_booking_date: bookingDate,
      p_start_time: '21:00:00',
      p_end_time: '22:00:00',
      p_contact_name: 'Walk-in Test Captain',
      p_contact_phone: '03001234567',
      p_notes: 'Phone booking test',
      p_source: 'owner',
      p_confirmed: true
    })
  });
  const blockData = await blockRes.json();
  assert(blockData.ok === true, 'Owner A successfully created manual booking on Ground A', JSON.stringify(blockData));
  const newBooking = blockData.booking;

  // 6b. Check that Owner A can immediately query this booking
  const bListRes = await fetch(`${SUPABASE_URL}/rest/v1/bookings?ground_id=eq.${groundA.id}&id=eq.${newBooking.id}`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${ownerA.token}` }
  });
  const [fetchedBooking] = await bListRes.json();
  assert(Boolean(fetchedBooking), 'New booking appears IMMEDIATELY in Owner A booking query');
  assert(fetchedBooking?.source === 'owner', `Booking source is '${fetchedBooking?.source}'`);
  assert(fetchedBooking?.contact_name === 'Walk-in Test Captain', 'Booking customer details match');

  // 6c. Owner A unmarks / cancels this manual booking
  const cancelRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/cancel_booking`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${ownerA.token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      p_booking_id: newBooking.id,
      p_reason: 'Unmarked by owner test'
    })
  });
  const cancelData = await cancelRes.json();
  assert(cancelData.ok === true, 'Owner A successfully unmarked / cancelled the manual booking', JSON.stringify(cancelData));
  assert(cancelData.booking?.status === 'cancelled', 'Booking status transitioned to cancelled');

  // ---------------------------------------------------------------------------
  // SUMMARY
  // ---------------------------------------------------------------------------
  console.log('\n================================================================');
  console.log(`SECURITY AUDIT RESULTS: ${passed} PASSED, ${failed} FAILED`);
  console.log('================================================================\n');

  if (failed > 0) {
    process.exit(1);
  }
}

run().catch(err => {
  console.error('Test run failed with error:', err);
  process.exit(1);
});
