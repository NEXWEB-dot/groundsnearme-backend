/**
 * Matchmaking ("open games").
 *
 * The feed is public — a visitor can browse who needs players before signing
 * up — but posting and joining require auth. Joining returns the host's
 * WhatsApp number so the UI can open the thread straight away, which is how the
 * mock cards behave.
 */

import { cached, json, unwrapRpc } from '../lib/http.js';
import { requireUser } from '../lib/auth.js';
import { sbRpc } from '../lib/supabase.js';
import { shapeList, shapeOpenGame, whatsappUrl } from '../lib/shape.js';
import { clockTime, int, isoDate, oneOf, readJson, str, uuid } from '../lib/validate.js';
import { enforceRateLimit } from '../lib/ratelimit.js';

const SKILLS = ['beginner', 'intermediate', 'advanced', 'any'];
const LOOKING = ['players', 'opposition'];

export async function listGames(request, env) {
  const q = new URL(request.url).searchParams;
  const payload = await sbRpc(env, 'list_open_games', {
    p_city:        str(q.get('city'), 'city', { required: false, max: 60 }) || 'Karachi',
    p_area:        str(q.get('area'), 'area', { required: false, max: 60 }),
    p_skill:       oneOf(q.get('skill'), 'skill', SKILLS),
    p_looking_for: oneOf(q.get('looking_for'), 'looking_for', LOOKING),
    p_from_date:   isoDate(q.get('from_date'), 'from_date', { required: false }),
    p_limit:       int(q.get('limit'), 'limit', { required: false, min: 1, max: 100 }) ?? 20,
    p_offset:      int(q.get('offset'), 'offset', { required: false, min: 0, max: 100000 }) ?? 0,
  });
  return cached(shapeList(payload, (row) => shapeOpenGame(env, row)), { seconds: 30 });
}

export async function createGame(request, env, { ctx }) {
  requireUser(ctx);
  await enforceRateLimit(request, env, ctx, { bucket: 'open_game', limit: 5, windowSeconds: 3600 });

  const body = await readJson(request);
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'create_open_game',
      {
        p_title:          str(body.title, 'title', { min: 6, max: 120 }),
        p_match_date:     isoDate(body.match_date ?? body.date, 'match_date'),
        p_looking_for:    oneOf(body.looking_for, 'looking_for', LOOKING, { fallback: 'players' }),
        p_skill_level:    oneOf(body.skill_level, 'skill_level', SKILLS, { fallback: 'any' }),
        p_players_needed: int(body.players_needed, 'players_needed', {
          required: false, min: 1, max: 22,
        }),
        p_start_time:     clockTime(body.start_time, 'start_time', { required: false }),
        p_format:         str(body.format, 'format', { required: false, max: 60 }),
        p_ground_id:      uuid(body.ground_id, 'ground_id', { required: false }),
        p_area_id:        uuid(body.area_id, 'area_id', { required: false }),
        p_notes:          str(body.notes, 'notes', { required: false, max: 1000 }),
      },
      { token: ctx.token },
    ),
    'game',
  );
  return json({ game: shapeOpenGame(env, payload) }, { status: 201 });
}

export async function joinGame(request, env, { ctx, params }) {
  requireUser(ctx);
  await enforceRateLimit(request, env, ctx, { bucket: 'interest', limit: 30, windowSeconds: 3600 });

  const body = request.headers.get('content-type') ? await readJson(request) : {};
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'express_interest',
      {
        p_open_game_id: uuid(params.id, 'id'),
        p_message: str(body.message, 'message', { required: false, max: 500 }),
      },
      { token: ctx.token },
    ),
  );

  return json({
    interest: payload.interest,
    interest_count: Number(payload.interest_count || 0),
    host_whatsapp_number: payload.host_whatsapp_number || null,
    host_whatsapp_url: whatsappUrl(payload.host_whatsapp_number, "Hi! I'm interested in your game on GroundsNearMe."),
  }, { status: 201 });
}

/** Host-side triage: accept or decline someone who put their hand up. */
export async function setInterestStatus(request, env, { ctx, params }) {
  requireUser(ctx);
  const body = await readJson(request);
  const payload = unwrapRpc(
    await sbRpc(
      env,
      'set_interest_status',
      {
        p_interest_id: uuid(params.id, 'id'),
        p_status: oneOf(body.status, 'status',
          ['interested', 'accepted', 'declined', 'withdrawn'], { required: true }),
      },
      { token: ctx.token },
    ),
  );
  return json({ id: payload.id, status: payload.status });
}
