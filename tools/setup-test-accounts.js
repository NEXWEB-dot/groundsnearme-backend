/**
 * Setup test accounts and link grounds for GroundsNearMe.
 * Idempotent: safe to re-run anytime.
 */

const SUPABASE_URL = 'https://mfybkflgkjpuqhlthagt.supabase.co';
const SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1meWJrZmxna2pwdXFobHRoYWd0Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4ODE3MTM3OCwiZXhwIjoyMTAzNzQ3Mzc4fQ.Q4mbuuOITqmBacJOsiN2V_ws6tj7xT_5Dv86Rh-L9iE';

const ACCOUNTS = [
  { email: 'owner_a@groundsnearme.pk', password: 'OwnerPassword123!', role: 'owner', name: 'Owner Alpha (Star & KCC)' },
  { email: 'owner_b@groundsnearme.pk', password: 'OwnerPassword123!', role: 'owner', name: 'Owner Beta (Champions)' },
  { email: 'admin@groundsnearme.pk', password: 'AdminPassword123!', role: 'admin', name: 'Staff Admin' },
  { email: 'player@groundsnearme.pk', password: 'PlayerPassword123!', role: 'player', name: 'Standard Player' },
];

async function main() {
  console.log('=== SETTING UP TEST ACCOUNTS & GROUND OWNERSHIP ===\n');

  // 1. Get existing users
  const resUsers = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
  });
  const { users } = await resUsers.json();
  const userMap = new Map((users || []).map(u => [u.email.toLowerCase(), u]));

  const createdIds = {};

  for (const acc of ACCOUNTS) {
    let user = userMap.get(acc.email.toLowerCase());
    if (!user) {
      console.log(`Creating user ${acc.email}...`);
      const createRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
        method: 'POST',
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          email: acc.email,
          password: acc.password,
          email_confirm: true,
          user_metadata: { account_type: acc.role, full_name: acc.name }
        })
      });
      user = await createRes.json();
      if (!user.id) {
        console.error(`Failed to create ${acc.email}:`, user);
        continue;
      }
    } else {
      console.log(`User ${acc.email} exists (${user.id}).`);
      // Ensure password is set to known test password
      await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${user.id}`, {
        method: 'PUT',
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ password: acc.password, email_confirm: true })
      });
    }

    createdIds[acc.email] = user.id;

    // Update profile role
    await fetch(`${SUPABASE_URL}/rest/v1/profiles?id=eq.${user.id}`, {
      method: 'PATCH',
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal'
      },
      body: JSON.stringify({
        role: acc.role,
        full_name: acc.name,
        is_active: true
      })
    });
    console.log(`  → Profile ${acc.email} updated to role '${acc.role}'`);
  }

  // 2. Link grounds
  console.log('\n=== LINKING GROUND OWNERSHIP ===');
  const groundsRes = await fetch(`${SUPABASE_URL}/rest/v1/grounds?select=id,slug,name,status`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
  });
  const grounds = await groundsRes.json();
  console.log(`Found ${grounds.length} grounds in database.`);

  const star = grounds.find(g => g.slug === 'star-indoor-cricket');
  const champions = grounds.find(g => g.slug === 'champions-arena');
  const kcc = grounds.find(g => g.slug === 'kcc-ground-nazimabad');

  const ownerAId = createdIds['owner_a@groundsnearme.pk'];
  const ownerBId = createdIds['owner_b@groundsnearme.pk'];

  if (star && ownerAId) {
    await fetch(`${SUPABASE_URL}/rest/v1/grounds?id=eq.${star.id}`, {
      method: 'PATCH',
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ owner_id: ownerAId })
    });
    console.log(`Assigned "${star.name}" (${star.slug}) to Owner A (${ownerAId})`);
  }

  if (kcc && ownerAId) {
    await fetch(`${SUPABASE_URL}/rest/v1/grounds?id=eq.${kcc.id}`, {
      method: 'PATCH',
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ owner_id: ownerAId })
    });
    console.log(`Assigned "${kcc.name}" (${kcc.slug}, status=${kcc.status}) to Owner A (${ownerAId})`);
  }

  if (champions && ownerBId) {
    await fetch(`${SUPABASE_URL}/rest/v1/grounds?id=eq.${champions.id}`, {
      method: 'PATCH',
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ owner_id: ownerBId })
    });
    console.log(`Assigned "${champions.name}" (${champions.slug}) to Owner B (${ownerBId})`);
  }

  console.log('\nSetup complete! All accounts and grounds are configured.');
}

main().catch(console.error);
