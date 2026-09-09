/**
 * Request context + role gates.
 *
 * The app role lives in public.profiles, not in the JWT, so it is read once
 * per request and memoised. If a project later enables a custom access-token
 * hook that stamps `app_metadata.gnm_role`, that claim is used instead and the
 * extra round trip disappears — no route changes needed.
 */

import { ApiError } from './http.js';
import { bearerFrom, verifySupabaseJwt } from './jwt.js';
import { sbMaybeOne } from './supabase.js';

const ROLES = ['player', 'owner', 'admin', 'superadmin'];

export async function buildContext(request, env) {
  const token = bearerFrom(request);
  const claims = token ? await verifySupabaseJwt(token, env) : null;

  if (token && !claims) {
    throw new ApiError('AUTH_REQUIRED', 'Your session has expired. Sign in again.');
  }

  return {
    token,
    claims,
    userId: claims?.sub || null,
    _role: undefined,
  };
}

export function requireUser(ctx) {
  if (!ctx.userId) throw new ApiError('AUTH_REQUIRED', 'Sign in to continue.');
  return ctx.userId;
}

export async function roleOf(ctx, env) {
  if (ctx._role !== undefined) return ctx._role;
  if (!ctx.userId) {
    ctx._role = null;
    return null;
  }

  const claimed = ctx.claims?.app_metadata?.gnm_role;
  if (typeof claimed === 'string' && ROLES.includes(claimed)) {
    ctx._role = claimed;
    return claimed;
  }

  const profile = await sbMaybeOne(
    env,
    `profiles?select=role,is_active&id=eq.${encodeURIComponent(ctx.userId)}&limit=1`,
    { token: ctx.token },
  );

  if (profile && profile.is_active === false) {
    throw new ApiError('FORBIDDEN', 'This account is disabled.');
  }

  ctx._role = profile?.role || 'player';
  return ctx._role;
}

export async function requireRole(ctx, env, allowed) {
  requireUser(ctx);
  const role = await roleOf(ctx, env);
  if (!allowed.includes(role)) {
    throw new ApiError('FORBIDDEN', 'You do not have access to this.');
  }
  return role;
}

export const requireOwner      = (ctx, env) => requireRole(ctx, env, ['owner', 'admin', 'superadmin']);
export const requireStaff      = (ctx, env) => requireRole(ctx, env, ['admin', 'superadmin']);
export const requireSuperadmin = (ctx, env) => requireRole(ctx, env, ['superadmin']);
